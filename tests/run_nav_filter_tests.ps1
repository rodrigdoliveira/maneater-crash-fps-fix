[CmdletBinding()]
param([string]$ZigPath)
$ErrorActionPreference='Stop'
$taskTests=$PSScriptRoot
$taskRoot=Split-Path -Parent $taskTests
$taskWork=Split-Path -Parent $taskRoot
if(-not [string]::IsNullOrWhiteSpace($ZigPath)) {$taskCompiler=(Resolve-Path -LiteralPath $ZigPath).ProviderPath}
else {
 $taskCommand=Get-Command zig -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
 $taskCompiler=if($taskCommand){$taskCommand.Source}else{$null}
}
if(-not [IO.File]::Exists($taskCompiler)){throw 'Put official Zig on PATH or pass -ZigPath with its full path.'}
$taskSource=Join-Path $taskTests 'test_nav_filter.c'
$taskCore=Join-Path $taskRoot 'src/nav_filter.h'
$taskExe=Join-Path $taskTests 'test_nav_filter.exe'
$taskBefore=(Get-FileHash -LiteralPath $taskCore -Algorithm SHA256).Hash
& $taskCompiler cc $taskSource -std=c11 -O2 -Wall -Wextra -Werror -fno-fast-math -ffp-contract=off -o $taskExe -lkernel32
if($LASTEXITCODE -ne 0){throw "Fixture compile failed: $LASTEXITCODE"}
$taskLines=@(& $taskExe)
if($LASTEXITCODE -ne 0){throw "Fixture failed: $LASTEXITCODE"}
$taskRecords=@($taskLines|ForEach-Object {$_|ConvertFrom-Json})
$taskAfter=(Get-FileHash -LiteralPath $taskCore -Algorithm SHA256).Hash
if($taskBefore -cne $taskAfter){throw 'Core changed while fixture was running.'}
$taskReport=[ordered]@{
 Result=$taskRecords[-1]
 Benchmarks=@($taskRecords|Select-Object -SkipLast 1)
 CoreSHA256=$taskAfter
 FixtureSHA256=(Get-FileHash -LiteralPath $taskSource -Algorithm SHA256).Hash
 FixtureExeSHA256=(Get-FileHash -LiteralPath $taskExe -Algorithm SHA256).Hash
 CompilerSHA256=(Get-FileHash -LiteralPath $taskCompiler -Algorithm SHA256).Hash
 CompilerVersion=((& $taskCompiler version)|Out-String).Trim()
 Limits=@('Synthetic distributions only; no observed game query skip fraction or FPS claim.','Core tests do not cover runtime TLS lifetime/identity, readable memory guards, eight-argument forwarding, installation or complete native height/output behavior.','FilterPortalVisitUpperBound is a bound, not an instrumented comparison count. AvoidedNativeEdgeScanIterations counts every edge slot for queries whose necessary conditions all fail.')
}
$taskReport|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $taskTests 'nav-filter-fixture-results.json') -Encoding utf8
$taskReport|ConvertTo-Json -Depth 8
