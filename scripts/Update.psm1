Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:Repository='rodrigdoliveira/maneater-crash-fps-fix'
$script:BootstrapFiles=@('Start.cmd','Updater.ps1','scripts/Update.psm1')
$script:Artifacts=@('dist/dxgi.dll','dist/ManeaterAreaHelper.exe','dist/build.json','dist/dxgi_proxy.def')

function Update-Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Write-UpdateJson([string]$Path,$Value){
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null
    $stage=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($stage,($Value|ConvertTo-Json -Depth 20)+"`n",[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($Path)){[IO.File]::Replace($stage,$Path,[NullString]::Value)}else{[IO.File]::Move($stage,$Path)}
    }finally{if([IO.File]::Exists($stage)){[IO.File]::Delete($stage)}}
}
function Assert-UpdateRelative([string]$Name){
    if([string]::IsNullOrWhiteSpace($Name)-or $Name.Length-gt220-or $Name-match '[\\:]|^/|//|[\x00-\x1f]' -or
       $Name-match '(^|/)(\.|\.\.|\.local|\.git|cache)(/|$)' -or $Name-match '(^|/)(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|/|$)' -or
       @($Name.Split('/')|Where-Object {$_-match '[ .]$'}).Count){throw 'Unsafe update package path.'}
    if($Name-match '\.(dll|exe|pdb|sav|etl|log)$'-and $Name-cnotin @('dist/dxgi.dll','dist/ManeaterAreaHelper.exe')){throw 'Unexpected binary in update package.'}
}
function Assert-UpdatePath([string]$Root,[string]$Path){
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Update path escapes its folder.'}
    $at=$full
    while($at-and $at.Length-ge$base.Length){
        $item=Get-Item -LiteralPath $at -Force -ErrorAction SilentlyContinue
        if($null-ne$item-and($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Linked update paths are preserved.'}
        if($at-ieq$base){break};$at=[IO.Path]::GetDirectoryName($at)
    }
}
function Get-UpdateVersion([string]$Text){
    if($Text-cnotmatch '^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'){throw 'Unsupported release version.'}
    return [version]$Text.TrimStart('v')
}
function Read-UpdateLedger([string]$Root,[switch]$VerifyFiles){
    $ledgerPath=Join-Path $Root 'dist/package-files.json'
    Assert-UpdatePath $Root $ledgerPath
    if(-not[IO.File]::Exists($ledgerPath)-or([IO.FileInfo]$ledgerPath).Length-gt1048576){throw 'Package inventory is missing or invalid.'}
    $ledger=Get-Content -LiteralPath $ledgerPath -Raw|ConvertFrom-Json
    if($ledger.SchemaVersion-ne1-or$ledger.BootstrapProtocol-ne1-or$ledger.Repository-cne$script:Repository){throw 'Unsupported updater package format.'}
    $null=Get-UpdateVersion $ledger.Version
    $properties=@($ledger.Files.PSObject.Properties)
    if($properties.Count-lt8-or$properties.Count-gt2048){throw 'Invalid package inventory size.'}
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in $properties){
        Assert-UpdateRelative $entry.Name
        if(-not$names.Add($entry.Name)-or$entry.Value-cnotmatch '^[0-9A-F]{64}$'){throw 'Invalid package inventory entry.'}
        $path=Join-Path $Root $entry.Name;Assert-UpdatePath $Root $path
        if($VerifyFiles-and(-not[IO.File]::Exists($path)-or(Update-Hash $path)-cne$entry.Value)){throw ('Package file changed or is missing: '+$entry.Name)}
    }
    foreach($name in $script:BootstrapFiles+@('Launcher.ps1','release-files.json')+$script:Artifacts){if(-not$names.Contains($name)){throw 'Required updater/application file is missing.'}}
    $sourcePath=Join-Path $Root 'release-files.json'
    $source=Get-Content -LiteralPath $sourcePath -Raw|ConvertFrom-Json
    if($source.Version-cne$ledger.Version-or@($source.SourceFiles).Count+4-ne$properties.Count){throw 'Source inventory differs from package inventory.'}
    $expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($name in @($source.SourceFiles)+$script:Artifacts){
        Assert-UpdateRelative $name
        if(-not$expected.Add($name)-or-not$names.Contains($name)){throw 'Source inventory is incomplete or duplicated.'}
    }
    $build=Get-Content -LiteralPath (Join-Path $Root 'dist/build.json') -Raw|ConvertFrom-Json
    if($build.Version-cne$ledger.Version-or$build.ModSHA256-cne$ledger.Files.'dist/dxgi.dll'-or
       $build.HelperSHA256-cne$ledger.Files.'dist/ManeaterAreaHelper.exe'-or$build.DefinitionSHA256-cne$ledger.Files.'dist/dxgi_proxy.def'){throw 'Native build inventory mismatch.'}
    foreach($entry in $build.SourceHashes.PSObject.Properties){
        Assert-UpdateRelative $entry.Name
        if(-not$names.Contains($entry.Name)-or$ledger.Files.PSObject.Properties[$entry.Name].Value-cne$entry.Value){throw 'Native source provenance mismatch.'}
    }
    return $ledger
}
function Assert-UpdateUri([uri]$Uri){
    if($Uri.Scheme-cne'https'-or$Uri.Port-ne443-or$Uri.UserInfo-or
       $Uri.Host-notin@('api.github.com','github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')){throw 'Update download is outside GitHub HTTPS.'}
}
function Receive-UpdateBytes([uri]$Uri,[string]$Path,[long]$Limit){
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol-bor[Net.SecurityProtocolType]::Tls12
    $response=$null;$input=$null;$output=$null;$request=$null
    try{
        for($redirect=0;$redirect-lt6;$redirect++){
            Assert-UpdateUri $Uri
            $request=[Net.HttpWebRequest]::Create($Uri);$request.UserAgent='Maneater-Crash-FPS-Fix-Updater'
            $request.Timeout=12000;$request.ReadWriteTimeout=12000;$request.AllowAutoRedirect=$false
            $response=$request.GetResponse()
            if([int]$response.StatusCode-in@(301,302,303,307,308)){
                $next=$response.Headers['Location'];$response.Dispose();$response=$null
                if(-not$next){throw 'Update redirect has no destination.'};$Uri=[uri]::new($Uri,$next);continue
            }
            if([int]$response.StatusCode-ne200){throw 'Update download failed.'};break
        }
        if($null-eq$response){throw 'Too many update redirects.'}
        if($response.ContentLength-gt$Limit){throw 'Update download exceeds its limit.'}
        $input=$response.GetResponseStream();$output=[IO.File]::Open($Path,'CreateNew','Write','None')
        $buffer=New-Object byte[] 65536;$total=0L
        while(($count=$input.Read($buffer,0,$buffer.Length))-gt0){$total+=$count;if($total-gt$Limit){throw 'Update download exceeds its limit.'};$output.Write($buffer,0,$count)}
        $output.Flush($true)
    }finally{if($output){$output.Dispose()};if($input){$input.Dispose()};if($response){$response.Dispose()};if($request){$request.Abort()}}
}
function Get-GitHubLauncherRelease([string]$Scratch){
    $metadata=Join-Path $Scratch ('release-'+[Guid]::NewGuid().ToString('N')+'.json')
    try{
        Receive-UpdateBytes ([uri]('https://api.github.com/repos/'+$script:Repository+'/releases/latest')) $metadata 1048576
        $release=Get-Content -LiteralPath $metadata -Raw|ConvertFrom-Json
        if($release.draft-isnot[bool]-or$release.prerelease-isnot[bool]-or$release.draft-or$release.prerelease){throw 'Latest release is not a regular published release.'}
        $version=Get-UpdateVersion $release.tag_name
        $zip=@($release.assets|Where-Object {$_.name-ceq'Maneater-Crash-FPS-Fix.zip'})
        $checksum=@($release.assets|Where-Object {$_.name-ceq'Maneater-Crash-FPS-Fix.zip.sha256'})
        if($zip.Count-ne1-or$checksum.Count-ne1-or$zip[0].size-lt1-or$zip[0].size-gt67108864-or$checksum[0].size-gt4096){throw 'Ready-to-run release assets are missing or invalid.'}
        $prefix='https://github.com/'+$script:Repository+'/releases/download/'+$release.tag_name+'/'
        foreach($entry in @($zip[0],$checksum[0])){if($entry.browser_download_url-cne($prefix+$entry.name)){throw 'Release asset URL does not match the project and tag.'}}
        $digest=$(if($null-ne$zip[0].PSObject.Properties['digest']){$zip[0].digest}else{$null})
        if($digest-and$digest-cnotmatch '^sha256:[0-9a-fA-F]{64}$'){throw 'Unsupported release digest.'}
        [pscustomobject]@{Version=$version.ToString();Tag=$release.tag_name;ZipUri=$zip[0].browser_download_url;ZipSize=[long]$zip[0].size;ChecksumUri=$checksum[0].browser_download_url;Digest=$digest}
    }finally{if([IO.File]::Exists($metadata)){[IO.File]::Delete($metadata)}}
}
function Expand-LauncherUpdate([string]$Zip,[string]$Destination){
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($Zip)
    try{
        if($archive.Entries.Count-gt2048){throw 'Update archive contains too many files.'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$total=0L
        foreach($entry in $archive.Entries){
            if($entry.FullName.EndsWith('/')){continue}
            $prefix='Maneater-Crash-FPS-Fix/'
            if(-not$entry.FullName.StartsWith($prefix,[StringComparison]::Ordinal)){throw 'Unexpected update archive root.'}
            $relative=$entry.FullName.Substring($prefix.Length);Assert-UpdateRelative $relative
            if(-not$seen.Add($relative)){throw 'Duplicate update archive path.'}
            $total+=$entry.Length;if($entry.Length-gt67108864-or$total-gt134217728){throw 'Expanded update archive is too large.'}
            $path=Join-Path $Destination $relative;Assert-UpdatePath $Destination $path
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null
            $input=$entry.Open();$output=[IO.File]::Open($path,'CreateNew','Write','None')
            try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}
        }
    }finally{$archive.Dispose()}
    $ledger=Read-UpdateLedger $Destination -VerifyFiles
    if($seen.Count-ne@($ledger.Files.PSObject.Properties).Count+1){throw 'Update archive has unowned files.'}
    foreach($name in $seen){if($name-cne'dist/package-files.json'-and$null-eq$ledger.Files.PSObject.Properties[$name]){throw 'Update archive has an unowned file.'}}
    return $ledger
}
function Read-UpdateTransaction([string]$Root){
    $path=Join-Path $Root '.local/update-pending.json';Assert-UpdatePath $Root $path
    if(-not[IO.File]::Exists($path)){return $null}
    if(([IO.FileInfo]$path).Length-gt2097152){throw 'Update recovery record is invalid.'}
    $plan=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    $full=[IO.Path]::GetFullPath($Root).TrimEnd('\');$stage=[IO.Path]::GetFullPath([string]$plan.Stage)
    if($plan.SchemaVersion-ne1-or$plan.Root-ine$full-or[IO.Path]::GetDirectoryName($stage)-ine(Join-Path $full '.local/updates')-or[IO.Path]::GetFileName($stage)-cnotmatch'^[0-9a-f]{32}$'){throw 'Invalid update recovery paths.'}
    Assert-UpdatePath $Root $stage
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if(@($plan.Entries).Count-gt2048){throw 'Invalid update recovery entry count.'}
    foreach($entry in $plan.Entries){
        Assert-UpdateRelative $entry.Name
        if(-not$seen.Add($entry.Name)-or$entry.Name-cin$script:BootstrapFiles){throw 'Invalid update recovery entry.'}
        foreach($hash in @($entry.OldHash,$entry.NewHash)){if($null-ne$hash-and$hash-cnotmatch '^[0-9A-F]{64}$'){throw 'Invalid update recovery hash.'}}
    }
    return $plan
}
function Restore-LauncherUpdate([string]$Root){
    $plan=Read-UpdateTransaction $Root
    if($null-eq$plan-or$plan.Status-in@('Complete','RolledBack')){return}
    if($plan.Status-notin@('Applying','RecoveryRequired')){throw 'Unknown update recovery state.'}
    foreach($entry in $plan.Entries){
        $target=Join-Path $Root $entry.Name;Assert-UpdatePath $Root $target
        if([IO.File]::Exists($target)){$current=Update-Hash $target;if($current-cne$entry.OldHash-and$current-cne$entry.NewHash){throw ('Changed file preserved during update recovery: '+$entry.Name)}}
        if($null-ne$entry.OldHash){$backup=Join-Path $plan.Stage ('backup/'+$entry.Name);Assert-UpdatePath $Root $backup;if(-not[IO.File]::Exists($backup)-or(Update-Hash $backup)-cne$entry.OldHash){throw 'Update rollback backup changed.'}}
    }
    foreach($entry in $plan.Entries){
        $target=Join-Path $Root $entry.Name
        $current=$(if([IO.File]::Exists($target)){Update-Hash $target}else{$null})
        if($current-ceq$entry.OldHash){continue}
        if($null-eq$entry.OldHash){if([IO.File]::Exists($target)){[IO.File]::Delete($target)};continue}
        $stage=Join-Path $plan.Stage ([Guid]::NewGuid().ToString('N')+'.restore.tmp')
        try{
            [IO.File]::Copy((Join-Path $plan.Stage ('backup/'+$entry.Name)),$stage,$false)
            if((Update-Hash $stage)-cne$entry.OldHash){throw 'Staged rollback file changed.'}
            if([IO.File]::Exists($target)){if((Update-Hash $target)-cne$entry.NewHash){throw 'Rollback destination changed.'};[IO.File]::Replace($stage,$target,[NullString]::Value)}
            else{[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null;[IO.File]::Move($stage,$target)}
        }finally{if([IO.File]::Exists($stage)){[IO.File]::Delete($stage)}}
    }
    $plan.Status='RolledBack';Write-UpdateJson (Join-Path $Root '.local/update-pending.json') $plan
}
function Install-LauncherUpdate([string]$Root,[string]$Payload,[scriptblock]$Progress={}){
    $Root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    Restore-LauncherUpdate $Root
    $old=Read-UpdateLedger $Root -VerifyFiles;$new=Read-UpdateLedger $Payload -VerifyFiles
    if((Get-UpdateVersion $new.Version)-le(Get-UpdateVersion $old.Version)){throw 'Update must be newer than the installed version.'}
    foreach($name in $script:BootstrapFiles){if($old.Files.PSObject.Properties[$name].Value-cne$new.Files.PSObject.Properties[$name].Value){throw 'This release needs a newer bootstrap. Download its full ZIP once.'}}
    $updates=Join-Path $Root '.local/updates';Assert-UpdatePath $Root $updates
    $stage=Join-Path $updates ([Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($stage)|Out-Null
    $entries=[Collections.Generic.List[object]]::new()
    $names=@(@($old.Files.PSObject.Properties|ForEach-Object Name)+@($new.Files.PSObject.Properties|ForEach-Object Name)+'dist/package-files.json'|Sort-Object -Unique)
    foreach($name in $names){
        if($name-cin$script:BootstrapFiles){continue}
        $target=Join-Path $Root $name;Assert-UpdatePath $Root $target
        $oldHash=$(if($name-ceq'dist/package-files.json'){Update-Hash $target}elseif($null-ne$old.Files.PSObject.Properties[$name]){$old.Files.PSObject.Properties[$name].Value}else{$null})
        $newHash=$(if($name-ceq'dist/package-files.json'){Update-Hash (Join-Path $Payload $name)}elseif($null-ne$new.Files.PSObject.Properties[$name]){$new.Files.PSObject.Properties[$name].Value}else{$null})
        if($null-eq$oldHash-and(Test-Path -LiteralPath $target)){throw ('Untracked file preserved: '+$name)}
        if($null-ne$oldHash){
            $backup=Join-Path $stage ('backup/'+$name);[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup))|Out-Null
            [IO.File]::Copy($target,$backup,$false);if((Update-Hash $backup)-cne$oldHash){throw 'Update backup changed.'}
        }
        $entries.Add([pscustomobject]@{Name=$name;OldHash=$oldHash;NewHash=$newHash})
    }
    $plan=[pscustomobject]@{SchemaVersion=1;Status='Applying';Root=$Root;Stage=$stage;OldVersion=$old.Version;NewVersion=$new.Version;Entries=$entries.ToArray()}
    Write-UpdateJson (Join-Path $Root '.local/update-pending.json') $plan
    try{
        foreach($entry in $plan.Entries){
            & $Progress ('Updating '+$entry.Name+'...')
            $target=Join-Path $Root $entry.Name;Assert-UpdatePath $Root $target
            $current=$(if([IO.File]::Exists($target)){Update-Hash $target}else{$null})
            if($current-cne$entry.OldHash){throw 'Installed file changed during update.'}
            if($null-eq$entry.NewHash){if([IO.File]::Exists($target)){[IO.File]::Delete($target)};continue}
            $staged=Join-Path $stage ([Guid]::NewGuid().ToString('N')+'.publish.tmp')
            try{
                [IO.File]::Copy((Join-Path $Payload $entry.Name),$staged,$false)
                if((Update-Hash $staged)-cne$entry.NewHash){throw 'Staged update file changed.'}
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null
                # UPDATE_BEFORE_FILE_PUBLISH
                if([IO.File]::Exists($target)){if((Update-Hash $target)-cne$entry.OldHash){throw 'Update destination changed.'};[IO.File]::Replace($staged,$target,[NullString]::Value)}else{[IO.File]::Move($staged,$target)}
            }finally{if([IO.File]::Exists($staged)){[IO.File]::Delete($staged)}}
        }
        $null=Read-UpdateLedger $Root -VerifyFiles
        $plan.Status='Complete';Write-UpdateJson (Join-Path $Root '.local/update-pending.json') $plan
    }catch{
        $failure=$_.Exception.Message
        try{Restore-LauncherUpdate $Root}catch{$plan.Status='RecoveryRequired';Write-UpdateJson (Join-Path $Root '.local/update-pending.json') $plan;throw ($failure+' Recovery: '+$_.Exception.Message)}
        throw ($failure+' The previous launcher files were restored.')
    }
    return $new.Version
}
function Invoke-LauncherUpdate([string]$Root,[scriptblock]$Progress={}){
    $Root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    if(Test-Path -LiteralPath (Join-Path $Root '.git')){return [pscustomobject]@{Updated=$false;Version=(Get-Content (Join-Path $Root 'release-files.json') -Raw|ConvertFrom-Json).Version;Message='Developer checkout: update with Git.'}}
    Restore-LauncherUpdate $Root
    $current=Read-UpdateLedger $Root -VerifyFiles
    $scratch=Join-Path $Root ('.local/updates/'+[Guid]::NewGuid().ToString('N'));Assert-UpdatePath $Root $scratch
    [IO.Directory]::CreateDirectory($scratch)|Out-Null
    & $Progress 'Checking GitHub releases...'
    $release=Get-GitHubLauncherRelease $scratch
    if((Get-UpdateVersion $release.Version)-le(Get-UpdateVersion $current.Version)){return [pscustomobject]@{Updated=$false;Version=$current.Version;Message='Launcher is up to date.'}}
    & $Progress ('Downloading launcher '+$release.Version+'...')
    $zip=Join-Path $scratch 'update.zip';$checksum=Join-Path $scratch 'update.sha256'
    Receive-UpdateBytes ([uri]$release.ChecksumUri) $checksum 4096
    $line=([IO.File]::ReadAllText($checksum)).Trim()
    if($line-cnotmatch '^([0-9a-fA-F]{64})\s+\*?Maneater-Crash-FPS-Fix\.zip$'){throw 'Release checksum is malformed.'}
    $expected=$Matches[1].ToUpperInvariant()
    if($release.Digest-and$release.Digest.Substring(7).ToUpperInvariant()-cne$expected){throw 'Release digest and checksum disagree.'}
    Receive-UpdateBytes ([uri]$release.ZipUri) $zip 67108864
    if(([IO.FileInfo]$zip).Length-ne$release.ZipSize-or(Update-Hash $zip)-cne$expected){throw 'Downloaded update does not match the release checksum.'}
    & $Progress 'Verifying the new package...'
    $payload=Join-Path $scratch 'payload';[IO.Directory]::CreateDirectory($payload)|Out-Null
    $ledger=Expand-LauncherUpdate $zip $payload
    if($ledger.Version-cne$release.Version){throw 'Downloaded package version differs from the release.'}
    $version=Install-LauncherUpdate $Root $payload $Progress
    [pscustomobject]@{Updated=$true;Version=$version;Message=('Updated to '+$version+'. Opening launcher...')}
}
Export-ModuleMember -Function Invoke-LauncherUpdate,Install-LauncherUpdate,Restore-LauncherUpdate,Read-UpdateLedger,Write-UpdateJson
