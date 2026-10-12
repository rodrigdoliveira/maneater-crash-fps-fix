# Composite transaction/recovery tests in an isolated copy. Real Steam VDF and
# Ansel backends operate on fixture files only. Process/registry/CPU/compiler/
# Windows-DXGI/native-installer boundaries are mocked; no game or DLL is loaded.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot=Join-Path $PSScriptRoot ('.tmp-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot)|Out-Null
$script:passed=0
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:passed++}
function Assert-Throws([scriptblock]$Operation,[string]$Message){$caught=$false;try{& $Operation|Out-Null}catch{$caught=$true};Assert-Test $caught $Message}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function New-Scenario([string]$Name){
    $repo=Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory((Join-Path $repo 'scripts'))|Out-Null
    foreach($name in @('Repair','PeExports','Compiler','CpuPlan','SteamFix','AnselFix')){[IO.File]::Copy((Join-Path $sourceRoot ('scripts\'+$name+'.psm1')),(Join-Path $repo ('scripts\'+$name+'.psm1')),$false)}
    # Keep Win32 rename paths below MAX_PATH in Windows PowerShell5.1. The
    # outer GUID directory already isolates every fixture from installations.
    $fixture=Join-Path $repo 'f'
    $game=Join-Path $fixture 'g';$bin=Join-Path $game 'Maneater\Binaries\Win64'
    $ansel=Join-Path $game 'Engine\Plugins\Runtime\Nvidia\Ansel\Binaries\ThirdParty\AnselSDK64.dll'
    foreach($directory in @($bin,[IO.Path]::GetDirectoryName($ansel),(Join-Path $repo 'dist'),(Join-Path $repo '.local'))){[IO.Directory]::CreateDirectory($directory)|Out-Null}
    $exe=Join-Path $bin 'Maneater-Win64-Shipping.exe';[IO.File]::WriteAllText($exe,'fixture game; not executable')
    [IO.File]::WriteAllText($ansel,'fixture Ansel; not DLL')
    # Substitute the expected SDK bytes only in this isolated module COPY.
    # Never change the public module or permit a real-game test override.
    $anselCopy=Join-Path $repo 'scripts\AnselFix.psm1'
    $anselSource=[IO.File]::ReadAllText($anselCopy)
    $anselSource=$anselSource.Replace('5560DA9B9D39F1DF17AB37ACDB66A19ED1F93F4F1C361590E05D7484D637D0C6',(Hash $ansel))
    [IO.File]::WriteAllText($anselCopy,$anselSource)
    $config=Join-Path $fixture 'localconfig.vdf'
    # Steam stores overlay and launch options in distinct nodes of one file.
    [IO.File]::WriteAllText($config,'"UserLocalConfigStore" { "apps" { "629820" { "OverlayAppEnable" "1" } } "Software" { "Valve" { "Steam" { "apps" { "629820" { "LaunchOptions" "" } } } } } }',[Text.UTF8Encoding]::new($false))
    $mod=Join-Path $repo 'dist\dxgi.dll';$system=Join-Path $repo 'dist\fixture-system.dll'
    [IO.File]::WriteAllText($mod,'fixture new proxy');[IO.File]::WriteAllText($system,'fixture system copy')
    $manifest=[pscustomobject]@{GameSHA256=(Hash $exe);TargetFPS=120;ModSHA256=(Hash $mod)}
    [IO.File]::WriteAllText((Join-Path $repo 'dist\build.json'),($manifest|ConvertTo-Json))
    $installer=@'
param([string]$Action,[string]$GameDirectory)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot;$state=Join-Path $root '.local\installation.json'
if($Action -ne 'Install'){throw 'Composite restore must handle owned fixture files directly.'}
[IO.File]::Copy((Join-Path $root 'dist\fixture-system.dll'),(Join-Path $GameDirectory 'dxgi_codex_system.dll'),$false)
[IO.File]::Copy((Join-Path $root 'dist\dxgi.dll'),(Join-Path $GameDirectory 'dxgi.dll'),$false)
$mode=Join-Path $root '.local\fail-native'
if([IO.File]::Exists($mode)){throw 'Injected failure after native copies before installation record.'}
$record=[pscustomobject]@{SchemaVersion=1;Status='installed';GameDirectory=$GameDirectory;ModSHA256=(Get-FileHash (Join-Path $GameDirectory 'dxgi.dll')).Hash;SystemSHA256=(Get-FileHash (Join-Path $GameDirectory 'dxgi_codex_system.dll')).Hash}
[IO.File]::WriteAllText($state,($record|ConvertTo-Json))
'@
    [IO.File]::WriteAllText((Join-Path $repo 'Manage-Mod.ps1'),$installer)
    $module=Import-Module (Join-Path $repo 'scripts\Repair.psm1') -Force -PassThru -DisableNameChecking
    $context=[pscustomobject]@{SteamDirectory=$fixture;SteamExe=(Join-Path $fixture 'steam.exe');ConfigPath=$config;AccountId='fixture'}
    & $module {
        param($Context,$ExeHash,$AnselHash,$SystemHash)
        $script:SupportedGameHash=$ExeHash;$script:FixtureContext=$Context;$script:FixtureAnselHash=$AnselHash;$script:FixtureSystemHash=$SystemHash
        function script:Assert-RepairProcessesClosed {}
        function script:Get-SteamFixContext {param($Context) $script:FixtureContext}
        function script:Assert-SteamManeaterInstallation {param($Context,$GameRoot) if($Context.ConfigPath -cne $script:FixtureContext.ConfigPath){throw 'Wrong fixture Steam context.'}}
        function script:Get-ManeaterCpuPlan {[pscustomobject]@{Apply=$false;Description='fixture CPU; no topology probe'}}
        function script:New-ManeaterLaunchOptions {param($ExistingOptions,$CpuPlan) 'cmd /c "set "OPENSSL_ia32cap=:~0x20000000" && %command%"'}
        function script:Get-RepairBuildReady {$true}
        function script:Get-RepairCompiler {throw 'Fixture must not download or run a compiler.'}
        function script:Get-VerifiedWindowsDxgi {[pscustomobject]@{Table=[pscustomobject]@{FileSHA256=$script:FixtureSystemHash}}}
        function script:Get-AuthenticodeSignature {param($LiteralPath) [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='O=Microsoft Corporation'}}}
        function script:Get-PeExportTable {param($Path) [pscustomobject]@{Path=$Path;FileSHA256=(Get-RepairHash $Path)}}
        function script:Assert-DxgiForwarderTable {param($Proxy,$System) $script:FixtureForwarderChecks++; if(-not [IO.File]::Exists($Proxy.Path) -or -not [IO.File]::Exists($System.Path)){throw 'Missing fixture forwarder input.'}}
        $script:FixtureForwarderChecks=0
    } $context (Hash $exe) (Hash $ansel) (Hash $system)
    $steamModule=& $module {(Get-Command Invoke-SteamFixPlan).Module}
    if($steamModule.Path -ine (Join-Path $repo 'scripts\SteamFix.psm1')){throw 'Process guard mock must be inside the isolated Steam module copy.'}
    & $steamModule {function script:Assert-SteamFixClosed {}; function script:Get-SteamFixRunningProcesses {@()}}
    [pscustomobject]@{Root=$repo;Module=$module;Game=$game;Bin=$bin;Exe=$exe;Ansel=$ansel;Config=$config;OriginalConfig=[IO.File]::ReadAllBytes($config);Context=$context;Mod=$mod;System=$system}
}
function Invoke-Case($Case){& $Case.Module {param($Exe,$Context) Invoke-ManeaterRepair -GameExecutable $Exe -SteamContext $Context} $Case.Exe $Case.Context}
function Restore-Case($Case){& $Case.Module {Restore-ManeaterRepair}}
function Read-Journal($Case){Get-Content -LiteralPath (Join-Path $Case.Root '.local\repair.json') -Raw|ConvertFrom-Json}
function Same-Config($Case){[Convert]::ToBase64String([IO.File]::ReadAllBytes($Case.Config)) -ceq [Convert]::ToBase64String($Case.OriginalConfig)}
function Test-CaseState($Case,$Journal){& $Case.Module {param($Journal) Test-ManeaterRepairState -Journal $Journal} $Journal}
function Manual-Journal($Case,[string]$Action){
    $plan=& $Case.Module {param($Exe,$Context) Get-ManeaterRepairPlan -GameExecutable $Exe -SteamContext $Context} $Case.Exe $Case.Context
    $plan.Native.Action=$Action;$plan.Native.InstalledHash=Hash $Case.Mod;$plan.Native.InstalledSystemHash=Hash $Case.System
    $backup=Join-Path $Case.Root '.local\backups\manual';[IO.Directory]::CreateDirectory($backup)|Out-Null
    $plan.Native.BackupMod=Join-Path $backup 'previous-dxgi.dll';$plan.Native.BackupSystem=Join-Path $backup 'previous-system-dxgi.dll'
    $journal=[pscustomobject]@{SchemaVersion=1;Status='applying';Plan=$plan;BackupDirectory=$backup;SteamRecord=$null;Errors=@();StartedUTC=[DateTime]::UtcNow.ToString('o')}
    & $Case.Module {param($Journal) Write-RepairJson -Path (Get-RepairStatePath) -Value $Journal} $journal
    $journal
}
try{
    $case=New-Scenario 'roundtrip';$journal=Invoke-Case $case
    Assert-Test ($journal.Status -eq 'applied') 'composite apply completed'
    Assert-Test (-not [IO.File]::Exists($case.Ansel) -and [IO.File]::Exists($journal.Plan.Ansel.DisabledPath)) 'real Ansel backend applied'
    Assert-Test (-not (Same-Config $case)) 'real Steam backend changed fixture settings'
    Assert-Test ([IO.File]::Exists((Join-Path $case.Bin 'dxgi.dll'))) 'fixture native installer applied'
    Assert-Test ((Invoke-Case $case).StartedUTC -ceq $journal.StartedUTC) 'reapply preserves transaction'
    Restore-Case $case|Out-Null
    Assert-Test ((Read-Journal $case).Status -eq 'restored' -and (Same-Config $case)) 'composite restore restores exact Steam bytes'
    Assert-Test ([IO.File]::Exists($case.Ansel) -and -not [IO.File]::Exists((Join-Path $case.Bin 'dxgi.dll'))) 'composite restore handles SDK and owned native files'

    $case=New-Scenario 'native-record-interruption';[IO.File]::WriteAllText((Join-Path $case.Root '.local\fail-native'),'inject')
    Assert-Throws {Invoke-Case $case} 'native installer failure propagated'
    Assert-Test ((Read-Journal $case).Status -eq 'restored') 'main write-ahead record recovers missing native record'
    Assert-Test (-not [IO.File]::Exists((Join-Path $case.Bin 'dxgi.dll')) -and -not [IO.File]::Exists((Join-Path $case.Bin 'dxgi_codex_system.dll'))) 'partial native copies removed only by planned hashes'
    Assert-Test ([IO.File]::Exists($case.Ansel) -and (Same-Config $case)) 'later steps untouched on early native failure'

    $case=New-Scenario 'steam-return-interruption';$journal=Manual-Journal $case 'Install'
    & $case.Module {param($Plan,$Backup) Invoke-SteamFixPlan -Plan $Plan -BackupDirectory $Backup|Out-Null} $journal.Plan.Steam $journal.BackupDirectory
    Assert-Test ($null -eq (Read-Journal $case).SteamRecord -and -not (Same-Config $case)) 'simulate power loss after backend VDF mutation before main journal result'
    Restore-Case $case|Out-Null
    Assert-Test ((Same-Config $case) -and (Read-Journal $case).Status -eq 'restored') 'manual Restore discovers backend write-ahead record'

    $case=New-Scenario 'samehash-original';$journal=Manual-Journal $case 'ReplaceRecognized'
    $journal.Plan.Native.OriginalModHash=$journal.Plan.Native.InstalledHash;$journal.Plan.Native.OriginalSystemHash=$journal.Plan.Native.InstalledSystemHash
    [IO.File]::Copy($case.Mod,$journal.Plan.Native.ModPath,$false);[IO.File]::Copy($case.System,$journal.Plan.Native.SystemPath,$false)
    & $case.Module {param($Journal) Write-RepairJson -Path (Get-RepairStatePath) -Value $Journal} $journal
    Restore-Case $case|Out-Null
    Assert-Test ([IO.File]::Exists($journal.Plan.Native.ModPath) -and [IO.File]::Exists($journal.Plan.Native.SystemPath)) 'original/new identical hash preserved before any backup exists'
    Assert-Test ((Read-Journal $case).Status -eq 'restored') 'same-hash pre-mutation restore succeeds'

    $case=New-Scenario 'recognized-replacement'
    $oldMod=Join-Path $case.Bin 'dxgi.dll';[IO.File]::WriteAllText($oldMod,'fixture recognized previous proxy')
    $oldHash=Hash $oldMod;[IO.File]::Copy($case.System,(Join-Path $case.Bin 'dxgi_codex_system.dll'),$false)
    & $case.Module {param($Hash) $script:LegacyModHash=$Hash} $oldHash
    $journal=Invoke-Case $case
    Assert-Test ($journal.Plan.Native.Action -eq 'ReplaceRecognized') 'recognized unmanaged pair backed up before replacement'
    Assert-Test ((& $case.Module {$script:FixtureForwarderChecks}) -gt 0) 'existing-system forwarder-validation boundary exercised'
    Restore-Case $case|Out-Null
    Assert-Test ((Hash $oldMod) -ceq $oldHash -and (Hash (Join-Path $case.Bin 'dxgi_codex_system.dll')) -ceq (Hash $case.System)) 'previous recognized pair restored byte-for-byte'
    Assert-Test (-not [IO.File]::Exists((Join-Path $case.Root '.local\installation.json'))) 'created native ownership record removed for restored unmanaged pair'

    $case=New-Scenario 'foreign-after-apply';$journal=Invoke-Case $case
    [IO.File]::WriteAllText($journal.Plan.Native.SystemPath,'foreign replacement')
    Assert-Throws {Restore-Case $case} 'foreign replacement reports recovery required'
    Assert-Test ([IO.File]::ReadAllText($journal.Plan.Native.SystemPath) -ceq 'foreign replacement') 'foreign replacement preserved'
    Assert-Test ([IO.File]::Exists($journal.Plan.Native.ModPath)) 'native preflight preserves other target when pair conflicts'
    Assert-Test ((Read-Journal $case).Status -eq 'recovery-required') 'failed recovery remains recorded'

    $case=New-Scenario 'foreign-before-apply';[IO.File]::WriteAllText((Join-Path $case.Bin 'dxgi.dll'),'foreign proxy')
    Assert-Throws {Invoke-Case $case} 'preexisting incomplete proxy refused before mutation'
    Assert-Test ((Same-Config $case) -and [IO.File]::Exists($case.Ansel)) 'refusal preserves settings and SDK'
    Assert-Test (-not [IO.File]::Exists((Join-Path $case.Root '.local\repair.json'))) 'refusal does not claim repair transaction'

    $case=New-Scenario 'final-verification-failure'
    & $case.Module {
        function script:Test-ManeaterRepairState {
            param($Journal)
            $script:VerificationInputStatus=$Journal.Status
            $script:VerificationSavedStatus=(Get-Content -LiteralPath (Get-RepairStatePath) -Raw|ConvertFrom-Json).Status
            [pscustomobject]@{Valid=$false;Reason='Injected final state verification failure.'}
        }
    }
    Assert-Throws {Invoke-Case $case} 'final verification failure propagated'
    Assert-Test ((& $case.Module {$script:VerificationInputStatus}) -ceq 'applied' -and (& $case.Module {$script:VerificationSavedStatus}) -ceq 'applying') 'final validation checks complete memory state before saving success'
    Assert-Test ((Read-Journal $case).Status -eq 'restored' -and (Same-Config $case) -and [IO.File]::Exists($case.Ansel) -and -not [IO.File]::Exists((Join-Path $case.Bin 'dxgi.dll'))) 'failed final validation rolls back all fixture mutations'

    $case=New-Scenario 'current-state';$journal=Invoke-Case $case
    Assert-Test ((Test-CaseState $case $journal).Valid) 'valid applied setup verified against fixture state'
    $target=$journal.Plan.Native.ModPath;$bytes=[IO.File]::ReadAllBytes($target)
    [IO.File]::WriteAllText($target,'foreign replacement')
    Assert-Test (-not (Test-CaseState $case $journal).Valid) 'changed native proxy invalidates applied state'
    [IO.File]::WriteAllBytes($target,$bytes)
    $target=$journal.Plan.Native.SystemPath;[IO.File]::Delete($target)
    Assert-Test (-not (Test-CaseState $case $journal).Valid) 'deleted native system copy invalidates applied state'
    [IO.File]::Copy($case.System,$target,$false)
    [IO.File]::Copy($journal.Plan.Ansel.DisabledPath,$case.Ansel,$false)
    Assert-Test (-not (Test-CaseState $case $journal).Valid) 're-enabled SDK invalidates applied state'
    [IO.File]::Delete($case.Ansel)
    $settings=[IO.File]::ReadAllBytes($case.Config)
    $text=[IO.File]::ReadAllText($case.Config)
    $pattern='"OverlayAppEnable"\s*"0"'
    Assert-Test ([regex]::Matches($text,$pattern).Count -eq 1) 'applied overlay exists at unique root-level fixture branch'
    [IO.File]::WriteAllText($case.Config,([regex]::Replace($text,$pattern,'"OverlayAppEnable" "1"')),[Text.UTF8Encoding]::new($false))
    Assert-Test (-not (Test-CaseState $case $journal).Valid) 'reset overlay alone invalidates applied state'
    [IO.File]::WriteAllBytes($case.Config,$settings)
    $pattern='"LaunchOptions"\s*"(?:\\.|[^"\\])*"'
    Assert-Test ([regex]::Matches($text,$pattern).Count -eq 1) 'applied launch options exist at unique deep fixture branch'
    [IO.File]::WriteAllText($case.Config,([regex]::Replace($text,$pattern,'"LaunchOptions" ""')),[Text.UTF8Encoding]::new($false))
    Assert-Test (-not (Test-CaseState $case $journal).Valid) 'reset launch options alone invalidate applied state'
    [IO.File]::WriteAllBytes($case.Config,$settings)
    Assert-Test ((Test-CaseState $case $journal).Valid) 'restored fixture inputs validate again'

    $case=New-Scenario 'restore-path-guard';$journal=Invoke-Case $case
    $outside=Join-Path $case.Root 'unrelated.dll';[IO.File]::Copy($case.Mod,$outside,$false)
    $journal.Plan.Native.ModPath=$outside
    & $case.Module {param($Journal) Write-RepairJson -Path (Get-RepairStatePath) -Value $Journal} $journal
    Assert-Throws {Restore-Case $case} 'tampered native restore target refused'
    Assert-Test ([IO.File]::Exists($outside) -and [IO.File]::Exists((Join-Path $case.Bin 'dxgi.dll'))) 'restore path refusal preserves matching unrelated file and installed proxy'

    Write-Output "PASS: $script:passed composite repair contracts; isolated fake installation only."
}finally{
    $full=[IO.Path]::GetFullPath($testRoot);$prefix=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^\.tmp-[0-9a-f]{32}$'){throw 'Unsafe test cleanup target.'}
    Get-Module Repair,AnselFix,SteamFix,CpuPlan,Compiler,PeExports|Remove-Module -Force
    Remove-Item -LiteralPath $full -Recurse -Force
}
