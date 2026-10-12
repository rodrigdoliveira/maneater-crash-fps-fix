Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Pinned official archive: https://ziglang.org/download/index.json, Zig 0.17.0.
$script:ArchiveHash = 'B5663F69581DCF391293FBF16C06CB80D81D806545CE618B4D0BAB7F0EB8C428'
$script:CompilerHash = 'F54B14F02A4D7D8AC62A94A0663486EB166BBA3745D85B466238C1B93E723D46'
function Get-RepairCompiler {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CacheDirectory, [scriptblock]$Progress = {})
    if (-not [Environment]::Is64BitProcess) { throw 'The launcher requires 64-bit Windows PowerShell.' }
    $cache = [IO.Path]::GetFullPath($CacheDirectory)
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    $archive = Join-Path $cache 'zig-0.17.0.zip'
    $folder = Join-Path $cache 'zig-x86_64-windows-0.17.0'
    $compiler = Join-Path $folder 'zig.exe'
    if ([IO.File]::Exists($compiler)) {
        if ((Get-FileHash -LiteralPath $compiler).Hash -cne $script:CompilerHash) { throw 'Cached compiler changed. Remove the tool cache and retry.' }
        return $compiler
    }
    if (-not [IO.File]::Exists($archive)) {
        & $Progress 'Downloading the compiler from ziglang.org (100 MB; first use only)...'
        $partial = Join-Path $cache ('download-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor [Net.SecurityProtocolType]::Tls12
            $client = New-Object Net.WebClient
            try { $client.DownloadFile('https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip', $partial) }
            finally { $client.Dispose() }
            if ((Get-FileHash -LiteralPath $partial).Hash -cne $script:ArchiveHash) { throw 'Compiler download failed its SHA-256 check.' }
            [IO.File]::Move($partial, $archive)
        } finally {
            [Net.ServicePointManager]::SecurityProtocol = $oldProtocol
            if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
        }
    }
    if ((Get-FileHash -LiteralPath $archive).Hash -cne $script:ArchiveHash) { throw 'Compiler archive changed. Remove it and retry.' }
    if ([IO.Directory]::Exists($folder)) { throw 'Incomplete compiler folder exists. Remove the tool cache and retry.' }
    & $Progress 'Verifying and extracting the compiler...'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stage = Join-Path $cache ('extract-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    try {
        # The archive hash is verified before extraction; inspect paths anyway.
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            foreach ($entry in $zip.Entries) {
                $destination = [IO.Path]::GetFullPath((Join-Path $stage $entry.FullName))
                if (-not $destination.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid compiler archive path.' }
            }
        } finally { $zip.Dispose() }
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $stage)
        $extracted = Join-Path $stage 'zig-x86_64-windows-0.17.0'
        if ((Get-FileHash -LiteralPath (Join-Path $extracted 'zig.exe')).Hash -cne $script:CompilerHash) { throw 'Extracted compiler failed verification.' }
        [IO.Directory]::Move($extracted, $folder)
    } finally {
        # Only the newly created, resolved staging directory is removed.
        if ([IO.Directory]::Exists($stage) -and $stage.StartsWith($cache + '\', [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
    return $compiler
}
Export-ModuleMember -Function Get-RepairCompiler
