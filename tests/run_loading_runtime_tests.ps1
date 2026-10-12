[CmdletBinding()]
param([string]$ZigPath)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskWork=Split-Path -Parent $taskRoot
$taskCompiler=if($ZigPath){(Resolve-Path -LiteralPath $ZigPath).ProviderPath}else{$taskFound=Get-Command zig -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1;if($taskFound){$taskFound.Source}else{$null}}
if(-not [IO.File]::Exists($taskCompiler)){throw 'Official Zig compiler is required; pass its full path.'}
$taskHeaders=@('src/maneater_fps_hook.c','src/getup_core.h','src/getup_runtime.h','src/getup_signatures.h','src/nav_filter.h','src/nav_scope.h','src/nav_runtime.h','src/nav_signatures.h','src/nav_helper_hash.h','src/loading_runtime.h','src/loading_signatures.h','src/nav_install_contract.h')
$taskHashes=[ordered]@{}
foreach($name in $taskHeaders){$taskHashes[$name]=(Get-FileHash -LiteralPath (Join-Path $taskRoot $name) -Algorithm SHA256).Hash}
$taskSource=Join-Path $PSScriptRoot 'test_loading_runtime.c'
$taskProbe=Join-Path $PSScriptRoot 'test_loading_abi_probe.S'
$taskExe=Join-Path $PSScriptRoot 'test_loading_runtime.exe'
$taskSources=@($taskSource,$taskProbe)+(@('vendor/minhook/src/buffer.c','vendor/minhook/src/trampoline.c','vendor/minhook/src/hde/hde64.c')|ForEach-Object {Join-Path $taskRoot $_})
& $taskCompiler cc -target x86_64-windows-gnu -std=c11 -O2 -fms-extensions -fno-omit-frame-pointer -fno-fast-math -ffp-contract=off -Wall -Wextra -Werror @taskSources -o $taskExe -lkernel32 -lbcrypt
if($LASTEXITCODE -ne 0){throw 'Loading runtime fixture compilation failed.'}
$taskOutput=@(& $taskExe)
if($LASTEXITCODE -ne 0){throw 'Loading runtime fixture failed.'}
foreach($name in $taskHeaders){if((Get-FileHash -LiteralPath (Join-Path $taskRoot $name) -Algorithm SHA256).Hash -cne $taskHashes[$name]){throw 'Implementation changed during fixture execution.'}}
$taskReport=[ordered]@{
 Result=($taskOutput[-1]|ConvertFrom-Json)
 SourceHashes=$taskHashes
 FixtureSHA256=(Get-FileHash -LiteralPath $taskSource -Algorithm SHA256).Hash
 ProbeSHA256=(Get-FileHash -LiteralPath $taskProbe -Algorithm SHA256).Hash
 FixtureExeSHA256=(Get-FileHash -LiteralPath $taskExe -Algorithm SHA256).Hash
 Limits=@('Authored replacement and typed mock only; no game, DLL, workers, helper, publication or attachment transaction executed.','Inert synthetic stock-prologue bytes are decoded/copied by MinHook and inspected using real host RtlVirtualUnwind; no trampoline instructions execute.','Tests establish forwarding, preserved nonvolatile GPR/XMM state and unwind contracts, not real-world loading benefit or runtime attachment.')
}
$taskReport|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'loading-runtime-fixture-results.json') -Encoding utf8
$taskReport|ConvertTo-Json -Depth 6
