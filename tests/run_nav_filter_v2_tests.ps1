[CmdletBinding()]
param([string]$ZigPath)
$ErrorActionPreference = 'Stop'
$candidateRoot = Split-Path -Parent $PSScriptRoot
$workRoot = Split-Path -Parent $candidateRoot
if (-not [string]::IsNullOrWhiteSpace($ZigPath)) { $compiler = (Resolve-Path -LiteralPath $ZigPath).ProviderPath }
else {
    $command = Get-Command zig -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $compiler = if ($command) { $command.Source } else { $null }
}
if (-not [IO.File]::Exists($compiler)) { throw 'Put official Zig on PATH or pass -ZigPath.' }
$source = Join-Path $PSScriptRoot 'test_nav_filter_v2.c'
$reference = Join-Path $PSScriptRoot 'nav_filter_v1_reference.h'
$core = Join-Path $candidateRoot 'src/nav_filter.h'
$exe = Join-Path $PSScriptRoot 'test_nav_filter_v2.exe'
$coreBefore = (Get-FileHash -LiteralPath $core -Algorithm SHA256).Hash
$referenceBefore = (Get-FileHash -LiteralPath $reference -Algorithm SHA256).Hash
if ($referenceBefore -cne '885B5BE6A9293DE3D13D4CB5FD8FE9A90F7A8DC42A4CB29EAB3702A0AB55B6D0') { throw 'The immutable v1 reference changed.' }
& $compiler cc $source -std=c11 -O2 -Wall -Wextra -Werror -fno-fast-math -ffp-contract=off -o $exe -lkernel32
if ($LASTEXITCODE -ne 0) { throw "Fixture compile failed: $LASTEXITCODE" }
$lines = @(& $exe)
if ($LASTEXITCODE -ne 0) { throw "Fixture failed: $LASTEXITCODE" }
$records = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
$coreAfter = (Get-FileHash -LiteralPath $core -Algorithm SHA256).Hash
if ($coreBefore -cne $coreAfter -or $referenceBefore -cne (Get-FileHash -LiteralPath $reference -Algorithm SHA256).Hash) { throw 'A core changed during validation.' }
$report = [ordered]@{
    Result = $records[-1]
    CoreBenchmarks = @($records | Select-Object -SkipLast 1)
    CoreSHA256 = $coreAfter
    ReferenceV1SHA256 = $referenceBefore
    FixtureSHA256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    FixtureExeSHA256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    CompilerSHA256 = (Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash
    CompilerVersion = ((& $compiler version) | Out-String).Trim()
    Limits = @(
        'The trusted API is restricted to builder-produced immutable owned records; its marker is not authentication.',
        'Detectable corrupt metadata refuses before record access, including a NOACCESS sentinel. A valid-looking wrong pointer or altered trusted record is outside the pure core memory contract.',
        'Native oracle covers necessary plane/overlap conditions, not complete height tests, result allocation or cluster writes.',
        'Core-only synthetic timing does not predict complete callback costs, real geometry distributions, loading duration or FPS.'
    )
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'nav-filter-v2-fixture-results.json') -Encoding utf8
$report | ConvertTo-Json -Depth 8
