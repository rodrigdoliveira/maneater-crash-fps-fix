[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $PSScriptRoot 'Repair.psm1') -Force
$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
$progressPath = $RequestPath + '.progress.json'
$resultPath = $RequestPath + '.result.json'
$progress = { param($Message) Write-RepairJson $progressPath ([pscustomobject]@{ Message=[string]$Message; UTC=[DateTime]::UtcNow.ToString('o') }) }.GetNewClosure()
$lock = $null
$activeLock=$null
try {
    $activePath=Join-Path $root '.local/launcher-active.lock'
    if(-not[IO.File]::Exists($activePath)){$creation=[IO.File]::Open($activePath,'OpenOrCreate','ReadWrite','ReadWrite');$creation.Dispose()}
    $activeLock=[IO.File]::Open($activePath,'Open','Read','Read')
    try { $lock = [IO.File]::Open((Join-Path $root '.local\repair.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'Another repair operation is running. Wait for it to finish, then retry.' }
    switch ($request.Action) {
        'Detect' {
            & $progress 'Looking for Maneater in Steam libraries...'
            Import-Module (Join-Path $PSScriptRoot 'SteamFix.psm1') -Force
            $result=Find-SteamManeaterExecutable
        }
        'Plan' { & $progress 'Checking the selected game...'; $result = Get-ManeaterRepairPlan -GameExecutable $request.GameExecutable -SteamContext $request.SteamContext }
        'Apply' {
            $allow=$null -ne $request.PSObject.Properties['AllowUntestedBuild'] -and $request.AllowUntestedBuild -is [bool] -and $request.AllowUntestedBuild
            if($null -eq $request.PSObject.Properties['ExpectedGameSHA256']){throw 'Apply requires the executable hash from the reviewed selection.'}
            $result = Invoke-ManeaterRepair -GameExecutable $request.GameExecutable -SteamContext $request.SteamContext -AllowUntestedBuild:$allow -ExpectedGameSHA256 $request.ExpectedGameSHA256 -Progress $progress
        }
        'Restore' { $result = Restore-ManeaterRepair -Progress $progress }
        'Verify' {
            $journal=Get-Content -LiteralPath (Get-RepairStatePath) -Raw | ConvertFrom-Json
            $result=Test-ManeaterRepairState -Journal $journal
        }
        default { throw 'Unknown repair action.' }
    }
    Write-RepairJson $resultPath ([pscustomobject]@{ Success=$true; Result=$result; Message='Completed.' })
} catch {
    Write-RepairJson $resultPath ([pscustomobject]@{ Success=$false; Result=$null; Message=$_.Exception.Message })
    exit 1
} finally { if ($null -ne $lock) { $lock.Dispose() };if($activeLock){$activeLock.Dispose()} }
