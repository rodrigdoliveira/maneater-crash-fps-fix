Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:SupportedGameHash = 'CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0'
$script:LegacyModHash = '5C9EF79C6F5EBC99DB15E62E883F5635FF4133442BFDE6891D98A38A1B9129E6'
$script:PublicV02ModHash = '3D6BE39D601175AD5DC435A68EFB6036C107C0646C94A99300567F82387B660E'
$script:PublicV07ModHash = 'BF59359AC0DA0823B563F501E18BBF407E6359C07B1E1524F8886D894112103D'
$script:PublicV07HelperHash = '898C59D575AFF5DD9F6CDB0F46A2DEB5F1700DF80A5DDFE2A86AE1C71B1DCB7A'
$script:PrivateLoadingModHash = '03FAD0061DD00A332E2C93CA10FE3ECF2379ADAFBEBE7A59A2FFDE384A11E744'
$script:PrivateLoadingHelperHash = 'B1399B39E4CA9E7E1C48F761AFA42FB0649A239F7EC55F6706655FC76FDC21B4'
$script:PreviewV07ModHash = '85B190F0AD305F9FD0D9C9A676D61B4179FB736F32D6ED3C4BC9E468F80208BF'
$script:PreviewV07HelperHash = '898C59D575AFF5DD9F6CDB0F46A2DEB5F1700DF80A5DDFE2A86AE1C71B1DCB7A'
foreach ($name in @('PeExports', 'CpuPlan', 'SteamFix', 'AnselFix')) { Import-Module (Join-Path $PSScriptRoot ($name + '.psm1')) -Force -DisableNameChecking }
function Get-RepairHash { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Write-RepairJson {
    param([string]$Path, $Value)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = Join-Path $parent ([Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 30) + "`n", [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) } else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Get-RepairStatePath { Join-Path $script:Root '.local\repair.json' }
function Assert-RepairProcessesClosed {
    if (@(Get-Process -Name 'Maneater','Maneater-Win64-Shipping' -ErrorAction SilentlyContinue).Count) { throw 'Quit Maneater before applying or restoring fixes.' }
    if (@(Get-Process -Name 'steam','steamwebhelper' -ErrorAction SilentlyContinue).Count) { throw 'Steam is still running. Exit Steam and retry.' }
}
function Resolve-ManeaterExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GameExecutable)
    $selected = (Resolve-Path -LiteralPath $GameExecutable).ProviderPath
    if($selected -match '["%\r\n]'){throw 'The game path contains characters unsupported by Steam command quoting. Use a Steam library path without percent signs.'}
    if (-not [IO.File]::Exists($selected)) { throw 'Choose the Maneater executable.' }
    switch ([IO.Path]::GetFileName($selected).ToLowerInvariant()) {
        'maneater.exe' { $gameRoot = [IO.Path]::GetDirectoryName($selected); $bin = Join-Path $gameRoot 'Maneater\Binaries\Win64' }
        'maneater-win64-shipping.exe' {
            $bin = [IO.Path]::GetDirectoryName($selected)
            if ($bin -notmatch '\\Maneater\\Binaries\\Win64$') { throw 'Shipping executable must be inside Maneater\Binaries\Win64.' }
            $gameRoot = [IO.Path]::GetFullPath((Join-Path $bin '..\..\..'))
        }
        default { throw 'Choose Maneater.exe or Maneater-Win64-Shipping.exe.' }
    }
    $exe = Join-Path $bin 'Maneater-Win64-Shipping.exe'
    if (-not [IO.File]::Exists($exe)) { throw 'Maneater shipping executable was not found.' }
    $hash=Get-RepairHash $exe; $tested=$hash -ceq $script:SupportedGameHash
    if(-not $tested){ Assert-ManeaterPeImage -Path $exe }
    [pscustomobject]@{ GameRoot = $gameRoot; Bin = [IO.Path]::GetFullPath($bin); Executable = $exe; GameSHA256 = $hash; TestedBuild=$tested }
}
function Assert-ManeaterPeImage {
    param([string]$Path)
    $stream=[IO.File]::Open($Path,'Open','Read','Read')
    try {
        $reader=New-Object IO.BinaryReader($stream)
        if($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d){throw 'Selected file is not a Windows x64 Maneater executable.'}
        $stream.Position=60; $offset=$reader.ReadInt32()
        if($offset -lt 64 -or $offset -gt 1048576 -or $offset+264 -gt $stream.Length){throw 'Invalid executable PE header.'}
        $stream.Position=$offset
        if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664){throw 'Only Windows x64 executables can be tried.'}
        $sections=$reader.ReadUInt16();$stream.Position=$offset+20;$optionalSize=$reader.ReadUInt16();$flags=$reader.ReadUInt16()
        if($sections -lt 1 -or $sections -gt 96 -or $optionalSize -lt 240 -or $offset+24+$optionalSize -gt $stream.Length -or ($flags-band 2)-eq 0 -or ($flags-band 0x2000)-ne 0 -or $reader.ReadUInt16()-ne 0x20b){throw 'Unsupported executable architecture or malformed PE header.'}
        $stream.Position=$offset+24+16;$entry=$reader.ReadUInt32();$stream.Position=$offset+24+56;$imageSize=$reader.ReadUInt32()
        if($entry-eq 0 -or $imageSize-eq 0 -or $entry-ge $imageSize){throw 'Malformed executable image bounds.'}
    } finally { $stream.Dispose() }
}
function Test-RepairGameTested {
    param($Game)
    if($null -ne $Game.PSObject.Properties['TestedBuild']){return [bool]$Game.TestedBuild}
    return $Game.GameSHA256 -ceq $script:SupportedGameHash
}
function Test-RepairAnselSkipped {
    param($Plan)
    return $null -ne $Plan.PSObject.Properties['AnselDisposition'] -and $Plan.AnselDisposition -eq 'SkippedUnknownSDK'
}
function Test-BundleUpdateAvailable($Journal){
    if(-not(Get-RepairBuildReady)){return $false}
    $build=Get-Content -LiteralPath (Join-Path $script:Root 'dist/build.json') -Raw|ConvertFrom-Json
    return $null-eq$Journal.PSObject.Properties['PackageVersion']-or$Journal.PackageVersion-cne$build.Version-or
        $Journal.Plan.Native.InstalledHash-cne$build.ModSHA256-or$Journal.Plan.Native.InstalledHelperHash-cne$build.HelperSHA256
}
function Get-RepairBuildReady {
    try {
        $manifest = Get-Content -LiteralPath (Join-Path $script:Root 'dist\build.json') -Raw | ConvertFrom-Json
        if ($manifest.SchemaVersion -ne 1 -or $manifest.Version -cne '0.8.0' -or $manifest.GameSHA256 -cne $script:SupportedGameHash -or $manifest.TargetFPS -ne 120 -or $manifest.HelperSHA256 -cnotmatch '^[0-9A-F]{64}$') { return $false }
        $sources = [Collections.Generic.List[string]]::new()
        foreach ($folder in @('src','vendor')) {
            $directory = Join-Path $script:Root $folder
            if ([IO.Directory]::Exists($directory)) {
                foreach ($file in Get-ChildItem -LiteralPath $directory -File -Recurse | Sort-Object FullName) { $sources.Add($file.FullName.Substring($script:Root.Length+1).Replace('\','/')) }
            }
        }
        foreach ($name in @('scripts/PeExports.psm1','build.ps1','Manage-Mod.ps1')) { $sources.Add($name) }
        if ('src/maneater_fps_hook.c' -cnotin $sources -or @($manifest.SourceHashes.PSObject.Properties).Count -ne $sources.Count) { return $false }
        foreach ($relative in $sources) {
            $property = $manifest.SourceHashes.PSObject.Properties[$relative]
            if ($null -eq $property -or $property.Value -cnotmatch '^[0-9A-F]{64}$' -or (Get-RepairHash (Join-Path $script:Root $relative)) -cne $property.Value) { return $false }
        }
        if ((Get-RepairHash (Join-Path $script:Root 'dist\dxgi.dll')) -cne $manifest.ModSHA256 -or
            (Get-RepairHash (Join-Path $script:Root 'dist\dxgi_proxy.def')) -cne $manifest.DefinitionSHA256 -or
            (Get-RepairHash (Join-Path $script:Root 'dist\ManeaterAreaHelper.exe')) -cne $manifest.HelperSHA256) { return $false }
        $system = Get-VerifiedWindowsDxgi
        if ($system.Table.ContractSHA256 -cne $manifest.SystemExportsSHA256 -or
            (Get-ExportContractHash -Exports @($manifest.SystemExports)) -cne $manifest.SystemExportsSHA256) { return $false }
        $proxy = Get-PeExportTable (Join-Path $script:Root 'dist\dxgi.dll')
        if ($proxy.FileSHA256 -cne $manifest.ModSHA256 -or $proxy.ContractSHA256 -cne $manifest.ModExportsSHA256) { return $false }
        Assert-DxgiForwarderTable -Proxy $proxy -System $system.Table
        return ($system.Table.ContractSHA256 -ceq $manifest.SystemExportsSHA256)
    } catch { return $false }
}
function Get-NativeRepairPlan {
    param($Game)
    $mod = Join-Path $Game.Bin 'dxgi.dll'; $systemCopy = Join-Path $Game.Bin 'dxgi_codex_system.dll'; $helper = Join-Path $Game.Bin 'ManeaterAreaHelper.exe'
    $modPresent = [IO.File]::Exists($mod); $systemPresent = [IO.File]::Exists($systemCopy); $helperPresent = [IO.File]::Exists($helper)
    $action = 'Install'; $oldModHash = $null; $oldSystemHash = $null; $oldHelperHash = $null; $originalNativeRecord = $null
    $nativeState = Join-Path $script:Root '.local\installation.json'
    if ([IO.File]::Exists($nativeState)) {
        $existingRecord = Get-Content -LiteralPath $nativeState -Raw | ConvertFrom-Json
        if ($existingRecord.Status -eq 'installed' -and $existingRecord.GameDirectory -ine $Game.Bin) { throw 'This launcher already tracks a different native installation. Restore it first.' }
    }
    if ($modPresent -or $systemPresent -or $helperPresent) {
        if (-not ($modPresent -and $systemPresent)) { throw 'An existing DXGI mod is incomplete or foreign. Its files were preserved.' }
        $oldModHash = Get-RepairHash $mod; $oldSystemHash = Get-RepairHash $systemCopy
        if ($helperPresent) { $oldHelperHash = Get-RepairHash $helper }
        if ([IO.File]::Exists($nativeState)) {
            $record = Get-Content -LiteralPath $nativeState -Raw | ConvertFrom-Json
            $recordHelper = $(if ($record.SchemaVersion -eq 3) { $record.HelperSHA256 } else { $null })
            if ($record.SchemaVersion -in @(1,2,3) -and $record.Status -eq 'installed' -and $record.GameDirectory -ieq $Game.Bin -and $record.ModSHA256 -ceq $oldModHash -and $record.SystemSHA256 -ceq $oldSystemHash -and $recordHelper -ceq $oldHelperHash) {
                $originalNativeRecord = $record
                $action = 'ReplaceRecognized'
                if (Get-RepairBuildReady) {
                    $build = Get-Content -LiteralPath (Join-Path $script:Root 'dist\build.json') -Raw | ConvertFrom-Json
                    $system = Get-VerifiedWindowsDxgi
                    $recordGameMatches = $null -ne $record.PSObject.Properties['GameSHA256'] -and $record.GameSHA256 -ceq $Game.GameSHA256
                    if ($record.SchemaVersion -in @(2,3)) {
                        $recordGameMatches = $recordGameMatches -and $record.TestedBuild -eq (Test-RepairGameTested $Game) -and
                            $record.UntestedBuildOptIn -eq (-not (Test-RepairGameTested $Game))
                    }
                    if ($oldModHash -ceq $build.ModSHA256 -and $oldSystemHash -ceq $system.Table.FileSHA256 -and $oldHelperHash -ceq $build.HelperSHA256 -and $recordGameMatches) { $action = 'None' }
                }
            } else { throw 'Native installation record does not match the files. Restore or repair that installation first.' }
        } else {
            $known = (-not $helperPresent) -and ($oldModHash -ceq $script:LegacyModHash -or $oldModHash -ceq $script:PublicV02ModHash)
            $known = $known -or ($oldModHash -ceq $script:PublicV07ModHash -and $oldHelperHash -ceq $script:PublicV07HelperHash)
            $known = $known -or ((Test-RepairGameTested $Game) -and $oldModHash -ceq $script:PrivateLoadingModHash -and $oldHelperHash -ceq $script:PrivateLoadingHelperHash)
            $known = $known -or ((Test-RepairGameTested $Game) -and $oldModHash -ceq $script:PreviewV07ModHash -and $oldHelperHash -ceq $script:PreviewV07HelperHash)
            if (Get-RepairBuildReady) {
                $build = Get-Content -LiteralPath (Join-Path $script:Root 'dist\build.json') -Raw | ConvertFrom-Json
                $knownCurrent = $oldModHash -ceq $build.ModSHA256 -and $oldHelperHash -ceq $build.HelperSHA256
                if ($oldModHash -ceq $script:PrivateLoadingModHash -and $oldHelperHash -ceq $script:PrivateLoadingHelperHash -and -not (Test-RepairGameTested $Game)) { $knownCurrent = $false }
                $known = $known -or $knownCurrent
            }
            $signature = Get-AuthenticodeSignature -LiteralPath $systemCopy
            if (-not $known -or $signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
                throw 'Another DXGI mod is installed. Existing files were preserved; remove that mod using its own uninstaller first.'
            }
            Assert-DxgiForwarderTable -Proxy (Get-PeExportTable $mod) -System (Get-PeExportTable $systemCopy)
            $action = 'ReplaceRecognized'
        }
    }
    [pscustomobject]@{ Action = $action; ModPath = $mod; SystemPath = $systemCopy; HelperPath = $helper; OriginalModHash = $oldModHash; OriginalSystemHash = $oldSystemHash; OriginalHelperHash = $oldHelperHash; OriginalNativeRecord = $originalNativeRecord; BackupMod = $null; BackupSystem = $null; BackupHelper = $null; InstalledHash = $null; InstalledSystemHash = $null; InstalledHelperHash = $null }
}
function Get-ManeaterRepairPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GameExecutable, $SteamContext)
    $game = Resolve-ManeaterExecutable $GameExecutable
    $steam = $(if ($null -ne $SteamContext) { Get-SteamFixContext -Context $SteamContext } else { Get-SteamFixContext })
    Assert-SteamManeaterInstallation -Context $steam -GameRoot $game.GameRoot | Out-Null
    $steamStatus = Get-SteamFixStatus -ConfigPath $steam.ConfigPath
    $cpu = Get-ManeaterCpuPlan
    $launch = New-ManeaterLaunchOptions -ExistingOptions $steamStatus.ExistingLaunchOptions -CpuPlan $cpu -AllowUntestedBuild:(-not $game.TestedBuild)
    $steamPlan = New-SteamFixPlan -ConfigPath $steam.ConfigPath -LaunchOptions $launch
    $ansel = Get-ManeaterAnselStatus -GameRoot $game.GameRoot
    $anselDisposition='ApplyKnownSDK'
    if(-not $game.TestedBuild -and $ansel.Status -in @('UnrecognizedOriginal','UnrecognizedDisabled')){$anselDisposition='SkippedUnknownSDK'}
    elseif ($ansel.Action -eq 'Refuse') { throw ('Ansel files need review before automatic repair: ' + $ansel.Status + '. Existing files were preserved.') }
    $native = Get-NativeRepairPlan $game
    [pscustomobject]@{ SchemaVersion = 1; Game = $game; SteamContext = $steam; Steam = $steamPlan; Cpu = $cpu; LaunchOptions = $launch; Ansel = $ansel; AnselDisposition=$anselDisposition; Native = $native; BuildReady = Get-RepairBuildReady }
}
function Test-ManeaterRepairState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Journal)
    try {
        if ($Journal.SchemaVersion -ne 1 -or $Journal.Status -ne 'applied') { throw 'No completed repair record.' }
        $game=Resolve-ManeaterExecutable $Journal.Plan.Game.Executable
        if ($game.Bin -ine $Journal.Plan.Game.Bin -or $game.GameSHA256 -cne $Journal.Plan.Game.GameSHA256) { throw 'The recorded game folder or executable changed.' }
        if(-not $game.TestedBuild -and ($null -eq $Journal.PSObject.Properties['UntestedBuildOptIn'] -or -not $Journal.UntestedBuildOptIn)){throw 'This untested executable has no recorded opt-in.'}
        if ((Get-RepairHash (Join-Path $game.Bin 'dxgi.dll')) -cne $Journal.Plan.Native.InstalledHash -or
            (Get-RepairHash (Join-Path $game.Bin 'dxgi_codex_system.dll')) -cne $Journal.Plan.Native.InstalledSystemHash) { throw 'The native mod files changed or were removed.' }
        if ($null -eq $Journal.Plan.Native.PSObject.Properties['InstalledHelperHash'] -or
            (Get-RepairHash (Join-Path $game.Bin 'ManeaterAreaHelper.exe')) -cne $Journal.Plan.Native.InstalledHelperHash) { throw 'The native helper is missing, changed, or belongs to an older setup. Restore, then apply this release.' }
        if ((Get-VerifiedWindowsDxgi).Table.FileSHA256 -cne $Journal.Plan.Native.InstalledSystemHash) { throw 'Windows updated its DXGI library.' }
        $context=Get-SteamFixContext -Context $Journal.Plan.SteamContext
        Assert-SteamManeaterInstallation -Context $context -GameRoot $game.GameRoot | Out-Null
        $steam=Get-SteamFixStatus -ConfigPath $context.ConfigPath
        $desired=New-ManeaterLaunchOptions -ExistingOptions $Journal.Plan.LaunchOptions -CpuPlan (Get-ManeaterCpuPlan) -AllowUntestedBuild:(-not $game.TestedBuild)
        if ($steam.ExistingLaunchOptions -cne $desired -or $steam.ExistingOverlay -cne '0') { throw 'Steam settings or CPU topology changed.' }
        if(Test-RepairAnselSkipped $Journal.Plan){
            $currentAnsel=Get-ManeaterAnselStatus -GameRoot $game.GameRoot
            if($currentAnsel.OriginalHash -cne $Journal.Plan.Ansel.OriginalHash -or $currentAnsel.DisabledHash -cne $Journal.Plan.Ansel.DisabledHash){throw 'The preserved unrecognized Ansel files changed.'}
        } else {
            if ([IO.File]::Exists($Journal.Plan.Ansel.OriginalPath)) { throw 'The Ansel SDK was enabled again.' }
            if ($Journal.Plan.Ansel.Action -eq 'Disable' -and (Get-RepairHash $Journal.Plan.Ansel.DisabledPath) -cne $Journal.Plan.Ansel.ExpectedHash) { throw 'The saved Ansel SDK changed or is missing.' }
        }
        return [pscustomobject]@{Valid=$true;Reason='All applicable fixes are present.';BundleUpdateAvailable=(Test-BundleUpdateAvailable $Journal)}
    } catch { return [pscustomobject]@{Valid=$false;Reason=$_.Exception.Message} }
}
function Assert-RepairWritable {
    param([string]$Directory)
    $probe = Join-Path $Directory ([Guid]::NewGuid().ToString('N') + '.tmp')
    try { $stream = [IO.File]::Open($probe, 'CreateNew', 'Write', 'None'); $stream.Dispose() }
    catch [UnauthorizedAccessException] { throw 'Write permission is required. Close this launcher and use Run as administrator on Start.cmd, then select the game again.' }
    finally { if ([IO.File]::Exists($probe)) { [IO.File]::Delete($probe) } }
}
function Restore-NativeRepair {
    param($Journal)
    $native = $Journal.Plan.Native
    if ($native.Action -eq 'None') { return }
    $hasHelper = $null -ne $native.PSObject.Properties['HelperPath']
    $bin = [IO.Path]::GetFullPath([string]$Journal.Plan.Game.Bin).TrimEnd('\')
    if ($bin -notmatch '\\Maneater\\Binaries\\Win64$' -or
        $native.ModPath -ine (Join-Path $bin 'dxgi.dll') -or $native.SystemPath -ine (Join-Path $bin 'dxgi_codex_system.dll') -or
        $native.InstalledHash -notmatch '^[0-9A-Fa-f]{64}$' -or $native.InstalledSystemHash -notmatch '^[0-9A-Fa-f]{64}$') { throw 'Invalid native restore paths or ownership hashes.' }
    if ($hasHelper -and ($native.HelperPath -ine (Join-Path $bin 'ManeaterAreaHelper.exe') -or $native.InstalledHelperHash -cnotmatch '^[0-9A-F]{64}$')) { throw 'Invalid helper restore path or ownership hash.' }
    $backupRoot = [IO.Path]::GetFullPath((Join-Path $script:Root '.local\backups')).TrimEnd('\') + '\'
    $backup = [IO.Path]::GetFullPath([string]$Journal.BackupDirectory)
    if (-not $backup.StartsWith($backupRoot,[StringComparison]::OrdinalIgnoreCase) -or
        $native.BackupMod -ine (Join-Path $backup 'previous-dxgi.dll') -or $native.BackupSystem -ine (Join-Path $backup 'previous-system-dxgi.dll')) { throw 'Invalid native backup directory.' }
    if ($hasHelper -and $native.BackupHelper -ine (Join-Path $backup 'previous-ManeaterAreaHelper.exe')) { throw 'Invalid helper backup path.' }
    $backups = @(@{Target=$native.ModPath;Backup=$native.BackupMod;Hash=$native.OriginalModHash},@{Target=$native.SystemPath;Backup=$native.BackupSystem;Hash=$native.OriginalSystemHash})
    if ($hasHelper) { $backups += @{Target=$native.HelperPath;Backup=$native.BackupHelper;Hash=$native.OriginalHelperHash} }
    if ($native.Action -eq 'ReplaceRecognized') {
        foreach ($entry in $backups) {
            if ($null -eq $entry.Hash) {
                if ([IO.File]::Exists($entry.Backup)) { throw 'Unexpected helper backup was preserved.' }
                continue
            }
            if ([IO.File]::Exists($entry.Backup)) {
                if ((Get-RepairHash $entry.Backup) -cne $entry.Hash) { throw 'Native backup changed; preserving the current installation.' }
            } elseif (-not [IO.File]::Exists($entry.Target) -or (Get-RepairHash $entry.Target) -cne $entry.Hash) { throw 'Native backup is missing; preserving the current installation.' }
        }
    }
    $statePath = Join-Path $script:Root '.local\installation.json'
    $originalRecord = $(if ($null -ne $native.PSObject.Properties['OriginalNativeRecord']) { $native.OriginalNativeRecord } else { $null })
    if ($null -ne $originalRecord -and ($native.Action -ne 'ReplaceRecognized' -or $originalRecord.Status -ne 'installed' -or
        $originalRecord.SchemaVersion -notin @(1,2,3) -or $originalRecord.GameDirectory -ine $bin -or
        $originalRecord.ModSHA256 -cne $native.OriginalModHash -or $originalRecord.SystemSHA256 -cne $native.OriginalSystemHash)) { throw 'Original native installation record does not match the saved pair.' }
    if ($null -ne $originalRecord -and $hasHelper) {
        $originalHelper = $(if ($originalRecord.SchemaVersion -eq 3) { $originalRecord.HelperSHA256 } else { $null })
        if ($originalHelper -cne $native.OriginalHelperHash) { throw 'Original helper ownership does not match its backup.' }
    }
    $state = $null
    if ([IO.File]::Exists($statePath)) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $matchesOriginal = $null -ne $originalRecord -and
            ($state | ConvertTo-Json -Depth 30 -Compress) -ceq ($originalRecord | ConvertTo-Json -Depth 30 -Compress)
        $matchesNew = $state.GameDirectory -ieq $bin -and $state.ModSHA256 -ceq $native.InstalledHash -and $state.SystemSHA256 -ceq $native.InstalledSystemHash
        if ($hasHelper) { $matchesNew = $matchesNew -and $state.SchemaVersion -eq 3 -and $state.HelperSHA256 -ceq $native.InstalledHelperHash }
        elseif ($state.SchemaVersion -eq 3) { $matchesNew = $false }
        if ($matchesNew -and $null -ne $state.PSObject.Properties['GameSHA256']) { $matchesNew = $state.GameSHA256 -ceq $Journal.Plan.Game.GameSHA256 }
        if (-not $matchesOriginal -and -not $matchesNew) { throw 'Native installation record changed; preserving it and the current files.' }
    }
    # Recover a terminated install even if it stopped before the native record
    # was committed. Only the exact tuple hashes in the write-ahead plan qualify.
    $owned = @(@{Path=$native.ModPath;Hash=$native.InstalledHash;Original=$native.OriginalModHash},@{Path=$native.SystemPath;Hash=$native.InstalledSystemHash;Original=$native.OriginalSystemHash})
    if ($hasHelper) { $owned += @{Path=$native.HelperPath;Hash=$native.InstalledHelperHash;Original=$native.OriginalHelperHash} }
    foreach ($entry in $owned) {
        if ([IO.File]::Exists($entry.Path)) {
            $hash = Get-RepairHash $entry.Path
            if ($hash -cne $entry.Hash -and ($native.Action -ne 'ReplaceRecognized' -or $hash -cne $entry.Original)) { throw 'Native restore preserved a file that changed after installation.' }
        }
    }
    foreach ($entry in $owned) {
        if ([IO.File]::Exists($entry.Path)) {
            $hash = Get-RepairHash $entry.Path
            # A byte-identical original is already restored, including a
            # Windows copy whose old and new hashes happen to be equal.
            if ($native.Action -eq 'ReplaceRecognized' -and $hash -ceq $entry.Original) { continue }
            if ($hash -ceq $entry.Hash) { [IO.File]::Delete($entry.Path) }
        }
    }
    if ($native.Action -eq 'ReplaceRecognized') {
        foreach ($entry in $backups) {
            if ($null -eq $entry.Hash) {
                if ([IO.File]::Exists($entry.Target)) { throw 'A helper created by another tool was preserved.' }
                continue
            }
            if ([IO.File]::Exists($entry.Target)) {
                if ((Get-RepairHash $entry.Target) -cne $entry.Hash) { throw 'Native restore preserved a file that changed after installation.' }
            } elseif ([IO.File]::Exists($entry.Backup)) {
                if ((Get-RepairHash $entry.Backup) -cne $entry.Hash) { throw 'Native backup changed; it was preserved.' }
                $staged = Join-Path $bin ('native-restore-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    [IO.File]::Copy($entry.Backup, $staged, $false)
                    if ((Get-RepairHash $staged) -cne $entry.Hash) { throw 'Staged native backup changed; nothing published.' }
                    # PREVIEW_BEFORE_RESTORE_PUBLISH
                    [IO.File]::Move($staged, $entry.Target)
                } finally { if ([IO.File]::Exists($staged)) { [IO.File]::Delete($staged) } }
            } else { throw 'Native backup is missing; manual recovery is required.' }
        }
    }
    if ($null -ne $originalRecord) {
        Write-RepairJson $statePath $originalRecord
    } elseif ($null -ne $state) {
        if ($native.Action -eq 'ReplaceRecognized') { [IO.File]::Delete($statePath) }
        else { $state.Status = 'uninstalled'; Write-RepairJson $statePath $state }
    }
}
function Restore-ManeaterRepair {
    [CmdletBinding()]
    param([scriptblock]$Progress = {})
    Assert-RepairProcessesClosed
    $statePath = Get-RepairStatePath
    if (-not [IO.File]::Exists($statePath)) { throw 'There is no repair record in this launcher folder.' }
    $journal = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if($journal.Status-in@('upgrading','upgrade-recovery-required')){$journal=Restore-NativeBundleUpgrade $journal}
    if ($journal.SchemaVersion -ne 1) { throw 'Unsupported restore record.' }
    if ($journal.Status -eq 'restored') { & $Progress 'Already restored.'; return $journal }
    $steamRecord = Join-Path $journal.BackupDirectory 'steam-fix.json'
    if ($null -eq $journal.SteamRecord -and [IO.File]::Exists($steamRecord)) { $journal.SteamRecord = Get-Content -LiteralPath $steamRecord -Raw | ConvertFrom-Json }
    $errors = New-Object 'Collections.Generic.List[string]'
    $warnings = @()
    & $Progress 'Restoring the previous Steam settings...'
    if ($null -ne $journal.SteamRecord) {
        try { $steamResult=Restore-SteamFix -Record $journal.SteamRecord; if (@($steamResult.PreservedForeignFields).Count) { $warnings += 'Kept Steam settings changed after installation: ' + ($steamResult.PreservedForeignFields -join ', ') } }
        catch { $errors.Add($_.Exception.Message) }
    }
    & $Progress 'Restoring Ansel...'
    if(-not (Test-RepairAnselSkipped $journal.Plan)){try { Restore-ManeaterAnselFix -Plan $journal.Plan.Ansel | Out-Null } catch { $errors.Add($_.Exception.Message) }}
    & $Progress 'Restoring the previous native mod files...'
    try { Restore-NativeRepair $journal } catch { $errors.Add($_.Exception.Message) }
    $journal.Status = $(if ($errors.Count) { 'recovery-required' } else { 'restored' })
    $journal.Errors = @($errors.ToArray()); Write-RepairJson $statePath $journal
    $journal | Add-Member -NotePropertyName Warnings -NotePropertyValue @($warnings) -Force; Write-RepairJson $statePath $journal
    if ($errors.Count) { throw ('Restore preserved conflicting files/settings: ' + ($errors -join '; ')) }
    & $Progress $(if($warnings.Count){'Restored our changes; kept settings changed afterward.'}else{'Restored the settings and files saved before Apply fixes.'})
    return $journal
}
function Restore-NativeBundleUpgrade($Journal){
    $upgrade=$Journal.NativeUpgrade;$prior=$upgrade.PriorJournal
    $bin=[IO.Path]::GetFullPath($prior.Plan.Game.Bin).TrimEnd('\')
    $directory=[IO.Path]::GetFullPath($upgrade.Directory)
    $prefix=[IO.Path]::GetFullPath((Join-Path $script:Root '.local/native-upgrades')).TrimEnd('\')+'\'
    if(-not$directory.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($directory)-cnotmatch'^[0-9a-f]{32}$'-or$bin-notmatch'\\Maneater\\Binaries\\Win64$'-or@($upgrade.Files).Count-ne3){throw 'Invalid native upgrade recovery record.'}
    $names=@('dxgi.dll','dxgi_codex_system.dll','ManeaterAreaHelper.exe')
    foreach($entry in $upgrade.Files){
        if($entry.Name-cnotin$names-or$entry.OldHash-cnotmatch'^[0-9A-F]{64}$'-or$entry.NewHash-cnotmatch'^[0-9A-F]{64}$'){throw 'Invalid native upgrade entry.'}
        $backup=Join-Path $directory $entry.Name
        if((Get-RepairHash $backup)-cne$entry.OldHash){throw 'Native upgrade backup changed.'}
        $target=Join-Path $bin $entry.Name
        if([IO.File]::Exists($target)){$hash=Get-RepairHash $target;if($hash-cne$entry.OldHash-and$hash-cne$entry.NewHash){throw 'Foreign native file preserved during upgrade recovery.'}}
    }
    if(@($upgrade.Files.Name|Select-Object -Unique).Count-ne3){throw 'Duplicate native upgrade entry.'}
    $statePath=Join-Path $script:Root '.local/installation.json'
    if([IO.File]::Exists($statePath)){
        $stateHash=Get-RepairHash $statePath
        if($stateHash-cne$upgrade.OldStateHash){
            $state=Get-Content $statePath -Raw|ConvertFrom-Json
            if($state.SchemaVersion-ne3-or$state.Status-cne'installed'-or$state.GameDirectory-ine$bin-or
               $state.ModSHA256-cne$upgrade.Files[0].NewHash-or$state.SystemSHA256-cne$upgrade.Files[1].NewHash-or
               $state.HelperSHA256-cne$upgrade.Files[2].NewHash-or$state.GameSHA256-cne$prior.Plan.Game.GameSHA256){throw 'Changed native ownership was preserved.'}
        }
    }
    foreach($entry in $upgrade.Files){
        $target=Join-Path $bin $entry.Name
        if([IO.File]::Exists($target)-and(Get-RepairHash $target)-ceq$entry.OldHash){continue}
        $stage=Join-Path $bin ('upgrade-restore-'+[Guid]::NewGuid().ToString('N')+'.tmp')
        try{[IO.File]::Copy((Join-Path $directory $entry.Name),$stage,$false);if((Get-RepairHash $stage)-cne$entry.OldHash){throw 'Staged upgrade restore changed.'}
            if([IO.File]::Exists($target)){if((Get-RepairHash $target)-cne$entry.NewHash){throw 'Upgrade restore target changed.'};[IO.File]::Replace($stage,$target,[NullString]::Value)}else{[IO.File]::Move($stage,$target)}
        }finally{if([IO.File]::Exists($stage)){[IO.File]::Delete($stage)}}
    }
    if($null-ne$upgrade.OldStateHash){
        $backup=Join-Path $directory 'installation.json'
        if((Get-RepairHash $backup)-cne$upgrade.OldStateHash){throw 'Previous native ownership backup changed.'}
        Write-RepairJson $statePath (Get-Content $backup -Raw|ConvertFrom-Json)
    }elseif([IO.File]::Exists($statePath)){[IO.File]::Delete($statePath)}
    Write-RepairJson (Get-RepairStatePath) $prior
    return $prior
}
function Update-AppliedNativeBundle($Prior,[scriptblock]$Progress={}){
    if(-not(Get-RepairBuildReady)){throw 'Updated mod package is invalid; existing fixes were preserved.'}
    $build=Get-Content -LiteralPath (Join-Path $script:Root 'dist/build.json') -Raw|ConvertFrom-Json
    if($Prior.Plan.Native.InstalledHash-ceq$build.ModSHA256-and$Prior.Plan.Native.InstalledHelperHash-ceq$build.HelperSHA256){
        $Prior|Add-Member -NotePropertyName PackageVersion -NotePropertyValue $build.Version -Force;Write-RepairJson (Get-RepairStatePath) $Prior;return $Prior
    }
    $bin=$Prior.Plan.Game.Bin;$directory=Join-Path $script:Root ('.local/native-upgrades/'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $files=@(
        [pscustomobject]@{Name='dxgi.dll';OldHash=$Prior.Plan.Native.InstalledHash;NewHash=$build.ModSHA256},
        [pscustomobject]@{Name='dxgi_codex_system.dll';OldHash=$Prior.Plan.Native.InstalledSystemHash;NewHash=$Prior.Plan.Native.InstalledSystemHash},
        [pscustomobject]@{Name='ManeaterAreaHelper.exe';OldHash=$Prior.Plan.Native.InstalledHelperHash;NewHash=$build.HelperSHA256})
    foreach($entry in $files){$target=Join-Path $bin $entry.Name;if((Get-RepairHash $target)-cne$entry.OldHash){throw 'Installed native files changed; no upgrade performed.'};[IO.File]::Copy($target,(Join-Path $directory $entry.Name),$false);if((Get-RepairHash (Join-Path $directory $entry.Name))-cne$entry.OldHash){throw 'Native upgrade backup verification failed.'}}
    $statePath=Join-Path $script:Root '.local/installation.json';$oldStateHash=$null
    if([IO.File]::Exists($statePath)){$oldStateHash=Get-RepairHash $statePath;[IO.File]::Copy($statePath,(Join-Path $directory 'installation.json'),$false);if((Get-RepairHash (Join-Path $directory 'installation.json'))-cne$oldStateHash){throw 'Native ownership backup changed.'}}
    $journal=$Prior|ConvertTo-Json -Depth 30|ConvertFrom-Json
    $journal.Status='upgrading'
    $journal|Add-Member -NotePropertyName NativeUpgrade -NotePropertyValue ([pscustomobject]@{Directory=$directory;Files=$files;OldStateHash=$oldStateHash;PriorJournal=$Prior}) -Force
    Write-RepairJson (Get-RepairStatePath) $journal
    try{
        & $Progress 'Updating installed native fixes...'
        foreach($entry in $files){if((Get-RepairHash (Join-Path $bin $entry.Name))-cne$entry.OldHash){throw 'Native upgrade destination changed.'}}
        foreach($entry in $files){[IO.File]::Delete((Join-Path $bin $entry.Name))}
        # BUNDLE_UPGRADE_BEFORE_INSTALL
        & (Join-Path $script:Root 'Manage-Mod.ps1') -Action Install -GameDirectory $bin -AllowUntestedBuild:([bool]$Prior.UntestedBuildOptIn) -ExpectedGameSHA256 $Prior.Plan.Game.GameSHA256|Out-Null
        if($journal.Plan.Native.Action-ceq'None'){
            $journal.Plan.Native.Action='ReplaceRecognized'
            $journal.Plan.Native.OriginalModHash=$files[0].OldHash;$journal.Plan.Native.OriginalSystemHash=$files[1].OldHash;$journal.Plan.Native.OriginalHelperHash=$files[2].OldHash
            foreach($pair in @(@{Source='dxgi.dll';Target=$journal.Plan.Native.BackupMod},@{Source='dxgi_codex_system.dll';Target=$journal.Plan.Native.BackupSystem},@{Source='ManeaterAreaHelper.exe';Target=$journal.Plan.Native.BackupHelper})){
                $source=Join-Path $directory $pair.Source
                if([IO.File]::Exists($pair.Target)){if((Get-RepairHash $pair.Target)-cne(Get-RepairHash $source)){throw 'Original native backup was changed.'}}
                else{[IO.File]::Copy($source,$pair.Target,$false)}
            }
            $journal.Plan.Native.OriginalNativeRecord=$(if($null-ne$oldStateHash){Get-Content (Join-Path $directory 'installation.json') -Raw|ConvertFrom-Json}else{$null})
        }
        $journal.Plan.Native.InstalledHash=$build.ModSHA256;$journal.Plan.Native.InstalledHelperHash=$build.HelperSHA256
        $journal|Add-Member -NotePropertyName PackageVersion -NotePropertyValue $build.Version -Force
        $journal.Status='applied'
        if(-not(Test-ManeaterRepairState $journal).Valid){throw 'Updated native files failed verification.'}
        $journal.PSObject.Properties.Remove('NativeUpgrade');Write-RepairJson (Get-RepairStatePath) $journal
        return $journal
    }catch{
        $failure=$_.Exception.Message
        $journal=Get-Content (Get-RepairStatePath) -Raw|ConvertFrom-Json
        try{$null=Restore-NativeBundleUpgrade $journal}catch{$journal.Status='upgrade-recovery-required';Write-RepairJson (Get-RepairStatePath) $journal;throw ($failure+' Recovery: '+$_.Exception.Message)}
        throw ($failure+' Previous working fixes restored.')
    }
}
function Invoke-ManeaterRepair {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GameExecutable, $SteamContext, [switch]$AllowUntestedBuild, [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedGameSHA256, [scriptblock]$Progress = {})
    Assert-RepairProcessesClosed
    $statePath = Get-RepairStatePath
    $selected=Resolve-ManeaterExecutable $GameExecutable
    if(-not [string]::IsNullOrEmpty($ExpectedGameSHA256) -and $selected.GameSHA256 -ine $ExpectedGameSHA256){throw 'Game executable changed since the warning/selection. Choose it again.'}
    if ([IO.File]::Exists($statePath)) {
        $prior = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($prior.Status -eq 'applied') {
            if ($prior.Plan.Game.Bin -ine $selected.Bin) { throw 'Restore the previous game installation before selecting another one.' }
            $current=Test-ManeaterRepairState -Journal $prior
            if (-not $current.Valid) { throw ('The setup changed: ' + $current.Reason + ' Use Restore, then apply again.') }
            if(Test-BundleUpdateAvailable $prior){
                if(-not$selected.TestedBuild-and-not$AllowUntestedBuild){throw 'Accept the untested-build warning before updating this game setup.'}
                return Update-AppliedNativeBundle $prior $Progress
            }
            & $Progress 'Fixes are already applied.'; return $prior
        }
        if ($prior.Status -ne 'restored') { throw 'An interrupted repair needs recovery. Click Restore, then apply again.' }
    }
    if(-not $selected.TestedBuild -and -not $AllowUntestedBuild){throw 'Untested Maneater build. Enable Allow an untested build to try it. No changes made.'}
    & $Progress 'Checking the game, Steam settings, and CPU topology...'
    $plan = Get-ManeaterRepairPlan -GameExecutable $GameExecutable -SteamContext $SteamContext
    if (-not $plan.BuildReady) {
        throw 'The ready-to-run mod bundle is missing, damaged, stale, or incompatible with this Windows DXGI export contract. Download and fully extract the ready-to-run release ZIP. Developers can rebuild manually using build.ps1 -ZigPath <compiler path>. No game files or settings changed.'
    }
    Assert-RepairWritable $plan.Game.Bin
    Assert-RepairWritable ([IO.Path]::GetDirectoryName($plan.SteamContext.ConfigPath))
    # Apply uses only the validated bundled mod; it never downloads or builds.
    Assert-RepairProcessesClosed
    if ($plan.Game.GameSHA256 -cne $selected.GameSHA256 -or (Get-RepairHash $plan.Game.Executable) -cne $plan.Game.GameSHA256) { throw 'Game executable changed during preparation.' }
    $build = Get-Content -LiteralPath (Join-Path $script:Root 'dist\build.json') -Raw | ConvertFrom-Json
    $plan.Native.InstalledHash = $(if($plan.Native.Action -eq 'None'){$plan.Native.OriginalModHash}else{$build.ModSHA256})
    $plan.Native.InstalledSystemHash = $(if($plan.Native.Action -eq 'None'){$plan.Native.OriginalSystemHash}else{(Get-VerifiedWindowsDxgi).Table.FileSHA256})
    $plan.Native.InstalledHelperHash = $(if($plan.Native.Action -eq 'None'){$plan.Native.OriginalHelperHash}else{$build.HelperSHA256})
    $backup = Join-Path $script:Root ('.local\backups\' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    $plan.Native.BackupMod = Join-Path $backup 'previous-dxgi.dll'
    $plan.Native.BackupSystem = Join-Path $backup 'previous-system-dxgi.dll'
    $plan.Native.BackupHelper = Join-Path $backup 'previous-ManeaterAreaHelper.exe'
    $warnings=@();if(-not $plan.Game.TestedBuild){$warnings+='Untested game build: native FPS activation depends on runtime compatibility checks.'};if(Test-RepairAnselSkipped $plan){$warnings+='Unrecognized Ansel SDK preserved; Ansel change skipped.'}
    $journal = [pscustomobject]@{ SchemaVersion=1; PackageVersion=$build.Version; Status='applying'; Plan=$plan; UntestedBuildOptIn=(-not $plan.Game.TestedBuild -and [bool]$AllowUntestedBuild); BackupDirectory=$backup; SteamRecord=$null; Errors=@(); Warnings=$warnings; StartedUTC=[DateTime]::UtcNow.ToString('o') }
    Write-RepairJson $statePath $journal
    try {
        & $Progress 'Installing the combined native fixes...'
        if ($plan.Native.Action -eq 'ReplaceRecognized') {
            $previousFiles = @(@{ Target=$plan.Native.ModPath; Backup=$plan.Native.BackupMod; Hash=$plan.Native.OriginalModHash }, @{ Target=$plan.Native.SystemPath; Backup=$plan.Native.BackupSystem; Hash=$plan.Native.OriginalSystemHash })
            if ($null -ne $plan.Native.OriginalHelperHash) { $previousFiles += @{Target=$plan.Native.HelperPath;Backup=$plan.Native.BackupHelper;Hash=$plan.Native.OriginalHelperHash} }
            elseif ([IO.File]::Exists($plan.Native.HelperPath)) { throw 'A foreign helper appeared during preparation; it was preserved.' }
            foreach ($entry in $previousFiles) {
                if ((Get-RepairHash $entry.Target) -cne $entry.Hash) { throw 'Existing native mod changed during preparation.' }
                $staged = Join-Path $backup ('native-backup-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    [IO.File]::Copy($entry.Target, $staged, $false)
                    if ((Get-RepairHash $staged) -cne $entry.Hash) { throw 'Native backup verification failed.' }
                    # PREVIEW_BEFORE_BACKUP_PUBLISH
                    [IO.File]::Move($staged, $entry.Backup)
                } finally { if ([IO.File]::Exists($staged)) { [IO.File]::Delete($staged) } }
            }
            foreach ($entry in $previousFiles) {
                if ((Get-RepairHash $entry.Target) -cne $entry.Hash) { throw 'Existing mod changed; preserving it.' }
                [IO.File]::Delete($entry.Target)
            }
        }
        if ($plan.Native.Action -ne 'None') { & (Join-Path $script:Root 'Manage-Mod.ps1') -Action Install -GameDirectory $plan.Game.Bin -AllowUntestedBuild:([bool]$AllowUntestedBuild) -ExpectedGameSHA256 $plan.Game.GameSHA256 | Out-Null }
        & $Progress 'Applying the Ansel stability setting...'
        if(-not (Test-RepairAnselSkipped $plan)){Apply-ManeaterAnselFix -Plan $plan.Ansel | Out-Null}
        & $Progress 'Applying OpenSSL, CPU scheduling, and per-game overlay settings...'
        $journal.SteamRecord = Invoke-SteamFixPlan -Plan $plan.Steam -BackupDirectory $backup
        Write-RepairJson $statePath $journal
        $journal.Status = 'applied'
        & $Progress 'Verifying every applied fix...'
        $verification=Test-ManeaterRepairState -Journal $journal
        if(-not $verification.Valid){throw ('Final verification failed: '+$verification.Reason)}
        Write-RepairJson $statePath $journal
        & $Progress $(if($plan.Game.TestedBuild){'Fixes installed. Click Play to start Maneater.'}else{'Setup installed for this untested build. FPS compatibility is checked when Maneater starts.'})
        return $journal
    } catch {
        $failure = $_.Exception.Message
        $journal.Status = 'recovery-required'
        # Steam backend saves its own write-ahead record before touching VDF.
        $steamRecord = Join-Path $backup 'steam-fix.json'
        if ($null -eq $journal.SteamRecord -and [IO.File]::Exists($steamRecord)) { $journal.SteamRecord = Get-Content -LiteralPath $steamRecord -Raw | ConvertFrom-Json }
        $journal.Errors = @($failure); Write-RepairJson $statePath $journal
        try { Restore-ManeaterRepair -Progress $Progress | Out-Null } catch { throw ($failure + ' Recovery: ' + $_.Exception.Message) }
        throw ($failure + ' Changes made by this attempt were restored.')
    }
}
Export-ModuleMember -Function Resolve-ManeaterExecutable, Get-ManeaterRepairPlan, Test-ManeaterRepairState, Invoke-ManeaterRepair, Restore-ManeaterRepair, Get-RepairStatePath, Write-RepairJson
