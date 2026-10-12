[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $root 'scripts\Compiler.psm1') -Force
$scratch=Join-Path $PSScriptRoot ('.tmp-'+[Guid]::NewGuid().ToString('N'))
$passed=0
function Assert-Throws {param([scriptblock]$Operation,[string]$Pattern) $caught=$false;try{& $Operation|Out-Null}catch{if($_.Exception.Message -notlike $Pattern){throw};$caught=$true};if(-not $caught){throw 'Expected compiler refusal.'};$script:passed++}
try {
    $cache=Join-Path $scratch 'archive';[IO.Directory]::CreateDirectory($cache)|Out-Null
    $archive=Join-Path $cache 'zig-0.17.0.zip';[IO.File]::WriteAllText($archive,'unverified fixture')
    Assert-Throws {Get-RepairCompiler -CacheDirectory $cache} 'Compiler archive changed*'
    if([IO.File]::ReadAllText($archive) -ne 'unverified fixture'){throw 'Unverified archive was modified.'};$passed++
    $cache=Join-Path $scratch 'executable';$folder=Join-Path $cache 'zig-x86_64-windows-0.17.0';[IO.Directory]::CreateDirectory($folder)|Out-Null
    $exe=Join-Path $folder 'zig.exe';[IO.File]::WriteAllText($exe,'unverified fixture; not executable')
    Assert-Throws {Get-RepairCompiler -CacheDirectory $cache} 'Cached compiler changed*'
    if([IO.File]::ReadAllText($exe) -ne 'unverified fixture; not executable'){throw 'Unverified compiler was modified.'};$passed++
    Write-Host "PASS: $passed compiler integrity refusal contracts. No download or executable ran."
} finally {
    $full=[IO.Path]::GetFullPath($scratch);$prefix=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($full)-match '^\.tmp-[0-9a-f]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
