# Synthetic VDF only. Never reads or changes a real Steam account configuration.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$package=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $package 'scripts\SteamFix.psm1') -Force
$module=Get-Module SteamFix
$originalProcessCheck=& $module { (Get-Item Function:Get-SteamFixRunningProcesses).ScriptBlock }
# Mock process detection only inside this test's imported module; no source edits.
& $module { function script:Get-SteamFixRunningProcesses { return @() } }
$scratch=Join-Path $PSScriptRoot ('.tmp-steam-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$config=Join-Path $scratch 'localconfig.vdf'
$encoding=[Text.UTF8Encoding]::new($false)
$passed=0
function Assert-Test { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw "FAIL: $Message" }; $script:passed++ }
function Assert-Throws { param([scriptblock]$Operation,[string]$Message) $caught=$false; try { & $Operation | Out-Null } catch { $caught=$true }; Assert-Test $caught $Message }
function Assert-Error { param([scriptblock]$Operation,[string]$Pattern,[string]$Message) $detail=''; try { & $Operation | Out-Null } catch { $detail=$_.Exception.Message }; Assert-Test ($detail -like $Pattern) $Message }
function Write-Fixture { param([string]$Text) [IO.File]::WriteAllText($config,$Text,$encoding) }
function Plan-Text { param($Plan) $bytes=[IO.File]::ReadAllBytes($config); $patches=@($Plan.Patches | ForEach-Object { [ManeaterCrashFpsFix.VdfPatch]::new([int]$_.Start,[int]$_.DeleteCount,[Convert]::FromBase64String($_.ReplacementBase64)) }); return [Text.Encoding]::UTF8.GetString([ManeaterCrashFpsFix.SteamVdf]::Apply($bytes,[ManeaterCrashFpsFix.VdfPatch[]]$patches)) }
$base=@'
"UserLocalConfigStore"
{
 // Braces { } and "quotes" in comments do not change the syntax.
 "Software" { "Valve" { "Steam" { "apps" {
  "123" { "LaunchOptions" "untouched \\ path" "other" "same" "other" "duplicate unrelated" }
  "629820"
  {
   "LaunchOptions" "-old \"quoted\" C:\\Games\\Test"
   "OverlayAppEnable" "legacy-wrong-branch-untouched"
   "Playtime" "12345"
   "Unicode" "UTF8_FIXTURE"
  }
 } } } }
 "apps" { "123" { "OverlayAppEnable" "1" } "629820" { "OverlayAppEnable" "1" } }
}
'@
$base=$base.Replace('UTF8_FIXTURE',('caf' + [char]0x00E9 + ' ' + [char]0x6D77))
$new='cmd /c "set "OPENSSL_ia32cap=:~0x20000000" && %command% -corelimit=4"'
try {
    Write-Fixture $base
    $status=Get-SteamFixStatus $config
    Assert-Test ($status.ExistingLaunchOptions -ceq '-old "quoted" C:\Games\Test') 'escaped original value decoded exactly'
    Assert-Test ($status.ExistingOverlay -ceq '1' -and $status.AppNodeExists) 'exact target app values selected'
    $plan=New-SteamFixPlan $config $new
    Assert-Test ($plan.HasChanges -and $plan.Patches.Count -eq 2) 'existing fields yield two value-only patches'
    $expected=$base.Replace('"-old \"quoted\" C:\\Games\\Test"',[Text.Encoding]::UTF8.GetString([ManeaterCrashFpsFix.SteamVdf]::Quote($new))).Replace('"629820" { "OverlayAppEnable" "1" }','"629820" { "OverlayAppEnable" "0" }')
    Assert-Test ((Plan-Text $plan) -ceq $expected) 'every unrelated byte including comments and duplicate unrelated keys preserved'
    $record=Invoke-SteamFixPlan $plan (Join-Path $scratch 'recovery1')
    Assert-Test ($record.State -eq 'applied' -and [IO.File]::Exists($record.JournalPath) -and [IO.File]::Exists($record.BackupPath)) 'write-ahead record and verified backup created'
    $applied=Get-SteamFixStatus $config
    Assert-Test ($applied.ExistingLaunchOptions -ceq $new -and $applied.ExistingOverlay -ceq '0') 'only desired app settings applied'
    $roundtrip=Get-Content -LiteralPath $record.JournalPath -Raw | ConvertFrom-Json
    $restored=Restore-SteamFix $roundtrip
    Assert-Test ($restored.Mode -eq 'exact-backup' -and [IO.File]::ReadAllText($config,$encoding) -ceq $base) 'JSON recovery roundtrip restores original bytes exactly'
    Assert-Test ((Restore-SteamFix $record).Mode -eq 'already-original') 'repeated restore is harmless'

    $record=Invoke-SteamFixPlan (New-SteamFixPlan $config $new) (Join-Path $scratch 'recovery2')
    $foreign=[IO.File]::ReadAllText($config,$encoding).Replace('"Playtime" "12345"','"Playtime" "99999"')
    [IO.File]::WriteAllText($config,$foreign,$encoding)
    $result=Restore-SteamFix $record
    Assert-Test ($result.Mode -eq 'owned-values-only' -and $result.PreservedForeignFields.Count -eq 0) 'foreign unrelated edit triggers surgical owned-value restore'
    Assert-Test ([IO.File]::ReadAllText($config,$encoding) -ceq $base.Replace('"Playtime" "12345"','"Playtime" "99999"')) 'unrelated edit preserved byte for byte'
    Assert-Test ((Restore-SteamFix $record).PreservedForeignFields.Count -eq 0) 'surgical restore is idempotent'

    Write-Fixture $base
    $record=Invoke-SteamFixPlan (New-SteamFixPlan $config $new) (Join-Path $scratch 'recovery3')
    $foreign=[IO.File]::ReadAllText($config,$encoding).Replace([Text.Encoding]::UTF8.GetString([ManeaterCrashFpsFix.SteamVdf]::Quote($new)),'"user-changed"')
    [IO.File]::WriteAllText($config,$foreign,$encoding)
    $result=Restore-SteamFix $record
    $status=Get-SteamFixStatus $config
    Assert-Test ($result.PreservedForeignFields.Count -eq 1 -and $result.PreservedForeignFields[0] -eq 'LaunchOptions') 'foreign target-field edit preserved and reported'
    Assert-Test ($status.ExistingLaunchOptions -ceq 'user-changed' -and $status.ExistingOverlay -ceq '1') 'other still-owned field restored separately'

    $missing=$base.Replace('   "LaunchOptions" "-old \"quoted\" C:\\Games\\Test"' + "`n",'').Replace('"629820" { "OverlayAppEnable" "1" }','"629820" { }')
    Write-Fixture $missing
    $record=Invoke-SteamFixPlan (New-SteamFixPlan $config $new) (Join-Path $scratch 'recovery4')
    Assert-Test ((Get-SteamFixStatus $config).ExistingLaunchOptions -ceq $new) 'absent fields inserted safely'
    [IO.File]::WriteAllText($config,[IO.File]::ReadAllText($config,$encoding).Replace('"Playtime" "12345"','"Playtime" "22222"'),$encoding)
    Restore-SteamFix $record | Out-Null
    $status=Get-SteamFixStatus $config
    Assert-Test (-not $status.LaunchOptionsPresent -and -not $status.OverlayPresent) 'surgical rollback removes only newly inserted keys'
    Assert-Test ([IO.File]::ReadAllText($config,$encoding).Contains('"Playtime" "22222"')) 'inserted-key rollback preserves later app data'

    Write-Fixture 'UserLocalConfigStore { Software { Valve { Steam { apps { 123 { X Y } } } } } }'
    $record=Invoke-SteamFixPlan (New-SteamFixPlan $config $new) (Join-Path $scratch 'recovery5')
    Assert-Test ((Get-SteamFixStatus $config).AppNodeExists) 'missing app container safely created within unique apps node'
    Assert-Test ((Restore-SteamFix $record).Mode -eq 'exact-backup') 'missing-container exact restoration returns original file'

    Write-Fixture $base
    $plan=New-SteamFixPlan $config $new
    [IO.File]::AppendAllText($config,"`n// another writer",$encoding)
    Assert-Throws { Invoke-SteamFixPlan $plan (Join-Path $scratch 'recovery-race') } 'changed file rejected before backup or mutation'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $scratch 'recovery-race'))) 'race refusal leaves no recovery artifacts'

    foreach ($bad in @(
        $base.Replace('"629820" { "OverlayAppEnable" "1" }','"629820" { "OverlayAppEnable" "1" "overlayappenable" "0" }'),
        $base.Replace('"629820"','"629820" { } "629820"'),
        $base.Replace('"apps" {','"apps" { } "apps" {'),
        $base.Replace('"Playtime" "12345"','"Playtime" "12345" [$WIN32]'),
        $base.Replace('// Braces','/* unsupported */ // Braces'),
        ('#include "external.vdf"' + "`n" + $base),
        $base.Replace('"-old \"quoted\" C:\\Games\\Test"','"bad\q"'),
        $base.Substring(0,$base.Length-1)
    )) {
        Write-Fixture $bad
        Assert-Throws { New-SteamFixPlan $config $new } 'ambiguous or unsupported VDF refused'
    }
    [IO.File]::WriteAllBytes($config,[byte[]]@(255,254,0,0))
    Assert-Throws { New-SteamFixPlan $config $new } 'unsupported encoding refused'
    Write-Fixture $base
    $bom=[byte[]](@(239,187,191) + @($encoding.GetBytes($base.Replace("`n","`r`n"))))
    [IO.File]::WriteAllBytes($config,$bom)
    $record=Invoke-SteamFixPlan (New-SteamFixPlan $config $new) (Join-Path $scratch 'recovery6')
    Restore-SteamFix $record | Out-Null
    Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -ceq [Convert]::ToBase64String($bom)) 'BOM and CRLF preserved on exact restore'

    Write-Fixture $base
    $record=Invoke-SteamFixPlan (New-SteamFixPlan $config $new) (Join-Path $scratch 'recovery7')
    [IO.File]::AppendAllText($record.BackupPath,'tampered',$encoding)
    Assert-Throws { Restore-SteamFix $record } 'tampered backup refused before restoration'

    # Captured-account and library ownership are tested entirely with fake paths.
    $steam=Join-Path $scratch 'fake-steam'; $library=Join-Path $scratch 'fake-library'
    foreach ($directory in @($steam,(Join-Path $steam 'userdata\42\config'),(Join-Path $steam 'steamapps'),(Join-Path $library 'steamapps\common\Maneater'),(Join-Path $library 'steamapps'))) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $steam 'steam.exe'),'Synthetic context fixture; never executed.')
    [IO.File]::WriteAllText((Join-Path $steam 'userdata\42\config\localconfig.vdf'),$base,$encoding)
    $context=[pscustomobject]@{ SteamDirectory=$steam; SteamExe=Join-Path $steam 'steam.exe'; AccountId=[uint32]42; ConfigPath=Join-Path $steam 'userdata\42\config\localconfig.vdf' }
    Assert-Test ((Get-SteamFixContext -Context $context).ConfigPath -ceq $context.ConfigPath) 'captured context works after shutdown without registry lookup'
    $wrongContext=[pscustomobject]@{ SteamDirectory=$steam; AccountId=[uint32]42; ConfigPath=$config }
    Assert-Throws { Get-SteamFixContext -Context $wrongContext } 'captured context cannot redirect to another settings file'
    $libraryToken=[Text.Encoding]::UTF8.GetString([ManeaterCrashFpsFix.SteamVdf]::Quote($library))
    $libraryFile=Join-Path $steam 'steamapps\libraryfolders.vdf'
    $libraryText='"libraryfolders" { "1" { "path" ' + $libraryToken + ' "apps" { "629820" "1234" } } }'
    [IO.File]::WriteAllText($libraryFile,$libraryText,$encoding)
    $manifest=Join-Path $library 'steamapps\appmanifest_629820.acf'
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "629820" "installdir" "Maneater" }',$encoding)
    $gameRoot=Join-Path $library 'steamapps\common\Maneater'
    Assert-Test ((Assert-SteamManeaterInstallation $context $gameRoot).Validated) 'registered library and correct appmanifest match selected game root'
    $copied=Join-Path $scratch 'arbitrary-copy'; [IO.Directory]::CreateDirectory($copied) | Out-Null
    Assert-Error { Assert-SteamManeaterInstallation $context $copied } '*outside a Steam library*Browse local files*' 'arbitrary executable-copy root refused with Steam picker guidance'
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "111" "installdir" "Maneater" }',$encoding)
    Assert-Error { Assert-SteamManeaterInstallation $context $gameRoot } '*does not identify Maneater*629820*' 'wrong manifest appid has a specific error'
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "629820" "installdir" "..\outside" }',$encoding)
    Assert-Error { Assert-SteamManeaterInstallation $context $gameRoot } '*invalid game folder*' 'manifest directory traversal refused with a specific error'
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "629820" "installdir" "Maneater" }',$encoding)
    [IO.File]::WriteAllText($libraryFile,$libraryText.Replace('"629820" "1234"','"other-app" "1234"'),$encoding)
    Assert-Test ((Assert-SteamManeaterInstallation $context $gameRoot).Validated) 'matching manifest validates selected copy when cached app registration is stale'
    [IO.File]::WriteAllText($libraryFile,$libraryText.Replace('"apps" { "629820" "1234" }',''),$encoding)
    Assert-Test ((Assert-SteamManeaterInstallation $context $gameRoot).Validated) 'matching manifest does not require a cached apps container'
    [IO.File]::WriteAllText($libraryFile,$libraryText.Replace('} } }','} } "2" { "path" ' + $libraryToken + ' "apps" { "629820" "1234" } } }'),$encoding)
    Assert-Test ((Assert-SteamManeaterInstallation $context $gameRoot).Validated) 'duplicate library references do not make the chosen manifest ambiguous'
    $secondLibrary=Join-Path $scratch 'second-library'; $secondGame=Join-Path $secondLibrary 'steamapps\common\Maneater'
    [IO.Directory]::CreateDirectory($secondGame)|Out-Null
    $secondManifest=Join-Path $secondLibrary 'steamapps\appmanifest_629820.acf'
    [IO.File]::WriteAllText($secondManifest,'"AppState" { "appid" "629820" "installdir" "Maneater" }',$encoding)
    $secondToken=[Text.Encoding]::UTF8.GetString([ManeaterCrashFpsFix.SteamVdf]::Quote($secondLibrary))
    $twoLibraries=$libraryText.Replace('} } }','} } "2" { "path" ' + $secondToken + ' "apps" { "629820" "1234" } } }')
    [IO.File]::WriteAllText($libraryFile,$twoLibraries,$encoding)
    $librariesHash=(Get-FileHash $libraryFile).Hash; $selectedManifestHash=(Get-FileHash $manifest).Hash
    $selectedFirst=Assert-SteamManeaterInstallation $context $gameRoot
    $selectedSecond=Assert-SteamManeaterInstallation $context $secondGame
    Assert-Test ($selectedFirst.Validated -and $selectedFirst.LibraryPath -ceq $library -and $selectedSecond.Validated -and $selectedSecond.LibraryPath -ceq $secondLibrary) 'manual selection of either registered copy succeeds with two installations'
    [IO.File]::WriteAllText($secondManifest,'malformed stale manifest',$encoding)
    Assert-Test ((Assert-SteamManeaterInstallation $context $gameRoot).Validated) 'unrelated stale manifest does not block the selected valid installation'
    Assert-Test ((Get-FileHash $libraryFile).Hash -ceq $librariesHash -and (Get-FileHash $manifest).Hash -ceq $selectedManifestHash) 'selection validation never edits Steam metadata'
    [IO.File]::WriteAllText($libraryFile,('"libraryfolders" { "1" { "path" '+$secondToken+' } }'),$encoding)
    Assert-Error { Assert-SteamManeaterInstallation $context $gameRoot } '*not in a registered Steam library*Settings > Storage*' 'a manifest in an unregistered library is still refused with storage guidance'
    [IO.File]::WriteAllText($libraryFile,'malformed metadata',$encoding)
    Assert-Error { Assert-SteamManeaterInstallation $context $gameRoot } '*libraryfolders.vdf*could not be read*' 'malformed library list has a specific error'
    [IO.File]::WriteAllText($libraryFile,'"libraryfolders" { "1" { "path" "relative-library" } }',$encoding)
    Assert-Error { Assert-SteamManeaterInstallation $context $gameRoot } '*library list contains an invalid path*' 'relative library paths are refused with a specific error'
    [IO.File]::Delete($libraryFile)
    Assert-Error { Assert-SteamManeaterInstallation $context $gameRoot } '*library list*is missing*Settings > Storage*' 'missing library list has a specific error'
    [IO.File]::WriteAllText($libraryFile,$libraryText,$encoding)
    [IO.File]::Delete($manifest)
    Assert-Error { Assert-SteamManeaterInstallation $context $gameRoot } '*missing Maneater*appmanifest_629820.acf*Browse local files*' 'missing selected manifest has a specific error and picker guidance'
    [IO.File]::WriteAllText($manifest,'malformed metadata',$encoding)
    Assert-Error { Assert-SteamManeaterInstallation $context $gameRoot } '*installation record*could not be read*' 'malformed selected manifest has a specific error'
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "629820" "installdir" "Another Maneater Folder" }',$encoding)
    Assert-Error { Assert-SteamManeaterInstallation $context $gameRoot } '*points to a different folder*Browse local files*' 'selected copy must match its own library manifest'
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "629820" "installdir" "Maneater" }',$encoding)
    [IO.File]::WriteAllText($libraryFile,'"libraryfolders" { "1" ' + $libraryToken + ' }',$encoding)
    Assert-Test ((Assert-SteamManeaterInstallation $context $gameRoot).Validated) 'legacy registered-library format supported'
    Assert-Test ((& $module { Normalize-SteamFixDirectory 'D:\' }) -ceq 'D:\') 'drive-root library path is not converted to drive-relative path'

    # Discovery is read-only and independent of Steam account selection.
    $shipping=Join-Path $gameRoot 'Maneater\Binaries\Win64\Maneater-Win64-Shipping.exe'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($shipping))|Out-Null
    [IO.File]::WriteAllText($shipping,'never-executed discovery fixture')
    $launcher=Join-Path $gameRoot 'Maneater.exe';[IO.File]::WriteAllText($launcher,'never-executed launcher fixture')
    $libraryBefore=(Get-FileHash $libraryFile).Hash;$manifestBefore=(Get-FileHash $manifest).Hash
    $found=Find-SteamManeaterExecutable -SteamDirectories @($steam,$steam)
    Assert-Test ($found.Found -and $found.Executable -ceq $launcher) 'legacy extra-drive library is detected and root launcher preferred; duplicate roots deduplicated'
    [IO.File]::WriteAllText($libraryFile,$libraryText,$encoding)
    Assert-Test ((Find-SteamManeaterExecutable -SteamDirectories @($steam)).Executable -ceq $launcher) 'modern registered Steam library is detected'
    Assert-Test ((Get-FileHash $manifest).Hash -ceq $manifestBefore) 'discovery does not modify installation metadata'
    [IO.File]::Delete($launcher)
    Assert-Test ((Find-SteamManeaterExecutable -SteamDirectories @($steam)).Executable -ceq $shipping) 'shipping executable is a fallback when root launcher is absent'
    $custom=Join-Path $library 'steamapps\common\Custom Maneater Folder'
    [IO.Directory]::Move($gameRoot,$custom)
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "629820" "installdir" "Custom Maneater Folder" }',$encoding)
    $customExe=Join-Path $custom 'Maneater\Binaries\Win64\Maneater-Win64-Shipping.exe'
    Assert-Test ((Find-SteamManeaterExecutable -SteamDirectories @($steam)).Executable -ceq $customExe) 'appmanifest custom installation directory is detected'
    Assert-Test ((Assert-SteamManeaterInstallation $context $custom).Validated) 'custom folder selected after discovery passes its own Steam manifest validation'
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "629820" "installdir" "..\outside" }',$encoding)
    Assert-Test (-not (Find-SteamManeaterExecutable -SteamDirectories @($steam)).Found) 'manifest traversal is never searched'
    [IO.Directory]::Move($custom,$gameRoot)
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "629820" "installdir" "Maneater" }',$encoding)
    $defaultRoot=Join-Path $steam 'steamapps\common\Maneater'
    $defaultShipping=Join-Path $defaultRoot 'Maneater\Binaries\Win64\Maneater-Win64-Shipping.exe'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($defaultShipping))|Out-Null
    [IO.File]::WriteAllText($defaultShipping,'never-executed default fixture')
    $multiple=Find-SteamManeaterExecutable -SteamDirectories @($steam)
    Assert-Test (-not $multiple.Found -and $multiple.Reason -like 'Multiple*') 'ambiguous installed copies are left for manual selection'
    $defaultManifest=Join-Path $steam 'steamapps\appmanifest_629820.acf'
    [IO.File]::WriteAllText($defaultManifest,'"AppState" { "appid" "629820" "installdir" "Maneater" }',$encoding)
    Assert-Test ((Assert-SteamManeaterInstallation $context $gameRoot).Validated -and (Assert-SteamManeaterInstallation $context $defaultRoot).Validated) 'both choices offered after ambiguous discovery pass installation validation'
    [IO.File]::Delete($libraryFile)
    Assert-Test ((Assert-SteamManeaterInstallation $context $defaultRoot).Validated) 'default Steam library needs no external library registration file'
    [IO.File]::WriteAllText($libraryFile,$libraryText,$encoding)
    [IO.File]::Delete($shipping)
    $defaultLauncher=Join-Path $defaultRoot 'Maneater.exe';[IO.File]::WriteAllText($defaultLauncher,'never-executed root fixture')
    Assert-Test ((Find-SteamManeaterExecutable -SteamDirectories @($steam)).Executable -ceq $defaultLauncher) 'conventional Steam common folder is detected without account settings'
    [IO.File]::WriteAllText($libraryFile,'malformed metadata',$encoding)
    Assert-Test ((Find-SteamManeaterExecutable -SteamDirectories @($steam)).Executable -ceq $defaultLauncher) 'malformed library list retains conventional-folder suggestion for normal preflight validation'
    [IO.File]::Delete($defaultShipping)
    $missing=Find-SteamManeaterExecutable -SteamDirectories @($steam,'relative-library')
    Assert-Test (-not $missing.Found -and $missing.Reason -like '*Choose game*') 'missing or incomplete installation and relative roots leave manual picker available'

    $loginDirectory=Join-Path $steam 'config'; [IO.Directory]::CreateDirectory($loginDirectory) | Out-Null
    $loginPath=Join-Path $loginDirectory 'loginusers.vdf'
    $fakeId=([uint64]1 -shl 56) + ([uint64]1 -shl 52) + ([uint64]1 -shl 32) + [uint64]42
    $login='"users" { "' + $fakeId.ToString() + '" { "AccountName" "synthetic" "MostRecent" "1" } }'
    [IO.File]::WriteAllText($loginPath,$login,$encoding)
    Assert-Test ((& $module { param($Path) Get-SteamFixMostRecentAccount $Path } $steam) -eq 42) 'one mostrecent account maps to its low32bit userdata ID'
    foreach ($badLogin in @(
        $login.Replace('"MostRecent" "1"','"MostRecent" "0"'),
        $login.Replace('"MostRecent" "1"','"MostRecent" "1" "MostRecent" "0"'),
        $login.Replace('} }','} "' + ($fakeId + [uint64]1).ToString() + '" { "MostRecent" "1" } }'),
        $login.Replace('"MostRecent" "1"','"MostRecent" "unknown"')
    )) {
        [IO.File]::WriteAllText($loginPath,$badLogin,$encoding)
        Assert-Throws { & $module { param($Path) Get-SteamFixMostRecentAccount $Path } $steam } 'ambiguous or invalid account selection refused'
    }

    # A failed post-mutation journal update remains recoverable from the
    # already-persisted prepared record, without relying on a caller's object.
    & $module { function script:Get-SteamFixRunningProcesses { return @() } }
    Write-Fixture $base
    $writeJournal=& $module { (Get-Item Function:Write-SteamFixJournal).ScriptBlock }
    & $module { param($Original) $script:SteamTestOriginalJournal=$Original; function script:Write-SteamFixJournal { param($Record,$Path) if($Record.State -eq 'applied') {throw 'Synthetic post-mutation journal failure'}; & $script:SteamTestOriginalJournal $Record $Path } } $writeJournal
    $interrupted=Join-Path $scratch 'recovery-interrupted'
    Assert-Throws { Invoke-SteamFixPlan (New-SteamFixPlan $config $new) $interrupted } 'post-mutation journal failure surfaces'
    & $module { param($Original) Set-Item Function:script:Write-SteamFixJournal -Value $Original } $writeJournal
    $pending=Join-Path $interrupted 'steam-fix.json'
    Assert-Test ((Get-Content -LiteralPath $pending -Raw | ConvertFrom-Json).State -eq 'prepared') 'prepared journal was persisted before mutation'
    Assert-Test ((Restore-SteamFix $pending).Mode -eq 'exact-backup' -and [IO.File]::ReadAllText($config,$encoding) -ceq $base) 'prepared journal recovers interrupted apply exactly'

    & $module { function script:Get-SteamFixRunningProcesses { return @([pscustomobject]@{ ProcessName='steam' }) } }
    Assert-Throws { Invoke-SteamFixPlan (New-SteamFixPlan $config $new) (Join-Path $scratch 'recovery-running') } 'running Steam refusal enforced'
    "PASS: $passed synthetic Steam VDF, ownership and recovery contracts. No real Steam file or game touched."
} finally {
    & $module { param($Original) Set-Item Function:script:Get-SteamFixRunningProcesses -Value $Original } $originalProcessCheck
    $resolved=[IO.Path]::GetFullPath($scratch); $parent=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing test cleanup outside tests directory.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
