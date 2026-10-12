# Packaging metadata/file contracts. Never loads a DLL or touches a game/Steam.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scratch=Join-Path $PSScriptRoot ('.tmp-'+[Guid]::NewGuid().ToString('N'))
$fixture=Join-Path $scratch 'repo'
$script:passed=0
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:passed++}
function Assert-Throws([scriptblock]$Operation,[string]$Message){$caught=$false;try{& $Operation|Out-Null}catch{$caught=$true};Assert-Test $caught $Message}
function Fixture-Git([string[]]$Arguments){$result=@(& git -C $fixture @Arguments 2>&1);if($LASTEXITCODE -ne 0){throw ('Fixture Git failed: '+($result -join "`n"))};return $result}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Save-Manifest($Manifest){[IO.File]::WriteAllText((Join-Path $fixture 'dist\build.json'),($Manifest|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
function Package-Fixture {& (Join-Path $fixture 'Package-Release.ps1')}
try{
    [IO.Directory]::CreateDirectory($fixture)|Out-Null
    $sources=@('.gitattributes','.gitignore','README.md','LICENSE','CONTRIBUTING.md','Start.cmd','Launcher.ps1','Manage-Mod.ps1','build.ps1','Package-Release.ps1',
        'docs/crash-workarounds.md','src/maneater_fps_hook.c','scripts/AnselFix.psm1','scripts/Compiler.psm1','scripts/CpuPlan.psm1','scripts/PeExports.psm1',
        'scripts/Repair.psm1','scripts/Run-Repair.ps1','scripts/SteamFix.psm1','tests/Run-All.ps1','tests/native_fps_contract_fixture.c',
        'tests/test_ansel.ps1','tests/test_compiler.ps1','tests/test_cpu_plan.ps1','tests/test_launcher.ps1','tests/test_repair.ps1','tests/test_release.ps1','tests/test_scripts.ps1','tests/test_steam.ps1')
    foreach($relative in $sources){$target=Join-Path $fixture $relative;[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null;[IO.File]::Copy((Join-Path $root $relative),$target,$false)}
    Fixture-Git -Arguments @('init','--quiet')|Out-Null
    Fixture-Git -Arguments @('config','user.name','Release fixture')|Out-Null
    Fixture-Git -Arguments @('config','user.email','fixture@example.invalid')|Out-Null
    Fixture-Git -Arguments @('config','core.autocrlf','false')|Out-Null
    Fixture-Git -Arguments @('config','core.safecrlf','false')|Out-Null
    Fixture-Git -Arguments @('add','--all')|Out-Null
    Fixture-Git -Arguments @('commit','--quiet','-m','Isolated release fixture')|Out-Null
    # Materialize committed text attributes before creating build provenance.
    Fixture-Git -Arguments @('checkout-index','--all','--force')|Out-Null
    $dist=Join-Path $fixture 'dist';[IO.Directory]::CreateDirectory($dist)|Out-Null
    foreach($name in @('dxgi.dll','dxgi_proxy.def')){[IO.File]::Copy((Join-Path $root ('dist\'+$name)),(Join-Path $dist $name),$false)}
    $manifest=Get-Content -LiteralPath (Join-Path $root 'dist\build.json') -Raw|ConvertFrom-Json
    $hashes=[ordered]@{}
    foreach($relative in @('src/maneater_fps_hook.c','scripts/PeExports.psm1','build.ps1','Manage-Mod.ps1')){$hashes[$relative]=Hash (Join-Path $fixture $relative)}
    $manifest.SourceHashes=[pscustomobject]$hashes;Save-Manifest $manifest
    $manifestBytes=[IO.File]::ReadAllBytes((Join-Path $dist 'build.json'))
    $proxyBytes=[IO.File]::ReadAllBytes((Join-Path $dist 'dxgi.dll'))
    $definitionBytes=[IO.File]::ReadAllBytes((Join-Path $dist 'dxgi_proxy.def'))
    foreach($relative in @('dist/cache/private.log','.local/tools/zig.exe','.local/private-state.json','dist/dxgi_codex_system.dll','dist/native_fps_contract_fixture.exe')){
        $path=Join-Path $fixture $relative;[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null;[IO.File]::WriteAllText($path,'excluded fixture marker')
    }
    $release=Package-Fixture
    Assert-Test ([IO.File]::Exists($release.ZipPath) -and $release.SHA256 -ceq (Hash $release.ZipPath)) 'ready ZIP returned with verified output hash'
    Assert-Test ($release.SourceCommit -ceq [string](Fixture-Git -Arguments @('rev-parse','HEAD')) -and $release.SourceTree -ceq [string](Fixture-Git -Arguments @('rev-parse','HEAD^{tree}'))) 'release reports pinned source commit/tree'
    Assert-Test ($release.SourceFileCount -eq $sources.Count -and $release.NativeArtifactCount -eq 3 -and $release.NativeExports -eq 20) 'release has source plus exactly three native artifacts'
    $zip=[IO.Compression.ZipFile]::OpenRead($release.ZipPath)
    try{
        $names=@($zip.Entries|Where-Object {-not $_.FullName.EndsWith('/')}|ForEach-Object {$_.FullName})
        $expected=@($sources|ForEach-Object {'Maneater-Crash-FPS-Fix/'+$_})+@('Maneater-Crash-FPS-Fix/dist/dxgi.dll','Maneater-Crash-FPS-Fix/dist/build.json','Maneater-Crash-FPS-Fix/dist/dxgi_proxy.def')
        Assert-Test ($names.Count -eq $expected.Count -and @($names|Where-Object {$_ -cnotin $expected}).Count -eq 0) 'archive entry set is exact and excludes Windows DLL/tools/state/cache/debug fixtures'
        $reader=New-Object IO.StreamReader(($zip.GetEntry('Maneater-Crash-FPS-Fix/Start.cmd')).Open(),[Text.Encoding]::ASCII)
        try{$batch=$reader.ReadToEnd()}finally{$reader.Dispose()}
        Assert-Test ($batch.Contains("`r`n") -and $batch -notmatch '(?<!\r)\n') 'packaged Start.cmd uses CRLF'
    }finally{$zip.Dispose()}
    $zipHash=Hash $release.ZipPath
    [IO.File]::AppendAllText((Join-Path $fixture 'README.md'),"`nUncommitted fixture change.")
    Assert-Throws {Package-Fixture} 'dirty source worktree refused'
    Fixture-Git -Arguments @('add','README.md')|Out-Null
    Assert-Throws {Package-Fixture} 'dirty source index refused'
    Fixture-Git -Arguments @('reset','--quiet','HEAD','--','README.md')|Out-Null
    Fixture-Git -Arguments @('checkout','--','README.md')|Out-Null
    $untracked=Join-Path $fixture 'private-notes.txt';[IO.File]::WriteAllText($untracked,'untracked fixture')
    Assert-Throws {Package-Fixture} 'nonignored untracked source refused';[IO.File]::Delete($untracked)
    Assert-Throws {& (Join-Path $fixture 'Package-Release.ps1') -OutputPath (Join-Path $fixture 'release.zip')} 'nonignored output inside source tree refused'
    Assert-Test (-not [IO.File]::Exists((Join-Path $fixture 'release.zip'))) 'refused output never created'
    $unexpected=Join-Path $fixture 'docs\private.json';[IO.File]::WriteAllText($unexpected,'tracked fixture outside source allowlist')
    Fixture-Git -Arguments @('add','docs/private.json')|Out-Null;Fixture-Git -Arguments @('commit','--quiet','-m','Unexpected tracked fixture')|Out-Null
    Assert-Throws {Package-Fixture} 'tracked file outside source allowlist refused'
    Fixture-Git -Arguments @('rm','--quiet','--','docs/private.json')|Out-Null;Fixture-Git -Arguments @('commit','--quiet','-m','Remove unexpected fixture')|Out-Null
    $source=Join-Path $fixture 'src\maneater_fps_hook.c';$sourceBytes=[IO.File]::ReadAllBytes($source)
    [IO.File]::AppendAllText($source,"`n/* Stale build fixture. */`n")
    Fixture-Git -Arguments @('add','src/maneater_fps_hook.c')|Out-Null;Fixture-Git -Arguments @('commit','--quiet','-m','Change build input fixture')|Out-Null
    Assert-Throws {Package-Fixture} 'clean HEAD different from build source provenance refused'
    [IO.File]::WriteAllBytes($source,$sourceBytes)
    Fixture-Git -Arguments @('add','src/maneater_fps_hook.c')|Out-Null;Fixture-Git -Arguments @('commit','--quiet','-m','Restore build input fixture')|Out-Null
    $changed=[byte[]]$proxyBytes.Clone();$changed[$changed.Length-1]=$changed[$changed.Length-1] -bxor 1
    [IO.File]::WriteAllBytes((Join-Path $dist 'dxgi.dll'),$changed)
    Assert-Throws {Package-Fixture} 'prebuilt DLL hash mismatch refused'
    [IO.File]::WriteAllBytes((Join-Path $dist 'dxgi.dll'),$proxyBytes)
    [IO.File]::AppendAllText((Join-Path $dist 'dxgi_proxy.def'),"`n; changed fixture")
    Assert-Throws {Package-Fixture} 'forwarder definition mismatch refused'
    Assert-Test ((Hash $release.ZipPath) -ceq $zipHash) 'failed packaging preserves existing release ZIP'
    [IO.File]::WriteAllBytes((Join-Path $dist 'dxgi_proxy.def'),$definitionBytes)
    $changedManifest=Get-Content -LiteralPath (Join-Path $dist 'build.json') -Raw|ConvertFrom-Json
    $changedManifest.SystemExports[0].Name='UnexpectedFixtureName'
    $changedManifest.SystemExportsSHA256=Get-ExportContractHash $changedManifest.SystemExports
    Save-Manifest $changedManifest
    Assert-Throws {Package-Fixture} 'self-consistent wrong manifest export contract refused'
    [IO.File]::WriteAllBytes((Join-Path $dist 'build.json'),$manifestBytes)
    $changed=[byte[]]$proxyBytes.Clone();$ascii=[Text.Encoding]::ASCII.GetString($changed);$at=$ascii.IndexOf('dxgi_codex_system.')
    if($at -lt 0){throw 'Fixture proxy forwarder text missing.'};$changed[$at]=[byte][char]'z'
    [IO.File]::WriteAllBytes((Join-Path $dist 'dxgi.dll'),$changed);$manifest.ModSHA256=Hash (Join-Path $dist 'dxgi.dll');Save-Manifest $manifest
    Assert-Throws {Package-Fixture} 'wrong native forwarder refused even with updated artifact hash'
    $changed=[byte[]]$proxyBytes.Clone();$at=([Text.Encoding]::ASCII.GetString($changed)).IndexOf('KERNEL32.dll')
    if($at -lt 0){throw 'Fixture Kernel32 import text missing.'};$changed[$at+5]=[byte][char]'Z'
    [IO.File]::WriteAllBytes((Join-Path $dist 'dxgi.dll'),$changed);$manifest.ModSHA256=Hash (Join-Path $dist 'dxgi.dll');Save-Manifest $manifest
    Assert-Throws {Package-Fixture} 'foreign native dependency refused even with valid export contract/hash'
    [IO.File]::WriteAllBytes((Join-Path $dist 'dxgi.dll'),$proxyBytes);[IO.File]::WriteAllBytes((Join-Path $dist 'build.json'),$manifestBytes)
    $outside=Join-Path $scratch 'ready.zip';$release=& (Join-Path $fixture 'Package-Release.ps1') -OutputPath $outside
    Assert-Test ($release.ZipPath -ceq [IO.Path]::GetFullPath($outside) -and (Hash $outside) -ceq $release.SHA256) 'explicit external release output succeeds'
    Assert-Test (@(Fixture-Git -Arguments @('status','--porcelain=v1','--untracked-files=normal')).Count -eq 0) 'successful and failed packaging preserve a clean source checkout'
    Write-Output "PASS: $script:passed ready-release provenance, exact ZIP contents and refusal contracts. No DLL loaded or game/Steam changed."
}finally{
    $full=[IO.Path]::GetFullPath($scratch);$prefix=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^\.tmp-[0-9a-f]{32}$'){throw 'Unsafe release fixture cleanup target.'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
