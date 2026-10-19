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
function Run-Request {param([string]$Action,[string]$Game='',[hashtable]$Additional=@{})
    $path=Join-Path $fixture ('.local\request-'+[Guid]::NewGuid().ToString('N')+'.json')
    $request=@{Action=$Action;GameExecutable=$Game;SteamContext=$null}
    foreach($key in $Additional.Keys){$request[$key]=$Additional[$key]}
    [IO.File]::WriteAllText($path,($request|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
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
    Assert-Test (-not $result.Success -and $result.Message -eq 'Maneater shipping executable was not found.') 'missing shipping executable fails before touching Steam or the game'
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

    # Inspect real controls before this isolated GUI disposes them. Preview
    # must neither discover the user's installation nor start a worker.
    $launcherPath=Join-Path $fixture 'Launcher.ps1'
    $guiChecks=@'
        $snapshot=[ordered]@{DefaultChecked=$untested.Checked;WorkerNotStarted=($null -eq $script:worker)}
        $fakePlan=[pscustomobject]@{Game=[pscustomobject]@{TestedBuild=$false};Native=[pscustomobject]@{Action='Install'};Cpu=[pscustomobject]@{Apply=$false;Description='fixture CPU'};Ansel=[pscustomobject]@{Action='None'}}
        Show-Plan $fakePlan
        $snapshot.UnknownKeepsDefault=($untested.Checked -eq (-not $DisallowUntestedBuild))
        $untested.Checked=$false;Show-Plan $fakePlan
        $snapshot.UncheckedPersists=(-not $untested.Checked -and -not $apply.Enabled)
        $untested.Checked=$true
        $snapshot.CheckedAllowsApply=$apply.Enabled
        $script:steamExitPending=$true;$untested.Checked=$false;$untested.Checked=$true
        $snapshot.BusyKeepsApplyDisabled=(-not $apply.Enabled);$script:steamExitPending=$false
        $fakePlan.Game.TestedBuild=$true;Show-Plan $fakePlan
        $snapshot.TestedKeepsChecked=($untested.Checked -and -not $untested.Enabled)
        [IO.File]::WriteAllText((Join-Path $local 'gui-state.json'),($snapshot|ConvertTo-Json))
'@
    $guiSource=[IO.File]::ReadAllText($launcherPath)
    $anchor='        $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)'
    if(-not $guiSource.Contains($anchor)){throw 'GUI inspection insertion point missing.'}
    [IO.File]::WriteAllText($launcherPath,$guiSource.Replace($anchor,$guiChecks+"`n"+$anchor),[Text.UTF8Encoding]::new($false))
    foreach($disallow in @($false,$true)){
        $args=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$launcherPath,'-RenderPreview')
        if($disallow){$args+='-DisallowUntestedBuild'}
        & $powershell @args
        Assert-Test ($LASTEXITCODE -eq 0) 'GUI state probe completes without discovery or game input'
        $state=Get-Content (Join-Path $fixture '.local\gui-state.json') -Raw|ConvertFrom-Json
        Assert-Test ($state.DefaultChecked -eq (-not $disallow) -and $state.WorkerNotStarted -and $state.UnknownKeepsDefault) 'preselection and explicit opt-out survive startup and unknown plan'
        Assert-Test ($state.UncheckedPersists -and $state.CheckedAllowsApply -and $state.BusyKeepsApplyDisabled -and $state.TestedKeepsChecked) 'checkbox selection, busy guard and tested-build display use real control state'
    }

    # Route Detect through the real worker and an isolated installation-path
    # provider. No real registry, Steam account or game is consulted.
    $steamCopy=Join-Path $fixture 'scripts\SteamFix.psm1'
    [IO.File]::AppendAllText($steamCopy,"`nfunction Get-SteamInstallDirectories { return @() }`n")
    $detected=Run-Request 'Detect'
    Assert-Test ($detected.Success -and -not $detected.Result.Found -and $detected.Result.Reason -like '*Choose game*') 'worker detection returns actionable manual-selection fallback'

    # Exercise discovery and both picker filenames through the real Plan
    # backend. Only CPU discovery is mocked; all Steam records and PE bytes
    # below are synthetic, and no Apply action runs on these installations.
    $steam=Join-Path $scratch 's'; $libraryA=Join-Path $scratch 'a'; $libraryB=Join-Path $scratch 'b'
    $config=Join-Path $steam 'userdata\42\config\localconfig.vdf'
    foreach($directory in @((Split-Path $config),(Join-Path $steam 'steamapps'),(Join-Path $libraryA 'steamapps'),(Join-Path $libraryB 'steamapps'))){[IO.Directory]::CreateDirectory($directory)|Out-Null}
    [IO.File]::WriteAllText((Join-Path $steam 'steam.exe'),'inert Steam fixture; never executed')
    [IO.File]::WriteAllText($config,'"UserLocalConfigStore" { "apps" { } "Software" { "Valve" { "Steam" { "apps" { } } } } }')
    $context=@{SteamDirectory=$steam;AccountId=42;ConfigPath=$config}
    $gameBytes=New-Object byte[] 1024
    foreach($pair in @(@(0,0x5a4d),@(0x84,0x8664),@(0x86,1),@(0x94,240),@(0x96,0x22),@(0x98,0x20b))){[Array]::Copy([BitConverter]::GetBytes([uint16]$pair[1]),0,$gameBytes,[int]$pair[0],2)}
    foreach($pair in @(@(60,0x80),@(0x80,0x4550),@(0xa8,0x1000),@(0xd0,0x2000))){[Array]::Copy([BitConverter]::GetBytes([uint32]$pair[1]),0,$gameBytes,[int]$pair[0],4)}
    [IO.File]::AppendAllText((Join-Path $fixture 'scripts\Repair.psm1'),"`nfunction Get-ManeaterCpuPlan { [pscustomobject]@{Apply=`$false;Description='synthetic CPU'} }`n")
    [IO.File]::AppendAllText($steamCopy,("`nfunction Get-SteamInstallDirectories { return @('"+$steam.Replace("'","''")+"') }`n"))
    $libraryFile=Join-Path $steam 'steamapps\libraryfolders.vdf'
    $tokenA=$libraryA.Replace('\','\\');$tokenB=$libraryB.Replace('\','\\')
    [IO.File]::WriteAllText($libraryFile,('"libraryfolders" { "1" { "path" "'+$tokenA+'" "apps" { } } "2" { "path" "'+$tokenB+'" "apps" { } } }'))
    $manualExecutables=@();$gameRoots=@()
    foreach($library in @($libraryA,$libraryB)){
        $game=Join-Path $library 'steamapps\common\Maneater'
        $shipping=Join-Path $game 'Maneater\Binaries\Win64\Maneater-Win64-Shipping.exe'
        [IO.Directory]::CreateDirectory((Split-Path $shipping))|Out-Null
        [IO.File]::WriteAllBytes($shipping,$gameBytes)
        [IO.File]::WriteAllText((Join-Path $game 'Maneater.exe'),'inert launcher fixture; never executed')
        [IO.File]::WriteAllText((Join-Path $library 'steamapps\appmanifest_629820.acf'),'"AppState" { "appid" "629820" "installdir" "Maneater" }')
        $manualExecutables+=$(if($library -eq $libraryA){Join-Path $game 'Maneater.exe'}else{$shipping})
        $gameRoots+=$game
        if($library -eq $libraryA){
            $detected=Run-Request 'Detect'
            Assert-Test ($detected.Success -and $detected.Result.Found -and $detected.Result.Executable -ceq $manualExecutables[0]) 'single installation is still detected automatically'
            $planned=Run-Request 'Plan' $detected.Result.Executable @{SteamContext=$context}
            Assert-Test ($planned.Success -and $planned.Result.Game.GameRoot -ceq $game) 'automatically detected copy passes real Steam preflight with an empty app cache'
        }
    }
    $detected=Run-Request 'Detect'
    Assert-Test ($detected.Success -and -not $detected.Result.Found -and $detected.Result.Reason -like 'Multiple*Choose game*Browse local files*') 'multiple copies prompt manual selection through the worker'
    $metadataPaths=@($config,$libraryFile,(Join-Path $libraryA 'steamapps\appmanifest_629820.acf'),(Join-Path $libraryB 'steamapps\appmanifest_629820.acf'))
    $metadataBefore=@($metadataPaths|ForEach-Object{(Get-FileHash -LiteralPath $_).Hash})
    for($i=0;$i -lt $manualExecutables.Count;$i++){
        $planned=Run-Request 'Plan' $manualExecutables[$i] @{SteamContext=$context}
        Assert-Test ($planned.Success -and $planned.Result.Game.GameRoot -ceq $gameRoots[$i]) 'either manually chosen copy passes real preflight, including root and shipping filenames'
    }
    $metadataAfter=@($metadataPaths|ForEach-Object{(Get-FileHash -LiteralPath $_).Hash})
    Assert-Test (($metadataBefore -join ',') -ceq ($metadataAfter -join ',') -and -not [IO.File]::Exists((Join-Path $fixture '.local\repair.json'))) 'automatic and manual planning preserve Steam metadata and create no repair journal'
    [IO.File]::Delete((Join-Path $libraryA 'steamapps\appmanifest_629820.acf'))
    $planned=Run-Request 'Plan' $manualExecutables[0] @{SteamContext=$context}
    Assert-Test (-not $planned.Success -and $planned.Message -like '*missing Maneater*appmanifest_629820.acf*Browse local files*') 'worker surfaces the specific selected-library error even when another copy is valid'

    # Exercise the actual worker's JSON/request boundary with a recording
    # backend in this isolated COPY. The real repair/backend is separately
    # covered by test_repair.ps1; these cases never probe Steam or a game.
    $stub=@'
Set-StrictMode -Version Latest
function Write-RepairJson {
    param([string]$Path,$Value)
    [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Invoke-ManeaterRepair {
    param([string]$GameExecutable,$SteamContext,[switch]$AllowUntestedBuild,[ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedGameSHA256,[scriptblock]$Progress)
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot '..\.local\stub-invoked.txt'),'recorded fixture callback')
    [pscustomobject]@{AllowUntestedBuild=[bool]$AllowUntestedBuild.IsPresent;ExpectedGameSHA256=$ExpectedGameSHA256;GameExecutable=$GameExecutable}
}
Export-ModuleMember -Function Write-RepairJson,Invoke-ManeaterRepair
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'scripts\Repair.psm1'),$stub,[Text.UTF8Encoding]::new($false))
    $invoked=Join-Path $fixture '.local\stub-invoked.txt'
    $result=Run-Request 'Apply' $exe @{AllowUntestedBuild=$true}
    Assert-Test (-not $result.Success -and $result.Message -eq 'Apply requires the executable hash from the reviewed selection.') 'Apply requires expected hash even when opted in'
    Assert-Test (-not [IO.File]::Exists($invoked)) 'missing expected hash never invokes the repair backend'
    foreach($hashValue in @('','not-a-sha256',$true)){
        $result=Run-Request 'Apply' $exe @{AllowUntestedBuild=$true;ExpectedGameSHA256=$hashValue}
        Assert-Test (-not $result.Success -and $result.Message -like '*ExpectedGameSHA256*') 'invalid expected hash rejected by backend parameter contract'
        Assert-Test (-not [IO.File]::Exists($invoked)) 'invalid expected hash never invokes the backend body'
    }
    $expectedHash='A'*64
    $result=Run-Request 'Apply' $exe @{ExpectedGameSHA256=$expectedHash}
    Assert-Test ($result.Success -and -not $result.Result.AllowUntestedBuild -and $result.Result.ExpectedGameSHA256 -ceq $expectedHash) 'missing opt-in defaults false and expected hash forwards unchanged'
    foreach($value in @($null,$false,$true,'true','false','1',1)){
        [IO.File]::Delete($invoked)
        $result=Run-Request 'Apply' $exe @{AllowUntestedBuild=$value;ExpectedGameSHA256=$expectedHash}
        $expectedAllow=$value -is [bool] -and $value
        Assert-Test ($result.Success -and $result.Result.AllowUntestedBuild -eq $expectedAllow -and [IO.File]::Exists($invoked)) 'only a typed JSON boolean true enables experimental request'
        Assert-Test ($result.Result.ExpectedGameSHA256 -ceq $expectedHash -and $result.Result.GameExecutable -ceq $exe) 'worker preserves the reviewed hash and selected executable'
    }
    Write-Host "PASS: $passed worker isolation, concurrency, and launcher rendering contracts. No real game or Steam settings changed."
} finally {
    if($null -ne $lock){$lock.Dispose()}
    $full=[IO.Path]::GetFullPath($scratch);$prefix=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($full)-match '^\.tmp-[0-9a-f]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
