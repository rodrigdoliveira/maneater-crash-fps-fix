[CmdletBinding()]
param([string]$ZigPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
$powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
foreach ($test in @('test_scripts.ps1','test_cpu_plan.ps1','test_ansel.ps1','test_steam.ps1','test_repair.ps1','test_launcher.ps1','test_compiler.ps1','test_release.ps1')) {
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test)
    if ($LASTEXITCODE -ne 0) { throw "Contract test failed: $test" }
}
if ([string]::IsNullOrWhiteSpace($ZigPath)) {
    Import-Module (Join-Path $root 'scripts\Compiler.psm1') -Force
    $ZigPath = Get-RepairCompiler -CacheDirectory (Join-Path $root '.local\tools') -Progress { param($message) Write-Host $message }
}
$dist = Join-Path $root 'dist'
[IO.Directory]::CreateDirectory($dist) | Out-Null
$fixture = Join-Path $dist 'native_fps_contract_fixture.exe'
$oldGlobal = $env:ZIG_GLOBAL_CACHE_DIR; $oldLocal = $env:ZIG_LOCAL_CACHE_DIR
try {
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $dist 'cache\global'
    $env:ZIG_LOCAL_CACHE_DIR = Join-Path $dist 'cache\local'
    & $ZigPath cc -target x86_64-windows-gnu -O2 -Wall -Wextra -Werror (Join-Path $PSScriptRoot 'native_fps_contract_fixture.c') -o $fixture -lkernel32
    if ($LASTEXITCODE -ne 0) { throw 'Native contract fixture failed to compile.' }
    & $fixture
    if ($LASTEXITCODE -ne 0) { throw 'Native contract fixture failed.' }
} finally { $env:ZIG_GLOBAL_CACHE_DIR=$oldGlobal; $env:ZIG_LOCAL_CACHE_DIR=$oldLocal }
Write-Host 'PASS: all repair and native contracts. Only isolated fixtures were modified.'
