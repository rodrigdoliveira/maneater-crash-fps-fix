[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ZigPath)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$compiler=(Resolve-Path -LiteralPath $ZigPath).ProviderPath
Import-Module (Join-Path $root 'scripts/PeExports.psm1') -Force
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('me-dxgi-portable-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch)|Out-Null
$script:checks=0
function Check([bool]$Value,[string]$Label){if(-not$Value){throw ('FAIL: '+$Label)};$script:checks++}
function Refuse([scriptblock]$Action,[string]$Label){$threw=$false;try{& $Action|Out-Null}catch{$threw=$true};Check $threw $Label}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Compile([string[]]$Arguments){& $compiler cc -target x86_64-windows-gnu -O2 -Wall -Wextra -Werror @Arguments;if($LASTEXITCODE-ne0){throw 'Portable fixture compilation failed.'}}
function Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
try{
    $source=Join-Path $PSScriptRoot 'dxgi_portable_fixture.c'
    $template=Join-Path $scratch 'template.dll';$definition=Join-Path $scratch 'template.def'
    [IO.File]::WriteAllText($definition,"LIBRARY fixture`nEXPORTS`n Placeholder=dxgi_codex_system.Placeholder @1`n")
    Compile @('-DFIXTURE_PROXY','-shared',$source,$definition,'-o',$template)
    $templateBytes=[IO.File]::ReadAllBytes($template);$templateHash=Hash $template
    $table=Get-PeExportTable $template
    $slot=@($table.Sections|Where-Object Name -eq '.dxgifwd')[0]
    Check ($slot.VirtualSize-eq65536) 'actual compiled template retains reserved read-only section'
    $caseCount=0
    foreach($case in @(
        @{Name='older';A=3;B=7;C=20;Third=$false;Alias=$false},
        @{Name='newer';A=15;B=2;C=27;Third=$true;Alias=$false},
        @{Name='additional-alias';A=42;B=9;C=55;Third=$true;Alias=$true}
    )){
        $dir=Join-Path $scratch $case.Name;[IO.Directory]::CreateDirectory($dir)|Out-Null
        $backend=Join-Path $dir 'dxgi_codex_system.dll';$def=Join-Path $dir 'backend.def'
        $third=$(if($case.Third){'CreateDXGIFactory2=Third @'+$case.C}else{'HiddenThird=Third @'+$case.C+' NONAME'})
        [IO.File]::WriteAllText($def,("LIBRARY dxgi_codex_system`nEXPORTS`n CreateDXGIFactory=First @"+$case.A+"`n CreateDXGIFactory1=Second @"+$case.B+"`n "+$third+"`n"))
        Compile @('-DFIXTURE_BACKEND','-shared',$source,$def,'-o',$backend)
        $system=Get-PeExportTable $backend
        if($case.Alias){$system.Exports+= [pscustomobject]@{Name='AliasFactory';Ordinal=$case.B;Forwarder=$null};$system.ContractSHA256=Get-ExportContractHash $system.Exports}
        $image=New-DxgiForwarderImage -TemplatePath $template -System $system
        $path=Join-Path $dir 'fixture_proxy.dll';[IO.File]::WriteAllBytes($path,$image.Bytes)
        $proxy=Get-PeExportTable $path
        Assert-DxgiForwarderTable -Proxy $proxy -System $system -Portable
        Check ($proxy.ContractSHA256-ceq$system.ContractSHA256-and$proxy.Exports.Count-eq$system.Exports.Count) ($case.Name+' preserves the local export surface')
        Check ($image.FileSHA256-ceq(Hash $path)-and$proxy.FileSHA256-ceq$image.FileSHA256) 'personalized image hash describes exact installed bytes'
        $repeat=New-DxgiForwarderImage -TemplatePath $template -System $system
        Check ($repeat.FileSHA256-ceq$image.FileSHA256) 'personalization is deterministic'
        $restored=[byte[]]$image.Bytes.Clone()
        [Array]::Copy($templateBytes,$slot.RawOffset,$restored,$slot.RawOffset,65536)
        foreach($range in @(@($table.ExportDirectoryFieldOffset,8),@($table.ChecksumOffset,4))){[Array]::Copy($templateBytes,[int]$range[0],$restored,[int]$range[0],[int]$range[1])}
        $sha=[Security.Cryptography.SHA256]::Create();try{$restoredHash=[BitConverter]::ToString($sha.ComputeHash($restored)).Replace('-','')}finally{$sha.Dispose()}
        Check ($restoredHash-ceq$templateHash) 'code, imports, resources, relocations and unwind bytes are unchanged'
        $exe=Join-Path $dir 'probe.exe';Compile @($source,'-municode','-o',$exe)
        & $exe $path $case.A $case.B $case.C ([int]$case.Third) ([int]$case.Alias)
        Check ($LASTEXITCODE-eq0) ($case.Name+' loads through real Windows forwarding by name and ordinal')
        Refuse {New-DxgiForwarderImage -TemplatePath $path -System $system} 'already-personalized templates are refused'
        $caseCount++
    }
    $local=Get-VerifiedWindowsDxgi
    $actual=New-DxgiForwarderImage -TemplatePath $template -System $local.Table
    Assert-DxgiForwarderTable -Proxy $actual.Table -System $local.Table -Portable
    Check ($actual.Table.ContractSHA256-ceq$local.Table.ContractSHA256) 'actual local Microsoft graphics table personalizes correctly'
    foreach($bad in @(@(),@([pscustomobject]@{Name='Bad.Name';Ordinal=1}),@([pscustomobject]@{Name='A';Ordinal=0}),@([pscustomobject]@{Name='A';Ordinal=1},[pscustomobject]@{Name='B';Ordinal=5000}))){
        Refuse {New-DxgiForwarderImage -TemplatePath $template -System ([pscustomobject]@{Exports=$bad})} 'invalid or excessive export layouts fail before installation'
    }
    foreach($change in @('marker','capacity','writable','dirty')){
        $bad=[byte[]]$templateBytes.Clone();$offset=[int]$slot.RawOffset
        switch($change){
            'marker'{$bad[$offset]=0}
            'dirty'{$bad[$offset+65535]=1}
            default{
                $pe=[BitConverter]::ToInt32($bad,60);$sections=$pe+24+[BitConverter]::ToUInt16($bad,$pe+20)
                for($i=0;$i-lt[BitConverter]::ToUInt16($bad,$pe+6);$i++){
                    $s=$sections+40*$i
                    if([Text.Encoding]::ASCII.GetString($bad,$s,8)-ceq'.dxgifwd'){
                        if($change-eq'capacity'){[Array]::Copy([BitConverter]::GetBytes([uint32]65535),0,$bad,$s+8,4)}
                        else{[Array]::Copy([BitConverter]::GetBytes([uint32]3221225536),0,$bad,$s+36,4)}
                    }
                }
            }
        }
        $path=Join-Path $scratch ('bad-'+$change+'.dll');[IO.File]::WriteAllBytes($path,$bad)
        Refuse {New-DxgiForwarderImage -TemplatePath $path -System $local.Table} ($change+' template is refused')
    }
    Check ((Hash $template)-ceq$templateHash) 'template remains untouched across all cases'
    # Exercise the production installer against a disposable game tree. Only
    # the expected executable hash/process check are substituted in this copy;
    # real Microsoft-signature, PE parsing, preparation and ownership run.
    $fixture=Join-Path $scratch 'installer';$bin=Join-Path $fixture 'game/Maneater/Binaries/Win64'
    foreach($d in @($bin,(Join-Path $fixture 'src'),(Join-Path $fixture 'scripts'),(Join-Path $fixture 'dist'))){[IO.Directory]::CreateDirectory($d)|Out-Null}
    $game=Join-Path $bin 'Maneater-Win64-Shipping.exe'
    $gameBytes=New-Object byte[] 1024
    foreach($p in @(@(0,0x5a4d),@(0x84,0x8664),@(0x86,1),@(0x94,240),@(0x96,0x22),@(0x98,0x20b))){[Array]::Copy([BitConverter]::GetBytes([uint16]$p[1]),0,$gameBytes,[int]$p[0],2)}
    foreach($p in @(@(60,0x80),@(0x80,0x4550),@(0xa8,0x1000),@(0xd0,0x2000),@(0xd4,0x200))){[Array]::Copy([BitConverter]::GetBytes([uint32]$p[1]),0,$gameBytes,[int]$p[0],4)}
    [IO.File]::WriteAllBytes($game,$gameBytes);$gameHash=Hash $game
    [IO.File]::Copy((Join-Path $root 'scripts/PeExports.psm1'),(Join-Path $fixture 'scripts/PeExports.psm1'))
    [IO.File]::Copy($source,(Join-Path $fixture 'src/maneater_fps_hook.c'))
    [IO.File]::WriteAllText((Join-Path $fixture 'build.ps1'),"throw 'Fixture must never compile during installation.'")
    [IO.File]::Copy($template,(Join-Path $fixture 'dist/dxgi.dll'))
    [IO.File]::Copy($definition,(Join-Path $fixture 'dist/dxgi_proxy.def'))
    [IO.File]::Copy((Join-Path $scratch 'older/probe.exe'),(Join-Path $fixture 'dist/ManeaterAreaHelper.exe'))
    $manager=Join-Path $fixture 'Manage-Mod.ps1';$managerText=[IO.File]::ReadAllText((Join-Path $root 'Manage-Mod.ps1')).Replace('CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0',$gameHash)
    $managerText=$managerText.Replace("if (@(Get-Process -Name 'Maneater', 'Maneater-Win64-Shipping' -ErrorAction SilentlyContinue).Count -ne 0)", 'if ($false)')
    [IO.File]::WriteAllText($manager,$managerText)
    $hashes=[ordered]@{};foreach($p in @('src/maneater_fps_hook.c','scripts/PeExports.psm1','build.ps1','Manage-Mod.ps1')){$hashes[$p]=Hash (Join-Path $fixture $p)}
    $manifest=[ordered]@{SchemaVersion=1;Version='0.9.1';GameSHA256=$gameHash;TargetFPS=120;ForwardingMode='LocalExportTableV1';ModSHA256=$templateHash;HelperSHA256=(Hash (Join-Path $fixture 'dist/ManeaterAreaHelper.exe'));DefinitionSHA256=(Hash (Join-Path $fixture 'dist/dxgi_proxy.def'));SourceHashes=$hashes;ModExportsSHA256=$table.ContractSHA256;SystemExportsSHA256=$table.ContractSHA256;SystemExports=@($table.Exports|Select-Object Name,Ordinal)}
    Json (Join-Path $fixture 'dist/build.json') $manifest
    Refuse {& $manager -Action Install -GameDirectory $bin -ExpectedModSHA256 ('0'*64)} 'mismatched preflight wrapper hash stops publication'
    Refuse {& $manager -Action Install -GameDirectory $bin -ExpectedSystemSHA256 ('0'*64)} 'changed preflight Windows hash stops publication'
    Check (-not[IO.File]::Exists((Join-Path $bin 'dxgi.dll'))-and-not[IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll'))) 'preflight mismatch leaves fake game untouched'
    & $manager -Action Install -GameDirectory $bin -ExpectedModSHA256 $actual.FileSHA256 -ExpectedSystemSHA256 $local.Table.FileSHA256|Out-Null
    $record=Get-Content (Join-Path $fixture '.local/installation.json') -Raw|ConvertFrom-Json
    $installed=Get-PeExportTable (Join-Path $bin 'dxgi.dll')
    Assert-DxgiForwarderTable -Proxy $installed -System $local.Table -Portable
    Check ($record.ModSHA256-ceq$actual.FileSHA256-and$record.ModSHA256-cne$templateHash-and$record.SystemSHA256-ceq$local.Table.FileSHA256) 'real installer records personalized and current Windows hashes'
    Check ((Hash (Join-Path $fixture 'dist/dxgi.dll'))-ceq$templateHash) 'installation does not modify the packaged template'
    & $manager -Action Uninstall|Out-Null
    Check (-not[IO.File]::Exists((Join-Path $bin 'dxgi.dll'))-and-not[IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll'))-and-not[IO.File]::Exists((Join-Path $bin 'ManeaterAreaHelper.exe'))) 'real manager restores the fake game by removing only its personalized files'
    [pscustomobject]@{Passed=$true;Checks=$script:checks;LoaderLayouts=$caseCount;GameExecuted=$false;ProductionModLoaded=$false;Compiler=((& $compiler version)|Out-String).Trim()}|ConvertTo-Json|Set-Content (Join-Path $PSScriptRoot 'dxgi-portable-results.json') -Encoding utf8
    Write-Output ('PASS: '+$script:checks+' portable graphics contracts and '+$caseCount+' native loader layouts; no game or production mod loaded.')
}finally{
    $full=[IO.Path]::GetFullPath($scratch);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not$full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($full)-cnotmatch'^me-dxgi-portable-[0-9a-f]{32}$'){throw 'Unsafe portable-fixture cleanup.'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
