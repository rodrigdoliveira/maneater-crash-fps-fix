Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:SupportedGameHash = 'CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0'
$script:LegacyModHash = '5C9EF79C6F5EBC99DB15E62E883F5635FF4133442BFDE6891D98A38A1B9129E6'
foreach ($name in @('PeExports', 'Compiler', 'CpuPlan', 'SteamFix', 'AnselFix')) { Import-Module (Join-Path $PSScriptRoot ($name + '.psm1')) -Force -DisableNameChecking }
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
function Get-RepairBuildReady {
    try {
        $manifest = Get-Content -LiteralPath (Join-Path $script:Root 'dist\build.json') -Raw | ConvertFrom-Json
        if ($manifest.GameSHA256 -cne $script:SupportedGameHash -or $manifest.TargetFPS -ne 120) { return $false }
        foreach ($relative in @('src/maneater_fps_hook.c','scripts/PeExports.psm1','build.ps1','Manage-Mod.ps1')) {
            if ((Get-RepairHash (Join-Path $script:Root $relative)) -cne $manifest.SourceHashes.PSObject.Properties[$relative].Value) { return $false }
        }
        if ((Get-RepairHash (Join-Path $script:Root 'dist\dxgi.dll')) -cne $manifest.ModSHA256 -or
            (Get-RepairHash (Join-Path $script:Root 'dist\dxgi_proxy.def')) -cne $manifest.DefinitionSHA256) { return $false }
        $system = Get-VerifiedWindowsDxgi
        $proxy = Get-PeExportTable (Join-Path $script:Root 'dist\dxgi.dll')
        Assert-DxgiForwarderTable -Proxy $proxy -System $system.Table
        return ($system.Table.ContractSHA256 -ceq $manifest.SystemExportsSHA256)
    } catch { return $false }
}
function Get-NativeRepairPlan {
    param($Game)
    $mod = Join-Path $Game.Bin 'dxgi.dll'; $systemCopy = Join-Path $Game.Bin 'dxgi_codex_system.dll'
    $modPresent = [IO.File]::Exists($mod); $systemPresent = [IO.File]::Exists($systemCopy)
    $action = 'Install'; $oldModHash = $null; $oldSystemHash = $null; $originalNativeRecord = $null
    $nativeState = Join-Path $script:Root '.local\installation.json'
    if ([IO.File]::Exists($nativeState)) {
        $existingRecord = Get-Content -LiteralPath $nativeState -Raw | ConvertFrom-Json
        if ($existingRecord.Status -eq 'installed' -and $existingRecord.GameDirectory -ine $Game.Bin) { throw 'This launcher already tracks a different native installation. Restore it first.' }
    }
    if ($modPresent -or $systemPresent) {
        if (-not ($modPresent -and $systemPresent)) { throw 'An existing DXGI mod is incomplete or foreign. Its files were preserved.' }
        $oldModHash = Get-RepairHash $mod; $oldSystemHash = Get-RepairHash $systemCopy
        if ([IO.File]::Exists($nativeState)) {
            $record = Get-Content -LiteralPath $nativeState -Raw | ConvertFrom-Json
            if ($record.Status -eq 'installed' -and $record.GameDirectory -ieq $Game.Bin -and $record.ModSHA256 -ceq $oldModHash -and $record.SystemSHA256 -ceq $oldSystemHash) {
                $originalNativeRecord = $record
                $action = 'ReplaceRecognized'
                if (Get-RepairBuildReady) {
                    $build = Get-Content -LiteralPath (Join-Path $script:Root 'dist\build.json') -Raw | ConvertFrom-Json
                    $system = Get-VerifiedWindowsDxgi
                    $recordGameMatches = $null -ne $record.PSObject.Properties['GameSHA256'] -and $record.GameSHA256 -ceq $Game.GameSHA256
                    if ($record.SchemaVersion -eq 2) {
                        $recordGameMatches = $recordGameMatches -and $record.TestedBuild -eq (Test-RepairGameTested $Game) -and
                            $record.UntestedBuildOptIn -eq (-not (Test-RepairGameTested $Game))
                    }
                    if ($oldModHash -ceq $build.ModSHA256 -and $oldSystemHash -ceq $system.Table.FileSHA256 -and $recordGameMatches) { $action = 'None' }
                }
            } else { throw 'Native installation record does not match the files. Restore or repair that installation first.' }
        } else {
            $known = $oldModHash -ceq $script:LegacyModHash
            if (Get-RepairBuildReady) {
                $build = Get-Content -LiteralPath (Join-Path $script:Root 'dist\build.json') -Raw | ConvertFrom-Json
                $known = $known -or ($oldModHash -ceq $build.ModSHA256)
            }
            $signature = Get-AuthenticodeSignature -LiteralPath $systemCopy
            if (-not $known -or $signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
                throw 'Another DXGI mod is installed. Existing files were preserved; remove that mod using its own uninstaller first.'
            }
            Assert-DxgiForwarderTable -Proxy (Get-PeExportTable $mod) -System (Get-PeExportTable $systemCopy)
            $action = 'ReplaceRecognized'
        }
    }
    [pscustomobject]@{ Action = $action; ModPath = $mod; SystemPath = $systemCopy; OriginalModHash = $oldModHash; OriginalSystemHash = $oldSystemHash; OriginalNativeRecord = $originalNativeRecord; BackupMod = $null; BackupSystem = $null; InstalledHash = $null; InstalledSystemHash = $null }
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
        return [pscustomobject]@{Valid=$true;Reason='All applicable fixes are present.'}
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
    $bin = [IO.Path]::GetFullPath([string]$Journal.Plan.Game.Bin).TrimEnd('\')
    if ($bin -notmatch '\\Maneater\\Binaries\\Win64$' -or
        $native.ModPath -ine (Join-Path $bin 'dxgi.dll') -or $native.SystemPath -ine (Join-Path $bin 'dxgi_codex_system.dll') -or
        $native.InstalledHash -notmatch '^[0-9A-Fa-f]{64}$' -or $native.InstalledSystemHash -notmatch '^[0-9A-Fa-f]{64}$') { throw 'Invalid native restore paths or ownership hashes.' }
    $backupRoot = [IO.Path]::GetFullPath((Join-Path $script:Root '.local\backups')).TrimEnd('\') + '\'
    $backup = [IO.Path]::GetFullPath([string]$Journal.BackupDirectory)
    if (-not $backup.StartsWith($backupRoot,[StringComparison]::OrdinalIgnoreCase) -or
        $native.BackupMod -ine (Join-Path $backup 'previous-dxgi.dll') -or $native.BackupSystem -ine (Join-Path $backup 'previous-system-dxgi.dll')) { throw 'Invalid native backup directory.' }
    if ($native.Action -eq 'ReplaceRecognized') {
        foreach ($entry in @(@{Target=$native.ModPath;Backup=$native.BackupMod;Hash=$native.OriginalModHash},@{Target=$native.SystemPath;Backup=$native.BackupSystem;Hash=$native.OriginalSystemHash})) {
            if ([IO.File]::Exists($entry.Backup)) {
                if ((Get-RepairHash $entry.Backup) -cne $entry.Hash) { throw 'Native backup changed; preserving the current installation.' }
            } elseif (-not [IO.File]::Exists($entry.Target) -or (Get-RepairHash $entry.Target) -cne $entry.Hash) { throw 'Native backup is missing; preserving the current installation.' }
        }
    }
    $statePath = Join-Path $script:Root '.local\installation.json'
    $originalRecord = $(if ($null -ne $native.PSObject.Properties['OriginalNativeRecord']) { $native.OriginalNativeRecord } else { $null })
    if ($null -ne $originalRecord -and ($native.Action -ne 'ReplaceRecognized' -or $originalRecord.Status -ne 'installed' -or
        $originalRecord.SchemaVersion -notin @(1,2) -or $originalRecord.GameDirectory -ine $bin -or
        $originalRecord.ModSHA256 -cne $native.OriginalModHash -or $originalRecord.SystemSHA256 -cne $native.OriginalSystemHash)) { throw 'Original native installation record does not match the saved pair.' }
    $state = $null
    if ([IO.File]::Exists($statePath)) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $matchesOriginal = $null -ne $originalRecord -and
            ($state | ConvertTo-Json -Depth 30 -Compress) -ceq ($originalRecord | ConvertTo-Json -Depth 30 -Compress)
        $matchesNew = $state.GameDirectory -ieq $bin -and $state.ModSHA256 -ceq $native.InstalledHash -and $state.SystemSHA256 -ceq $native.InstalledSystemHash
        if ($matchesNew -and $null -ne $state.PSObject.Properties['GameSHA256']) { $matchesNew = $state.GameSHA256 -ceq $Journal.Plan.Game.GameSHA256 }
        if (-not $matchesOriginal -and -not $matchesNew) { throw 'Native installation record changed; preserving it and the current files.' }
    }
    # Recover a terminated install even if it stopped before the native record
    # was committed. Only the two exact hashes in the write-ahead plan qualify.
    $owned = @(@{Path=$native.ModPath;Hash=$native.InstalledHash;Original=$native.OriginalModHash},@{Path=$native.SystemPath;Hash=$native.InstalledSystemHash;Original=$native.OriginalSystemHash})
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
        foreach ($entry in @(@{ Target=$native.ModPath; Backup=$native.BackupMod; Hash=$native.OriginalModHash }, @{ Target=$native.SystemPath; Backup=$native.BackupSystem; Hash=$native.OriginalSystemHash })) {
            if ([IO.File]::Exists($entry.Target)) {
                if ((Get-RepairHash $entry.Target) -cne $entry.Hash) { throw 'Native restore preserved a file that changed after installation.' }
            } elseif ([IO.File]::Exists($entry.Backup)) {
                if ((Get-RepairHash $entry.Backup) -cne $entry.Hash) { throw 'Native backup changed; it was preserved.' }
                [IO.File]::Copy($entry.Backup, $entry.Target, $false)
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
            & $Progress 'Fixes are already applied. Use Restore before changing the installation.'; return $prior
        }
        if ($prior.Status -ne 'restored') { throw 'An interrupted repair needs recovery. Click Restore, then apply again.' }
    }
    if(-not $selected.TestedBuild -and -not $AllowUntestedBuild){throw 'Untested Maneater build. Enable Allow an untested build (experimental) to try it. No changes made.'}
    & $Progress 'Checking the game, Steam settings, and CPU topology...'
    $plan = Get-ManeaterRepairPlan -GameExecutable $GameExecutable -SteamContext $SteamContext
    Assert-RepairWritable $plan.Game.Bin
    Assert-RepairWritable ([IO.Path]::GetDirectoryName($plan.SteamContext.ConfigPath))
    if (-not $plan.BuildReady) {
        $compiler = Get-RepairCompiler -CacheDirectory (Join-Path $script:Root '.local\tools') -Progress $Progress
        & $Progress 'Building the FPS mod for this Windows installation...'
        & (Join-Path $script:Root 'build.ps1') -ZigPath $compiler | Out-Null
    }
    # All potentially slow/download operations precede game/settings changes.
    Assert-RepairProcessesClosed
    if ($plan.Game.GameSHA256 -cne $selected.GameSHA256 -or (Get-RepairHash $plan.Game.Executable) -cne $plan.Game.GameSHA256) { throw 'Game executable changed during preparation.' }
    $build = Get-Content -LiteralPath (Join-Path $script:Root 'dist\build.json') -Raw | ConvertFrom-Json
    $plan.Native.InstalledHash = $(if($plan.Native.Action -eq 'None'){$plan.Native.OriginalModHash}else{$build.ModSHA256})
    $plan.Native.InstalledSystemHash = $(if($plan.Native.Action -eq 'None'){$plan.Native.OriginalSystemHash}else{(Get-VerifiedWindowsDxgi).Table.FileSHA256})
    $backup = Join-Path $script:Root ('.local\backups\' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    $plan.Native.BackupMod = Join-Path $backup 'previous-dxgi.dll'
    $plan.Native.BackupSystem = Join-Path $backup 'previous-system-dxgi.dll'
    $warnings=@();if(-not $plan.Game.TestedBuild){$warnings+='Untested game build: native FPS activation depends on runtime compatibility checks.'};if(Test-RepairAnselSkipped $plan){$warnings+='Unrecognized Ansel SDK preserved; Ansel change skipped.'}
    $journal = [pscustomobject]@{ SchemaVersion=1; Status='applying'; Plan=$plan; UntestedBuildOptIn=(-not $plan.Game.TestedBuild -and [bool]$AllowUntestedBuild); BackupDirectory=$backup; SteamRecord=$null; Errors=@(); Warnings=$warnings; StartedUTC=[DateTime]::UtcNow.ToString('o') }
    Write-RepairJson $statePath $journal
    try {
        & $Progress 'Installing the native FPS correction...'
        if ($plan.Native.Action -eq 'ReplaceRecognized') {
            foreach ($entry in @(@{ Target=$plan.Native.ModPath; Backup=$plan.Native.BackupMod; Hash=$plan.Native.OriginalModHash }, @{ Target=$plan.Native.SystemPath; Backup=$plan.Native.BackupSystem; Hash=$plan.Native.OriginalSystemHash })) {
                if ((Get-RepairHash $entry.Target) -cne $entry.Hash) { throw 'Existing native mod changed during preparation.' }
                [IO.File]::Copy($entry.Target, $entry.Backup, $false)
                if ((Get-RepairHash $entry.Backup) -cne $entry.Hash) { throw 'Native backup verification failed.' }
            }
            foreach ($entry in @(@{ Target=$plan.Native.ModPath; Hash=$plan.Native.OriginalModHash }, @{ Target=$plan.Native.SystemPath; Hash=$plan.Native.OriginalSystemHash })) {
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
        & $Progress $(if($plan.Game.TestedBuild){'Fixes installed. Click Play to start Maneater.'}else{'Experimental setup installed. FPS compatibility is checked when Maneater starts.'})
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
