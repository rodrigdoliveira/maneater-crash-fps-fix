[CmdletBinding()]
param([ValidateSet('Install', 'Uninstall', 'Status')][string]$Action = 'Status', [string]$GameDirectory,
      [switch]$AllowUntestedBuild, [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedGameSHA256)
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
        Move-Item -LiteralPath $temporary -Destination $statePath -Force
    } finally { if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary } }
}
$state = $null
if ([IO.File]::Exists($statePath)) {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.SchemaVersion -eq 1) {
        if ($state.GameSHA256 -ine $supportedGameHash) { throw 'Unsupported legacy installation record.' }
    } elseif ($state.SchemaVersion -eq 2) {
        if ($state.GameSHA256 -notmatch '^[0-9A-Fa-f]{64}$' -or $state.TestedBuild -isnot [bool] -or
            $state.UntestedBuildOptIn -isnot [bool] -or $state.TestedBuild -ne ($state.GameSHA256 -ieq $supportedGameHash) -or
            (-not $state.TestedBuild -and -not $state.UntestedBuildOptIn)) { throw 'Unsupported or inconsistent installation record.' }
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
    $proxyPresent = $false; $systemPresent = $false
    if ($null -ne $bin) { $proxyPresent = [IO.File]::Exists((Join-Path $bin 'dxgi.dll')); $systemPresent = [IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll')) }
    [pscustomobject]@{ GameDirectory = $bin; ProxyPresent = $proxyPresent; SystemCopyPresent = $systemPresent; StatePresent = $null -ne $state
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
    # Verify both before deleting either; preserve all files if one is foreign.
    foreach ($entry in $targets) { if ([IO.File]::Exists($entry.Path)) { Assert-OwnedTarget $entry.Path $entry.Hash $bin } }
    foreach ($entry in $targets) { if ([IO.File]::Exists($entry.Path)) { Remove-Item -LiteralPath $entry.Path } }
    $state.Status = 'uninstalled'; Write-State $state
    'Native FPS mod uninstalled.'; return
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) { throw 'Install with 64-bit PowerShell on Windows.' }
$gameExe = Join-Path $bin 'Maneater-Win64-Shipping.exe'
Assert-GamePeHeader $gameExe
$gameHash = Get-Hash $gameExe
if ($PSBoundParameters.ContainsKey('ExpectedGameSHA256') -and $gameHash -ine $ExpectedGameSHA256) { throw 'Game executable changed since selection; nothing installed. Select it again.' }
$testedBuild = $gameHash -ieq $supportedGameHash
if (-not $testedBuild -and -not $AllowUntestedBuild) { throw 'This game build is untested. Explicit -AllowUntestedBuild is required to proceed; nothing installed.' }
$dist = Join-Path $root 'dist'; $modSource = Join-Path $dist 'dxgi.dll'; $definition = Join-Path $dist 'dxgi_proxy.def'
$manifest = Get-Content -LiteralPath (Join-Path $dist 'build.json') -Raw | ConvertFrom-Json
if ($manifest.SchemaVersion -ne 1 -or $manifest.GameSHA256 -ine $supportedGameHash -or $manifest.TargetFPS -ne 120) { throw 'Unsupported build manifest.' }
foreach ($relative in @('src/maneater_fps_hook.c', 'scripts/PeExports.psm1', 'build.ps1', 'Manage-Mod.ps1')) {
    $recorded = $manifest.SourceHashes.PSObject.Properties[$relative]
    if ($null -eq $recorded -or (Get-Hash (Join-Path $root $relative)) -ine $recorded.Value) { throw 'Source scripts changed since compilation; rebuild before installing.' }
}
if ((Get-Hash $modSource) -ine $manifest.ModSHA256 -or (Get-Hash $definition) -ine $manifest.DefinitionSHA256) { throw 'Built files changed; rebuild before installing.' }
$system = Get-VerifiedWindowsDxgi
if ($system.Table.ContractSHA256 -cne $manifest.SystemExportsSHA256 -or
    (Get-ExportContractHash -Exports @($manifest.SystemExports)) -cne $manifest.SystemExportsSHA256) { throw 'Windows DXGI export contract changed; rebuild before installing.' }
$proxy = Get-PeExportTable -Path $modSource
if ($proxy.FileSHA256 -cne $manifest.ModSHA256 -or $proxy.ContractSHA256 -cne $manifest.ModExportsSHA256) {
    throw 'Proxy changed during validation or differs from its build manifest.'
}
Assert-DxgiForwarderTable -Proxy $proxy -System $system.Table
$modTarget = Join-Path $bin 'dxgi.dll'; $systemTarget = Join-Path $bin 'dxgi_codex_system.dll'
foreach ($target in @($modTarget, $systemTarget)) { if (Test-Path -LiteralPath $target) { throw "Existing file preserved: $target" } }
$systemHash = $system.Table.FileSHA256; $modHash = [string]$manifest.ModSHA256; $copiedSystem = $false; $copiedMod = $false
Assert-GameClosed
$copyGameHash = Get-Hash $gameExe
if ($copyGameHash -cne $gameHash) { throw 'Game executable changed during preparation; nothing installed. Select it again.' }
try {
    [IO.File]::Copy($system.Path, $systemTarget, $false); $copiedSystem = $true
    [IO.File]::Copy($modSource, $modTarget, $false); $copiedMod = $true
    Assert-OwnedTarget $systemTarget $systemHash $bin; Assert-OwnedTarget $modTarget $modHash $bin
    Write-State ([pscustomobject]@{ SchemaVersion = 2; Status = 'installed'; GameDirectory = $bin; GameSHA256 = $gameHash
        TestedBuild = [bool]$testedBuild; UntestedBuildOptIn = [bool](-not $testedBuild -and $AllowUntestedBuild)
        ModSHA256 = $modHash; SystemSHA256 = $systemHash; SystemExportsSHA256 = $system.Table.ContractSHA256; InstalledUTC = [DateTime]::UtcNow.ToString('o') })
    if ($testedBuild) { 'Native FPS mod installed. Check maneater_codex_fps.log after loading a save.' }
    else { 'Native FPS mod installed for an untested build. Runtime guards may leave the hook inactive; check maneater_codex_fps.log after loading a save.' }
} catch {
    $installationError = $_
    $rollbackErrors = @()
    foreach ($entry in @(@{ Copied = $copiedMod; Path = $modTarget; Hash = $modHash }, @{ Copied = $copiedSystem; Path = $systemTarget; Hash = $systemHash })) {
        if ($entry.Copied -and [IO.File]::Exists($entry.Path)) {
            try { Assert-OwnedTarget $entry.Path $entry.Hash $bin; Remove-Item -LiteralPath $entry.Path }
            catch { $rollbackErrors += $_.Exception.Message }
        }
    }
    if ($rollbackErrors.Count -ne 0) { throw ('Installation failed: ' + $installationError.Exception.Message + ' Rollback preserved changed files: ' + ($rollbackErrors -join '; ')) }
    throw $installationError
}
