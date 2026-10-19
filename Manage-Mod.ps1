[CmdletBinding()]
param([ValidateSet('Install', 'Uninstall', 'Status')][string]$Action = 'Status', [string]$GameDirectory,
      [switch]$AllowUntestedBuild, [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedGameSHA256,
      [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedModSHA256,
      [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedSystemSHA256)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$stateDirectory = Join-Path $root '.local'
$statePath = Join-Path $stateDirectory 'installation.json'
$supportedGameHash = 'CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0'
Import-Module (Join-Path $root 'scripts\PeExports.psm1') -Force

function Resolve-GameBin {
    param([Parameter(Mandatory = $true)][string]$Directory, [switch]$RequireExecutable)
    $resolved = (Resolve-Path -LiteralPath $Directory).ProviderPath
    if (-not [IO.Directory]::Exists($resolved)) { throw 'GameDirectory must be a directory.' }
    if ([IO.File]::Exists((Join-Path $resolved 'Maneater-Win64-Shipping.exe'))) { $bin = $resolved }
    elseif ([IO.File]::Exists((Join-Path $resolved 'Maneater\Binaries\Win64\Maneater-Win64-Shipping.exe'))) { $bin = Join-Path $resolved 'Maneater\Binaries\Win64' }
    elseif (-not $RequireExecutable -and [IO.Path]::GetFileName($resolved.TrimEnd('\')) -ieq 'Win64') { $bin = $resolved }
    else { throw 'Specify the Maneater game root or its Binaries\Win64 directory.' }
    return [IO.Path]::GetFullPath($bin).TrimEnd('\')
}
function Assert-GameClosed {
    if (@(Get-Process -Name 'Maneater', 'Maneater-Win64-Shipping' -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'Quit Maneater before installing or uninstalling.'
    }
}
function Get-Hash { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Get-RequiredBuildSources {
    $required = [Collections.Generic.List[string]]::new()
    foreach ($folder in @('src','vendor')) {
        $directory = Join-Path $root $folder
        if ([IO.Directory]::Exists($directory)) {
            foreach ($file in Get-ChildItem -LiteralPath $directory -File -Recurse | Sort-Object FullName) {
                $required.Add($file.FullName.Substring($root.Length+1).Replace('\','/'))
            }
        }
    }
    foreach ($name in @('scripts/PeExports.psm1','build.ps1','Manage-Mod.ps1')) { $required.Add($name) }
    return $required.ToArray()
}
function Read-GameHeaderBytes {
    param([IO.Stream]$Stream, [int]$Count)
    $bytes = New-Object byte[] $Count; $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($bytes, $offset, $Count - $offset)
        if ($read -eq 0) { throw 'Malformed game executable: incomplete PE header.' }
        $offset += $read
    }
    return ,$bytes
}
function Assert-GamePeHeader {
    param([string]$Path)
    # Check only bounded file headers. Packed game exports are not enumerated,
    # and a renamed DLL/plain file cannot qualify for untested-build opt-in.
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
    try {
        if ($stream.Length -lt 64) { throw 'Choose a valid Windows AMD64 game executable.' }
        $dos = Read-GameHeaderBytes $stream 64
        if ([BitConverter]::ToUInt16($dos, 0) -ne 0x5a4d) { throw 'Choose a valid Windows AMD64 game executable (missing MZ header).' }
        $ntOffset = [long][BitConverter]::ToUInt32($dos, 60)
        if ($ntOffset -lt 64 -or $ntOffset -gt 1048576 -or $ntOffset -gt ($stream.Length - 24)) { throw 'Malformed game executable: PE header offset is outside its bounds.' }
        $stream.Position = $ntOffset
        $nt = Read-GameHeaderBytes $stream 24
        $sections = [int][BitConverter]::ToUInt16($nt, 6)
        $optionalSize = [int][BitConverter]::ToUInt16($nt, 20)
        $characteristics = [BitConverter]::ToUInt16($nt, 22)
        if ([BitConverter]::ToUInt32($nt, 0) -ne 0x4550 -or [BitConverter]::ToUInt16($nt, 4) -ne 0x8664 -or
            ($characteristics -band 2) -eq 0 -or ($characteristics -band 0x2000) -ne 0) { throw 'Choose a Windows AMD64 executable, not a DLL or another architecture.' }
        $headerEnd = $ntOffset + 24 + $optionalSize + 40 * $sections
        if ($sections -lt 1 -or $sections -gt 96 -or $optionalSize -lt 112 -or $optionalSize -gt 4096 -or $headerEnd -gt $stream.Length) { throw 'Malformed game executable: optional or section headers are outside their bounds.' }
        $optional = Read-GameHeaderBytes $stream $optionalSize
        $entry = [long][BitConverter]::ToUInt32($optional, 16)
        $imageSize = [long][BitConverter]::ToUInt32($optional, 56)
        $headersSize = [long][BitConverter]::ToUInt32($optional, 60)
        if ([BitConverter]::ToUInt16($optional, 0) -ne 0x20b -or $headersSize -lt $headerEnd -or
            $headersSize -gt $stream.Length -or $imageSize -lt $headersSize -or $entry -lt 1 -or $entry -ge $imageSize) { throw 'Malformed game executable: invalid PE32+ image headers.' }
    } finally { $stream.Dispose() }
}
function Assert-OwnedTarget {
    param([string]$Path, [string]$Expected, [string]$Bin)
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($full) -ine $Bin) { throw 'Unexpected target directory; no file removed.' }
    if ($Expected -notmatch '^[0-9A-Fa-f]{64}$' -or (Get-Hash $full) -ine $Expected) { throw "File changed since installation; preserving it: $full" }
}
function Write-State {
    param($State)
    [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
    $temporary = Join-Path $stateDirectory ('installation-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Depth 5) + "`n", [Text.UTF8Encoding]::new($false))
        if ($null -eq $stateExpectedHash) { [IO.File]::Move($temporary,$statePath) }
        else {
            if (-not [IO.File]::Exists($statePath) -or (Get-Hash $statePath) -cne $stateExpectedHash) { throw 'Native ownership record changed; preserving it.' }
            [IO.File]::Replace($temporary,$statePath,[NullString]::Value)
        }
    } finally { if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary } }
}
$state = $null
$stateExpectedHash = $null
if ([IO.File]::Exists($statePath)) {
    $stateExpectedHash = Get-Hash $statePath
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ((Get-Hash $statePath) -cne $stateExpectedHash) { throw 'Native ownership record changed while reading it.' }
    if ($state.SchemaVersion -eq 1) {
        if ($state.GameSHA256 -ine $supportedGameHash) { throw 'Unsupported legacy installation record.' }
    } elseif ($state.SchemaVersion -in @(2,3)) {
        if ($state.GameSHA256 -notmatch '^[0-9A-Fa-f]{64}$' -or $state.TestedBuild -isnot [bool] -or
            $state.UntestedBuildOptIn -isnot [bool] -or $state.TestedBuild -ne ($state.GameSHA256 -ieq $supportedGameHash) -or
            (-not $state.TestedBuild -and -not $state.UntestedBuildOptIn)) { throw 'Unsupported or inconsistent installation record.' }
        if ($state.SchemaVersion -eq 3 -and $state.HelperSHA256 -cnotmatch '^[0-9A-F]{64}$') { throw 'Invalid helper ownership hash.' }
    } else { throw 'Unsupported installation record.' }
}
$bin = $null
if (-not [string]::IsNullOrWhiteSpace($GameDirectory)) { $bin = Resolve-GameBin $GameDirectory -RequireExecutable:($Action -eq 'Install') }
elseif ($Action -eq 'Install') { throw 'Install requires -GameDirectory <Maneater root or Binaries\Win64>.' }
elseif ($null -ne $state) {
    # Status and an already-completed uninstall still work if Steam has since
    # removed the game directory. A record always stores an absolute Win64 path.
    if (-not [IO.Path]::IsPathRooted($state.GameDirectory)) { throw 'Installation record must contain an absolute game directory.' }
    $bin = [IO.Path]::GetFullPath($state.GameDirectory).TrimEnd('\')
}
if ($null -ne $state -and $null -ne $bin -and $state.Status -eq 'installed' -and $state.GameDirectory -ine $bin) {
    throw 'This source folder tracks another installation; uninstall that record first.'
}
if ($Action -eq 'Status') {
    $proxyPresent = $false; $systemPresent = $false; $helperPresent = $false
    if ($null -ne $bin) { $proxyPresent = [IO.File]::Exists((Join-Path $bin 'dxgi.dll')); $systemPresent = [IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll')); $helperPresent = [IO.File]::Exists((Join-Path $bin 'ManeaterAreaHelper.exe')) }
    [pscustomobject]@{ GameDirectory = $bin; ProxyPresent = $proxyPresent; SystemCopyPresent = $systemPresent; HelperPresent = $helperPresent; StatePresent = $null -ne $state
        RecordedStatus = $(if ($null -ne $state) { $state.Status } else { 'none' }); GameSHA256 = $(if ($null -ne $state) { $state.GameSHA256 } else { $null })
        TestedBuild = $(if ($null -eq $state) { $null } elseif ($state.SchemaVersion -eq 1) { $true } else { $state.TestedBuild })
        UntestedBuildOptIn = $(if ($null -eq $state -or $state.SchemaVersion -eq 1) { $false } else { $state.UntestedBuildOptIn }) }
    return
}
Assert-GameClosed
if ($Action -eq 'Uninstall') {
    if ($null -eq $state) { throw 'No installation record; no files removed.' }
    if ($state.Status -eq 'uninstalled') { 'Already uninstalled.'; return }
    if ($state.Status -ne 'installed' -or $state.GameDirectory -ine $bin) { throw 'Installation record does not match the selected game directory.' }
    $targets = @(@{ Path = Join-Path $bin 'dxgi.dll'; Hash = $state.ModSHA256 }, @{ Path = Join-Path $bin 'dxgi_codex_system.dll'; Hash = $state.SystemSHA256 })
    if ($state.SchemaVersion -eq 3) { $targets += @{ Path = Join-Path $bin 'ManeaterAreaHelper.exe'; Hash = $state.HelperSHA256 } }
    # Verify the whole owned tuple before deleting any member.
    foreach ($entry in $targets) { if ([IO.File]::Exists($entry.Path)) { Assert-OwnedTarget $entry.Path $entry.Hash $bin } }
    if (-not [IO.File]::Exists($statePath) -or (Get-Hash $statePath) -cne $stateExpectedHash) { throw 'Native ownership record changed; preserving the current files.' }
    foreach ($entry in $targets) { if ([IO.File]::Exists($entry.Path)) { Remove-Item -LiteralPath $entry.Path } }
    $state.Status = 'uninstalled'; Write-State $state
    'Combined native fixes uninstalled.'; return
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) { throw 'Install with 64-bit PowerShell on Windows.' }
$gameExe = Join-Path $bin 'Maneater-Win64-Shipping.exe'
Assert-GamePeHeader $gameExe
$gameHash = Get-Hash $gameExe
if ($PSBoundParameters.ContainsKey('ExpectedGameSHA256') -and $gameHash -ine $ExpectedGameSHA256) { throw 'Game executable changed since selection; nothing installed. Select it again.' }
$testedBuild = $gameHash -ieq $supportedGameHash
if (-not $testedBuild -and -not $AllowUntestedBuild) { throw 'This game build is untested. Explicit -AllowUntestedBuild is required to proceed; nothing installed.' }
$dist = Join-Path $root 'dist'; $modSource = Join-Path $dist 'dxgi.dll'; $definition = Join-Path $dist 'dxgi_proxy.def'; $helperSource = Join-Path $dist 'ManeaterAreaHelper.exe'
$manifest = Get-Content -LiteralPath (Join-Path $dist 'build.json') -Raw | ConvertFrom-Json
if ($manifest.SchemaVersion -ne 1 -or $manifest.Version -cne '0.9.2' -or $manifest.GameSHA256 -ine $supportedGameHash -or $manifest.TargetFPS -ne 120 -or $manifest.HelperSHA256 -cnotmatch '^[0-9A-F]{64}$') { throw 'Unsupported build manifest.' }
$requiredSources = @(Get-RequiredBuildSources)
if (@($manifest.SourceHashes.PSObject.Properties).Count -ne $requiredSources.Count -or 'src/maneater_fps_hook.c' -cnotin $requiredSources) { throw 'Incomplete build source provenance.' }
foreach ($relative in $requiredSources) {
    $recorded = $manifest.SourceHashes.PSObject.Properties[$relative]
    if ($null -eq $recorded -or (Get-Hash (Join-Path $root $relative)) -ine $recorded.Value) { throw 'Source scripts changed since compilation; rebuild before installing.' }
}
if ((Get-Hash $modSource) -ine $manifest.ModSHA256 -or (Get-Hash $definition) -ine $manifest.DefinitionSHA256 -or (Get-Hash $helperSource) -cne $manifest.HelperSHA256) { throw 'Built files changed; rebuild before installing.' }
$system = Get-VerifiedWindowsDxgi
if ((Get-ExportContractHash -Exports @($manifest.SystemExports)) -cne $manifest.SystemExportsSHA256) { throw 'The packaged graphics manifest failed verification.' }
$proxy = Get-PeExportTable -Path $modSource
if ($proxy.FileSHA256 -cne $manifest.ModSHA256 -or $proxy.ContractSHA256 -cne $manifest.ModExportsSHA256) {
    throw 'Proxy changed during validation or differs from its build manifest.'
}
$portable=$null-ne$manifest.PSObject.Properties['ForwardingMode']
$adapted=$null
if($portable){
    if($manifest.ForwardingMode-cne'LocalExportTableV1'){throw 'Unsupported graphics forwarding mode.'}
    $baseContract=[pscustomobject]@{ContractSHA256=$manifest.SystemExportsSHA256;Exports=$manifest.SystemExports}
    Assert-DxgiForwarderTable -Proxy $proxy -System $baseContract
    $adapted=New-DxgiForwarderImage -TemplatePath $modSource -System $system.Table
}else{Assert-DxgiForwarderTable -Proxy $proxy -System $system.Table}
$modTarget = Join-Path $bin 'dxgi.dll'; $systemTarget = Join-Path $bin 'dxgi_codex_system.dll'; $helperTarget = Join-Path $bin 'ManeaterAreaHelper.exe'
foreach ($target in @($modTarget, $systemTarget, $helperTarget)) { if (Test-Path -LiteralPath $target) { throw "Existing file preserved: $target" } }
$systemHash = $system.Table.FileSHA256; $modHash = $(if($portable){$adapted.FileSHA256}else{[string]$manifest.ModSHA256}); $helperHash = [string]$manifest.HelperSHA256; $copiedSystem = $false; $copiedMod = $false; $copiedHelper = $false
if($ExpectedModSHA256 -and $modHash -ine $ExpectedModSHA256){throw 'The prepared graphics wrapper changed since preflight. Retry Apply; nothing installed.'}
if($ExpectedSystemSHA256 -and $systemHash -ine $ExpectedSystemSHA256){throw 'Windows graphics changed since preflight. Retry Apply; nothing installed.'}
Assert-GameClosed
$copyGameHash = Get-Hash $gameExe
if ($copyGameHash -cne $gameHash) { throw 'Game executable changed during preparation; nothing installed. Select it again.' }
$stageSystem = Join-Path $bin ('native-system-' + [Guid]::NewGuid().ToString('N') + '.tmp')
$stageMod = Join-Path $bin ('native-mod-' + [Guid]::NewGuid().ToString('N') + '.tmp')
$stageHelper = Join-Path $bin ('native-helper-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::Copy($system.Path,$stageSystem,$false)
    if($portable){[IO.File]::WriteAllBytes($stageMod,$adapted.Bytes)}else{[IO.File]::Copy($modSource,$stageMod,$false)}
    [IO.File]::Copy($helperSource,$stageHelper,$false)
    if ((Get-Hash $stageSystem) -cne $systemHash -or (Get-Hash $stageMod) -cne $modHash -or (Get-Hash $stageHelper) -cne $helperHash -or (Get-Hash $modSource) -cne $manifest.ModSHA256) { throw 'Staged native tuple changed; nothing published.' }
    if($portable){Assert-DxgiForwarderTable -Proxy (Get-PeExportTable $stageMod) -System (Get-PeExportTable $stageSystem) -Portable}
    Assert-GameClosed
    if ((Get-Hash $gameExe) -cne $gameHash) { throw 'Game executable changed before native publication.' }
    if ($null -ne $stateExpectedHash -and (-not [IO.File]::Exists($statePath) -or (Get-Hash $statePath) -cne $stateExpectedHash)) { throw 'Native ownership record changed during preparation.' }
    # Publication is absent-only. The composite repair journal owns recovery
    # from a terminated install; the direct manager rolls back known bytes.
    [IO.File]::Move($stageSystem,$systemTarget); $copiedSystem = $true
    [IO.File]::Move($stageMod,$modTarget); $copiedMod = $true
    # PREVIEW_BEFORE_HELPER_PUBLISH
    [IO.File]::Move($stageHelper,$helperTarget); $copiedHelper = $true
    Assert-OwnedTarget $systemTarget $systemHash $bin; Assert-OwnedTarget $modTarget $modHash $bin; Assert-OwnedTarget $helperTarget $helperHash $bin
    Write-State ([pscustomobject]@{ SchemaVersion = 3; Status = 'installed'; GameDirectory = $bin; GameSHA256 = $gameHash
        TestedBuild = [bool]$testedBuild; UntestedBuildOptIn = [bool](-not $testedBuild -and $AllowUntestedBuild)
        ModSHA256 = $modHash; SystemSHA256 = $systemHash; HelperSHA256 = $helperHash; SystemExportsSHA256 = $system.Table.ContractSHA256; InstalledUTC = [DateTime]::UtcNow.ToString('o') })
    if ($testedBuild) { 'Combined native fixes installed. Check maneater_codex_fps.log after loading a save.' }
    else { 'Combined native fixes installed for an untested build. Runtime guards may leave hooks inactive; check maneater_codex_fps.log after loading a save.' }
} catch {
    $installationError = $_
    $rollbackErrors = @()
    foreach ($entry in @(@{ Copied = $copiedMod; Path = $modTarget; Hash = $modHash }, @{ Copied = $copiedSystem; Path = $systemTarget; Hash = $systemHash }, @{ Copied = $copiedHelper; Path = $helperTarget; Hash = $helperHash })) {
        if ($entry.Copied -and [IO.File]::Exists($entry.Path)) {
            try { Assert-OwnedTarget $entry.Path $entry.Hash $bin; Remove-Item -LiteralPath $entry.Path }
            catch { $rollbackErrors += $_.Exception.Message }
        }
    }
    if ($rollbackErrors.Count -ne 0) { throw ('Installation failed: ' + $installationError.Exception.Message + ' Rollback preserved changed files: ' + ($rollbackErrors -join '; ')) }
    throw $installationError
} finally {
    foreach ($staged in @($stageMod,$stageSystem,$stageHelper)) { if ([IO.File]::Exists($staged)) { [IO.File]::Delete($staged) } }
}
