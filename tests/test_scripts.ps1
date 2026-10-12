# Metadata/filesystem contracts only. No game, proxy DLL, or native worker runs.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $root 'scripts\PeExports.psm1') -Force
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('me-preview-scripts-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$passed = 0
function Assert-Test { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw "FAIL: $Message" }; $script:passed++ }
function Assert-Throws { param([scriptblock]$Operation, [string]$Message) $caught = $false; try { & $Operation | Out-Null } catch { $caught = $true }; Assert-Test $caught $Message }
function Put-U16 { param([byte[]]$Bytes, [int]$Offset, [uint16]$Value) [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 2) }
function Put-U32 { param([byte[]]$Bytes, [int]$Offset, [uint32]$Value) [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 4) }
function New-FixturePe {
    param([object[]]$Exports, [string]$Path, [switch]$OrdinalOnly)
    $bytes = New-Object byte[] 5120
    Put-U16 $bytes 0 0x5a4d; Put-U32 $bytes 60 0x80; Put-U32 $bytes 0x80 0x4550
    Put-U16 $bytes 0x84 0x8664; Put-U16 $bytes 0x86 2; Put-U16 $bytes 0x94 240; Put-U16 $bytes 0x96 0x2022
    $optional = 0x98; Put-U16 $bytes $optional 0x20b
    Put-U32 $bytes ($optional + 56) 0x3000; Put-U32 $bytes ($optional + 60) 0x200
    Put-U32 $bytes ($optional + 108) 16; Put-U32 $bytes ($optional + 112) 0x1000; Put-U32 $bytes ($optional + 116) 0x1000
    $sections = $optional + 240
    Put-U32 $bytes ($sections + 8) 0x1000; Put-U32 $bytes ($sections + 12) 0x1000
    Put-U32 $bytes ($sections + 16) 0x1000; Put-U32 $bytes ($sections + 20) 0x200; Put-U32 $bytes ($sections + 36) 0x40000040
    $sections += 40
    Put-U32 $bytes ($sections + 8) 0x200; Put-U32 $bytes ($sections + 12) 0x2000
    Put-U32 $bytes ($sections + 16) 0x200; Put-U32 $bytes ($sections + 20) 0x1200; Put-U32 $bytes ($sections + 36) 0x60000020
    $bytes[0x1200] = 0xc3
    $base = [int](@($Exports | Measure-Object Ordinal -Minimum).Minimum)
    $maximum = [int](@($Exports | Measure-Object Ordinal -Maximum).Maximum)
    $count = $maximum - $base + 1 + [int]$OrdinalOnly.IsPresent
    $directory = 0x200; $functions = 0x240; $names = $functions + 4 * $count; $ordinals = $names + 4 * $Exports.Count; $cursor = $ordinals + 2 * $Exports.Count
    Put-U32 $bytes ($directory + 16) ([uint32]$base); Put-U32 $bytes ($directory + 20) ([uint32]$count); Put-U32 $bytes ($directory + 24) ([uint32]$Exports.Count)
    Put-U32 $bytes ($directory + 28) ([uint32]($functions - 0x200 + 0x1000)); Put-U32 $bytes ($directory + 32) ([uint32]($names - 0x200 + 0x1000))
    Put-U32 $bytes ($directory + 36) ([uint32]($ordinals - 0x200 + 0x1000))
    $index = 0
    foreach ($entry in @($Exports | Sort-Object Name)) {
        $nameBytes = [Text.Encoding]::ASCII.GetBytes($entry.Name + [char]0)
        Put-U32 $bytes ($names + 4 * $index) ([uint32]($cursor - 0x200 + 0x1000))
        [Array]::Copy($nameBytes, 0, $bytes, $cursor, $nameBytes.Length); $cursor += $nameBytes.Length
        $forwarder = [Text.Encoding]::ASCII.GetBytes('dxgi_codex_system.' + $entry.Name + [char]0)
        Put-U32 $bytes ($functions + 4 * ($entry.Ordinal - $base)) ([uint32]($cursor - 0x200 + 0x1000))
        [Array]::Copy($forwarder, 0, $bytes, $cursor, $forwarder.Length); $cursor += $forwarder.Length
        Put-U16 $bytes ($ordinals + 2 * $index) ([uint16]($entry.Ordinal - $base)); ++$index
    }
    if ($OrdinalOnly) { Put-U32 $bytes ($functions + 4 * ($count - 1)) 0x2000 }
    if ($cursor -gt 0x1200) { throw 'Fixture export buffer exhausted.' }
    [IO.File]::WriteAllBytes($Path, $bytes)
    return $bytes
}
function New-FixtureGamePe {
    # A bounded AMD64 PE32+ executable header; this file is never executed.
    $bytes = New-Object byte[] 1024
    Put-U16 $bytes 0 0x5a4d; Put-U32 $bytes 60 0x80; Put-U32 $bytes 0x80 0x4550
    Put-U16 $bytes 0x84 0x8664; Put-U16 $bytes 0x86 1; Put-U16 $bytes 0x94 240; Put-U16 $bytes 0x96 0x22
    $optional = 0x98; Put-U16 $bytes $optional 0x20b; Put-U32 $bytes ($optional + 16) 0x1000
    Put-U32 $bytes ($optional + 56) 0x2000; Put-U32 $bytes ($optional + 60) 0x200; Put-U32 $bytes ($optional + 108) 16
    $section = $optional + 240
    Put-U32 $bytes ($section + 8) 0x200; Put-U32 $bytes ($section + 12) 0x1000
    Put-U32 $bytes ($section + 16) 0x200; Put-U32 $bytes ($section + 20) 0x200; Put-U32 $bytes ($section + 36) 0x60000020
    $bytes[0x200] = 0xc3
    return ,$bytes
}
function Update-FixtureManifest {
    param([string]$Fixture, [string]$GameHash, $System)
    $proxy = Get-PeExportTable -Path (Join-Path $Fixture 'dist\dxgi.dll')
    $hashes = [ordered]@{}
    foreach ($relative in @('src/maneater_fps_hook.c', 'scripts/PeExports.psm1', 'build.ps1', 'Manage-Mod.ps1')) {
        $hashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $Fixture $relative) -Algorithm SHA256).Hash
    }
    $manifest = @{ SchemaVersion = 1; Version = '0.7.0-preview.1'; GameSHA256 = $GameHash; TargetFPS = 120; SourceHashes = $hashes
        HelperSHA256 = (Get-FileHash -LiteralPath (Join-Path $Fixture 'dist\ManeaterAreaHelper.exe')).Hash
        ModSHA256 = $proxy.FileSHA256; DefinitionSHA256 = (Get-FileHash -LiteralPath (Join-Path $Fixture 'dist\dxgi_proxy.def')).Hash
        SystemExportsSHA256 = $System.Table.ContractSHA256; ModExportsSHA256 = $proxy.ContractSHA256; SystemExports = @($System.Table.Exports | Select-Object Name, Ordinal) }
    [IO.File]::WriteAllText((Join-Path $Fixture 'dist\build.json'), ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}
try {
    $fixtureExports = @([pscustomobject]@{Name = 'Alpha'; Ordinal = 3}, [pscustomobject]@{Name = 'Beta'; Ordinal = 4})
    $validPath = Join-Path $testRoot 'valid.dll'
    $original = New-FixturePe $fixtureExports $validPath
    $valid = Get-PeExportTable $validPath
    Assert-Test ($valid.Machine -eq 'AMD64' -and $valid.Exports.Count -eq 2 -and $valid.Exports[0].Ordinal -eq 3) 'valid AMD64 named export table'
    Assert-Test ($valid.FileSHA256 -ceq (Get-FileHash -LiteralPath $validPath -Algorithm SHA256).Hash) 'hash describes parsed byte snapshot'
    Assert-Test ($valid.Exports[0].Forwarder -ceq 'dxgi_codex_system.Alpha') 'forwarder string parsing'
    $definition = Join-Path $testRoot 'fixture.def'; New-DxgiForwarderDefinition $valid.Exports $definition
    Assert-Test (([IO.File]::ReadAllText($definition)) -match 'Alpha=dxgi_codex_system.Alpha @3') 'definition preserves name and ordinal'
    Assert-DxgiForwarderTable $valid $valid; Assert-Test $true 'matching forwarder contract accepted'
    $different = [pscustomobject]@{ ContractSHA256 = 'different'; Exports = $valid.Exports }
    Assert-Throws { Assert-DxgiForwarderTable $valid $different } 'different system contract refused'
    $ordinalOnly = Join-Path $testRoot 'ordinal-only.dll'; New-FixturePe $fixtureExports $ordinalOnly -OrdinalOnly | Out-Null
    Assert-Throws { Get-PeExportTable $ordinalOnly } 'ordinal-only export refused'
    foreach ($mutation in @('DOS', 'NTOffset', 'Machine', 'ExportCount', 'NameRva', 'NameOrdinal')) {
        $bytes = [byte[]]$original.Clone()
        switch ($mutation) {
            'DOS' { Put-U16 $bytes 0 0 }
            'NTOffset' { Put-U32 $bytes 60 ([uint32]::MaxValue) }
            'Machine' { Put-U16 $bytes 0x84 0x14c }
            'ExportCount' { Put-U32 $bytes 0x214 65536 }
            'NameRva' { Put-U32 $bytes 0x248 ([uint32]4294967280) }
            'NameOrdinal' { Put-U16 $bytes 0x250 65535 }
        }
        $bad = Join-Path $testRoot ('bad-' + $mutation + '.dll'); [IO.File]::WriteAllBytes($bad, $bytes)
        Assert-Throws { Get-PeExportTable $bad } "$mutation corruption refused"
    }
    $coreHash = (Get-FileHash -LiteralPath (Join-Path $root 'src\maneater_fps_hook.c') -Algorithm SHA256).Hash
    $build = Get-Content -LiteralPath (Join-Path $root 'dist\build.json') -Raw | ConvertFrom-Json
    Assert-Test ($coreHash -ceq $build.SourceHashes.'src/maneater_fps_hook.c') 'packaged native core matches reviewed build provenance'
    Assert-Throws { & (Join-Path $root 'Manage-Mod.ps1') -Action Install } 'Install requires explicit game path'
    $status = & (Join-Path $root 'Manage-Mod.ps1') -Action Status
    Assert-Test ($status.PSObject.Properties.Name -contains 'StatePresent') 'Status is read-only without game path'

    # End-to-end filesystem fixtures copy only this package and local signed
    # DXGI into a disposable fake game. The fixture manager's expected game hash
    # alone is substituted; production script/source never changes or runs a DLL.
    $system = Get-VerifiedWindowsDxgi
    $fixture = Join-Path $testRoot 'package'
    foreach ($directory in @('src', 'scripts', 'dist', 'game\Maneater\Binaries\Win64')) { [IO.Directory]::CreateDirectory((Join-Path $fixture $directory)) | Out-Null }
    foreach ($relative in @('src/maneater_fps_hook.c', 'scripts/PeExports.psm1', 'build.ps1')) { [IO.File]::Copy((Join-Path $root $relative), (Join-Path $fixture $relative), $false) }
    $bin = Join-Path $fixture 'game\Maneater\Binaries\Win64'; $game = Join-Path $bin 'Maneater-Win64-Shipping.exe'
    $gameBytes = New-FixtureGamePe
    [IO.File]::WriteAllBytes($game, $gameBytes)
    $gameHash = (Get-FileHash -LiteralPath $game -Algorithm SHA256).Hash
    $managerText = [IO.File]::ReadAllText((Join-Path $root 'Manage-Mod.ps1')).Replace('CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0', $gameHash)
    $manager = Join-Path $fixture 'Manage-Mod.ps1'; [IO.File]::WriteAllText($manager, $managerText, [Text.UTF8Encoding]::new($false))
    New-FixturePe $system.Table.Exports (Join-Path $fixture 'dist\dxgi.dll') | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'dist\ManeaterAreaHelper.exe'),'inert helper fixture; never executed')
    New-DxgiForwarderDefinition $system.Table.Exports (Join-Path $fixture 'dist\dxgi_proxy.def')
    Update-FixtureManifest $fixture $gameHash $system
    & $manager -Action Install -GameDirectory (Join-Path $fixture 'game') -ExpectedGameSHA256 $gameHash | Out-Null
    Assert-Test ([IO.File]::Exists((Join-Path $bin 'dxgi.dll')) -and [IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll')) -and [IO.File]::Exists((Join-Path $bin 'ManeaterAreaHelper.exe'))) 'fixture installation copies the validated three-file tuple'
    Assert-Test ((& $manager -Action Status).HelperPresent) 'status reports helper presence'
    $nativeStatePath = Join-Path $fixture '.local\installation.json'
    $nativeState = Get-Content -LiteralPath $nativeStatePath -Raw | ConvertFrom-Json
    Assert-Test ($nativeState.SchemaVersion -eq 3 -and $nativeState.HelperSHA256 -ceq (Get-FileHash (Join-Path $bin 'ManeaterAreaHelper.exe')).Hash -and $nativeState.GameSHA256 -ceq $gameHash -and $nativeState.TestedBuild -and -not $nativeState.UntestedBuildOptIn) 'tested installation records helper hash and build classification'
    Assert-Throws { & $manager -Action Install -GameDirectory $bin } 'existing loader refused without overwrite'
    [IO.File]::WriteAllText((Join-Path $bin 'dxgi.dll'), 'Foreign replacement')
    Assert-Throws { & $manager -Action Uninstall } 'modified target preserved on uninstall'
    Assert-Test ([IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll'))) 'uninstall validates both before removing either'
    [IO.File]::Copy((Join-Path $fixture 'dist\dxgi.dll'), (Join-Path $bin 'dxgi.dll'), $true)
    & $manager -Action Uninstall | Out-Null
    Assert-Test (-not [IO.File]::Exists((Join-Path $bin 'dxgi.dll')) -and -not [IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll')) -and -not [IO.File]::Exists((Join-Path $bin 'ManeaterAreaHelper.exe'))) 'uninstall removes owned three-file tuple'
    & $manager -Action Uninstall | Out-Null; Assert-Test $true 'repeated uninstall is harmless'
    $unknownGame = [byte[]]$gameBytes.Clone(); $unknownGame[1023] = 1
    [IO.File]::WriteAllBytes($game, $unknownGame)
    $unknownHash = (Get-FileHash -LiteralPath $game -Algorithm SHA256).Hash
    Assert-Throws { & $manager -Action Install -GameDirectory $bin } 'untested build requires explicit opt-in by default'
    Assert-Throws { & $manager -Action Install -GameDirectory $bin -AllowUntestedBuild -ExpectedGameSHA256 $gameHash } 'selected game hash mismatch rejected even with untested opt-in'
    Assert-Test (-not [IO.File]::Exists((Join-Path $bin 'dxgi.dll')) -and -not [IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll'))) 'untested rejection and hash mismatch make no copies'
    & $manager -Action Install -GameDirectory $bin -AllowUntestedBuild -ExpectedGameSHA256 $unknownHash | Out-Null
    $nativeState = Get-Content -LiteralPath $nativeStatePath -Raw | ConvertFrom-Json
    Assert-Test ($nativeState.SchemaVersion -eq 3 -and $nativeState.GameSHA256 -ceq $unknownHash -and -not $nativeState.TestedBuild -and $nativeState.UntestedBuildOptIn) 'opted-in installation records actual untested game hash'
    $unknownStatus = & $manager -Action Status
    Assert-Test ($unknownStatus.GameSHA256 -ceq $unknownHash -and -not $unknownStatus.TestedBuild -and $unknownStatus.UntestedBuildOptIn) 'untested status does not require repeated opt-in'
    [IO.File]::Delete($game)
    & $manager -Action Uninstall | Out-Null
    Assert-Test (-not [IO.File]::Exists((Join-Path $bin 'dxgi.dll')) -and -not [IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll'))) 'untested uninstall needs only owned DLL hashes, even after game removal'
    [IO.File]::WriteAllBytes($game, $gameBytes)
    & $manager -Action Install -GameDirectory $bin | Out-Null
    $legacy = Get-Content -LiteralPath $nativeStatePath -Raw | ConvertFrom-Json
    $legacy.SchemaVersion = 1; $legacy.PSObject.Properties.Remove('TestedBuild'); $legacy.PSObject.Properties.Remove('UntestedBuildOptIn')
    [IO.File]::WriteAllText($nativeStatePath, ($legacy | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $legacyStatus = & $manager -Action Status
    Assert-Test ($legacyStatus.TestedBuild -and -not $legacyStatus.UntestedBuildOptIn) 'legacy schema1 tested record remains readable'
    & $manager -Action Uninstall | Out-Null
    Assert-Test (-not [IO.File]::Exists((Join-Path $bin 'dxgi.dll'))) 'legacy schema1 owned installation still uninstalls'
    Assert-Test ([IO.File]::Exists((Join-Path $bin 'ManeaterAreaHelper.exe'))) 'legacy two-file record preserves untracked helper'
    [IO.File]::Delete((Join-Path $bin 'ManeaterAreaHelper.exe'))
    foreach ($corruption in @('MZ','NTOffset','Machine','OptionalMagic','OptionalSize','Sections','HeaderSize','Entry','DLL')) {
        $badGame = [byte[]]$gameBytes.Clone()
        switch ($corruption) {
            'MZ' { Put-U16 $badGame 0 0 }
            'NTOffset' { Put-U32 $badGame 60 ([uint32]::MaxValue) }
            'Machine' { Put-U16 $badGame 0x84 0x14c }
            'OptionalMagic' { Put-U16 $badGame 0x98 0x10b }
            'OptionalSize' { Put-U16 $badGame 0x94 1 }
            'Sections' { Put-U16 $badGame 0x86 0 }
            'HeaderSize' { Put-U32 $badGame (0x98 + 60) 0x120 }
            'Entry' { Put-U32 $badGame (0x98 + 16) 0x2000 }
            'DLL' { Put-U16 $badGame 0x96 0x2022 }
        }
        [IO.File]::WriteAllBytes($game, $badGame)
        Assert-Throws { & $manager -Action Install -GameDirectory $bin -AllowUntestedBuild } "$corruption game header refused despite opt-in"
    }
    [IO.File]::WriteAllText($game, 'Not a PE executable.')
    Assert-Throws { & $manager -Action Install -GameDirectory $bin -AllowUntestedBuild } 'arbitrary non-PE file refused despite opt-in'
    Assert-Test (-not [IO.File]::Exists((Join-Path $bin 'dxgi.dll'))) 'malformed opted-in game headers never install a proxy'
    [IO.File]::WriteAllBytes($game, $gameBytes)
    $changedGame = $managerText.Replace('$copyGameHash = Get-Hash $gameExe', "`$changed = [IO.File]::ReadAllBytes(`$gameExe); `$changed[1023] = 2; [IO.File]::WriteAllBytes(`$gameExe, `$changed)`n`$copyGameHash = Get-Hash `$gameExe")
    [IO.File]::WriteAllText($manager, $changedGame, [Text.UTF8Encoding]::new($false)); Update-FixtureManifest $fixture $gameHash $system
    Assert-Throws { & $manager -Action Install -GameDirectory $bin -ExpectedGameSHA256 $gameHash } 'game replacement during preparation rejected before copies'
    Assert-Test (-not [IO.File]::Exists((Join-Path $bin 'dxgi.dll')) -and -not [IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll'))) 'game race leaves both loader destinations absent'
    [IO.File]::WriteAllBytes($game, $gameBytes)
    $failedState = $managerText.Replace('    Write-State ([pscustomobject]@{', "    throw 'Synthetic state-write failure'`n    Write-State ([pscustomobject]@{")
    [IO.File]::WriteAllText($manager, $failedState, [Text.UTF8Encoding]::new($false)); Update-FixtureManifest $fixture $gameHash $system
    Assert-Throws { & $manager -Action Install -GameDirectory $bin } 'state-write failure propagated'
    Assert-Test (-not [IO.File]::Exists((Join-Path $bin 'dxgi.dll')) -and -not [IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll'))) 'failed install rolls back only owned copies'
    $foreignFailure = $managerText.Replace('    Write-State ([pscustomobject]@{', "    [IO.File]::WriteAllText(`$modTarget, 'Foreign rollback replacement')`n    throw 'Synthetic state-write failure'`n    Write-State ([pscustomobject]@{")
    [IO.File]::WriteAllText($manager, $foreignFailure, [Text.UTF8Encoding]::new($false)); Update-FixtureManifest $fixture $gameHash $system
    Assert-Throws { & $manager -Action Install -GameDirectory $bin } 'foreign replacement during rollback reported'
    Assert-Test (([IO.File]::ReadAllText((Join-Path $bin 'dxgi.dll'))) -ceq 'Foreign rollback replacement' -and
        -not [IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll'))) 'rollback preserves foreign replacement and removes the other owned copy'
    Remove-Item -LiteralPath (Join-Path $bin 'dxgi.dll')
    $changedProxy = $managerText.Replace('$proxy = Get-PeExportTable -Path $modSource', "`$changed = [IO.File]::ReadAllBytes(`$modSource); `$changed[5119] = 1; [IO.File]::WriteAllBytes(`$modSource, `$changed)`n`$proxy = Get-PeExportTable -Path `$modSource")
    [IO.File]::WriteAllText($manager, $changedProxy, [Text.UTF8Encoding]::new($false)); Update-FixtureManifest $fixture $gameHash $system
    Assert-Throws { & $manager -Action Install -GameDirectory $bin } 'proxy replacement between initial hash and PE validation refused'
    Assert-Test (-not [IO.File]::Exists((Join-Path $bin 'dxgi.dll')) -and -not [IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll'))) 'source replacement never copied into the fake game'

    New-FixturePe $system.Table.Exports (Join-Path $fixture 'dist\dxgi.dll') | Out-Null
    [IO.File]::WriteAllText($manager,$managerText,[Text.UTF8Encoding]::new($false)); Update-FixtureManifest $fixture $gameHash $system
    $helperSource = Join-Path $fixture 'dist\ManeaterAreaHelper.exe'; $helperBytes = [IO.File]::ReadAllBytes($helperSource)
    [IO.File]::Delete($helperSource)
    Assert-Throws { & $manager -Action Install -GameDirectory $bin } 'missing packaged helper fails before publication'
    Assert-Test (-not [IO.File]::Exists((Join-Path $bin 'dxgi.dll')) -and -not [IO.File]::Exists((Join-Path $bin 'ManeaterAreaHelper.exe'))) 'missing helper makes no tuple copies'
    [IO.File]::WriteAllBytes($helperSource,$helperBytes)
    $lateHelper=$managerText.Replace('# PREVIEW_BEFORE_HELPER_PUBLISH',"[IO.File]::WriteAllText(`$helperTarget,'late foreign helper')")
    [IO.File]::WriteAllText($manager,$lateHelper,[Text.UTF8Encoding]::new($false));Update-FixtureManifest $fixture $gameHash $system
    Assert-Throws { & $manager -Action Install -GameDirectory $bin } 'late foreign helper refuses absent-only publication'
    Assert-Test ([IO.File]::ReadAllText((Join-Path $bin 'ManeaterAreaHelper.exe')) -ceq 'late foreign helper' -and -not [IO.File]::Exists((Join-Path $bin 'dxgi.dll')) -and -not [IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll'))) 'late helper preserved while own partial tuple rolled back'
    [IO.File]::Delete((Join-Path $bin 'ManeaterAreaHelper.exe'))
    $lateOwner=$managerText.Replace('# PREVIEW_BEFORE_HELPER_PUBLISH',"[IO.File]::WriteAllText(`$statePath,'late foreign owner')")
    [IO.File]::WriteAllText($manager,$lateOwner,[Text.UTF8Encoding]::new($false));Update-FixtureManifest $fixture $gameHash $system
    Assert-Throws { & $manager -Action Install -GameDirectory $bin } 'changed native owner refuses final state publication'
    Assert-Test ([IO.File]::ReadAllText($nativeStatePath) -ceq 'late foreign owner' -and -not [IO.File]::Exists((Join-Path $bin 'dxgi.dll')) -and -not [IO.File]::Exists((Join-Path $bin 'dxgi_codex_system.dll')) -and -not [IO.File]::Exists((Join-Path $bin 'ManeaterAreaHelper.exe'))) 'foreign owner preserved; all exact candidate copies rolled back'
    Assert-Test (@(Get-ChildItem $bin -Filter 'native-*.tmp').Count -eq 0) 'failed publications leave no staged tuple files'
    "PASS: $passed PE, build-provenance, and scratch installer contracts. No game or DLL was executed."
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $intendedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($intendedParent, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedRoot) -notmatch '^me-preview-scripts-[0-9a-f]{32}$') { throw 'Refusing cleanup outside the owned test directory.' }
    if ([IO.Directory]::Exists($resolvedRoot)) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
