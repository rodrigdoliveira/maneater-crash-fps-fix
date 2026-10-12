# Isolated filesystem contracts. No installed game, DLL loading or journal IO.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
# Keep deeply nested source checkouts from exceeding Windows PowerShell's
# MAX_PATH. Exercise an unchanged module copy with the same fixture boundary.
$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=Join-Path $tempPrefix ('mfx-ansel-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $root 'scripts'))|Out-Null
[IO.Directory]::CreateDirectory((Join-Path $root 'tests'))|Out-Null
[IO.File]::Copy((Join-Path $sourceRoot 'scripts/AnselFix.psm1'),(Join-Path $root 'scripts/AnselFix.psm1'),$false)
Import-Module (Join-Path $root 'scripts\AnselFix.psm1') -Force -DisableNameChecking
$testRoot=Join-Path (Join-Path $root 'tests') ('.tmp-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot)|Out-Null
$script:passed=0
$script:fixtureLinks=@()
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:passed++}
function Assert-Throws([scriptblock]$Operation,[string]$Message){$caught=$false;try{& $Operation|Out-Null}catch{$caught=$true};Assert-Test $caught $Message}
function New-Game([string]$Name){$game=Join-Path $testRoot $Name;[IO.Directory]::CreateDirectory((Join-Path $game 'Engine\Plugins\Runtime\Nvidia\Ansel\Binaries\ThirdParty'))|Out-Null;return $game}
function Original([string]$Game){Join-Path $Game 'Engine\Plugins\Runtime\Nvidia\Ansel\Binaries\ThirdParty\AnselSDK64.dll'}
function Write-Sdk([string]$Path){[IO.File]::WriteAllBytes($Path,[byte[]](1,3,5,7,11,13));(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Fixture-Plan([string]$Game,[string]$Hash){Get-ManeaterAnselStatus -GameRoot $Game -TestExpectedHash $Hash}
try{
    $game=New-Game 'roundtrip';$original=Original $game;$hash=Write-Sdk $original
    $before=[IO.File]::ReadAllBytes($original);$plan=Fixture-Plan $game $hash
    Assert-Test ($plan.Status -eq 'Ready' -and $plan.Action -eq 'Disable') 'known original planned'
    Assert-Test ([IO.File]::Exists($original) -and -not [IO.File]::Exists($plan.DisabledPath)) 'planning is read-only'
    $journal=$plan|ConvertTo-Json -Depth 6|ConvertFrom-Json
    $result=Apply-ManeaterAnselFix -Plan $journal
    Assert-Test ($result.Outcome -eq 'Applied' -and $result.Changed -and $result.MutationPresent) 'apply result'
    Assert-Test (-not [IO.File]::Exists($original) -and (Get-FileHash $plan.DisabledPath -Algorithm SHA256).Hash -eq $hash) 'rename preserves hash'
    $repeat=Apply-ManeaterAnselFix -Plan $journal
    Assert-Test ($repeat.Outcome -eq 'AlreadyApplied' -and -not $repeat.Changed) 'persisted-plan retry'
    $now=Fixture-Plan $game $hash
    Assert-Test ($now.Status -eq 'DisabledFilePresent' -and $now.Action -eq 'None') 'preexisting suffix is not adopted'
    $result=Restore-ManeaterAnselFix -Plan $journal
    Assert-Test ($result.Outcome -eq 'Restored' -and $result.Changed -and -not $result.MutationPresent) 'restore after journal serialization'
    Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes($original)) -eq [Convert]::ToBase64String($before)) 'roundtrip byte preservation'
    Assert-Test ((Restore-ManeaterAnselFix -Plan $journal).Outcome -eq 'AlreadyRestored') 'restore idempotent'
    $result=Restore-ManeaterAnselFix -Plan $now
    Assert-Test ($result.Outcome -eq 'Preserved' -and -not $result.Changed) 'new status cannot claim old mutation'

    $game=New-Game 'external';$original=Original $game;$hash=Write-Sdk ($original+'.disabled-by-codex')
    $plan=Fixture-Plan $game $hash
    Assert-Test ($plan.Status -eq 'ExternallyDisabled' -and $plan.Action -eq 'None') 'external disabled status'
    Assert-Test ((Apply-ManeaterAnselFix -Plan $plan).Outcome -eq 'Preserved') 'external state preserved on apply'
    Assert-Test ((Restore-ManeaterAnselFix -Plan $plan).Outcome -eq 'Preserved' -and [IO.File]::Exists($original+'.disabled-by-codex')) 'external state preserved on restore'
    $game=New-Game 'missing';$plan=Fixture-Plan $game $hash
    Assert-Test ($plan.Status -eq 'Missing' -and $plan.Action -eq 'None') 'missing SDK harmless'

    $game=New-Game 'foreign';$original=Original $game;$hash=Write-Sdk $original
    $plan=Get-ManeaterAnselStatus -GameRoot $game
    Assert-Test ($plan.Status -eq 'UnrecognizedOriginal' -and $plan.Action -eq 'Refuse') 'production hash not overridden'
    Assert-Throws {Apply-ManeaterAnselFix -Plan $plan} 'unknown SDK refused'
    $plan=Fixture-Plan $game $hash;[IO.File]::WriteAllText($plan.DisabledPath,'foreign destination')
    Assert-Throws {Apply-ManeaterAnselFix -Plan $plan} 'destination created after planning preserved'
    Assert-Test ([IO.File]::ReadAllText($plan.DisabledPath) -eq 'foreign destination' -and [IO.File]::Exists($original)) 'neither conflicting file overwritten'
    $both=Fixture-Plan $game $hash
    Assert-Test ($both.Status -eq 'Conflict' -and $both.Action -eq 'Refuse') 'both files refuse plan'

    $game=New-Game 'sourcechanged';$original=Original $game;$hash=Write-Sdk $original;$plan=Fixture-Plan $game $hash
    [IO.File]::WriteAllText($original,'changed source')
    Assert-Throws {Apply-ManeaterAnselFix -Plan $plan} 'changed source refused'
    Assert-Test (-not [IO.File]::Exists($plan.DisabledPath)) 'failed source check has no rename'

    $game=New-Game 'backupchanged';$original=Original $game;$hash=Write-Sdk $original;$plan=Fixture-Plan $game $hash
    Apply-ManeaterAnselFix -Plan $plan|Out-Null;[IO.File]::WriteAllText($plan.DisabledPath,'changed backup')
    Assert-Throws {Restore-ManeaterAnselFix -Plan $plan} 'changed owned hash preserved'
    Assert-Test ([IO.File]::ReadAllText($plan.DisabledPath) -eq 'changed backup' -and -not [IO.File]::Exists($original)) 'changed backup not consumed'

    $game=New-Game 'restoredestination';$original=Original $game;$hash=Write-Sdk $original;$plan=Fixture-Plan $game $hash
    Apply-ManeaterAnselFix -Plan $plan|Out-Null;Write-Sdk $original|Out-Null
    Assert-Throws {Restore-ManeaterAnselFix -Plan $plan} 'restore destination never overwritten even same hash'
    Assert-Test ([IO.File]::Exists($original) -and [IO.File]::Exists($plan.DisabledPath)) 'both restore-conflict files retained'

    $game=New-Game 'pathguard';$original=Original $game;$hash=Write-Sdk $original;$plan=Fixture-Plan $game $hash
    $altered=$plan|ConvertTo-Json -Depth 6|ConvertFrom-Json;$altered.DisabledPath=Join-Path $testRoot 'unrelated.dll'
    Assert-Throws {Apply-ManeaterAnselFix -Plan $altered} 'tampered target refused'
    $altered=$plan|ConvertTo-Json -Depth 6|ConvertFrom-Json;$altered.ExpectedHash='0'*64
    Assert-Throws {Apply-ManeaterAnselFix -Plan $altered} 'tampered expected/recorded source hash refused'
    Assert-Throws {Get-ManeaterAnselStatus -GameRoot $root -TestExpectedHash $hash} 'test injection forbidden outside ignored fixtures'
    Assert-Test ([IO.File]::Exists($original)) 'guard failures retain original'

    $game=New-Game 'backupdirectory';$original=Original $game;$hash=Write-Sdk $original;$plan=Fixture-Plan $game $hash
    [IO.Directory]::CreateDirectory($plan.DisabledPath)|Out-Null
    Assert-Throws {Apply-ManeaterAnselFix -Plan $plan} 'directory occupying rename destination preserved'
    Assert-Test ([IO.Directory]::Exists($plan.DisabledPath) -and [IO.File]::Exists($original)) 'destination directory and original retained'

    # Simulate power loss after rename and before the Apply return: rollback
    # needs only the PRE-mutation plan, not any completion metadata.
    $game=New-Game 'powerloss';$original=Original $game;$hash=Write-Sdk $original;$plan=Fixture-Plan $game $hash
    [IO.File]::Move($original,$plan.DisabledPath)
    Assert-Test ((Restore-ManeaterAnselFix -Plan $plan).Outcome -eq 'Restored') 'write-ahead plan recovers interrupted apply'

    # Exercise the NORMAL path, with no TestExpectedHash argument. Only an
    # isolated module copy substitutes the fixture SDK hash for its known hash.
    $normalModulePath=Join-Path $testRoot 'normal_ansel.psm1'
    $normalSource=[IO.File]::ReadAllText((Join-Path $root 'scripts\AnselFix.psm1'))
    $normalSource=$normalSource.Replace('5560DA9B9D39F1DF17AB37ACDB66A19ED1F93F4F1C361590E05D7484D637D0C6',$hash)
    [IO.File]::WriteAllText($normalModulePath,$normalSource)
    $normalModule=Import-Module $normalModulePath -Force -PassThru -DisableNameChecking
    $target=New-Game 'linked-target';$targetOriginal=Original $target;Write-Sdk $targetOriginal|Out-Null
    $game=Join-Path $testRoot 'normal-parent-link';[IO.Directory]::CreateDirectory($game)|Out-Null
    $link=Join-Path $game 'Engine';New-Item -ItemType Junction -Path $link -Target (Join-Path $target 'Engine')|Out-Null;$script:fixtureLinks+=$link
    Assert-Throws {& $normalModule {param($Game) Get-ManeaterAnselStatus -GameRoot $Game} $game} 'normal known-hash status rejects linked SDK ancestor'
    Assert-Test ([IO.File]::Exists($targetOriginal) -and -not [IO.File]::Exists($targetOriginal+'.disabled-by-maneater-crash-fps-fix')) 'normal link refusal preserves external fixture SDK'

    $game=New-Game 'normal-plan-link';$original=Original $game;Write-Sdk $original|Out-Null
    $plan=& $normalModule {param($Game) Get-ManeaterAnselStatus -GameRoot $Game} $game
    Assert-Test ($plan.Action -eq 'Disable' -and -not $plan.TestOnly) 'normal fixture plan uses production path validation'
    $engine=Join-Path $game 'Engine';$moved=Join-Path $testRoot 'moved-engine'
    # Both resolved move targets are explicitly inside this isolated GUID root.
    foreach($path in @($engine,$moved)){if(-not [IO.Path]::GetFullPath($path).StartsWith([IO.Path]::GetFullPath($testRoot)+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture move target.'}}
    [IO.Directory]::Move($engine,$moved)
    New-Item -ItemType Junction -Path $engine -Target $moved|Out-Null;$script:fixtureLinks+=$engine
    Assert-Throws {& $normalModule {param($Plan) Apply-ManeaterAnselFix -Plan $Plan} $plan} 'normal Apply rechecks ancestor changed after planning'
    Assert-Test ([IO.File]::Exists($original) -and -not [IO.File]::Exists($plan.DisabledPath)) 'late link preserves SDK on Apply'
    [IO.Directory]::Delete($engine);[IO.Directory]::Move($moved,$engine)
    & $normalModule {param($Plan) Apply-ManeaterAnselFix -Plan $Plan|Out-Null} $plan
    [IO.Directory]::Move($engine,$moved);New-Item -ItemType Junction -Path $engine -Target $moved|Out-Null
    Assert-Throws {& $normalModule {param($Plan) Restore-ManeaterAnselFix -Plan $Plan} $plan} 'normal Restore rechecks linked SDK ancestor'
    Assert-Test ([IO.File]::Exists($plan.DisabledPath) -and -not [IO.File]::Exists($original)) 'late link preserves disabled SDK on Restore'

    $selectedRootLink=Join-Path $testRoot 'explicit-root-link'
    New-Item -ItemType Junction -Path $selectedRootLink -Target $target|Out-Null;$script:fixtureLinks+=$selectedRootLink
    $selectedPlan=& $normalModule {param($Game) Get-ManeaterAnselStatus -GameRoot $Game} $selectedRootLink
    Assert-Test ($selectedPlan.Action -eq 'Disable') 'explicitly selected linked game root remains allowed'
    Write-Output "PASS: $script:passed Ansel contracts; no installed-game files accessed or changed."
}finally{
    $full=[IO.Path]::GetFullPath($testRoot);$tests=[IO.Path]::GetFullPath((Join-Path $root 'tests')).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($tests,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^\.tmp-[0-9a-f]{32}$'){throw 'Unsafe test cleanup target.'}
    # Remove only the fixture junction entries, never recursively their targets.
    foreach($link in $script:fixtureLinks){
        if(-not [IO.Path]::GetFullPath($link).StartsWith($full+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture link cleanup target.'}
        $item=Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        if($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){[IO.Directory]::Delete($link)}
    }
    if($null -ne (Get-Module normal_ansel)){Get-Module normal_ansel|Remove-Module -Force}
    Remove-Item -LiteralPath $full -Recurse -Force
    $safeRoot=[IO.Path]::GetFullPath($root)
    if(-not $safeRoot.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($safeRoot) -notmatch '^mfx-ansel-[0-9a-f]{32}$'){throw 'Unsafe outer fixture cleanup target.'}
    Get-Module AnselFix | Where-Object {$_.Path -ieq (Join-Path $root 'scripts/AnselFix.psm1')} | Remove-Module -Force
    Remove-Item -LiteralPath $safeRoot -Recurse -Force
}
