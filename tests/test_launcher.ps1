[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scratch=Join-Path $PSScriptRoot ('.tmp-'+[Guid]::NewGuid().ToString('N'))
$fixture=Join-Path $scratch 'launcher'
$powershell=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$passed=0; $lock=$null
function Assert-Test {param([bool]$Condition,[string]$Message) if(-not $Condition){throw "FAIL: $Message"};$script:passed++}
function Run-Request {param([string]$Action,[string]$Game='')
    $path=Join-Path $fixture ('.local\request-'+[Guid]::NewGuid().ToString('N')+'.json')
    [IO.File]::WriteAllText($path,(@{Action=$Action;GameExecutable=$Game;SteamContext=$null}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'scripts\Run-Repair.ps1') -RequestPath $path
    Assert-Test ([IO.File]::Exists($path+'.result.json')) 'worker commits an actionable result'
    return Get-Content -LiteralPath ($path+'.result.json') -Raw|ConvertFrom-Json
}
try {
    [IO.Directory]::CreateDirectory((Join-Path $fixture '.local'))|Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'dist'))|Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'scripts') -Destination $fixture -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'Launcher.ps1') -Destination $fixture
    $exe=Join-Path $scratch 'Maneater.exe';[IO.File]::WriteAllText($exe,'unsupported fixture')
    $before=(Get-FileHash -LiteralPath $exe).Hash
    $result=Run-Request 'Plan' $exe
    Assert-Test (-not $result.Success -and $result.Message -like '*unsupported*') 'unsupported executable fails before touching Steam or the game'
    Assert-Test ((Get-FileHash -LiteralPath $exe).Hash -ceq $before) 'selected unsupported executable unchanged'
    Assert-Test (-not [IO.File]::Exists((Join-Path $fixture '.local\repair.json'))) 'plan creates no installation journal'
    $result=Run-Request 'Unexpected'
    Assert-Test (-not $result.Success -and $result.Message -eq 'Unknown repair action.') 'unknown action rejected'
    $lock=[IO.File]::Open((Join-Path $fixture '.local\repair.lock'),'OpenOrCreate','ReadWrite','None')
    $result=Run-Request 'Plan' $exe
    Assert-Test (-not $result.Success -and $result.Message -like 'Another repair operation*') 'concurrent workers fail closed'
    $lock.Dispose();$lock=$null
    & $powershell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $fixture 'Launcher.ps1') -RenderPreview
    Assert-Test ($LASTEXITCODE -eq 0) 'GUI renders under Windows PowerShell5.1 STA'
    $preview=Join-Path $fixture 'dist\launcher-preview.png'
    Assert-Test ([IO.File]::Exists($preview)) 'GUI emits its own rendered preview'
    Add-Type -AssemblyName System.Drawing
    $image=[Drawing.Bitmap]::FromFile($preview)
    try {
        Assert-Test ($image.Width -ge 820 -and $image.Height -ge 620) 'GUI is large enough for the repair controls'
        $colors=New-Object 'Collections.Generic.HashSet[int]'
        for($y=35;$y -lt $image.Height;$y+=8){for($x=15;$x -lt $image.Width;$x+=8){$colors.Add($image.GetPixel($x,$y).ToArgb())|Out-Null}}
        Assert-Test ($colors.Count -gt 20) 'GUI preview contains visible controls and text'
    } finally {$image.Dispose()}
    Write-Host "PASS: $passed worker isolation, concurrency, and launcher rendering contracts. No real game or Steam settings changed."
} finally {
    if($null -ne $lock){$lock.Dispose()}
    $full=[IO.Path]::GetFullPath($scratch);$prefix=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($full)-match '^\.tmp-[0-9a-f]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
