[CmdletBinding()]
param([string]$ZigPath)
$ErrorActionPreference='Stop'
$taskTests=$PSScriptRoot
$taskRoot=Split-Path -Parent $taskTests
$taskWork=Split-Path -Parent $taskRoot
if(-not [string]::IsNullOrWhiteSpace($ZigPath)) {
  $taskCompiler=(Resolve-Path -LiteralPath $ZigPath).ProviderPath
} else {
  $taskZigCommand=Get-Command zig -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
  if($taskZigCommand) { $taskCompiler=$taskZigCommand.Source }
  else { $taskCompiler=$null }
}
if(-not [IO.File]::Exists($taskCompiler)) { throw 'Zig was not found. Put zig on PATH or pass -ZigPath with the full path to the official compiler.' }
$taskSource=Join-Path $taskTests 'test_getup_core.c'
$taskCore=Join-Path $taskRoot 'src/getup_core.h'
$taskExe=Join-Path $taskTests 'test_getup_core.exe'
$taskCoreBefore=(Get-FileHash -LiteralPath $taskCore -Algorithm SHA256).Hash
& $taskCompiler cc $taskSource -std=c11 -O2 -Wall -Wextra -Werror -o $taskExe -lkernel32
if($LASTEXITCODE -ne 0){throw "Fixture compilation failed: $LASTEXITCODE"}
$taskOutput=& $taskExe
if($LASTEXITCODE -ne 0){throw "Fixture failed: $LASTEXITCODE"}
$taskResult=$taskOutput|ConvertFrom-Json
$taskCoreAfter=(Get-FileHash -LiteralPath $taskCore -Algorithm SHA256).Hash
if($taskCoreBefore -ne $taskCoreAfter){throw 'Core changed during the fixture build/test; result does not cover a stable source.'}
$taskReport=[ordered]@{
  Result=$taskResult
  CoreSHA256=$taskCoreAfter
  FixtureSHA256=(Get-FileHash -LiteralPath $taskSource -Algorithm SHA256).Hash
  FixtureExeSHA256=(Get-FileHash -LiteralPath $taskExe -Algorithm SHA256).Hash
  CompilerSHA256=(Get-FileHash -LiteralPath $taskCompiler -Algorithm SHA256).Hash
  CompilerVersion=((& $taskCompiler version)|Out-String).Trim()
  Command='zig cc tests/test_getup_core.c -std=c11 -O2 -Wall -Wextra -Werror -o tests/test_getup_core.exe -lkernel32'
  Coverage=@('Preserve complete source bytes and object/frame/result sentinels','Exact copied count with null/duplicate pointers and unused capacity','Selector once including empty array; game-style ownership transfer and exactly one free','Frame.Code consumes zero or one byte; other frame bytes preserved','Null/overflow/mismatched native function/malformed array/input refusal','Every safe-read/writable failure ordinal and partial-copy failure cleanup','Allocation failure and insufficient capacity cleanup','Real Windows read-only, no-access and guard pages','2048 deterministic randomized source arrays and capacities')
  Limits=@('No game code was executed.','These mocks verify the pure core contract; they do not establish equivalence to the opaque game getter or gameplay improvement.')
}
$taskReport|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $taskTests 'getup-core-fixture-result.json') -Encoding utf8
$taskReport|ConvertTo-Json -Depth 6
