[CmdletBinding()]
param([string]$ZigPath)
$ErrorActionPreference='Stop'
$taskTests=$PSScriptRoot;$taskRoot=Split-Path -Parent $taskTests;$taskWork=Split-Path -Parent $taskRoot
if(-not [string]::IsNullOrWhiteSpace($ZigPath)){$taskCompiler=(Resolve-Path -LiteralPath $ZigPath).ProviderPath}
else{$taskCommand=Get-Command zig -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1;$taskCompiler=if($taskCommand){$taskCommand.Source}else{$null}}
if(-not [IO.File]::Exists($taskCompiler)){throw 'Put official Zig on PATH or pass -ZigPath.'}
$taskSource=Join-Path $taskTests 'test_nav_scope.c';$taskCore=Join-Path $taskRoot 'src/nav_scope.h';$taskFilter=Join-Path $taskRoot 'src/nav_filter.h';$taskExe=Join-Path $taskTests 'test_nav_scope.exe'
$taskBefore=(Get-FileHash -LiteralPath $taskCore -Algorithm SHA256).Hash
& $taskCompiler cc $taskSource -std=c11 -O2 -Wall -Wextra -Werror -fno-fast-math -ffp-contract=off -o $taskExe
if($LASTEXITCODE -ne 0){throw "Compile failed: $LASTEXITCODE"}
$taskOutput=& $taskExe
if($LASTEXITCODE -ne 0){throw "Scope fixture failed: $LASTEXITCODE"}
$taskAfter=(Get-FileHash -LiteralPath $taskCore -Algorithm SHA256).Hash
if($taskBefore -cne $taskAfter){throw 'Scope header changed during the fixture run.'}
$taskReport=[ordered]@{Result=($taskOutput|ConvertFrom-Json);ScopeSHA256=$taskAfter;FilterSHA256=(Get-FileHash -LiteralPath $taskFilter -Algorithm SHA256).Hash;FixtureSHA256=(Get-FileHash -LiteralPath $taskSource -Algorithm SHA256).Hash;FixtureExeSHA256=(Get-FileHash -LiteralPath $taskExe -Algorithm SHA256).Hash;CompilerVersion=((& $taskCompiler version)|Out-String).Trim()}
$taskReport|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $taskTests 'nav-scope-fixture-results.json') -Encoding utf8
$taskReport|ConvertTo-Json -Depth 6
