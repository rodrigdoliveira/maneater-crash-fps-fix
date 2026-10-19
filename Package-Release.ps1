[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not [Environment]::Is64BitProcess -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Package with 64-bit PowerShell on Windows.'}
$root=[IO.Path]::GetFullPath($PSScriptRoot)
Import-Module (Join-Path $root 'scripts\PeExports.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$sourceAllowlist=@((Get-Content -LiteralPath (Join-Path $root 'release-files.json') -Raw | ConvertFrom-Json).SourceFiles)
if (-not $sourceAllowlist.Count -or @($sourceAllowlist | Select-Object -Unique).Count -ne $sourceAllowlist.Count) { throw 'Invalid release source allowlist.' }
foreach ($name in $sourceAllowlist) {
    if ($name -match '(^/|\\|(^|/)\.\.(/|$)|:|(^|/)(\.git|\.local|dist|cache)(/|$))' -or $name -match '\.(dll|exe|pdb|etl|csv|sav|log)$') { throw 'Unsafe release source path.' }
}
$provenanceFiles=@($sourceAllowlist | Where-Object { $_ -match '^(src|vendor)/' })+@('scripts/PeExports.psm1','build.ps1','Manage-Mod.ps1')
$prebuiltArtifacts=@('dxgi.dll','ManeaterAreaHelper.exe','build.json','dxgi_proxy.def')
$artifacts=$prebuiltArtifacts+@('package-files.json')
$dist=Join-Path $root 'dist'
$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if([string]::IsNullOrWhiteSpace($OutputPath)){$OutputPath=Join-Path $dist 'Maneater-Crash-FPS-Fix.zip'}
$output=[IO.Path]::GetFullPath($OutputPath)
$rootPrefix=$root.TrimEnd('\')+'\';$distPrefix=[IO.Path]::GetFullPath($dist).TrimEnd('\')+'\'
if($output.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase) -and -not $output.StartsWith($distPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Write the release outside the source repository or under its ignored dist directory.'}
if([IO.Path]::GetExtension($output) -ine '.zip'){throw 'Release output must have a .zip extension.'}
function Invoke-ReleaseGit {
    param([string[]]$Arguments)
    $result=@(& git -C $root @Arguments 2>&1)
    if($LASTEXITCODE -ne 0){throw ('Git release operation failed: '+($result -join "`n"))}
    return $result
}
function Assert-ReleaseClean {
    if(@(Invoke-ReleaseGit -Arguments @('status','--porcelain=v1','--untracked-files=normal')).Count){throw 'Commit or remove all source changes and nonignored untracked files before packaging.'}
}
function Release-Hash {param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Get-ReleaseImports {
    param([string]$Path)
    # Reuse the validated PE module's bounded RVA/string readers. This inspects
    # file data only; packaging never loads the native DLL.
    $peModule=(Get-Command Get-PeExportTable).Module
    & $peModule {
        param($Path)
        $bytes=[IO.File]::ReadAllBytes($Path);$pe=[long](Read-U32 $bytes 60);$optional=$pe+24
        $count=Read-U16 $bytes ($pe+6);$optionalSize=Read-U16 $bytes ($pe+20)
        $headers=[long](Read-U32 $bytes ($optional+60));$directories=Read-U32 $bytes ($optional+108)
        if($directories -lt 2 -or $optionalSize -lt 128){throw 'Native import directory is missing.'}
        $sections=@()
        for($i=0;$i -lt $count;$i++){
            $at=$optional+$optionalSize+40*$i
            $sections+=[pscustomobject]@{VirtualSize=[long](Read-U32 $bytes ($at+8));VirtualAddress=[long](Read-U32 $bytes ($at+12));RawSize=[long](Read-U32 $bytes ($at+16));RawOffset=[long](Read-U32 $bytes ($at+20))}
        }
        if($directories -ge 14){
            if($optionalSize -lt 224){throw 'Native delay-import directory exceeds optional header.'}
            if((Read-U32 $bytes ($optional+216)) -ne 0 -or (Read-U32 $bytes ($optional+220)) -ne 0){throw 'Native delay imports are not allowed in this release.'}
        }
        $rva=[long](Read-U32 $bytes ($optional+120));$size=[long](Read-U32 $bytes ($optional+124))
        if($rva -eq 0 -or $size -lt 20){throw 'Native import directory is missing.'}
        $imports=@()
        for($i=0;$i -lt 1024;$i++){
            if(20*$i+20 -gt $size){throw 'Native import directory has no bounded terminator.'}
            $offset=Convert-RvaOffset $bytes $sections $headers ($rva+20*$i) 20
            $nonzero=$false
            for($field=0;$field -lt 5;$field++){if((Read-U32 $bytes ($offset+4*$field)) -ne 0){$nonzero=$true}}
            if(-not $nonzero){return $imports}
            $name=Read-PeAscii $bytes $sections $headers (Read-U32 $bytes ($offset+12))
            $imports+=$name.ToLowerInvariant()
        }
        throw 'Native import directory exceeds the release bound.'
    } $Path
}
$stage=$null;$outputTemp=$null
try{
    $top=[IO.Path]::GetFullPath([string](Invoke-ReleaseGit -Arguments @('rev-parse','--show-toplevel')))
    if($top -ine $root){throw 'Package-Release.ps1 must be at the Git repository root.'}
    Assert-ReleaseClean
    $head=[string](Invoke-ReleaseGit -Arguments @('rev-parse','--verify','HEAD'))
    $tree=[string](Invoke-ReleaseGit -Arguments @('rev-parse','HEAD^{tree}'))
    $sources=@(Invoke-ReleaseGit -Arguments @('ls-tree','-r','--name-only','HEAD'))
    foreach($path in $sources){if($path -cnotin $sourceAllowlist){throw ('Tracked path is outside the release source allowlist: '+$path)}}
    foreach($path in $sourceAllowlist){if($path -cnotin $sources){throw ('Required release source is absent from HEAD: '+$path)}}
    foreach($name in $prebuiltArtifacts){if(-not [IO.File]::Exists((Join-Path $dist $name))){throw ('Prebuilt artifact is missing: dist/'+$name+'. Build before packaging.')}}
    [IO.Directory]::CreateDirectory($dist)|Out-Null
    # A short OS temporary path avoids MAX_PATH failures when the checkout is
    # already deeply nested; the isolated stage is never part of the ZIP.
    $stage=Join-Path $tempPrefix ('maneater-release-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage)|Out-Null
    $archive=Join-Path $stage 'source.zip'
    $gitArguments=@('archive','--format=zip','--prefix=Maneater-Crash-FPS-Fix/',"--output=$archive",$head,'--')+$sources
    Invoke-ReleaseGit $gitArguments|Out-Null
    $extract=Join-Path $stage 'contents'
    [IO.Compression.ZipFile]::ExtractToDirectory($archive,$extract)
    $payload=Join-Path $extract 'Maneater-Crash-FPS-Fix'
    $payloadDist=Join-Path $payload 'dist';[IO.Directory]::CreateDirectory($payloadDist)|Out-Null
    foreach($name in $prebuiltArtifacts){[IO.File]::WriteAllBytes((Join-Path $payloadDist $name),[IO.File]::ReadAllBytes((Join-Path $dist $name)))}
    $manifest=Get-Content -LiteralPath (Join-Path $payloadDist 'build.json') -Raw|ConvertFrom-Json
    if($manifest.SchemaVersion -ne 1 -or $manifest.Version -cne '0.9.2' -or $manifest.TargetFPS -ne 120 -or
        $manifest.GameSHA256 -cne 'CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0'){throw 'Prebuilt manifest does not describe the v0.9.2 build.'}
    if ($manifest.HelperSHA256 -cnotmatch '^[0-9A-F]{64}$' -or (Release-Hash (Join-Path $payloadDist 'ManeaterAreaHelper.exe')) -cne $manifest.HelperSHA256) { throw 'Companion helper hash differs from manifest.' }
    $helperHeader=[IO.File]::ReadAllText((Join-Path $payload 'src/nav_helper_hash.h'))
    $helperBytes=([regex]::Matches($helperHeader,'0x([0-9a-fA-F]{2})') | ForEach-Object { $_.Groups[1].Value }) -join ''
    if ($helperBytes -ine $manifest.HelperSHA256) { throw 'Native source embeds a different companion helper hash.' }
    if(@($manifest.SourceHashes.PSObject.Properties).Count -ne $provenanceFiles.Count){throw 'Unexpected build source provenance set.'}
    foreach($relative in $provenanceFiles){
        $property=$manifest.SourceHashes.PSObject.Properties[$relative]
        if($null -eq $property -or $property.Value -notmatch '^[0-9A-F]{64}$' -or
            (Release-Hash (Join-Path $payload $relative)) -cne $property.Value -or
            (Release-Hash (Join-Path $root $relative)) -cne $property.Value){throw ('Build source provenance differs from clean HEAD: '+$relative)}
    }
    if((Release-Hash (Join-Path $payloadDist 'dxgi_proxy.def')) -cne $manifest.DefinitionSHA256){throw 'Prebuilt forwarder definition hash differs from manifest.'}
    $proxy=Get-PeExportTable (Join-Path $payloadDist 'dxgi.dll')
    if($proxy.FileSHA256 -cne $manifest.ModSHA256 -or $proxy.Exports.Count -lt 2 -or
        $proxy.ContractSHA256 -cne $manifest.ModExportsSHA256 -or
        @($manifest.SystemExports).Count -ne $proxy.Exports.Count -or
        (Get-ExportContractHash $manifest.SystemExports) -cne $manifest.SystemExportsSHA256){throw 'Native hash/export provenance differs from manifest.'}
    $manifestContract=[pscustomobject]@{ContractSHA256=$manifest.SystemExportsSHA256;Exports=$manifest.SystemExports}
    Assert-DxgiForwarderTable -Proxy $proxy -System $manifestContract
    $system=Get-VerifiedWindowsDxgi
    if($null-ne$manifest.PSObject.Properties['ForwardingMode']){
        if($manifest.ForwardingMode-cne'LocalExportTableV1'){throw 'Unknown portable graphics format.'}
        $null=New-DxgiForwarderImage -TemplatePath (Join-Path $payloadDist 'dxgi.dll') -System $system.Table
    }else{Assert-DxgiForwarderTable -Proxy $proxy -System $system.Table}
    $imports=@(Get-ReleaseImports (Join-Path $payloadDist 'dxgi.dll'))
    $helperImports=@(Get-ReleaseImports (Join-Path $payloadDist 'ManeaterAreaHelper.exe'))
    $allowedImports=@('kernel32.dll','bcrypt.dll','api-ms-win-crt-runtime-l1-1-0.dll','api-ms-win-crt-stdio-l1-1-0.dll','api-ms-win-crt-heap-l1-1-0.dll','api-ms-win-crt-string-l1-1-0.dll','api-ms-win-crt-math-l1-1-0.dll','api-ms-win-crt-convert-l1-1-0.dll','api-ms-win-crt-locale-l1-1-0.dll','api-ms-win-crt-private-l1-1-0.dll','api-ms-win-crt-environment-l1-1-0.dll')
    foreach ($set in @(@{Names=$imports},@{Names=$helperImports})) {
        if('kernel32.dll' -notin $set.Names -or @($set.Names|Select-Object -Unique).Count -ne $set.Names.Count){throw 'Native dependency set is missing Kernel32 or has duplicates.'}
        foreach($name in $set.Names){if($name -cnotin $allowedImports){throw ('Unexpected native dependency: '+$name)}}
    }
    # Git's text normalization is appropriate for source. The batch entrypoint
    # needs CRLF in the ready package, without changing the committed source.
    $start=Join-Path $payload 'Start.cmd';$startBytes=[IO.File]::ReadAllBytes($start)
    foreach($value in $startBytes){if($value -gt 127){throw 'Start.cmd must be an ASCII batch entrypoint.'}}
    $startText=[Text.Encoding]::ASCII.GetString($startBytes).Replace("`r`n","`n").Replace("`r","`n").Replace("`n","`r`n")
    [IO.File]::WriteAllBytes($start,[Text.Encoding]::ASCII.GetBytes($startText))
    $inventory=[ordered]@{}
    foreach($relative in @($sources)+@($prebuiltArtifacts|ForEach-Object {'dist/'+$_})){$inventory[$relative]=Release-Hash (Join-Path $payload $relative)}
    $ledger=[ordered]@{SchemaVersion=1;BootstrapProtocol=1;Repository='rodrigdoliveira/maneater-crash-fps-fix';Version=$manifest.Version;Files=$inventory}
    [IO.File]::WriteAllText((Join-Path $payloadDist 'package-files.json'),($ledger|ConvertTo-Json -Depth 5)+"`n",[Text.UTF8Encoding]::new($false))
    Assert-ReleaseClean
    if([string](Invoke-ReleaseGit -Arguments @('rev-parse','HEAD')) -cne $head){throw 'Git HEAD changed during packaging.'}
    $readyZip=Join-Path $stage 'ready.zip'
    $relativeFiles=@($sources)+@($artifacts|ForEach-Object {'dist/'+$_})
    $zipStream=[IO.File]::Open($readyZip,'CreateNew','ReadWrite','None')
    $writer=New-Object IO.Compression.ZipArchive($zipStream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try{
        foreach($relative in $relativeFiles){
            # .NET Framework's CreateFromDirectory emits backslashes on
            # Windows; explicit entry names keep portable ZIP separators.
            $entry=$writer.CreateEntry('Maneater-Crash-FPS-Fix/'+$relative,[IO.Compression.CompressionLevel]::Optimal)
            $input=[IO.File]::OpenRead((Join-Path $payload $relative));$destination=$entry.Open()
            try{$input.CopyTo($destination)}finally{$destination.Dispose();$input.Dispose()}
        }
    }finally{$writer.Dispose();$zipStream.Dispose()}
    $zip=[IO.Compression.ZipFile]::OpenRead($readyZip)
    try{
        $actual=@($zip.Entries|Where-Object {-not $_.FullName.EndsWith('/') }|ForEach-Object {$_.FullName})
        $expected=@($sources|ForEach-Object {'Maneater-Crash-FPS-Fix/'+$_})+@($artifacts|ForEach-Object {'Maneater-Crash-FPS-Fix/dist/'+$_})
        if($actual.Count -ne $expected.Count -or @($actual|Select-Object -Unique).Count -ne $actual.Count){throw 'Release ZIP file count or uniqueness differs from allowlist.'}
        foreach($name in $actual){if($name -cnotin $expected){throw ('Unexpected release ZIP entry: '+$name)}}
    }finally{$zip.Dispose()}
    $outputParent=[IO.Path]::GetDirectoryName($output);[IO.Directory]::CreateDirectory($outputParent)|Out-Null
    $outputTemp=Join-Path $outputParent ([Guid]::NewGuid().ToString('N')+'.tmp')
    [IO.File]::Copy($readyZip,$outputTemp,$false)
    $zipHash=Release-Hash $readyZip
    if((Release-Hash $outputTemp) -cne $zipHash){throw 'Release ZIP copy verification failed.'}
    if([IO.File]::Exists($output)){[IO.File]::Replace($outputTemp,$output,[NullString]::Value)}else{[IO.File]::Move($outputTemp,$output)}
    [pscustomobject]@{Version='0.9.2';ZipPath=$output;SHA256=$zipHash;SourceCommit=$head;SourceTree=$tree;SourceFileCount=$sources.Count;NativeArtifactCount=$artifacts.Count;NativeExports=$proxy.Exports.Count;NativeImports=$imports;HelperImports=$helperImports}
}finally{
    if($null -ne $outputTemp -and [IO.File]::Exists($outputTemp)){[IO.File]::Delete($outputTemp)}
    if($null -ne $stage -and [IO.Directory]::Exists($stage)){
        $safeStage=[IO.Path]::GetFullPath($stage)
        if(-not $safeStage.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($safeStage) -notmatch '^maneater-release-[0-9a-f]{32}$'){throw 'Unsafe release staging cleanup target.'}
        Remove-Item -LiteralPath $safeStage -Recurse -Force
    }
}
