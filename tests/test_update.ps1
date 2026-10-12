# Synthetic packages and mocked network only. Never runs a game or installs a mod.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('me-update-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch)|Out-Null
$module=Import-Module (Join-Path $source 'scripts/Update.psm1') -Force -PassThru
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$script:passed=0
function Check([bool]$Value,[string]$Message){if(-not$Value){throw ('FAIL: '+$Message)};$script:passed++}
function Throws([scriptblock]$Action,[string]$Message){$caught=$false;try{&$Action|Out-Null}catch{$caught=$true};Check $caught $Message}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Put([string]$Root,[string]$Name,[string]$Text){$path=Join-Path $Root $Name;[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null;[IO.File]::WriteAllText($path,$Text,[Text.UTF8Encoding]::new($false))}
function New-Package([string]$Name,[string]$Version,[switch]$New){
    $root=Join-Path $scratch $Name;[IO.Directory]::CreateDirectory($root)|Out-Null
    foreach($name in @('Start.cmd','Updater.ps1','scripts/Update.psm1')){Put $root $name ([IO.File]::ReadAllText((Join-Path $source $name)))}
    $sources=@('Start.cmd','Updater.ps1','scripts/Update.psm1','Launcher.ps1','README.md','release-files.json','src/fixture.c')
    if($New){$sources+='Feature.ps1';Put $root 'Feature.ps1' 'new feature; inert'}else{$sources+='Retired.txt';Put $root 'Retired.txt' 'retired source'}
    Put $root 'Launcher.ps1' ('# inert launcher '+$Version)
    Put $root 'README.md' ('package '+$Version);Put $root 'src/fixture.c' ('/* version '+$Version+' */')
    Put $root 'dist/dxgi.dll' ('inert proxy '+$Version);Put $root 'dist/ManeaterAreaHelper.exe' ('inert helper '+$Version);Put $root 'dist/dxgi_proxy.def' 'inert definition'
    Put $root 'release-files.json' (([ordered]@{Version=$Version;SourceFiles=$sources})|ConvertTo-Json -Depth 5)
    Put $root 'dist/build.json' (([ordered]@{Version=$Version;ModSHA256=(Hash (Join-Path $root 'dist/dxgi.dll'));HelperSHA256=(Hash (Join-Path $root 'dist/ManeaterAreaHelper.exe'));DefinitionSHA256=(Hash (Join-Path $root 'dist/dxgi_proxy.def'));SourceHashes=@{'src/fixture.c'=(Hash (Join-Path $root 'src/fixture.c'))}})|ConvertTo-Json -Depth 5)
    Save-Ledger $root
    return $root
}
function Save-Ledger([string]$Root){
    $sources=(Get-Content (Join-Path $Root 'release-files.json') -Raw|ConvertFrom-Json).SourceFiles
    $files=[ordered]@{}
    foreach($name in @($sources)+@('dist/dxgi.dll','dist/ManeaterAreaHelper.exe','dist/build.json','dist/dxgi_proxy.def')){$files[$name]=Hash (Join-Path $Root $name)}
    Put $Root 'dist/package-files.json' (([ordered]@{SchemaVersion=1;BootstrapProtocol=1;Repository='rodrigdoliveira/maneater-crash-fps-fix';Version=(Get-Content (Join-Path $Root 'release-files.json') -Raw|ConvertFrom-Json).Version;Files=$files})|ConvertTo-Json -Depth 8)
}
function Zip-Package([string]$Root,[string]$Name,[string]$Extra=''){
    $path=Join-Path $scratch $Name;$stream=[IO.File]::Open($path,'CreateNew','ReadWrite','None');$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try{
        foreach($file in Get-ChildItem -LiteralPath $Root -File -Recurse){$relative=$file.FullName.Substring($Root.Length+1).Replace('\','/');$entry=$archive.CreateEntry('Maneater-Crash-FPS-Fix/'+$relative);$output=$entry.Open();try{$bytes=[IO.File]::ReadAllBytes($file.FullName);$output.Write($bytes,0,$bytes.Length)}finally{$output.Dispose()}}
        if($Extra){$entry=$archive.CreateEntry($Extra);$output=$entry.Open();try{$output.WriteByte(1)}finally{$output.Dispose()}}
    }finally{$archive.Dispose();$stream.Dispose()}
    return $path
}
function Snapshot([string]$Root){$files=[ordered]@{};foreach($file in Get-ChildItem -LiteralPath $Root -File -Recurse|Where-Object {$_.FullName-notmatch'\\\.local\\'}){$files[$file.FullName.Substring($Root.Length+1)]=Hash $file.FullName};$files|ConvertTo-Json -Compress}
function Network-Fixture([string]$Zip,[string]$Version,[string]$DigestOverride=''){
    $digest=Hash $Zip;$size=([IO.FileInfo]$Zip).Length
    $metadata=[ordered]@{draft=$false;prerelease=$false;tag_name=('v'+$Version);assets=@(
        @{name='Maneater-Crash-FPS-Fix.zip';size=$size;digest=('sha256:'+$(if($DigestOverride){$DigestOverride}else{$digest.ToLowerInvariant()}));browser_download_url=('https://github.com/rodrigdoliveira/maneater-crash-fps-fix/releases/download/v'+$Version+'/Maneater-Crash-FPS-Fix.zip')},
        @{name='Maneater-Crash-FPS-Fix.zip.sha256';size=94;browser_download_url=('https://github.com/rodrigdoliveira/maneater-crash-fps-fix/releases/download/v'+$Version+'/Maneater-Crash-FPS-Fix.zip.sha256')})}
    & $module {param($Zip,$Text,$Digest)
        $script:fixtureZip=$Zip;$script:fixtureMetadata=$Text;$script:fixtureDigest=$Digest
        function script:Receive-UpdateBytes([uri]$Uri,[string]$Path,[long]$Limit){
            if($Uri.Host-ceq'api.github.com'){[IO.File]::WriteAllText($Path,$script:fixtureMetadata)}
            elseif($Uri.AbsolutePath.EndsWith('.sha256')){[IO.File]::WriteAllText($Path,$script:fixtureDigest+'  Maneater-Crash-FPS-Fix.zip')}
            else{[IO.File]::Copy($script:fixtureZip,$Path,$false)}
        }
    } $Zip ($metadata|ConvertTo-Json -Depth 8) $digest
}
try{
    foreach($name in @('../outside.txt','/absolute.txt','a\b.txt','.local/repair.json','a/CON.txt','dist/foreign.exe','a./file.txt','a:stream','a//b.txt')){Throws {&$module {param($Name) Assert-UpdateRelative $Name} $name} ('unsafe path '+$name)}
    foreach($uri in @('http://github.com/a','https://evil.example/a','https://github.com:444/a','https://user@github.com/a')){Throws {&$module {param($Uri) Assert-UpdateUri ([uri]$Uri)} $uri} ('unsafe host '+$uri)}
    Check ((&$module {Get-UpdateVersion 'v1.10.0'})-gt(&$module {Get-UpdateVersion 'v1.9.0'})) 'numeric version comparison'
    foreach($version in @('v1.0.0-rc.1','1.2','01.2.3','1.2.3.4')){Throws {&$module {param($V) Get-UpdateVersion $V} $version} 'unsupported version excluded'}
    $old=New-Package 'roundtrip' '0.8.0';$new=New-Package 'incoming' '0.9.0' -New
    Put $old '.local/repair.json' 'original restore record';Put $old '.local/backups/sentinel.dat' 'original backup';Put $old 'user-notes.txt' 'unowned notes'
    $stateHash=Hash (Join-Path $old '.local/repair.json');$backupHash=Hash (Join-Path $old '.local/backups/sentinel.dat');$bootstrapHash=Hash (Join-Path $old 'Updater.ps1')
    $version=Install-LauncherUpdate $old $new
    Check ($version-ceq'0.9.0') 'newer application installed'
    Check ((Read-UpdateLedger $old -VerifyFiles).Version-ceq'0.9.0') 'complete new package verifies'
    Check (-not[IO.File]::Exists((Join-Path $old 'Retired.txt'))-and[IO.File]::Exists((Join-Path $old 'Feature.ps1'))) 'owned retired/new files handled'
    Check ((Hash (Join-Path $old '.local/repair.json'))-ceq$stateHash-and(Hash (Join-Path $old '.local/backups/sentinel.dat'))-ceq$backupHash) 'restore records and backups preserved'
    Check ((Hash (Join-Path $old 'Updater.ps1'))-ceq$bootstrapHash-and[IO.File]::ReadAllText((Join-Path $old 'user-notes.txt'))-ceq'unowned notes') 'bootstrap and unowned data preserved'
    Throws {Install-LauncherUpdate $old $new} 'same version is not reinstalled'
    $pendingPath=Join-Path $old '.local/update-pending.json';$pending=Get-Content $pendingPath -Raw|ConvertFrom-Json
    $pending.Status='Applying';[IO.File]::WriteAllText($pendingPath,($pending|ConvertTo-Json -Depth 12))
    Restore-LauncherUpdate $old
    Check ((Read-UpdateLedger $old -VerifyFiles).Version-ceq'0.8.0'-and-not[IO.File]::Exists((Join-Path $old 'Feature.ps1'))) 'restart recovers a completed file swap with an unfinished transaction'
    Check ((Hash (Join-Path $old '.local/repair.json'))-ceq$stateHash-and(Hash (Join-Path $old '.local/backups/sentinel.dat'))-ceq$backupHash) 'restart recovery retains game restore state'

    $changed=New-Package 'modified-source' '0.8.0';Put $changed 'README.md' 'user modification';$before=Snapshot $changed
    Throws {Install-LauncherUpdate $changed $new} 'changed owned file preserved'
    Check ((Snapshot $changed)-ceq$before) 'refused modified package remains unchanged'
    $collision=New-Package 'collision' '0.8.0';Put $collision 'Feature.ps1' 'foreign feature';$before=Snapshot $collision
    Throws {Install-LauncherUpdate $collision $new} 'new untracked destination preserved'
    Check ((Snapshot $collision)-ceq$before) 'untracked collision leaves all app files unchanged'
    $newBoot=New-Package 'new-bootstrap' '0.9.0' -New;Put $newBoot 'Updater.ps1' '# incompatible bootstrap';Save-Ledger $newBoot
    $original=New-Package 'old-bootstrap' '0.8.0'
    Throws {Install-LauncherUpdate $original $newBoot} 'bootstrap protocol compatibility retained'

    $failing=New-Package 'rollback' '0.8.0';$before=Snapshot $failing
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'scripts/Update.psm1'),[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($node) $node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-eq'Install-LauncherUpdate'},$true)
    $body=$fn.Extent.Text.Replace('function Install-LauncherUpdate','function script:Install-LauncherUpdate').Replace('# UPDATE_BEFORE_FILE_PUBLISH',"if(`$entry.Name -ceq 'Launcher.ps1'){throw 'injected publication failure'}")
    & $module {param($Body) Invoke-Expression $Body} $body
    Throws {&$module {param($Root,$Payload) Install-LauncherUpdate $Root $Payload} $failing $new} 'mid-update failure reports rollback'
    Check ((Snapshot $failing)-ceq$before) 'all package files restored after a partial update'
    Check ((Get-Content (Join-Path $failing '.local/update-pending.json') -Raw|ConvertFrom-Json).Status-ceq'RolledBack') 'rollback result recorded'
    $module=Import-Module (Join-Path $source 'scripts/Update.psm1') -Force -PassThru

    $zip=Zip-Package $new 'good.zip';$expanded=Join-Path $scratch 'expanded';[IO.Directory]::CreateDirectory($expanded)|Out-Null
    Check ((&$module {param($Zip,$Path) Expand-LauncherUpdate $Zip $Path} $zip $expanded).Version-ceq'0.9.0') 'validated archive expands'
    foreach($extra in @('Maneater-Crash-FPS-Fix/../escape.txt','Maneater-Crash-FPS-Fix/.local/repair.json','Maneater-Crash-FPS-Fix/Launcher.ps1','Other/app.txt','Maneater-Crash-FPS-Fix/unlisted.txt')){
        $bad=Zip-Package $new ([Guid]::NewGuid().ToString('N')+'.zip') $extra;$dest=Join-Path $scratch ([Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($dest)|Out-Null
        Throws {&$module {param($Zip,$Path) Expand-LauncherUpdate $Zip $Path} $bad $dest} 'malformed/unowned archive refused'
    }
    $online=New-Package 'download-roundtrip' '0.8.0';Network-Fixture $zip '0.9.0'
    Check ((Invoke-LauncherUpdate $online).Updated) 'mock GitHub checksum and update pipeline succeeds'
    $mismatch=New-Package 'bad-digest' '0.8.0';$before=Snapshot $mismatch;Network-Fixture $zip '0.9.0' ('0'*64)
    Throws {Invoke-LauncherUpdate $mismatch} 'conflicting GitHub/sidecar digests refused'
    Check ((Snapshot $mismatch)-ceq$before) 'bad download never changes installed package'
    Network-Fixture $zip '0.8.0';Check (-not(Invoke-LauncherUpdate $mismatch).Updated) 'current release opens without reinstall'

    # Actual bootstrap rendering only; no worker, request, registry or network.
    $powershell=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell/v1.0/powershell.exe'
    & $powershell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $source 'Updater.ps1') -RenderPreview
    Check ($LASTEXITCODE-eq0-and[IO.File]::Exists((Join-Path $source 'dist/updater-preview.png'))) 'separate updater UI renders without running update work'

    # Run the real bootstrap, worker and process handoff against an inert core.
    # Mock only its HTTP transport in an isolated module copy. No live launcher
    # registry discovery or game process is allowed to run.
    $boot=New-Package 'bootstrap-flow' '0.8.0'
    $metadata=[ordered]@{draft=$false;prerelease=$false;tag_name='v0.8.0';assets=@(
        @{name='Maneater-Crash-FPS-Fix.zip';size=100;digest=('sha256:'+('0'*64));browser_download_url='https://github.com/rodrigdoliveira/maneater-crash-fps-fix/releases/download/v0.8.0/Maneater-Crash-FPS-Fix.zip'},
        @{name='Maneater-Crash-FPS-Fix.zip.sha256';size=94;browser_download_url='https://github.com/rodrigdoliveira/maneater-crash-fps-fix/releases/download/v0.8.0/Maneater-Crash-FPS-Fix.zip.sha256'})}|ConvertTo-Json -Depth 7 -Compress
    $mock="`nfunction Receive-UpdateBytes([uri]`$Uri,[string]`$Path,[long]`$Limit){if(`$Uri.Host -cne 'api.github.com'){throw 'No fixture downloads expected'};[IO.File]::WriteAllText(`$Path,'"+$metadata.Replace("'","''")+"')}"
    [IO.File]::AppendAllText((Join-Path $boot 'scripts/Update.psm1'),$mock)
    Put $boot 'Launcher.ps1' "param([switch]`$FromUpdater)`n[IO.File]::WriteAllText((Join-Path `$PSScriptRoot '.local/core-opened.txt'),'inert core opened')"
    $bootstrap=[IO.File]::ReadAllText((Join-Path $boot 'Updater.ps1')).Replace("`$form.StartPosition='CenterScreen'", "`$form.StartPosition='Manual';`$form.Location=New-Object Drawing.Point(-2000,-2000);`$form.ShowInTaskbar=`$false")
    Put $boot 'Updater.ps1' $bootstrap;Save-Ledger $boot
    $process=Start-Process -FilePath $powershell -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "'+(Join-Path $boot 'Updater.ps1')+'"') -WindowStyle Hidden -PassThru
    try{Check ($process.WaitForExit(15000)) 'bootstrap completes check and closes after inert core exits';Check ($process.ExitCode-eq0-and[IO.File]::Exists((Join-Path $boot '.local/core-opened.txt'))) 'verified updater opens the launcher automatically'}finally{$process.Dispose()}
    $results=@(Get-ChildItem -LiteralPath (Join-Path $boot '.local') -Filter '*.result.json')
    Check ($results.Count-eq1-and(Get-Content $results[0].FullName -Raw|ConvertFrom-Json).Success) 'bootstrap worker returns its completed update result'
    Write-Output "PASS: $script:passed updater integrity, archive, preservation, rollback, download and bootstrap contracts. No real network or game used."
}catch{Write-Output ('Updater fixture failure: '+$_.Exception.Message);throw}finally{
    $full=[IO.Path]::GetFullPath($scratch);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not$full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($full)-cnotmatch'^me-update-[0-9a-f]{32}$'){throw 'Unsafe updater fixture cleanup.'}
    try{Remove-Item -LiteralPath $full -Recurse -Force}catch{Write-Warning ('Fixture cleanup deferred: '+$_.Exception.Message)}
}
