[CmdletBinding()]
param([string]$ZigPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
    throw 'Build with 64-bit PowerShell on Windows.'
}
$root = [IO.Path]::GetFullPath($PSScriptRoot)
Import-Module (Join-Path $root 'scripts\PeExports.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ZigPath)) {
    $compiler = Get-Command 'zig' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $compiler) { throw 'Zig was not found on PATH. Supply -ZigPath <path-to-zig.exe>.' }
    $ZigPath = $compiler.Source
} else { $ZigPath = (Resolve-Path -LiteralPath $ZigPath).ProviderPath }
if (-not [IO.File]::Exists($ZigPath)) { throw 'Zig executable is missing.' }
$source = Join-Path $root 'src\maneater_fps_hook.c'
if (-not [IO.File]::Exists($source)) { throw 'FPS hook source is missing.' }
$system = Get-VerifiedWindowsDxgi
$dist = Join-Path $root 'dist'
[IO.Directory]::CreateDirectory($dist) | Out-Null
$definition = Join-Path $dist 'dxgi_proxy.def'
$output = Join-Path $dist 'dxgi.dll'
$temporary = Join-Path $dist ('dxgi-build-' + [Guid]::NewGuid().ToString('N') + '.dll')
New-DxgiForwarderDefinition -Exports $system.Table.Exports -Path $definition
$savedGlobalCache = $env:ZIG_GLOBAL_CACHE_DIR
$savedLocalCache = $env:ZIG_LOCAL_CACHE_DIR
try {
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $dist 'cache\global'
    $env:ZIG_LOCAL_CACHE_DIR = Join-Path $dist 'cache\local'
    $compilerVersion = (& $ZigPath version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not read Zig version.' }
    $flags = @('cc','-target','x86_64-windows-gnu','-fms-extensions','-O2','-fno-omit-frame-pointer','-ffp-contract=off','-Wall','-Wextra','-Werror')
    $helper = Join-Path $dist 'ManeaterAreaHelper.exe'
    & $ZigPath @flags (Join-Path $root 'src/nav_install_external.c') -o $helper -municode -lbcrypt -lkernel32
    if ($LASTEXITCODE -ne 0) { throw 'Attachment helper failed to build.' }
    $helperHash = (Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash
    $hexBytes = for ($i=0; $i -lt 64; $i+=2) { '0x'+$helperHash.Substring($i,2).ToLowerInvariant() }
    $hashSource = "/* Generated from the helper built by this script. */`nstatic const unsigned char nav_expected_helper_sha[32]={" + ($hexBytes -join ',') + "};`n"
    [IO.File]::WriteAllText((Join-Path $root 'src/nav_helper_hash.h'),$hashSource,[Text.UTF8Encoding]::new($false))
    $sources = @($source) + @('vendor/minhook/src/buffer.c','vendor/minhook/src/trampoline.c','vendor/minhook/src/hde/hde64.c' | ForEach-Object { Join-Path $root $_ })
    & $ZigPath @flags -shared @sources $definition -o $temporary -lkernel32 -lbcrypt
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed with exit code $LASTEXITCODE." }
    $proxy = Get-PeExportTable -Path $temporary
    Assert-DxgiForwarderTable -Proxy $proxy -System $system.Table
    # Detect servicing/replacement while building; the recorded hash is local
    # provenance, never a fixed hash that other Windows installations must use.
    $currentSystem = Get-VerifiedWindowsDxgi
    if ($currentSystem.Table.FileSHA256 -cne $system.Table.FileSHA256) { throw 'Windows DXGI changed during compilation; rebuild.' }
    [IO.File]::Copy($temporary, $output, $true)
    $sourceHashes = [ordered]@{}
    foreach ($folder in @('src','vendor')) {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root $folder) -File -Recurse | Sort-Object FullName) {
            $relative = $file.FullName.Substring($root.Length+1).Replace('\','/')
            $sourceHashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    }
    foreach ($relative in @('scripts/PeExports.psm1', 'build.ps1', 'Manage-Mod.ps1')) {
        $sourceHashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash
    }
    $manifest = [ordered]@{
        SchemaVersion = 1; Version = '0.7.0'; TargetFPS = 120
        GameSHA256 = 'CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0'
        ModSHA256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
        HelperSHA256 = $helperHash
        DefinitionSHA256 = (Get-FileHash -LiteralPath $definition -Algorithm SHA256).Hash
        SystemExportsSHA256 = $system.Table.ContractSHA256; ModExportsSHA256 = $proxy.ContractSHA256
        BuildSystemDLLSHA256 = $system.Table.FileSHA256; SystemExports = @($system.Table.Exports | Select-Object Name, Ordinal)
        SourceHashes = $sourceHashes; Compiler = "Zig $compilerVersion; x86_64-windows-gnu O2; no FP contraction; warnings-as-errors"
        GameplayValidation = [ordered]@{
            UserReportedSuccess = $true; NativeAttachmentObserved = $true
            TestedModSHA256 = '85B190F0AD305F9FD0D9C9A676D61B4179FB736F32D6ED3C4BC9E468F80208BF'
            TestedHelperSHA256 = '898C59D575AFF5DD9F6CDB0F46A2DEB5F1700DF80A5DDFE2A86AE1C71B1DCB7A'
            Scope = 'Same algorithms tested on reference Steam build and one Intel PC; version/docs/log text updated for release.'
        }
        BuiltUTC = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $dist 'build.json'), ($manifest | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ DLL = $output; SHA256 = $manifest.ModSHA256; HelperSHA256 = $helperHash; ExportCount = $proxy.Exports.Count; Manifest = Join-Path $dist 'build.json' }
} finally {
    $env:ZIG_GLOBAL_CACHE_DIR = $savedGlobalCache
    $env:ZIG_LOCAL_CACHE_DIR = $savedLocalCache
    if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary }
}
# This script only builds inside dist; it never installs or loads the DLL.
