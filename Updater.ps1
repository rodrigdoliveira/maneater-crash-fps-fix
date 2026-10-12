[CmdletBinding()]
param([switch]$Worker,[string]$RequestPath,[switch]$RenderPreview)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$local=Join-Path $root '.local'
Import-Module (Join-Path $root 'scripts/Update.psm1') -Force
if($Worker){
    $request=[IO.Path]::GetFullPath($RequestPath)
    if(-not$request.StartsWith($local+'\',[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($request)-cnotmatch'^update-request-[0-9a-f]{32}\.json$'){throw 'Invalid updater request path.'}
    try{
        $result=Invoke-LauncherUpdate -Root $root -Progress {param($message) Write-UpdateJson ($request+'.progress.json') ([pscustomobject]@{Message=$message})}
        Write-UpdateJson ($request+'.result.json') ([pscustomobject]@{Success=$true;Result=$result;CanOpen=$true;Message=$result.Message})
    }catch{
        $failure=$_.Exception.Message
        $canOpen=$false
        try{$null=Read-UpdateLedger $root -VerifyFiles;$canOpen=$true}catch{}
        Write-UpdateJson ($request+'.result.json') ([pscustomobject]@{Success=$false;Result=$null;CanOpen=$canOpen;Message=$failure})
    }
    exit
}
if(-not[Environment]::Is64BitProcess){throw 'Use Start.cmd on 64-bit Windows.'}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
if(-not$RenderPreview){[IO.Directory]::CreateDirectory($local)|Out-Null}
$script:lock=$null;$script:activeGuard=$null;$script:updateWorker=$null;$script:launcher=$null;$script:request='';$script:started=$false
$form=New-Object Windows.Forms.Form
$form.Text='Maneater Crash & FPS Fix - Updater';$form.StartPosition='CenterScreen'
$form.ClientSize=New-Object Drawing.Size(570,190);$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
$title=New-Object Windows.Forms.Label;$title.Text='Checking for launcher updates';$title.Font=New-Object Drawing.Font('Segoe UI',14,[Drawing.FontStyle]::Bold);$title.SetBounds(22,20,525,32);$form.Controls.Add($title)
$status=New-Object Windows.Forms.Label;$status.Text='Updates are downloaded from the official GitHub releases.';$status.SetBounds(22,64,525,48);$form.Controls.Add($status)
$bar=New-Object Windows.Forms.ProgressBar;$bar.SetBounds(22,122,525,7);$bar.Style='Marquee';$form.Controls.Add($bar)
$open=New-Object Windows.Forms.Button;$open.Text='Open installed version';$open.SetBounds(332,146,215,30);$open.Visible=$false;$form.Controls.Add($open)
$powerShell=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell/v1.0/powershell.exe'
function Test-LauncherRunning {
    $path=Join-Path $local 'launcher-instance.json'
    if(-not[IO.File]::Exists($path)){return $false}
    try{
        $instance=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
        if($instance.Root-ine$root-or$instance.Pid-le0){return $false}
        $process=Get-Process -Id $instance.Pid -ErrorAction Stop
        return $process.StartTime.ToUniversalTime().Ticks-eq[long]$instance.StartTicks
    }catch{return $false}
}
function Start-UpdateWorker {
    $script:started=$true
    $script:request=Join-Path $local ('update-request-'+[Guid]::NewGuid().ToString('N')+'.json')
    Write-UpdateJson $script:request ([pscustomobject]@{Action='UpdateBeforeLaunch'})
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$powerShell;$start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Updater.ps1')+'" -Worker -RequestPath "'+$script:request+'"'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle='Hidden';$start.WorkingDirectory=$root
    $script:updateWorker=New-Object Diagnostics.Process;$script:updateWorker.StartInfo=$start
    if(-not$script:updateWorker.Start()){throw 'Could not start the update check.'}
}
function Open-Launcher {
    if($script:activeGuard){$script:activeGuard.Dispose();$script:activeGuard=$null}
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$powerShell;$start.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $root 'Launcher.ps1')+'" -FromUpdater'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle='Hidden';$start.WorkingDirectory=$root
    $script:launcher=New-Object Diagnostics.Process;$script:launcher.StartInfo=$start
    if(-not$script:launcher.Start()){throw 'Could not open the launcher.'}
    $form.Hide()
}
$open.Add_Click({try{Open-Launcher}catch{$status.Text=$_.Exception.Message}})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=250
$timer.Add_Tick({
    if($RenderPreview){return}
    try{
        if($null-ne$script:launcher){if($script:launcher.HasExited){$form.Close()};return}
        if(-not$script:started){
            if(Test-LauncherRunning){$status.Text='Close the open launcher to check for updates.';return}
            try{$script:lock=[IO.File]::Open((Join-Path $local 'update.lock'),'OpenOrCreate','ReadWrite','None')}catch [IO.IOException]{$status.Text='Waiting for the other launcher or updater to close...';return}
            if(Test-LauncherRunning){$script:lock.Dispose();$script:lock=$null;return}
            try{$script:activeGuard=[IO.File]::Open((Join-Path $local 'launcher-active.lock'),'OpenOrCreate','ReadWrite','None')}
            catch [IO.IOException]{$script:lock.Dispose();$script:lock=$null;$status.Text='Waiting for the open launcher operation to finish...';return}
            Start-UpdateWorker
        }
        if($null-eq$script:updateWorker){return}
        $progress=$script:request+'.progress.json'
        if([IO.File]::Exists($progress)){$status.Text=(Get-Content -LiteralPath $progress -Raw|ConvertFrom-Json).Message}
        if(-not$script:updateWorker.HasExited){return}
        $resultPath=$script:request+'.result.json'
        $script:updateWorker.Dispose();$script:updateWorker=$null;$bar.Style='Blocks'
        if(-not[IO.File]::Exists($resultPath)){throw 'The updater stopped. Reopen Start.cmd to recover an interrupted update.'}
        $result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json
        if($result.Success){$status.Text=$result.Message;Open-Launcher}
        elseif($result.CanOpen){$status.Text='Update check could not finish. '+$result.Message;$open.Visible=$true}
        else{$status.Text=$result.Message;$title.Text='Update needs recovery'}
    }catch{$status.Text=$_.Exception.Message;$bar.Style='Blocks'}
})
$form.Add_FormClosing({param($sender,$eventArgs) if($null-ne$script:updateWorker-and-not$script:updateWorker.HasExited){$eventArgs.Cancel=$true;$status.Text='Please wait for the updater to finish safely.'}})
if($RenderPreview){
    $form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-2000,-2000);$form.ShowInTaskbar=$false
    $form.Show();[Windows.Forms.Application]::DoEvents()
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try{[IO.Directory]::CreateDirectory((Join-Path $root 'dist'))|Out-Null;$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $root 'dist/updater-preview.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose();$form.Dispose()}
    exit
}
$timer.Start()
try{[Windows.Forms.Application]::Run($form)}finally{
    $timer.Stop();$timer.Dispose()
    if($script:updateWorker){$script:updateWorker.Dispose()};if($script:launcher){$script:launcher.Dispose()};if($script:activeGuard){$script:activeGuard.Dispose()};if($script:lock){$script:lock.Dispose()}
    $form.Dispose()
}
