# Reversible, write-ahead-planned Ansel SDK rename. The caller validates the
# selected executable/game root, closes the game and persists the plan BEFORE
# Apply. This module never writes a journal, downloads files or changes settings.
Set-StrictMode -Version Latest
$script:AnselKnownHash = '5560DA9B9D39F1DF17AB37ACDB66A19ED1F93F4F1C361590E05D7484D637D0C6'
$script:AnselRelativePath = 'Engine\Plugins\Runtime\Nvidia\Ansel\Binaries\ThirdParty\AnselSDK64.dll'
$script:AnselDisabledSuffix = '.disabled-by-maneater-crash-fps-fix'

function Get-AnselPaths {
    param([Parameter(Mandatory=$true)][string]$GameRoot)
    $root = [IO.Path]::GetFullPath($GameRoot)
    if ($root.Length -gt [IO.Path]::GetPathRoot($root).Length) { $root = $root.TrimEnd([char[]]'\/') }
    if (-not [IO.Directory]::Exists($root)) { throw 'The selected game root is not a directory.' }
    $original = [IO.Path]::GetFullPath((Join-Path $root $script:AnselRelativePath))
    $disabled = $original + $script:AnselDisabledSuffix
    $prefix = $root.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    foreach ($path in @($original, $disabled)) {
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Ansel path escapes the selected game root.' }
    }
    # The explicitly selected root may itself be a mounted/linked directory.
    # Descendant links must not redirect our fixed SDK paths outside that root.
    # This runs for normal status and every persisted-plan validation, not just
    # fixture overrides. Missing SDK directories are harmless and stay absent.
    $directory = [IO.Path]::GetDirectoryName($original)
    while ($directory -and -not [string]::Equals($directory, $root, [StringComparison]::OrdinalIgnoreCase)) {
        if (-not $directory.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Ansel parent path escapes the selected game root.' }
        $item = Get-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Ansel descendant directory links are preserved; automatic rename is refused.' }
        $directory = [IO.Path]::GetDirectoryName($directory)
    }
    foreach ($path in @($original, $disabled)) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Ansel SDK file links are preserved; automatic rename is refused.' }
    }
    [pscustomobject]@{ GameRoot=$root; OriginalPath=$original; DisabledPath=$disabled }
}

function Assert-AnselFixtureRoot {
    param([Parameter(Mandatory=$true)][string]$GameRoot)
    # Hash substitution is available only under this checkout's ignored,
    # GUID-named test directory. It cannot target a real selected installation.
    $tests = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\tests')).TrimEnd([char[]]'\/')
    $prefix = $tests + [IO.Path]::DirectorySeparatorChar
    if (-not $GameRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture hash override is restricted to isolated tests.' }
    $relative = $GameRoot.Substring($prefix.Length)
    if ($relative -notmatch '^\.tmp-[0-9a-fA-F]{32}[\\/]') { throw 'Fixture hash override requires a GUID-named isolated test directory.' }
    # A junction under an otherwise valid fixture prefix must not redirect
    # hash substitution or a rename into an actual installation.
    $directory = [IO.Path]::GetDirectoryName((Join-Path $GameRoot $script:AnselRelativePath))
    while ($directory -and $directory.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        if ([IO.Directory]::Exists($directory) -and
            ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Fixture directory links cannot be used for hash substitution.' }
        $directory = [IO.Path]::GetDirectoryName($directory)
    }
}

function Get-AnselFileHash {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Ansel SDK file links are preserved; automatic rename is refused.' }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-ManeaterAnselStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$GameRoot,
        [Parameter(DontShow=$true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$TestExpectedHash
    )
    $paths = Get-AnselPaths -GameRoot $GameRoot
    $expected = $script:AnselKnownHash
    $testOnly = $PSBoundParameters.ContainsKey('TestExpectedHash')
    if ($testOnly) { Assert-AnselFixtureRoot -GameRoot $paths.GameRoot; $expected = $TestExpectedHash.ToUpperInvariant() }
    $originalExists = [IO.File]::Exists($paths.OriginalPath)
    $disabledExists = [IO.File]::Exists($paths.DisabledPath)
    $originalHash = Get-AnselFileHash -Path $paths.OriginalPath
    $disabledHash = Get-AnselFileHash -Path $paths.DisabledPath
    $alternates = @()
    $parent = [IO.Path]::GetDirectoryName($paths.OriginalPath)
    if ([IO.Directory]::Exists($parent)) {
        $alternates = @(Get-ChildItem -LiteralPath $parent -Filter 'AnselSDK64.dll*' -File -Force |
            Where-Object { $_.FullName -ine $paths.OriginalPath -and $_.FullName -ine $paths.DisabledPath } |
            ForEach-Object { $_.Name })
    }
    $status = 'Missing'; $action = 'None'
    if ($originalExists -and $disabledExists) { $status = 'Conflict'; $action = 'Refuse' }
    elseif ($originalExists) {
        if ($originalHash -eq $expected) { $status = 'Ready'; $action = 'Disable' }
        else { $status = 'UnrecognizedOriginal'; $action = 'Refuse' }
    }
    elseif ($disabledExists) {
        if ($disabledHash -eq $expected) { $status = 'DisabledFilePresent' }
        else { $status = 'UnrecognizedDisabled'; $action = 'Refuse' }
    }
    elseif ($alternates.Count -gt 0) { $status = 'ExternallyDisabled' }
    $length = $null; $attributes = $null; $lastWriteUtc = $null
    if ($originalExists) {
        $item = Get-Item -LiteralPath $paths.OriginalPath -Force
        $length = [long]$item.Length; $attributes = [int]$item.Attributes; $lastWriteUtc = $item.LastWriteTimeUtc.ToString('o')
    }
    # This is the complete plan to persist before mutation. An existing file
    # with our suffix is NOT adopted as owned without a prior Disable plan.
    [pscustomobject][ordered]@{
        PlanVersion=1; Owner='maneater-crash-fps-fix'; Kind='AnselRename'; Action=$action; Status=$status
        GameRoot=$paths.GameRoot; OriginalPath=$paths.OriginalPath; DisabledPath=$paths.DisabledPath
        OriginalHash=$originalHash; DisabledHash=$disabledHash; ExpectedHash=$expected
        OriginalExists=$originalExists; DisabledExists=$disabledExists; AlternateFileNames=$alternates
        OriginalLength=$length; OriginalAttributes=$attributes; OriginalLastWriteUtc=$lastWriteUtc
        TestOnly=$testOnly
    }
}

function Assert-AnselPlan {
    param([Parameter(Mandatory=$true)]$Plan)
    if ($Plan.PlanVersion -ne 1 -or $Plan.Owner -cne 'maneater-crash-fps-fix' -or $Plan.Kind -cne 'AnselRename') { throw 'Unsupported Ansel rollback plan.' }
    $paths = Get-AnselPaths -GameRoot ([string]$Plan.GameRoot)
    if (-not [string]::Equals([string]$Plan.OriginalPath, $paths.OriginalPath, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$Plan.DisabledPath, $paths.DisabledPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Ansel plan paths do not match the fixed game-relative paths.' }
    $expected = $script:AnselKnownHash
    if ($Plan.TestOnly -isnot [bool]) { throw 'Invalid Ansel fixture flag.' }
    if ($Plan.TestOnly) {
        Assert-AnselFixtureRoot -GameRoot $paths.GameRoot
        if ([string]$Plan.ExpectedHash -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid fixture hash.' }
        $expected = ([string]$Plan.ExpectedHash).ToUpperInvariant()
    }
    if ([string]$Plan.ExpectedHash -cne $expected) { throw 'Ansel plan expected hash differs from the known SDK.' }
    if ($Plan.Action -notin @('Disable','None','Refuse')) { throw 'Invalid Ansel action.' }
    if ($Plan.Action -eq 'Disable' -and ($Plan.Status -cne 'Ready' -or
        $Plan.OriginalExists -ne $true -or $Plan.DisabledExists -ne $false -or
        [string]$Plan.OriginalHash -cne $expected -or $null -ne $Plan.DisabledHash)) { throw 'Ansel Disable plan did not record an eligible original and absent destination.' }
    $paths
}

function New-AnselResult {
    param($Plan, [string]$Outcome, [bool]$Changed, [bool]$MutationPresent)
    [pscustomobject]@{ Outcome=$Outcome; Changed=$Changed; MutationPresent=$MutationPresent; Plan=$Plan }
}

function Apply-ManeaterAnselFix {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Plan)
    $paths = Assert-AnselPlan -Plan $Plan
    if ($Plan.Action -eq 'Refuse') { throw 'Ansel files are unrecognized or conflicting; all files were preserved.' }
    if ($Plan.Action -eq 'None') { return New-AnselResult -Plan $Plan -Outcome 'Preserved' -Changed $false -MutationPresent $false }
    $originalExists = [IO.File]::Exists($paths.OriginalPath)
    $disabledExists = [IO.File]::Exists($paths.DisabledPath)
    if (-not $originalExists -and $disabledExists) {
        if ((Get-AnselFileHash -Path $paths.DisabledPath) -cne [string]$Plan.OriginalHash) { throw 'Previously planned disabled SDK changed; it was preserved.' }
        return New-AnselResult -Plan $Plan -Outcome 'AlreadyApplied' -Changed $false -MutationPresent $true
    }
    if ($disabledExists -or [IO.Directory]::Exists($paths.DisabledPath)) { throw 'Existing Ansel destination was preserved; rename was not performed.' }
    if (-not $originalExists -or (Get-AnselFileHash -Path $paths.OriginalPath) -cne [string]$Plan.OriginalHash) { throw 'Original Ansel SDK changed after planning; rename was not performed.' }
    # Same-directory non-overwriting rename. The caller's persisted plan also
    # supports restore after power loss between this move and the return.
    [IO.File]::Move($paths.OriginalPath, $paths.DisabledPath)
    if ((Get-AnselFileHash -Path $paths.DisabledPath) -cne [string]$Plan.OriginalHash) { throw 'Renamed SDK changed; preserve the journal and files for recovery.' }
    New-AnselResult -Plan $Plan -Outcome 'Applied' -Changed $true -MutationPresent $true
}

function Restore-ManeaterAnselFix {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][Alias('Transaction')]$Plan)
    $paths = Assert-AnselPlan -Plan $Plan
    if ($Plan.Action -ne 'Disable') { return New-AnselResult -Plan $Plan -Outcome 'Preserved' -Changed $false -MutationPresent $false }
    $originalExists = [IO.File]::Exists($paths.OriginalPath)
    $disabledExists = [IO.File]::Exists($paths.DisabledPath)
    if ($originalExists -and -not $disabledExists) {
        if ((Get-AnselFileHash -Path $paths.OriginalPath) -cne [string]$Plan.OriginalHash) { throw 'Original-name SDK changed; restore will not replace it.' }
        return New-AnselResult -Plan $Plan -Outcome 'AlreadyRestored' -Changed $false -MutationPresent $false
    }
    if ($originalExists -or [IO.Directory]::Exists($paths.OriginalPath)) { throw 'Original-name Ansel destination exists; both files were preserved.' }
    if (-not $disabledExists -or (Get-AnselFileHash -Path $paths.DisabledPath) -cne [string]$Plan.OriginalHash) { throw 'Owned disabled SDK is missing or changed; restore was not performed.' }
    [IO.File]::Move($paths.DisabledPath, $paths.OriginalPath)
    if ((Get-AnselFileHash -Path $paths.OriginalPath) -cne [string]$Plan.OriginalHash) { throw 'Restored SDK changed; preserve the journal and files for recovery.' }
    New-AnselResult -Plan $Plan -Outcome 'Restored' -Changed $true -MutationPresent $false
}

Export-ModuleMember -Function Get-ManeaterAnselStatus,Apply-ManeaterAnselFix,Restore-ManeaterAnselFix
