# Inert native-file updates only, reusing the isolated repair fixtures.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'test_repair.ps1') -DefinitionsOnly
function New-Bundle($Case){
    [IO.File]::WriteAllText($Case.Mod,'newer inert native proxy')
    [IO.File]::WriteAllText($Case.Helper,'newer inert attachment helper')
    $path=Join-Path $Case.Root 'dist/build.json';$build=Get-Content $path -Raw|ConvertFrom-Json
    $build.Version='0.9.0';$build.ModSHA256=Hash $Case.Mod;$build.HelperSHA256=Hash $Case.Helper
    [IO.File]::WriteAllText($path,($build|ConvertTo-Json -Depth 10))
}
try{
    $case=New-Scenario 'applied-upgrade';$first=Invoke-Case $case
    $steamHash=Hash $case.Config;$anselHash=Hash $first.Plan.Ansel.DisabledPath;$originalBackup=$first.BackupDirectory
    New-Bundle $case
    Assert-Test ((Test-CaseState $case $first).Valid-and(Test-CaseState $case $first).BundleUpdateAvailable) 'working older repair reports a bundled update'
    $updated=Invoke-Case $case
    Assert-Test ($updated.PackageVersion-ceq'0.9.0'-and$updated.BackupDirectory-ceq$originalBackup) 'upgrade retains original restore record and backup directory'
    Assert-Test ((Hash $updated.Plan.Native.ModPath)-ceq(Hash $case.Mod)-and(Hash $updated.Plan.Native.HelperPath)-ceq(Hash $case.Helper)) 'updated native pair installed'
    Assert-Test ((Hash $case.Config)-ceq$steamHash-and(Hash $updated.Plan.Ansel.DisabledPath)-ceq$anselHash) 'upgrade does not rewrite Steam or Ansel settings'
    Assert-Test ((Test-CaseState $case $updated).Valid-and-not(Test-CaseState $case $updated).BundleUpdateAvailable) 'new bundle verifies and update flag clears'
    Restore-Case $case|Out-Null
    Assert-Test ((Same-Config $case)-and[IO.File]::Exists($case.Ansel)-and-not[IO.File]::Exists((Join-Path $case.Bin 'dxgi.dll'))-and-not[IO.File]::Exists((Join-Path $case.Bin 'ManeaterAreaHelper.exe'))) 'Restore still returns original pre-repair setup after upgrade'

    foreach($mode in @('before-record','after-record')){
        $case=New-Scenario ('upgrade-failure-'+$mode);$first=Invoke-Case $case
        $modHash=Hash $first.Plan.Native.ModPath;$helperHash=Hash $first.Plan.Native.HelperPath;$steamHash=Hash $case.Config
        $oldState=Get-Content (Join-Path $case.Root '.local/installation.json') -Raw|ConvertFrom-Json
        New-Bundle $case
        $marker=$(if($mode-eq'before-record'){'fail-native'}else{'fail-native-after-state'})
        [IO.File]::WriteAllText((Join-Path $case.Root ('.local/'+$marker)),'injected interruption')
        Assert-Throws {Invoke-Case $case} 'failed upgrade reports recovery'
        Assert-Test ((Hash $first.Plan.Native.ModPath)-ceq$modHash-and(Hash $first.Plan.Native.HelperPath)-ceq$helperHash) 'previous working native pair restored'
        Assert-Test ((Read-Journal $case).Status-ceq'applied'-and(Same-NativeRecord $case $oldState)-and(Hash $case.Config)-ceq$steamHash) 'previous journal, ownership and Steam configuration retained'
    }

    $case=New-Scenario 'no-file-change';$first=Invoke-Case $case;$oldMod=Hash $first.Plan.Native.ModPath
    $path=Join-Path $case.Root 'dist/build.json';$build=Get-Content $path -Raw|ConvertFrom-Json;$build.Version='0.9.0';[IO.File]::WriteAllText($path,($build|ConvertTo-Json))
    $updated=Invoke-Case $case
    Assert-Test ($updated.PackageVersion-ceq'0.9.0'-and(Hash $updated.Plan.Native.ModPath)-ceq$oldMod-and$updated.BackupDirectory-ceq$first.BackupDirectory) 'metadata-only bundle update preserves installed files and original backups'

    $case=New-Scenario 'preexisting-owned-pair';$original=Set-OldNative $case -SameHashes;$first=Invoke-Case $case
    Assert-Test ($first.Plan.Native.Action-ceq'None') 'matching preexisting pair initially left alone'
    New-Bundle $case;$updated=Invoke-Case $case
    Assert-Test ($updated.Plan.Native.Action-ceq'ReplaceRecognized') 'first real change acquires reversible ownership'
    Restore-Case $case|Out-Null
    Assert-Test ((Same-NativeRecord $case $original)-and(Hash (Join-Path $case.Bin 'dxgi.dll'))-ceq$original.ModSHA256-and(Hash (Join-Path $case.Bin 'ManeaterAreaHelper.exe'))-ceq$original.HelperSHA256) 'preexisting pair and ownership restored after upgrade'
    Write-Output "PASS: $script:passed applied-bundle update and original-restore contracts. No real game or native executable used."
}finally{
    $full=[IO.Path]::GetFullPath($testRoot);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not$full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($full)-cnotmatch'^me-preview-repair-[0-9a-f]{32}$'){throw 'Unsafe bundle fixture cleanup.'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
