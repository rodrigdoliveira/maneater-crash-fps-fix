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
$baseExports=@([pscustomobject]@{Name='CreateDXGIFactory';Ordinal=1},[pscustomobject]@{Name='CreateDXGIFactory1';Ordinal=2},[pscustomobject]@{Name='CreateDXGIFactory2';Ordinal=3})
$baseContract=[pscustomobject]@{Exports=$baseExports;ContractSHA256=(Get-ExportContractHash $baseExports)}
New-DxgiForwarderDefinition -Exports $baseExports -Path $definition
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
    Assert-DxgiForwarderTable -Proxy $proxy -System $baseContract
    $null=New-DxgiForwarderImage -TemplatePath $temporary -System $system.Table
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
        SchemaVersion = 1; Version = '0.9.1'; TargetFPS = 120
        GameSHA256 = 'CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0'
        ModSHA256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
        HelperSHA256 = $helperHash
        DefinitionSHA256 = (Get-FileHash -LiteralPath $definition -Algorithm SHA256).Hash
        ForwardingMode = 'LocalExportTableV1'
        SystemExportsSHA256 = $baseContract.ContractSHA256; ModExportsSHA256 = $proxy.ContractSHA256
        BuildSystemDLLSHA256 = $system.Table.FileSHA256; SystemExports = $baseExports
        SourceHashes = $sourceHashes; Compiler = "Zig $compilerVersion; x86_64-windows-gnu O2; no FP contraction; warnings-as-errors"
        GameplayValidation = [ordered]@{
            UserReportedSuccess = $true; NativeAttachmentObserved = $false
            TestedPackageSHA256 = 'D9F24329BA24B03BA332565DA512C9A1498D3B3C184B89578C5DA8EEBA15A33A'
            TestedTemplateSHA256 = '3BD4E92CEB5DC5694DE39C419557F55286A02C560DEDB7B14729E93B8D4008EE'
            TestedHelperSHA256 = '7536884CBDDB9CE07784708AB952E5D0F3BBCDBB9CE98D7C20F1C93EAA58BD31'
            Scope = 'The tester reported that the local Windows-portability package works great on Steam build 7837297 with i9-13900K and RTX 4070. The tested hash describes its template, not the personalized installed DLL. Release version labels and build metadata are refreshed; forwarding and gameplay implementations are retained. Other Windows installations are covered by synthetic export-layout and installer tests, not additional gameplay reports.'
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
