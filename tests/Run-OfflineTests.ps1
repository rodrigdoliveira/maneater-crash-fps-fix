[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ZigPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not [Environment]::Is64BitProcess){throw 'Use 64-bit PowerShell for native fixtures.'}
$taskCompiler=(Resolve-Path -LiteralPath $ZigPath).ProviderPath
$taskRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($name in @('src/nav_helper_hash.h','dist/dxgi.dll','dist/ManeaterAreaHelper.exe')){
    if(-not [IO.File]::Exists((Join-Path $taskRoot $name))){throw 'Run build.ps1 first; the combined DLL and companion helper must be built together.'}
}
$taskInputs=[ordered]@{}
foreach($folder in @('src','vendor')){
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $taskRoot $folder) -File -Recurse|Sort-Object FullName){
        $relative=$file.FullName.Substring($taskRoot.Length+1).Replace('\','/')
        $taskInputs[$relative]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
}
# All native executables below are isolated synthetic fixtures. This facade
# never invokes DllMain, any real game installer, a game executable or a worker.
foreach($name in @('run_nav_filter_tests.ps1','run_nav_filter_v2_tests.ps1','run_nav_scope_tests.ps1','run_nav_runtime_tests.ps1','run_loading_runtime_tests.ps1','run_test_getup_core.ps1','run_loading_helper_fixtures.ps1')){
    & (Join-Path $PSScriptRoot $name) -ZigPath $taskCompiler
}
$taskVendor=@('vendor/minhook/src/buffer.c','vendor/minhook/src/trampoline.c','vendor/minhook/src/hde/hde64.c')|ForEach-Object {Join-Path $taskRoot $_}
$taskFlags=@('cc','-target','x86_64-windows-gnu','-fms-extensions','-O2','-fno-omit-frame-pointer','-fno-fast-math','-ffp-contract=off','-Wall','-Wextra','-Werror')
foreach($name in @('native_fps_contract_fixture','loading_review_unwind')){
    $taskExe=Join-Path $PSScriptRoot ($name+'.exe')
    & $taskCompiler @taskFlags (Join-Path $PSScriptRoot ($name+'.c')) @taskVendor -o $taskExe -lkernel32 -lbcrypt
    if($LASTEXITCODE-ne0){throw ('Native fixture compilation failed: '+$name)}
    & $taskExe
    if($LASTEXITCODE-ne0){throw ('Native fixture failed: '+$name)}
}
foreach($name in $taskInputs.Keys){
    if((Get-FileHash -LiteralPath (Join-Path $taskRoot $name) -Algorithm SHA256).Hash-cne$taskInputs[$name]){throw 'Combined native source changed during the offline suite.'}
}
$taskReport=[ordered]@{
    Passed=$true;GameExecuted=$false;GameInstalled=$false
    SourceHashes=$taskInputs
    PackagedDLLSHA256=(Get-FileHash -LiteralPath (Join-Path $taskRoot 'dist/dxgi.dll') -Algorithm SHA256).Hash
    PackagedHelperSHA256=(Get-FileHash -LiteralPath (Join-Path $taskRoot 'dist/ManeaterAreaHelper.exe') -Algorithm SHA256).Hash
    Suites=@('FPS guards and forwarding','get-up copy/failure and frame ownership','conservative nav filter oracle and v1/v2 equivalence','packed layout and alias refusals','eight-argument nav forwarding/TLS/SEH cleanup','five-to-six-argument loading forwarding and Windows unwind','native relocation and three-hook transaction rollback/resume','separate synthetic process attachment and packaged-helper strict refusal')
    Limits=@('No game, proxy DLL, production installer, runtime worker or real-game attachment runs.','The external helper suite starts only its owned synthetic fixture process and verifies production helper refusal.','Offline tests establish contracts and failure behavior; they do not establish gameplay benefit or compatibility with another game build.')
}
$taskReport|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'offline-suite-results.json') -Encoding utf8
Write-Output 'PASS: combined native offline fixtures; no game was launched or installed.'
