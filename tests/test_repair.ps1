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
function New-GameBytes {
    $bytes=New-Object byte[] 1024
    foreach($pair in @(@(0,0x5a4d),@(0x84,0x8664),@(0x86,1),@(0x94,240),@(0x96,0x22),@(0x98,0x20b))){[Array]::Copy([BitConverter]::GetBytes([uint16]$pair[1]),0,$bytes,[int]$pair[0],2)}
    foreach($pair in @(@(60,0x80),@(0x80,0x4550),@(0xa8,0x1000),@(0xd0,0x2000),@(0xd4,0x200))){[Array]::Copy([BitConverter]::GetBytes([uint32]$pair[1]),0,$bytes,[int]$pair[0],4)}
    return ,$bytes
}
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
    $exe=Join-Path $bin 'Maneater-Win64-Shipping.exe';[IO.File]::WriteAllBytes($exe,(New-GameBytes))
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
param([string]$Action,[string]$GameDirectory,[switch]$AllowUntestedBuild,[string]$ExpectedGameSHA256)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot;$state=Join-Path $root '.local\installation.json'
if($Action -ne 'Install'){throw 'Composite restore must handle owned fixture files directly.'}
$gameHash=(Get-FileHash (Join-Path $GameDirectory 'Maneater-Win64-Shipping.exe')).Hash
if($ExpectedGameSHA256 -and $gameHash -cne $ExpectedGameSHA256){throw 'Selected fixture game changed.'}
$template=Get-Content -LiteralPath (Join-Path $root 'dist\build.json') -Raw|ConvertFrom-Json
$tested=$gameHash -ceq $template.GameSHA256
if(-not $tested -and -not $AllowUntestedBuild){throw 'Fixture unknown build needs opt-in.'}
[IO.File]::Copy((Join-Path $root 'dist\fixture-system.dll'),(Join-Path $GameDirectory 'dxgi_codex_system.dll'),$false)
[IO.File]::Copy((Join-Path $root 'dist\dxgi.dll'),(Join-Path $GameDirectory 'dxgi.dll'),$false)
$mode=Join-Path $root '.local\fail-native'
if([IO.File]::Exists($mode)){throw 'Injected failure after native copies before installation record.'}
$record=[pscustomobject]@{SchemaVersion=2;Status='installed';GameDirectory=$GameDirectory;GameSHA256=$gameHash;TestedBuild=$tested;UntestedBuildOptIn=(-not $tested -and [bool]$AllowUntestedBuild);ModSHA256=(Get-FileHash (Join-Path $GameDirectory 'dxgi.dll')).Hash;SystemSHA256=(Get-FileHash (Join-Path $GameDirectory 'dxgi_codex_system.dll')).Hash}
[IO.File]::WriteAllText($state,($record|ConvertTo-Json))
if([IO.File]::Exists((Join-Path $root '.local\fail-native-after-state'))){throw 'Injected failure after native state write before return.'}
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
        function script:New-ManeaterLaunchOptions {param($ExistingOptions,$CpuPlan,[switch]$AllowUntestedBuild) 'cmd /c "set "OPENSSL_ia32cap=:~0x20000000" && set "MANEATER_FIX_ALLOW_UNTESTED='+$(if($AllowUntestedBuild){'1'}else{'0'})+'" && %command%"'}
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
function Invoke-Case($Case,[switch]$AllowUntestedBuild,[string]$ExpectedGameSHA256,[scriptblock]$Progress={}){& $Case.Module {param($Exe,$Context,$Allow,$Expected,$Progress) $params=@{GameExecutable=$Exe;SteamContext=$Context;AllowUntestedBuild=$Allow;Progress=$Progress};if($Expected){$params.ExpectedGameSHA256=$Expected};Invoke-ManeaterRepair @params} $Case.Exe $Case.Context ([bool]$AllowUntestedBuild) $ExpectedGameSHA256 $Progress}
function Restore-Case($Case){& $Case.Module {Restore-ManeaterRepair}}
function Read-Journal($Case){Get-Content -LiteralPath (Join-Path $Case.Root '.local\repair.json') -Raw|ConvertFrom-Json}
function Same-Config($Case){[Convert]::ToBase64String([IO.File]::ReadAllBytes($Case.Config)) -ceq [Convert]::ToBase64String($Case.OriginalConfig)}
function Test-CaseState($Case,$Journal){& $Case.Module {param($Journal) Test-ManeaterRepairState -Journal $Journal} $Journal}
function Set-OldNative($Case,[switch]$SameHashes){
    $mod=Join-Path $Case.Bin 'dxgi.dll';$system=Join-Path $Case.Bin 'dxgi_codex_system.dll'
    if($SameHashes){[IO.File]::Copy($Case.Mod,$mod,$false)}else{[IO.File]::WriteAllText($mod,'fixture owned previous proxy')}
    [IO.File]::Copy($Case.System,$system,$false)
    $record=[pscustomobject]@{SchemaVersion=2;Status='installed';GameDirectory=$Case.Bin;GameSHA256=(Hash $Case.Exe);TestedBuild=$true;UntestedBuildOptIn=$false;ModSHA256=(Hash $mod);SystemSHA256=(Hash $system);PreviousMetadata='must survive upgrade and rollback'}
    [IO.File]::WriteAllText((Join-Path $Case.Root '.local\installation.json'),($record|ConvertTo-Json))
    return $record
}
function Same-NativeRecord($Case,$Expected){
    $current=Get-Content -LiteralPath (Join-Path $Case.Root '.local\installation.json') -Raw|ConvertFrom-Json
    return ($current|ConvertTo-Json -Depth 30 -Compress) -ceq ($Expected|ConvertTo-Json -Depth 30 -Compress)
}
function Use-RealBundleReadiness($Case){
    # Exercise the production readiness function with real provenance hashes.
    # Only Windows-signature/export parsing remains a fixture boundary.
    [IO.Directory]::CreateDirectory((Join-Path $Case.Root 'src'))|Out-Null
    [IO.File]::WriteAllText((Join-Path $Case.Root 'src\maneater_fps_hook.c'),'fixture source; never compiled')
    [IO.File]::WriteAllText((Join-Path $Case.Root 'build.ps1'),"[IO.File]::WriteAllText((Join-Path `$PSScriptRoot '.local\build-was-called'),'tripwire'); throw 'Build fallback tripwire'")
    $definition=Join-Path $Case.Root 'dist\dxgi_proxy.def';[IO.File]::WriteAllText($definition,'fixture export definition')
    $hashes=[ordered]@{}
    foreach($relative in @('src/maneater_fps_hook.c','scripts/PeExports.psm1','build.ps1','Manage-Mod.ps1')){$hashes[$relative]=Hash (Join-Path $Case.Root $relative)}
    $exports=@([pscustomobject]@{Name='Alpha';Ordinal=1},[pscustomobject]@{Name='Beta';Ordinal=2})
    $contract=& $Case.Module {param($Exports) Get-ExportContractHash -Exports $Exports} $exports
    $manifest=[pscustomobject]@{SchemaVersion=1;GameSHA256=(Hash $Case.Exe);TargetFPS=120;ModSHA256=(Hash $Case.Mod);DefinitionSHA256=(Hash $definition);SystemExportsSHA256=$contract;ModExportsSHA256=$contract;SystemExports=$exports;BuildSystemDLLSHA256=(Hash $Case.System);SourceHashes=$hashes}
    [IO.File]::WriteAllText((Join-Path $Case.Root 'dist\build.json'),($manifest|ConvertTo-Json -Depth 6))
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'scripts\Repair.psm1'),[ref]$tokens,[ref]$errors)
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-RepairBuildReady'},$true)
    $definitionText=$function.Extent.Text.Replace('function Get-RepairBuildReady','function script:Get-RepairBuildReady')
    & $Case.Module {
        param($Definition,$SystemPath,$Contract)
        Invoke-Expression $Definition
        $script:FixtureSystemPath=$SystemPath;$script:FixtureExportContract=$Contract;$script:FixtureProxyContract=$Contract;$script:CompilerTripwireCount=0
        function script:Get-RepairCompiler {$script:CompilerTripwireCount++;throw 'Compiler/network fallback tripwire'}
        function script:Get-VerifiedWindowsDxgi {[pscustomobject]@{Path=$script:FixtureSystemPath;Table=[pscustomobject]@{Path=$script:FixtureSystemPath;FileSHA256=$script:FixtureSystemHash;ContractSHA256=$script:FixtureExportContract}}}
        function script:Get-PeExportTable {param($Path) [pscustomobject]@{Path=$Path;FileSHA256=(Get-RepairHash $Path);ContractSHA256=$script:FixtureProxyContract}}
        function script:Assert-DxgiForwarderTable {param($Proxy,$System) if($Proxy.ContractSHA256 -cne $System.ContractSHA256){throw 'Fixture Windows export contract differs.'}}
    } $definitionText $Case.System $contract
}
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
    Assert-Test ([DateTimeOffset](Invoke-Case $case).StartedUTC -eq [DateTimeOffset]$journal.StartedUTC) 'reapply preserves transaction'
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

    $case=New-Scenario 'owned-current';$oldRecord=Set-OldNative $case -SameHashes
    $plan=& $case.Module {param($Exe,$Context) Get-ManeaterRepairPlan -GameExecutable $Exe -SteamContext $Context} $case.Exe $case.Context
    Assert-Test ($plan.Native.Action -eq 'None' -and $plan.Native.OriginalNativeRecord.PreviousMetadata -ceq $oldRecord.PreviousMetadata) 'current owned pair preserved with captured record'
    & $case.Module {function script:Get-RepairBuildReady {$false}}
    $plan=& $case.Module {param($Exe,$Context) Get-ManeaterRepairPlan -GameExecutable $Exe -SteamContext $Context} $case.Exe $case.Context
    Assert-Test ($plan.Native.Action -eq 'ReplaceRecognized') 'stale source/build readiness forces owned pair refresh'
    & $case.Module {function script:Get-RepairBuildReady {$true}}
    $journal=Manual-Journal $case 'ReplaceRecognized'
    Restore-Case $case|Out-Null
    Assert-Test ((Same-NativeRecord $case $oldRecord) -and (Hash (Join-Path $case.Bin 'dxgi.dll')) -ceq $oldRecord.ModSHA256) 'identical owned old/new pair and prior record survive restore before backups'

    $case=New-Scenario 'owned-upgrade';$oldRecord=Set-OldNative $case;$journal=Invoke-Case $case
    Assert-Test ($journal.Plan.Native.Action -eq 'ReplaceRecognized' -and $journal.Plan.Native.OriginalNativeRecord.PreviousMetadata -ceq $oldRecord.PreviousMetadata) 'different desired DLL plans owned upgrade with original native record'
    Assert-Test ((Hash (Join-Path $case.Bin 'dxgi.dll')) -ceq (Hash $case.Mod)) 'owned upgrade installs refreshed proxy'
    Restore-Case $case|Out-Null
    Assert-Test ((Same-NativeRecord $case $oldRecord) -and (Hash (Join-Path $case.Bin 'dxgi.dll')) -ceq $oldRecord.ModSHA256 -and (Hash (Join-Path $case.Bin 'dxgi_codex_system.dll')) -ceq $oldRecord.SystemSHA256) 'owned upgrade restores exact old pair and all prior record metadata'

    $case=New-Scenario 'owned-before-backup';$oldRecord=Set-OldNative $case
    Assert-Throws {Invoke-Case $case -Progress {param($message) if($message -ceq 'Installing the native FPS correction...'){throw 'Injected before owned backup.'}}} 'owned upgrade pre-backup interruption reported'
    Assert-Test ((Read-Journal $case).Status -eq 'restored' -and (Same-NativeRecord $case $oldRecord) -and (Hash (Join-Path $case.Bin 'dxgi.dll')) -ceq $oldRecord.ModSHA256) 'preexisting old native state accepted without backups or mutations'

    foreach($phase in @('fail-native','fail-native-after-state')){
        $case=New-Scenario ('owned-'+$phase);$oldRecord=Set-OldNative $case
        [IO.File]::WriteAllText((Join-Path $case.Root ('.local\'+$phase)),'inject')
        Assert-Throws {Invoke-Case $case} "$phase owned upgrade interruption reported"
        Assert-Test ((Read-Journal $case).Status -eq 'restored' -and (Same-NativeRecord $case $oldRecord) -and (Hash (Join-Path $case.Bin 'dxgi.dll')) -ceq $oldRecord.ModSHA256 -and (Hash (Join-Path $case.Bin 'dxgi_codex_system.dll')) -ceq $oldRecord.SystemSHA256) "$phase restores prior owned pair/record before native return"
    }

    $case=New-Scenario 'untested-default'
    $unknown=[IO.File]::ReadAllBytes($case.Exe);$unknown[1023]=1;[IO.File]::WriteAllBytes($case.Exe,$unknown)
    $resolved=& $case.Module {param($Exe) Resolve-ManeaterExecutable $Exe} $case.Exe
    Assert-Test (-not $resolved.TestedBuild -and $resolved.GameSHA256 -ceq (Hash $case.Exe)) 'unknown AMD64 PE resolves with its actual hash for warning'
    Assert-Throws {Invoke-Case $case} 'untested repair requires opt-in before mutations'
    Assert-Test (-not [IO.File]::Exists((Join-Path $case.Root '.local\repair.json')) -and (Same-Config $case) -and [IO.File]::Exists($case.Ansel) -and -not [IO.File]::Exists((Join-Path $case.Bin 'dxgi.dll'))) 'default unknown rejection writes no journal/settings/game files'

    $case=New-Scenario 'untested-selection-race';$selectedHash=Hash $case.Exe
    $unknown=[IO.File]::ReadAllBytes($case.Exe);$unknown[1023]=2;[IO.File]::WriteAllBytes($case.Exe,$unknown)
    Assert-Throws {Invoke-Case $case -AllowUntestedBuild -ExpectedGameSHA256 $selectedHash} 'changed warning/selection hash rejects even opted-in repair'
    Assert-Test (-not [IO.File]::Exists((Join-Path $case.Root '.local\repair.json')) -and (Same-Config $case)) 'selection race makes no configuration transaction'

    $case=New-Scenario 'untested-sdk-preserved'
    $unknown=[IO.File]::ReadAllBytes($case.Exe);$unknown[1023]=3;[IO.File]::WriteAllBytes($case.Exe,$unknown)
    [IO.File]::WriteAllText($case.Ansel,'different unrecognized SDK; never a DLL');$sdkHash=Hash $case.Ansel
    $actualHash=Hash $case.Exe;$journal=Invoke-Case $case -AllowUntestedBuild -ExpectedGameSHA256 $actualHash
    Assert-Test ($journal.Status -ceq 'applied' -and $journal.UntestedBuildOptIn -and -not $journal.Plan.Game.TestedBuild -and $journal.Plan.Game.GameSHA256 -ceq $actualHash) 'opted-in repair journal records actual untested hash'
    $nativeRecord=Get-Content -LiteralPath (Join-Path $case.Root '.local\installation.json') -Raw|ConvertFrom-Json
    Assert-Test ($nativeRecord.GameSHA256 -ceq $actualHash -and -not $nativeRecord.TestedBuild -and $nativeRecord.UntestedBuildOptIn) 'native installer boundary receives opt-in and selected hash'
    Assert-Test ($journal.Plan.AnselDisposition -ceq 'SkippedUnknownSDK' -and (Hash $case.Ansel) -ceq $sdkHash -and -not [IO.File]::Exists($journal.Plan.Ansel.DisabledPath)) 'untested unknown SDK is preserved and explicitly skipped'
    Assert-Test ((Test-CaseState $case $journal).Valid -and $journal.Plan.LaunchOptions -match 'MANEATER_FIX_ALLOW_UNTESTED=1') 'current same-hash opted-in setup verifies with scoped experimental flag'
    $journal.UntestedBuildOptIn=$false
    Assert-Test (-not (Test-CaseState $case $journal).Valid) 'unknown applied state without opt-in is invalid'
    $journal.UntestedBuildOptIn=$true;$unknown[1023]=4;[IO.File]::WriteAllBytes($case.Exe,$unknown)
    Assert-Test (-not (Test-CaseState $case $journal).Valid) 'unknown applied state with changed executable is invalid'
    Restore-Case $case|Out-Null
    Assert-Test ((Read-Journal $case).Status -ceq 'restored' -and (Hash $case.Ansel) -ceq $sdkHash -and (Same-Config $case) -and -not [IO.File]::Exists((Join-Path $case.Bin 'dxgi.dll'))) 'untested restore leaves skipped SDK unchanged and removes only owned modifications'

    $case=New-Scenario 'ready-bundle-only';Use-RealBundleReadiness $case
    Assert-Test ((& $case.Module {Get-RepairBuildReady})) 'complete prebuilt bundle passes actual provenance/export readiness'
    $journal=Invoke-Case $case
    Assert-Test ($journal.Status -ceq 'applied' -and (& $case.Module {$script:CompilerTripwireCount}) -eq 0 -and -not [IO.File]::Exists((Join-Path $case.Root '.local\build-was-called')) -and -not [IO.Directory]::Exists((Join-Path $case.Root '.local\tools'))) 'ready bundle applies without compiler/build/network fallback or tool cache'
    Restore-Case $case|Out-Null

    foreach($failure in @('missing','damaged','stale','contract')){
        $case=New-Scenario ('bundle-'+$failure);Use-RealBundleReadiness $case
        switch($failure){
            'missing'{[IO.File]::Delete($case.Mod)}
            'damaged'{[IO.File]::WriteAllText($case.Mod,'damaged bundled proxy')}
            'stale'{[IO.File]::AppendAllText((Join-Path $case.Root 'build.ps1'),"`n# source changed after bundling")}
            'contract'{& $case.Module {$script:FixtureExportContract='F'*64}}
        }
        & $case.Module {$script:WritableProbeCount=0;function script:Assert-RepairWritable {param($Directory) $script:WritableProbeCount++;throw 'Writable probe tripwire'}}
        $message='';try{Invoke-Case $case|Out-Null}catch{$message=$_.Exception.Message}
        Assert-Test ($message -like 'The ready-to-run mod bundle*' -and $message -match 'release ZIP' -and $message -match 'build.ps1') "$failure bundle fails with ready-release/manual-build action"
        Assert-Test ((& $case.Module {$script:WritableProbeCount}) -eq 0 -and (& $case.Module {$script:CompilerTripwireCount}) -eq 0 -and -not [IO.File]::Exists((Join-Path $case.Root '.local\build-was-called'))) "$failure bundle stops before writable probes/compiler/build fallback"
        Assert-Test ((Same-Config $case) -and [IO.File]::Exists($case.Ansel) -and -not [IO.File]::Exists((Join-Path $case.Root '.local\repair.json')) -and -not [IO.Directory]::Exists((Join-Path $case.Root '.local\backups')) -and -not [IO.File]::Exists((Join-Path $case.Bin 'dxgi.dll'))) "$failure bundle writes no repair journal/backups/game/settings"
    }

    $case=New-Scenario 'same-export-new-windows-dll';Use-RealBundleReadiness $case
    $oldSystemHash=Hash $case.System
    [IO.File]::WriteAllText($case.System,'fixture newer Windows DLL with unchanged exports')
    & $case.Module {param($Hash) $script:FixtureSystemHash=$Hash} (Hash $case.System)
    Assert-Test ((Hash $case.System) -cne $oldSystemHash -and (& $case.Module {Get-RepairBuildReady})) 'different local Windows DLL bytes do not invalidate unchanged verified export contract'
    $journal=Invoke-Case $case
    Assert-Test ($journal.Status -ceq 'applied' -and $journal.Plan.Native.InstalledSystemHash -ceq (Hash $case.System)) 'same-export Windows update installs current local copy without rebuilding'
    Restore-Case $case|Out-Null

    foreach($corruption in @('schema','recorded-exports','mod-exports','proxy-snapshot')){
        $case=New-Scenario ('manifest-'+$corruption);Use-RealBundleReadiness $case
        $oldRecord=Set-OldNative $case
        $manifestPath=Join-Path $case.Root 'dist\build.json'
        $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
        switch($corruption){
            'schema'{$manifest.SchemaVersion=2}
            'recorded-exports'{$manifest.SystemExports[0].Ordinal=77}
            'mod-exports'{$manifest.ModExportsSHA256='0'*64}
            'proxy-snapshot'{& $case.Module {function script:Get-PeExportTable {param($Path) [pscustomobject]@{Path=$Path;FileSHA256=('0'*64);ContractSHA256=$script:FixtureProxyContract}}}}
        }
        [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 6))
        & $case.Module {$script:WritableProbeCount=0;function script:Assert-RepairWritable {param($Directory) $script:WritableProbeCount++;throw 'Writable probe tripwire'}}
        $message='';try{Invoke-Case $case|Out-Null}catch{$message=$_.Exception.Message}
        Assert-Test ($message -like 'The ready-to-run mod bundle*') "$corruption manifest is refused during ready-package preflight"
        Assert-Test ((& $case.Module {$script:WritableProbeCount}) -eq 0 -and (& $case.Module {$script:CompilerTripwireCount}) -eq 0 -and -not [IO.File]::Exists((Join-Path $case.Root '.local\repair.json')) -and -not [IO.Directory]::Exists((Join-Path $case.Root '.local\backups'))) "$corruption manifest creates no writable probe/journal/backup/fallback"
        Assert-Test ((Same-NativeRecord $case $oldRecord) -and (Hash (Join-Path $case.Bin 'dxgi.dll')) -ceq $oldRecord.ModSHA256 -and (Hash (Join-Path $case.Bin 'dxgi_codex_system.dll')) -ceq $oldRecord.SystemSHA256 -and (Same-Config $case) -and [IO.File]::Exists($case.Ansel)) "$corruption manifest preserves an owned upgrade's old pair/state/settings"
    }

    $case=New-Scenario 'amd-worker-budget'
    & $case.Module {
        $rows=@();for($logical=0;$logical -lt 12;$logical++){
            $rows+=[pscustomobject]@{Id=900+$logical;Group=0;LogicalProcessorIndex=$logical;CoreIndex=[int][Math]::Floor($logical/2);EfficiencyClass=0;Flags=0}
        }
        $script:AmdFixturePlan=Get-CpuLaunchPlan -CpuSets $rows -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen fixture'
        function script:Get-ManeaterCpuPlan {return $script:AmdFixturePlan}
        function script:New-ManeaterLaunchOptions {
            param($ExistingOptions,$CpuPlan,[switch]$AllowUntestedBuild)
            return (New-GameLaunchPlan -ExistingOptions $ExistingOptions -CpuPlan $CpuPlan -AllowUntestedBuild:$AllowUntestedBuild).SteamLaunchOptions
        }
    }
    $journal=Invoke-Case $case
    Assert-Test ($journal.Status -ceq 'applied' -and $journal.Plan.Cpu.IsAmdWorkerBudget -and $journal.Plan.Cpu.Experimental -and -not $journal.Plan.Cpu.ApplyAffinity -and $journal.Plan.Cpu.CoreLimit -eq 6) 'AMD budget-only experimental plan is recorded in real composite transaction'
    $actualSteam=& $case.Module {param($Config) Get-SteamFixStatus -ConfigPath $Config} $case.Config
    Assert-Test ($actualSteam.ExistingLaunchOptions -match '-corelimit=6' -and $actualSteam.ExistingLaunchOptions -match 'MANEATER_FIX_CPU_MANAGED=1' -and $actualSteam.ExistingLaunchOptions -notmatch '/affinity') 'Steam backend applies physical AMD budget without an affinity mask'
    Assert-Test ((Test-CaseState $case $journal).Valid) 'applied AMD budget verifies through actual launch-wrapper regeneration'
    Restore-Case $case|Out-Null
    Assert-Test ((Same-Config $case) -and (Read-Journal $case).Status -ceq 'restored') 'AMD budget restore returns exact previous Steam launch options'

    Write-Output "PASS: $script:passed composite repair contracts; isolated fake installation only."
}finally{
    $full=[IO.Path]::GetFullPath($testRoot);$prefix=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^\.tmp-[0-9a-f]{32}$'){throw 'Unsafe test cleanup target.'}
    Get-Module Repair,AnselFix,SteamFix,CpuPlan,Compiler,PeExports|Remove-Module -Force
    Remove-Item -LiteralPath $full -Recurse -Force
}
