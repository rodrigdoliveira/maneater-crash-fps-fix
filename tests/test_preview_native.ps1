# Inert filesystem fixtures only. No game, native DLL, helper, or compiler runs.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'test_repair.ps1') -DefinitionsOnly

function New-KnownPrivate($Case){
    $dll=Join-Path $Case.Bin 'dxgi.dll';$sys=Join-Path $Case.Bin 'dxgi_codex_system.dll';$helper=Join-Path $Case.Bin 'ManeaterAreaHelper.exe'
    [IO.File]::WriteAllText($dll,'inert old private DLL')
    [IO.File]::Copy($Case.System,$sys,$false)
    [IO.File]::WriteAllText($helper,'inert old private helper')
    & $Case.Module {param($DllHash,$HelperHash) $script:PrivateLoadingModHash=$DllHash;$script:PrivateLoadingHelperHash=$HelperHash} (Hash $dll) (Hash $helper)
    [pscustomobject]@{Dll=$dll;System=$sys;Helper=$helper;DllHash=(Hash $dll);SystemHash=(Hash $sys);HelperHash=(Hash $helper)}
}
function Inject-Function($Case,[string]$Name,[string]$Marker,[string]$Injection){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Case.Root 'scripts\Repair.psm1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Fixture module parse failure.'}
    $fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name},$true)
    if($null -eq $fn -or -not $fn.Extent.Text.Contains($Marker)){throw 'Fixture injection marker absent.'}
    $body=$fn.Extent.Text.Replace($Marker,$Injection).Replace(('function '+$Name),('function script:'+$Name))
    & $Case.Module {param($Body) Invoke-Expression $Body} $body
}
function Assert-OldTuple($Case,$Old,[string]$Message){
    Assert-Test ((Hash $Old.Dll) -ceq $Old.DllHash -and (Hash $Old.System) -ceq $Old.SystemHash -and (Hash $Old.Helper) -ceq $Old.HelperHash) $Message
}

try{
    $case=New-Scenario 'private-upgrade';$old=New-KnownPrivate $case
    $owner=Join-Path $case.Bin 'maneater_private_loading.owner.json';[IO.File]::WriteAllText($owner,'prior private owner remains unchanged');$ownerHash=Hash $owner
    $oldBackup=Join-Path $case.Bin 'dxgi.dll.before-private-loading';[IO.File]::WriteAllText($oldBackup,'prior private backup');$oldBackupHash=Hash $oldBackup
    $journal=Invoke-Case $case
    Assert-Test ($journal.Plan.Native.Action -ceq 'ReplaceRecognized' -and $journal.Plan.Native.OriginalHelperHash -ceq $old.HelperHash -and (Hash $journal.Plan.Native.BackupHelper) -ceq $old.HelperHash) 'new-folder private tuple gets verified helper backup'
    $record=Get-Content (Join-Path $case.Root '.local\installation.json') -Raw|ConvertFrom-Json
    Assert-Test ($record.SchemaVersion -eq 3 -and $record.HelperSHA256 -ceq (Hash $case.Helper)) 'preview ownership records the installed helper'
    Assert-Test ((Test-CaseState $case $journal).Valid) 'all three preview native files verify'
    Restore-Case $case|Out-Null
    Assert-OldTuple $case $old 'restore returns exact previous private DLL, helper and system'
    Assert-Test ((Hash $owner) -ceq $ownerHash -and (Hash $oldBackup) -ceq $oldBackupHash -and -not [IO.File]::Exists((Join-Path $case.Root '.local\installation.json'))) 'old private ownership and backups untouched'

    $case=New-Scenario 'tested-preview-upgrade';$old=New-KnownPrivate $case
    & $case.Module {param($DllHash,$HelperHash)
        $script:PrivateLoadingModHash='0'*64;$script:PrivateLoadingHelperHash='0'*64
        $script:PreviewV07ModHash=$DllHash;$script:PreviewV07HelperHash=$HelperHash
    } $old.DllHash $old.HelperHash
    $journal=Invoke-Case $case
    Assert-Test ($journal.Plan.Native.Action -ceq 'ReplaceRecognized' -and (Hash $journal.Plan.Native.BackupHelper) -ceq $old.HelperHash) 'tested preview pair upgrades with a matching helper backup'
    Restore-Case $case|Out-Null
    Assert-OldTuple $case $old 'tested preview upgrade restores exact previous tuple'

    foreach($mode in @('mismatched-helper','untested-game')){
        $case=New-Scenario ('preview-'+$mode);$old=New-KnownPrivate $case
        & $case.Module {param($DllHash,$HelperHash)
            $script:PrivateLoadingModHash='0'*64;$script:PrivateLoadingHelperHash='0'*64
            $script:PreviewV07ModHash=$DllHash;$script:PreviewV07HelperHash=$HelperHash
        } $old.DllHash $old.HelperHash
        if($mode -eq 'mismatched-helper'){[IO.File]::WriteAllText($old.Helper,'foreign helper');$old.HelperHash=Hash $old.Helper}
        else{$bytes=[IO.File]::ReadAllBytes($case.Exe);$bytes[1023]=1;[IO.File]::WriteAllBytes($case.Exe,$bytes)}
        Assert-Throws {Invoke-Case $case -AllowUntestedBuild} "$mode preview pair refused before mutation"
        Assert-OldTuple $case $old "$mode preview files remain intact"
    }

    $case=New-Scenario 'public-upgrade';$dll=Join-Path $case.Bin 'dxgi.dll'
    [IO.File]::WriteAllText($dll,'inert public v0.2');[IO.File]::Copy($case.System,(Join-Path $case.Bin 'dxgi_codex_system.dll'),$false);$oldHash=Hash $dll
    & $case.Module {param($Hash) $script:PublicV02ModHash=$Hash} $oldHash
    $journal=Invoke-Case $case
    Assert-Test ($journal.Plan.Native.Action -ceq 'ReplaceRecognized' -and $null -eq $journal.Plan.Native.OriginalHelperHash) 'public two-file setup recognized only without helper'
    Restore-Case $case|Out-Null
    Assert-Test ((Hash $dll) -ceq $oldHash -and -not [IO.File]::Exists((Join-Path $case.Bin 'ManeaterAreaHelper.exe'))) 'public restore removes preview helper and preserves original pair'

    foreach($mode in @('foreign','missing','untested')){
        $case=New-Scenario ('private-'+$mode);$old=New-KnownPrivate $case
        if($mode -eq 'foreign'){[IO.File]::WriteAllText($old.Helper,'foreign helper');$old.HelperHash=Hash $old.Helper}
        if($mode -eq 'missing'){[IO.File]::Delete($old.Helper)}
        if($mode -eq 'untested'){$bytes=[IO.File]::ReadAllBytes($case.Exe);$bytes[1023]=1;[IO.File]::WriteAllBytes($case.Exe,$bytes)}
        Assert-Throws {Invoke-Case $case -AllowUntestedBuild} "$mode untracked private tuple refused before mutation"
        Assert-Test ((Hash $old.Dll) -ceq $old.DllHash -and (Hash $old.System) -ceq $old.SystemHash -and (Same-Config $case) -and [IO.File]::Exists($case.Ansel) -and -not [IO.File]::Exists((Join-Path $case.Root '.local\repair.json'))) "$mode refusal preserves game/settings and creates no journal"
        if($mode -ne 'missing'){Assert-Test ((Hash $old.Helper) -ceq $old.HelperHash) "$mode helper preserved"}
    }

    $case=New-Scenario 'helper-alone';$helper=Join-Path $case.Bin 'ManeaterAreaHelper.exe';[IO.File]::WriteAllText($helper,'foreign helper alone')
    Assert-Throws {Invoke-Case $case} 'helper alone cannot be overwritten'
    Assert-Test ([IO.File]::ReadAllText($helper) -ceq 'foreign helper alone' -and (Same-Config $case)) 'helper-alone refusal leaves foreign bytes/settings'

    $case=New-Scenario 'foreign-after';$old=New-KnownPrivate $case;$journal=Invoke-Case $case
    [IO.File]::WriteAllText($journal.Plan.Native.HelperPath,'foreign helper after apply');$dllHash=Hash $journal.Plan.Native.ModPath;$sysHash=Hash $journal.Plan.Native.SystemPath
    Assert-Throws {Restore-Case $case} 'changed helper blocks tuple restore before native deletion'
    Assert-Test ([IO.File]::ReadAllText($journal.Plan.Native.HelperPath) -ceq 'foreign helper after apply' -and (Hash $journal.Plan.Native.ModPath) -ceq $dllHash -and (Hash $journal.Plan.Native.SystemPath) -ceq $sysHash -and (Hash $journal.Plan.Native.BackupHelper) -ceq $old.HelperHash) 'foreign helper and current tuple preserved, original backup recoverable'
    Assert-Test (-not (Test-CaseState $case $journal).Valid) 'changed helper invalidates current-state verification'

    $case=New-Scenario 'missing-after';$old=New-KnownPrivate $case;$journal=Invoke-Case $case
    [IO.File]::Delete($journal.Plan.Native.HelperPath)
    Assert-Test (-not (Test-CaseState $case $journal).Valid) 'missing helper invalidates installed status'
    Restore-Case $case|Out-Null;Assert-OldTuple $case $old 'missing owned helper still restores verified original tuple'

    $case=New-Scenario 'partial-helper';$old=New-KnownPrivate $case
    $manager=Join-Path $case.Root 'Manage-Mod.ps1';$text=[IO.File]::ReadAllText($manager)
    $text=$text.Replace("[IO.File]::Copy((Join-Path `$root 'dist\ManeaterAreaHelper.exe'),", "throw 'Fixture failure before helper copy'`n[IO.File]::Copy((Join-Path `$root 'dist\ManeaterAreaHelper.exe'),")
    [IO.File]::WriteAllText($manager,$text)
    Assert-Throws {Invoke-Case $case} 'partial new tuple before helper publication rolls back'
    Assert-OldTuple $case $old 'partial candidate copies recover exact original three-file setup'
    Assert-Test ((Read-Journal $case).Status -ceq 'restored') 'partial helper failure recovery recorded'

    $case=New-Scenario 'partial-backup';$old=New-KnownPrivate $case
    Inject-Function $case 'Invoke-ManeaterRepair' '# PREVIEW_BEFORE_BACKUP_PUBLISH' "[IO.File]::WriteAllText(`$staged,'partial inert backup');throw 'Injected staged backup failure'"
    Assert-Throws {Invoke-Case $case} 'interrupted backup stage reports failure'
    Assert-OldTuple $case $old 'backup failure leaves original tuple intact'
    $journal=Read-Journal $case
    Assert-Test ($journal.Status -ceq 'restored' -and -not [IO.File]::Exists($journal.Plan.Native.BackupMod) -and @(Get-ChildItem $journal.BackupDirectory -Filter 'native-backup-*.tmp').Count -eq 0) 'partial backup never published; clean recovery can retry'

    $case=New-Scenario 'partial-restore';$old=New-KnownPrivate $case;$journal=Invoke-Case $case
    Inject-Function $case 'Restore-NativeRepair' '# PREVIEW_BEFORE_RESTORE_PUBLISH' "[IO.File]::WriteAllText(`$staged,'partial inert restore');throw 'Injected staged restore failure'"
    Assert-Throws {Restore-Case $case} 'interrupted restore stage reports recovery required'
    Assert-Test (-not [IO.File]::Exists($old.Dll) -and (Hash $journal.Plan.Native.BackupMod) -ceq $old.DllHash -and @(Get-ChildItem $case.Bin -Filter 'native-restore-*.tmp').Count -eq 0) 'partial restore not published, verified original remains in backup'
    Inject-Function $case 'Restore-NativeRepair' '# PREVIEW_BEFORE_RESTORE_PUBLISH' '# Original publication restored in inert fixture'
    Restore-Case $case|Out-Null;Assert-OldTuple $case $old 'retry after interrupted stage restores tuple'

    $case=New-Scenario 'foreign-restore';$old=New-KnownPrivate $case;$journal=Invoke-Case $case
    Inject-Function $case 'Restore-NativeRepair' '# PREVIEW_BEFORE_RESTORE_PUBLISH' "[IO.File]::WriteAllText(`$entry.Target,'late foreign target')"
    Assert-Throws {Restore-Case $case} 'absent-only restore publication refuses late foreign target'
    Assert-Test ([IO.File]::ReadAllText($old.Dll) -ceq 'late foreign target' -and (Hash $journal.Plan.Native.BackupMod) -ceq $old.DllHash -and @(Get-ChildItem $case.Bin -Filter 'native-restore-*.tmp').Count -eq 0) 'late foreign bytes and original backup preserved'

    foreach($mode in @('missing','changed','vendor')){
        $case=New-Scenario ('helper-ready-'+$mode);Use-RealBundleReadiness $case
        if($mode -eq 'missing'){[IO.File]::Delete($case.Helper)}
        if($mode -eq 'changed'){[IO.File]::WriteAllText($case.Helper,'corrupt inert helper')}
        if($mode -eq 'vendor'){[IO.Directory]::CreateDirectory((Join-Path $case.Root 'vendor'))|Out-Null;[IO.File]::WriteAllText((Join-Path $case.Root 'vendor\new.c'),'unmanifested source')}
        Assert-Test (-not (& $case.Module {Get-RepairBuildReady})) "$mode helper/source provenance rejected"
        Assert-Throws {Invoke-Case $case} "$mode bundle failure stops preflight"
        Assert-Test (-not [IO.File]::Exists((Join-Path $case.Root '.local\repair.json')) -and (Same-Config $case)) "$mode readiness failure has no install side effects"
    }
    Write-Output "PASS: $script:passed preview tuple, helper, provenance and interruption contracts. All fixture binaries are inert."
}finally{
    $full=[IO.Path]::GetFullPath($testRoot);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^me-preview-repair-[0-9a-f]{32}$'){throw 'Unsafe preview fixture cleanup.'}
    Get-Module Repair,AnselFix,SteamFix,CpuPlan,Compiler,PeExports|Remove-Module -Force
    Remove-Item -LiteralPath $full -Recurse -Force
}
