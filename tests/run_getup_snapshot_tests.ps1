[CmdletBinding()]
param([string]$ZigPath)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskCompiler=if($ZigPath){(Resolve-Path -LiteralPath $ZigPath).ProviderPath}else{$taskFound=Get-Command zig -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1;if($taskFound){$taskFound.Source}else{$null}}
if(-not [IO.File]::Exists($taskCompiler)){throw 'Official Zig compiler is required; pass its full path.'}
$taskSource=Join-Path $PSScriptRoot 'test_getup_snapshot.c'
$taskExe=Join-Path $PSScriptRoot 'test_getup_snapshot.exe'
$taskFiles=@('src/maneater_fps_hook.c','src/getup_core.h','src/getup_runtime.h')
$taskHashes=[ordered]@{}
foreach($name in $taskFiles){$taskHashes[$name]=(Get-FileHash -LiteralPath (Join-Path $taskRoot $name) -Algorithm SHA256).Hash}
$taskSources=@($taskSource)+(@('vendor/minhook/src/buffer.c','vendor/minhook/src/trampoline.c','vendor/minhook/src/hde/hde64.c')|ForEach-Object {Join-Path $taskRoot $_})
& $taskCompiler cc -target x86_64-windows-gnu -std=c11 -O2 -fms-extensions -fno-omit-frame-pointer -fno-fast-math -ffp-contract=off -Wall -Wextra -Werror @taskSources -o $taskExe -lkernel32 -lbcrypt
if($LASTEXITCODE -ne 0){throw 'Get-up snapshot fixture compilation failed.'}
$taskOutput=@(& $taskExe)
if($LASTEXITCODE -ne 0){throw 'Get-up snapshot fixture failed.'}
foreach($name in $taskFiles){if((Get-FileHash -LiteralPath (Join-Path $taskRoot $name) -Algorithm SHA256).Hash -cne $taskHashes[$name]){throw 'Implementation changed during fixture execution.'}}
$taskReport=[ordered]@{
 Result=($taskOutput[-1]|ConvertFrom-Json)
 SourceHashes=$taskHashes
 FixtureSHA256=(Get-FileHash -LiteralPath $taskSource -Algorithm SHA256).Hash
 Coverage=@('Real production snapshot reader and get-up dispatch wrapper','Only explicit writable checks query memory regions','Empty and nonempty arrays, null and repeated entries, bytecode and native-call frame modes','Read-only result/frame refusal before mutation','No-access/guard source and frame refusal; guard protection remains intact','Cross-page partial read frees copy without consuming bytecode or selecting')
 Limits=@('Synthetic owned memory and allocator/selector/fallback mocks only. No game, native getter/selector, worker, DLL entry, attachment or installer executes.','No game performance or compatibility claim follows from these contract checks.')
}
$taskReport|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'getup-snapshot-fixture-results.json') -Encoding utf8
$taskReport|ConvertTo-Json -Depth 6
