[CmdletBinding()]
param([string]$ZigPath)
$ErrorActionPreference='Stop'
if(-not $ZigPath){
    $taskFound=Get-Command zig -ErrorAction SilentlyContinue
    if($taskFound){$ZigPath=$taskFound.Source}else{$ZigPath=$null}
}
if(-not $ZigPath){throw 'Put official Zig on PATH or pass -ZigPath.'}
$taskCompiler=(Resolve-Path -LiteralPath $ZigPath).ProviderPath
$taskRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskPackagedHelper=Join-Path $taskRoot 'dist/ManeaterAreaHelper.exe'
if(-not [IO.File]::Exists($taskPackagedHelper)){throw 'Run build.ps1 before the helper suite.'}
$taskHashSource=[IO.File]::ReadAllText((Join-Path $taskRoot 'src/nav_helper_hash.h'))
$taskHashBytes=@([regex]::Matches($taskHashSource,'0x([0-9a-fA-F]{2})')|ForEach-Object {$_.Groups[1].Value.ToUpperInvariant()})
if($taskHashBytes.Count-ne32-or(Get-FileHash -LiteralPath $taskPackagedHelper -Algorithm SHA256).Hash-cne($taskHashBytes-join'')){throw 'Packaged helper does not match the generated DLL dependency hash.'}
$taskFlags=@('cc','-target','x86_64-windows-gnu','-fms-extensions','-O2','-Wall','-Wextra','-Werror')
$taskVendor=@('vendor/minhook/src/buffer.c','vendor/minhook/src/trampoline.c','vendor/minhook/src/hde/hde64.c') | ForEach-Object {Join-Path $taskRoot $_}
function Compile-Fixture([string]$Name,[switch]$Vendor,[switch]$Unicode){
    $taskArgs=@($taskFlags)+(Join-Path $PSScriptRoot ($Name+'.c'))
    if($Vendor){$taskArgs+=@($taskVendor)}
    $taskExe=Join-Path $PSScriptRoot ($Name+'.exe')
    $taskArgs+=@('-o',$taskExe,'-lbcrypt','-lkernel32')
    if($Unicode){$taskArgs+='-municode'}
    & $taskCompiler @taskArgs
    if($LASTEXITCODE -ne 0){throw ('Compile failed: '+$Name)}
    return $taskExe
}
$taskHelper=Join-Path $PSScriptRoot 'ManeaterAreaHelper.validation.exe'
& $taskCompiler @taskFlags (Join-Path $taskRoot 'src/nav_install_external.c') -o $taskHelper -municode -lbcrypt -lkernel32
if($LASTEXITCODE -ne 0){throw 'Private helper compilation failed.'}
$taskResults=[ordered]@{}
foreach($taskName in @('test_nav_install_transaction','test_nav_vendor_relocation','test_loading_vendor_relocation')){
    $taskExe=Compile-Fixture $taskName -Vendor:($taskName -ne 'test_nav_install_transaction')
    $taskOutput=& $taskExe
    if($LASTEXITCODE -ne 0){throw ('Fixture failed: '+$taskName)}
    $taskResults[$taskName]=$taskOutput | ConvertFrom-Json
}
$taskTarget=Compile-Fixture 'nav_fixture_target' -Vendor -Unicode
$taskExternal=Compile-Fixture 'test_nav_install_external_process' -Unicode
$taskOutput=& $taskExternal $taskTarget $taskHelper
if($LASTEXITCODE -ne 0){throw 'Separate-process fixture failed.'}
$taskResults['external_process']=$taskOutput | ConvertFrom-Json
$taskOutput=& $taskExternal $taskTarget $taskPackagedHelper
if($LASTEXITCODE-ne0){throw 'Packaged helper strict-refusal/separate-process fixture failed.'}
$taskResults['packaged_helper_external_process']=$taskOutput|ConvertFrom-Json
$taskReport=[ordered]@{Passed=$true;GameExecuted=$false;ProtocolVersion=2;Hooks=3;SharedBytes=6544;Results=$taskResults;
    HelperSHA256=(Get-FileHash -LiteralPath $taskHelper -Algorithm SHA256).Hash;
    PackagedHelperSHA256=(Get-FileHash -LiteralPath $taskPackagedHelper -Algorithm SHA256).Hash;
    Scope='Owned synthetic buffers/current and separate fixture processes only; no production game launch or installed-file mutation.'}
$taskReport | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'loading-helper-fixture-results.json') -Encoding utf8
$taskReport | ConvertTo-Json -Depth 10
