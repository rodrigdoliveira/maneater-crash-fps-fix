[CmdletBinding()]
param([string]$GameExecutable, [string]$SteamContextPath, [switch]$AutoApply, [switch]$AllowUntestedBuild, [switch]$DisallowUntestedBuild, [switch]$RenderPreview, [switch]$FromUpdater)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not [Environment]::Is64BitProcess -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Use Start.cmd on 64-bit Windows.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$local = Join-Path $root '.local'
try { [IO.Directory]::CreateDirectory($local) | Out-Null }
catch { [Windows.Forms.MessageBox]::Show('Extract this launcher into a writable folder, such as Downloads, then run Start.cmd again.','Launcher folder is not writable','OK','Error')|Out-Null; exit 1 }
$script:launcherLock=$null
$script:activeLock=$null;$script:elevatedChild=$null
if(-not$RenderPreview){
    if(-not$FromUpdater){
        try{$script:launcherLock=[IO.File]::Open((Join-Path $local 'update.lock'),'OpenOrCreate','ReadWrite','None')}
        catch{[Windows.Forms.MessageBox]::Show('Another launcher or updater is running. Close it first.','Launcher is open','OK','Information')|Out-Null;exit 1}
    }
    $activePath=Join-Path $local 'launcher-active.lock'
    if(-not[IO.File]::Exists($activePath)){$creation=[IO.File]::Open($activePath,'OpenOrCreate','ReadWrite','ReadWrite');$creation.Dispose()}
    $script:activeLock=[IO.File]::Open($activePath,'Open','Read','Read')
    $instance=[ordered]@{Root=$root.TrimEnd('\');Pid=$PID;StartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks}
    [IO.File]::WriteAllText((Join-Path $local 'launcher-instance.json'),($instance|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
}
$script:worker = $null; $script:requestPath = $null; $script:plan = $null; $script:action = ''; $script:lastMessage = ''; $script:steamExitPending=$false
$script:initialSteamContext=$null
if(-not [string]::IsNullOrWhiteSpace($SteamContextPath)){
    $contextFile=[IO.Path]::GetFullPath($SteamContextPath)
    if(-not $contextFile.StartsWith($local.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Steam context must be a private file in this launcher folder.'}
    $script:initialSteamContext=Get-Content -LiteralPath $contextFile -Raw|ConvertFrom-Json
}
$form = New-Object Windows.Forms.Form
$form.Text = 'Maneater Crash & FPS Fix - 0.9.2'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size(860,740)
$form.MinimumSize = New-Object Drawing.Size(820,780)
$form.Font = New-Object Drawing.Font('Segoe UI',10)
$form.BackColor = [Drawing.Color]::FromArgb(246,248,251)
$form.AutoScaleMode = 'Dpi'

function Add-Label { param([string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height) $control=New-Object Windows.Forms.Label; $control.Text=$Text; $control.SetBounds($X,$Y,$Width,$Height); $form.Controls.Add($control); return $control }
$title = Add-Label 'Make Maneater smoother. Apply the complete repair.' 24 20 812 38
$title.Font = New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold)
$subtitle = Add-Label 'Maneater is detected automatically. You can also choose its executable. Your current visuals and saves are preserved.' 24 65 812 48
$pathBox = New-Object Windows.Forms.TextBox; $pathBox.SetBounds(24,120,682,29); $pathBox.ReadOnly=$true; $pathBox.Anchor='Top,Left,Right'; $form.Controls.Add($pathBox)
$browse = New-Object Windows.Forms.Button; $browse.Text='Choose game...'; $browse.SetBounds(720,117,116,34); $browse.Anchor='Top,Right'; $form.Controls.Add($browse)
$list = New-Object Windows.Forms.ListView; $list.SetBounds(24,171,812,258); $list.View='Details'; $list.FullRowSelect=$true; $list.GridLines=$false; $list.HeaderStyle='Nonclickable'; $list.ShowItemToolTips=$true; $list.Anchor='Top,Left,Right'; $form.Controls.Add($list)
$list.Columns.Add('Fix',174) | Out-Null; $list.Columns.Add('Status',112) | Out-Null; $list.Columns.Add('What it changes',496) | Out-Null
function Set-FixRow { param([string]$Name,[string]$Status,[string]$Detail) $item=New-Object Windows.Forms.ListViewItem($Name); $item.SubItems.Add($Status)|Out-Null; $item.SubItems.Add($Detail)|Out-Null; $item.ToolTipText=$Detail; $list.Items.Add($item)|Out-Null }
function Show-DefaultRows {
    $list.Items.Clear()
    Set-FixRow 'Native FPS fix' 'Waiting' 'Installs the included mod; compatible engine calls redirect 60 FPS to 120 FPS.'
    Set-FixRow 'Character recovery' 'Waiting' 'Avoids repeated recovery-animation evaluation on the guarded path.'
    Set-FixRow 'Navigation' 'Waiting' 'Filters impossible connections while preserving native navigation results.'
    Set-FixRow 'Package loading' 'Waiting' 'Removes unused temporary string work; original loading remains in control.'
    Set-FixRow 'OpenSSL crash fix' 'Waiting' 'Sets the official compatibility flag for Maneater only.'
    Set-FixRow 'CPU scheduling' 'Detecting' 'Chooses performance cores and worker count where applicable.'
    Set-FixRow 'Ansel' 'Waiting' 'Disables the bundled photo-mode SDK; restore is available.'
    Set-FixRow 'Steam overlay' 'Waiting' 'Disables the overlay for Maneater only.'
}
Show-DefaultRows
$untested = New-Object Windows.Forms.CheckBox; $untested.Text='Allow an untested build'; $untested.SetBounds(24,442,650,24); $untested.Enabled=$false; $untested.Checked=-not $DisallowUntestedBuild; $form.Controls.Add($untested)
$status = Add-Label 'Select Maneater.exe or Maneater-Win64-Shipping.exe to get started.' 24 478 812 48
$status.Font = New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)
$bar = New-Object Windows.Forms.ProgressBar; $bar.SetBounds(24,542,812,7); $bar.Style='Blocks'; $bar.Anchor='Bottom,Left,Right'; $form.Controls.Add($bar)
$apply = New-Object Windows.Forms.Button; $apply.Text='Apply all fixes'; $apply.SetBounds(24,574,190,42); $apply.BackColor=[Drawing.Color]::FromArgb(20,98,155); $apply.ForeColor=[Drawing.Color]::White; $apply.FlatStyle='Flat'; $apply.Enabled=$false; $apply.Anchor='Bottom,Left'; $form.Controls.Add($apply)
$play = New-Object Windows.Forms.Button; $play.Text='Play Maneater'; $play.SetBounds(230,574,180,42); $play.Enabled=$false; $play.Anchor='Bottom,Left'; $form.Controls.Add($play)
$restore = New-Object Windows.Forms.Button; $restore.Text='Restore previous setup'; $restore.SetBounds(590,574,246,42); $restore.Enabled=$false; $restore.Anchor='Bottom,Right'; $form.Controls.Add($restore)
$note = Add-Label 'Includes the compiled mod and helper; no compiler download. Gameplay tested on the reference Steam build. Installed means files are present; activation is checked at startup. Keep this folder for Restore.' 24 633 812 72
$note.Anchor='Bottom,Left,Right'; $note.ForeColor=[Drawing.Color]::FromArgb(74,86,101)

function Get-SavedRepair {
    $state = Join-Path $local 'repair.json'
    if ([IO.File]::Exists($state)) { return Get-Content -LiteralPath $state -Raw | ConvertFrom-Json }
    return $null
}
function Test-SelectedBuildTested { if($null -eq $script:plan){return $false};if($null -ne $script:plan.Game.PSObject.Properties['TestedBuild']){return [bool]$script:plan.Game.TestedBuild};return $script:plan.Game.GameSHA256 -ceq 'CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0' }
function Update-ApplyEnabled { $apply.Enabled=($null -eq $script:worker -and -not $script:steamExitPending -and $null -ne $script:plan -and ((Test-SelectedBuildTested)-or $untested.Checked)) }
function Set-Busy { param([bool]$Busy) $browse.Enabled=-not $Busy; $apply.Enabled=(-not $Busy -and $null -ne $script:plan -and ((Test-SelectedBuildTested)-or $untested.Checked)); $untested.Enabled=(-not $Busy -and $null -ne $script:plan -and -not (Test-SelectedBuildTested)); $saved=Get-SavedRepair; $restore.Enabled=(-not $Busy -and $null -ne $saved -and $saved.Status -ne 'restored'); $play.Enabled=$false; $bar.Style=$(if($Busy){'Marquee'}else{'Blocks'}) }
function Start-RepairWorker {
    param([string]$Action)
    if ($null -ne $script:worker) { return }
    $script:action=$Action; $script:lastMessage=''; Set-Busy $true
    $script:requestPath=Join-Path $local ('request-' + [Guid]::NewGuid().ToString('N') + '.json')
    $request=[pscustomobject]@{ Action=$Action; GameExecutable=$pathBox.Text; SteamContext=$(if($null -ne $script:plan){$script:plan.SteamContext}else{$script:initialSteamContext}); AllowUntestedBuild=$untested.Checked; ExpectedGameSHA256=$(if($null -ne $script:plan){$script:plan.Game.GameSHA256}else{$null}) }
    [IO.File]::WriteAllText($script:requestPath,($request|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'scripts\Run-Repair.ps1')+'" -RequestPath "'+$script:requestPath+'"'
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.WindowStyle='Hidden'; $start.WorkingDirectory=$root
    $script:worker=New-Object Diagnostics.Process; $script:worker.StartInfo=$start
    if (-not $script:worker.Start()) { $script:worker=$null; Set-Busy $false; throw 'Could not start the repair worker.' }
}
function Show-Plan { param($Plan)
    $script:plan=$Plan; $list.Items.Clear()
    Set-FixRow 'Native FPS fix' $(if($Plan.Native.Action -eq 'None'){'Installed'}else{'Ready'}) 'Activation is checked at game startup; incompatible engine layouts pass through.'
    $previewState=$(if(Test-SelectedBuildTested){if($Plan.Native.Action -eq 'None'){'Installed'}else{'Ready'}}else{'Guarded'})
    Set-FixRow 'Character recovery' $previewState 'Recovery-animation lookup optimization with compatibility guards.'
    Set-FixRow 'Navigation' $previewState 'Scoped navigation filter; uncertain queries use original code.'
    Set-FixRow 'Package loading' $previewState 'Removes unused loading-label work; original loading order preserved.'
    Set-FixRow 'OpenSSL crash fix' 'Ready' 'Official flag applied through this game''s Steam launch options.'
    Set-FixRow 'CPU scheduling' $(if($Plan.Cpu.Apply){'Ready'}else{'Not needed'}) $Plan.Cpu.Description
    if($null -ne $Plan.PSObject.Properties['AnselDisposition'] -and $Plan.AnselDisposition -eq 'SkippedUnknownSDK'){Set-FixRow 'Ansel' 'Skipped' 'Unrecognized SDK preserved; this change will not be applied.'}
    else{Set-FixRow 'Ansel' $(if($Plan.Ansel.Action -eq 'None'){'Already absent'}else{'Ready'}) 'Disables the bundled photo-mode SDK with a reversible rename.'}
    Set-FixRow 'Steam overlay' 'Ready' 'Disables the overlay for Maneater only.'
    $tested=Test-SelectedBuildTested
    $untested.Enabled=-not $tested
    if($tested){$status.Text='Tested build found. Apply all applicable fixes in one step.'}
    else{$status.Text='Untested build. Apply will ask you to accept its compatibility warning; FPS may remain inactive.'}
    Update-ApplyEnabled
}
function Request-ExperimentalTrial {
    if(Test-SelectedBuildTested){return $true}
    if(-not $untested.Checked){$status.Text='Enable Allow an untested build before applying.';return $false}
    $message='This executable was not tested. The tested Steam build is 7837297. Fixes may not work on this version. The FPS hook will activate only if its engine checks pass; incompatible layouts stay inactive. Any unrecognized Ansel SDK is skipped. Backups and Restore remain available. Apply to this untested build?'
    return [Windows.Forms.MessageBox]::Show($form,$message,'Untested Maneater build','YesNo','Warning','Button2') -eq 'Yes'
}
function Request-SteamExit {
    if ($script:steamExitPending) { return $false }
    if (@(Get-Process -Name 'Maneater','Maneater-Win64-Shipping' -ErrorAction SilentlyContinue).Count) { [Windows.Forms.MessageBox]::Show($form,'Quit Maneater, then apply or restore the fixes.','Game is running','OK','Information')|Out-Null; return $false }
    if (-not @(Get-Process -Name 'steam','steamwebhelper' -ErrorAction SilentlyContinue).Count) { return $true }
    $otherGames=@(Get-ChildItem 'HKCU:\Software\Valve\Steam\Apps' -ErrorAction SilentlyContinue | ForEach-Object { $p=Get-ItemProperty $_.PSPath; if ($null -ne $p.PSObject.Properties['Running'] -and $p.Running -eq 1) { $_.PSChildName } })
    if ($otherGames.Count) { [Windows.Forms.MessageBox]::Show($form,'Close running Steam games first. The launcher will not force them to exit.','Steam game is running','OK','Information')|Out-Null; return $false }
    $choice=[Windows.Forms.MessageBox]::Show($form,'Steam must exit briefly to save Maneater''s settings. Close Steam now? Downloads will pause; Play starts Steam again.','Save Steam settings','YesNo','Information')
    if ($choice -ne 'Yes') { return $false }
    if ($null -eq $script:plan) {
        Import-Module (Join-Path $root 'scripts\SteamFix.psm1') -Force
        $steam=$(if($null -ne $script:initialSteamContext){Get-SteamFixContext -Context $script:initialSteamContext}else{Get-SteamFixContext})
    } else { $steam=$script:plan.SteamContext }
    $script:steamExitPending=$true; Set-Busy $true
    try {
        Start-Process -FilePath $steam.SteamExe -ArgumentList '-shutdown' -WindowStyle Hidden | Out-Null
        $status.Text='Waiting for Steam to exit...'; $form.Refresh()
        $deadline=[DateTime]::UtcNow.AddSeconds(20)
        while (@(Get-Process -Name 'steam','steamwebhelper' -ErrorAction SilentlyContinue).Count -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
        if (@(Get-Process -Name 'steam','steamwebhelper' -ErrorAction SilentlyContinue).Count) { [Windows.Forms.MessageBox]::Show($form,'Steam is still running. Exit it from its menu, then retry.','Steam is running','OK','Information')|Out-Null; return $false }
    } finally { $script:steamExitPending=$false; Set-Busy $false }
    return $true
}
$browse.Add_Click({
    try {
        $picker=New-Object Windows.Forms.OpenFileDialog; $picker.Title='Choose your Maneater executable'; $picker.Filter='Maneater executables|Maneater.exe;Maneater-Win64-Shipping.exe|Executable files|*.exe'
        if ($picker.ShowDialog($form) -eq 'OK') { $pathBox.Text=$picker.FileName; $script:plan=$null; Start-RepairWorker 'Plan' }
        $picker.Dispose()
    } catch { $status.Text=$_.Exception.Message }
})
$untested.Add_CheckedChanged({Update-ApplyEnabled})
$apply.Add_Click({ try { if((Request-ExperimentalTrial)-and (Request-SteamExit)){Start-RepairWorker 'Apply'} } catch { $status.Text=$_.Exception.Message } })
$restore.Add_Click({ try { if(Request-SteamExit){Start-RepairWorker 'Restore'} } catch { $status.Text=$_.Exception.Message } })
$play.Add_Click({ try { Start-Process 'steam://rungameid/629820' | Out-Null; $status.Text='Starting Maneater through Steam...' } catch { $status.Text=$_.Exception.Message } })
$timer=New-Object Windows.Forms.Timer; $timer.Interval=250
$timer.Add_Tick({
    if($null-ne$script:elevatedChild){if($script:elevatedChild.HasExited){$form.Close()};return}
    if ($null -eq $script:worker) { return }
    try {
        $progressPath=$script:requestPath+'.progress.json'
        if ([IO.File]::Exists($progressPath)) {
            $message=(Get-Content -LiteralPath $progressPath -Raw|ConvertFrom-Json).Message
            if ($message -ne $script:lastMessage) { $status.Text=$message; $script:lastMessage=$message }
        }
        if (-not $script:worker.HasExited) { return }
        $resultPath=$script:requestPath+'.result.json'
        if (-not [IO.File]::Exists($resultPath)) { throw 'Repair worker stopped without a result. Use Restore if an installation was interrupted.' }
        $result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json
        $script:worker.Dispose(); $script:worker=$null; Set-Busy $false
        if (-not $result.Success) {
            $status.Text=$result.Message
            if ($result.Message -like 'Write permission is required*') {
                $choice=[Windows.Forms.MessageBox]::Show($form,'Windows requires administrator access to this game folder. Restart this launcher with administrator access?','Write permission','YesNo','Information')
                if($choice -eq 'Yes') {
                    $powerShell=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
                    $contextFile=Join-Path $local ('steam-context-'+[Guid]::NewGuid().ToString('N')+'.json')
                    [IO.File]::WriteAllText($contextFile,($script:plan.SteamContext|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
                    $arguments='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $root 'Launcher.ps1')+'" -GameExecutable "'+$pathBox.Text+'" -SteamContextPath "'+$contextFile+'" -AutoApply -FromUpdater'
                    if($untested.Checked){$arguments+=' -AllowUntestedBuild'}else{$arguments+=' -DisallowUntestedBuild'}
                    $script:elevatedChild=Start-Process -FilePath $powerShell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru; $form.Hide()
                }
            }
        } elseif ($script:action -eq 'Detect') {
            $status.Text=$result.Result.Reason
            if($result.Result.Found){$pathBox.Text=$result.Result.Executable;Start-RepairWorker 'Plan'}
        } elseif ($script:action -eq 'Plan') {
            Show-Plan $result.Result
            if ($AutoApply) { $script:AutoApply=$false; if((Request-ExperimentalTrial)-and (Request-SteamExit)){Start-RepairWorker 'Apply'} }
        } elseif ($script:action -eq 'Verify') {
            $apply.Enabled=$false
            if($result.Result.Valid){$status.Text=$(if(Test-SelectedBuildTested){'Setup is installed. FPS activation is checked when Maneater starts.'}else{'Setup is installed for this untested build. FPS may remain inactive if engine checks fail.'});$play.Enabled=$true;foreach($row in $list.Items){if($row.SubItems[1].Text -eq 'Ready'){$row.SubItems[1].Text=$(if($row.Text -in @('Native FPS fix','Character recovery','Navigation','Package loading')){'Installed'}else{'Applied'})}}}
            else{$status.Text='The setup changed: '+$result.Result.Reason+' Use Restore, then apply again.'}
            if($result.Result.Valid-and$null-ne$result.Result.PSObject.Properties['BundleUpdateAvailable']-and$result.Result.BundleUpdateAvailable){$status.Text='Launcher updated. Click Apply all fixes to update the game setup.';$apply.Enabled=$true}
        } elseif ($script:action -eq 'Apply') {
            $script:plan=$result.Result.Plan
            $status.Text=$(if(Test-SelectedBuildTested){'Setup installed. Play Maneater; FPS activation is checked at startup.'}else{'Setup installed for this untested build. FPS may remain inactive if engine checks fail.'}); $play.Enabled=$true; $apply.Enabled=$false
            foreach($row in $list.Items){if($row.SubItems[1].Text -eq 'Ready'){$row.SubItems[1].Text=$(if($row.Text -in @('Native FPS fix','Character recovery','Navigation','Package loading')){'Installed'}else{'Applied'})}}
        } else { $status.Text=$(if(@($result.Result.Warnings).Count){'Restored our changes; kept settings you changed afterward.'}else{'Previous setup restored. You can apply the fixes again whenever you want.'}); Show-DefaultRows; $script:plan=$null; $apply.Enabled=$false; if(-not [string]::IsNullOrWhiteSpace($pathBox.Text)){Start-RepairWorker 'Plan'} }
    } catch { $status.Text=$_.Exception.Message; if($null -ne $script:worker -and $script:worker.HasExited){$script:worker.Dispose();$script:worker=$null;Set-Busy $false} }
})
$timer.Start()
$form.Add_FormClosing({param($sender,$eventArgs) if($script:steamExitPending -or ($null -ne $script:worker -and -not $script:worker.HasExited)){$eventArgs.Cancel=$true;[Windows.Forms.MessageBox]::Show($form,'Wait for the current operation to finish.','Repair is running','OK','Information')|Out-Null}})
$form.Add_Shown({
    if($RenderPreview){return}
    if (-not [string]::IsNullOrWhiteSpace($GameExecutable)) { $pathBox.Text=$GameExecutable; Start-RepairWorker 'Plan' }
    else {
        $saved=Get-SavedRepair
        if($null -ne $saved -and $saved.Status -eq 'applied'){ $pathBox.Text=$saved.Plan.Game.Executable; $script:plan=$saved.Plan; Show-Plan $saved.Plan; $status.Text='Checking the applied repair...'; Start-RepairWorker 'Verify' }
        elseif($null -ne $saved -and $saved.Status -ne 'restored'){ $status.Text='An interrupted operation needs recovery. Click Restore previous setup.'; $restore.Enabled=$true }
        else{Start-RepairWorker 'Detect'}
    }
})
try {
    if ($RenderPreview) {
        # Render this app's own controls without reading or controlling the desktop.
        $form.StartPosition='Manual'; $form.Location=New-Object Drawing.Point(-2000,-2000); $form.ShowInTaskbar=$false
        $form.Show(); [Windows.Forms.Application]::DoEvents()
        $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $root 'dist\launcher-preview.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
    } else { [Windows.Forms.Application]::Run($form) }
} finally {
    $timer.Stop(); $timer.Dispose(); $form.Dispose()
    if(-not$RenderPreview){
        $instancePath=Join-Path $local 'launcher-instance.json'
        try{if([IO.File]::Exists($instancePath)-and(Get-Content $instancePath -Raw|ConvertFrom-Json).Pid-eq$PID){[IO.File]::Delete($instancePath)}}catch{}
    }
    if($script:launcherLock){$script:launcherLock.Dispose()}
    if($script:activeLock){$script:activeLock.Dispose()};if($script:elevatedChild){$script:elevatedChild.Dispose()}
}
