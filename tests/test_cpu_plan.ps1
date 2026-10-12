# Pure topology/launch fixtures plus a read-only local API smoke check.
# No game is launched, process affinity changed, or environment written.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\scripts\CpuPlan.psm1') -Force
$passed = 0
function Check { param([bool]$Value,[string]$Message) if (-not $Value) { throw "FAIL: $Message" }; $script:passed++ }
function Check-Throws { param([scriptblock]$Operation,[string]$Message) $caught=$false; try { & $Operation | Out-Null } catch { $caught=$true }; Check $caught $Message }
function Row { param([int]$Id,[int]$Logical,[int]$Core,[int]$Class,[int]$Group=0,[int]$Flags=0)
    return [pscustomobject]@{Id=$Id;LogicalProcessorIndex=$Logical;CoreIndex=$Core;EfficiencyClass=$Class;Group=$Group;Flags=$Flags}
}
function Cpu-Buffer { param([object[]]$Rows,[int]$RecordSize=32)
    $buffer=New-Object byte[] ($Rows.Count*$RecordSize);$index=0
    foreach($row in $Rows){
        $offset=$index*$RecordSize
        [Array]::Copy([BitConverter]::GetBytes([uint32]$RecordSize),0,$buffer,$offset,4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$row.Id),0,$buffer,$offset+8,4)
        [Array]::Copy([BitConverter]::GetBytes([uint16]$row.Group),0,$buffer,$offset+12,2)
        $buffer[$offset+14]=[byte]$row.LogicalProcessorIndex;$buffer[$offset+15]=[byte]$row.CoreIndex
        $buffer[$offset+18]=[byte]$row.EfficiencyClass;$buffer[$offset+19]=[byte]$row.Flags;++$index
    }
    return ,$buffer
}
$hybrid=@((Row 100 1 10 3),(Row 101 5 10 3),(Row 102 7 14 3),(Row 103 9 14 3),(Row 104 0 22 0),(Row 105 2 23 0))
$parsed=ConvertFrom-CpuSetBuffer -Buffer (Cpu-Buffer $hybrid)
Check ($parsed.CpuSets.Count -eq 6 -and $parsed.CpuSets[3].LogicalProcessorIndex -eq 9 -and $parsed.CpuSets[3].CoreIndex -eq 14) 'fixed fields parsed without pointer-sized structure assumptions'
$extended=ConvertFrom-CpuSetBuffer -Buffer (Cpu-Buffer $hybrid 48)
Check ($extended.CpuSets.Count -eq 6 -and $extended.CpuSets[5].Id -eq 105) 'future record sizes advance using Size'
$unknown=New-Object byte[] 8;[Array]::Copy([BitConverter]::GetBytes([uint32]8),0,$unknown,0,4);[Array]::Copy([BitConverter]::GetBytes([uint32]19),0,$unknown,4,4)
$mixed=[byte[]]($unknown+(Cpu-Buffer @($hybrid[0])));$skip=ConvertFrom-CpuSetBuffer -Buffer $mixed
Check ($skip.UnknownRecordTypes -eq 1 -and $skip.CpuSets.Count -eq 1) 'unknown record types skipped by Size'
Check-Throws {ConvertFrom-CpuSetBuffer -Buffer (New-Object byte[] 7)} 'short header refused'
Check-Throws {ConvertFrom-CpuSetBuffer -Buffer (New-Object byte[] 32)} 'zero-sized record refused'
$short=New-Object byte[] 24;[Array]::Copy([BitConverter]::GetBytes([uint32]24),0,$short,0,4)
Check-Throws {ConvertFrom-CpuSetBuffer -Buffer $short} 'short known payload refused'
$overrun=Cpu-Buffer @($hybrid[0]);[Array]::Copy([BitConverter]::GetBytes([uint32]64),0,$overrun,0,4)
Check-Throws {ConvertFrom-CpuSetBuffer -Buffer $overrun} 'record beyond buffer refused'
$plan=Get-CpuLaunchPlan -CpuSets $parsed.CpuSets -Manufacturer GenuineIntel -ActiveGroupCount 1
Check ($plan.Apply -and $plan.CoreLimit -eq 2 -and $plan.PerformanceLogicalProcessors -eq 4 -and $plan.AffinityMaskHex -ceq '2A2') 'noncontiguous P mask and physical budget derived from topology'
Check ($plan.TotalPhysicalCores -eq 4 -and $plan.TotalLogicalProcessors -eq 6 -and $plan.EfficiencyClass -eq 3) 'higher efficiency class means performance cores'
$noSmt=@((Row 1 0 0 1),(Row 2 3 1 1),(Row 3 8 2 1),(Row 4 12 3 1),(Row 5 1 4 0))
$noSmtPlan=Get-CpuLaunchPlan -CpuSets $noSmt -Manufacturer GenuineIntel
Check ($noSmtPlan.Apply -and $noSmtPlan.CoreLimit -eq 4 -and $noSmtPlan.AffinityMaskHex -ceq '1109') 'P-core budget does not assume two SMT siblings'
$homogeneous=@((Row 1 0 0 1),(Row 2 1 0 1),(Row 3 2 1 1),(Row 4 3 1 1))
$same=Get-CpuLaunchPlan -CpuSets $homogeneous -Manufacturer GenuineIntel
Check (-not $same.Apply -and $null -eq $same.CoreLimit -and $null -eq $same.AffinityMaskHex) 'homogeneous Intel left unrestricted'
$amd=Get-CpuLaunchPlan -CpuSets $hybrid -Manufacturer AuthenticAMD
Check (-not $amd.Apply) 'non-Intel layout left unrestricted'
Check (-not (Get-CpuLaunchPlan -CpuSets @() -Manufacturer GenuineIntel).Apply) 'missing topology left unrestricted'
Check (-not (Get-CpuLaunchPlan -CpuSets $hybrid -Manufacturer GenuineIntel -ActiveGroupCount 2).Apply) 'active multi-group system refused even if records show one group'
$otherGroup=@((Row 1 0 0 1 1),(Row 2 1 1 1 1),(Row 3 2 2 0 1))
Check (-not (Get-CpuLaunchPlan -CpuSets $otherGroup -Manufacturer GenuineIntel -ActiveGroupCount 1).Apply) 'nonzero single group refused for cmd affinity'
$duplicates=@($hybrid)+@($hybrid[0]);Check (-not (Get-CpuLaunchPlan -CpuSets $duplicates -Manufacturer GenuineIntel).Apply) 'duplicate logical identity refused'
$siblings=@((Row 1 0 0 1),(Row 2 1 0 0),(Row 3 2 1 1))
Check (-not (Get-CpuLaunchPlan -CpuSets $siblings -Manufacturer GenuineIntel).Apply) 'mixed SMT performance classes refused'
$allocated=@((Row 1 0 0 1 0 2),(Row 2 1 1 1),(Row 3 2 2 0))
Check (-not (Get-CpuLaunchPlan -CpuSets $allocated -Manufacturer GenuineIntel).Apply) 'exclusive performance CPU sets refused'
$parked=@((Row 1 0 0 1 0 1),(Row 2 1 1 1),(Row 3 2 2 0))
Check ((Get-CpuLaunchPlan -CpuSets $parked -Manufacturer GenuineIntel).Apply) 'temporary parking does not erase a performance core'
$highBit=@((Row 1 0 0 1),(Row 2 63 1 1),(Row 3 1 2 0));$highPlan=Get-CpuLaunchPlan -CpuSets $highBit -Manufacturer GenuineIntel
Check ($highPlan.Apply -and $highPlan.AffinityMaskHex -ceq '8000000000000001') 'logical processor63 handled as unsigned64-bit mask'

$before=[Environment]::GetEnvironmentVariable('OPENSSL_ia32cap','Process')
$plain='-dx11 -fullscreen -ExecCmds="r.Test 1;r.Other 2"'
$launch=New-GameLaunchPlan -ExistingOptions $plain -CpuPlan $plan -ExePath 'D:\Games & Local\Maneater-Win64-Shipping.exe'
Check ($launch.PreservedExistingArguments -ceq $plain -and $launch.GameArguments -ceq ($plain+' -corelimit=2')) 'raw UE argument quotes and graphics settings preserved'
Check ($launch.SteamLaunchOptions -match '/affinity 2A2' -and $launch.EnvironmentOverrides.OPENSSL_ia32cap -ceq ':~0x20000000') 'hardware-derived affinity and child environment generated'
Check ($launch.CmdArguments -match '/d "D:\\Games & Local" "D:\\Games & Local\\Maneater-Win64-Shipping.exe"') 'direct command quotes executable and working directory'
Check ([Environment]::GetEnvironmentVariable('OPENSSL_ia32cap','Process') -ceq $before) 'planner never changes parent environment'
$compatible=New-GameLaunchPlan -ExistingOptions '-dx11 -corelimit=2' -CpuPlan $plan
Check ([regex]::Matches($compatible.GameArguments,'-corelimit=2').Count -eq 1) 'compatible existing corelimit not duplicated'
Check-Throws {New-GameLaunchPlan -ExistingOptions '-corelimit=8' -CpuPlan $plan} 'plain conflicting user corelimit preserved for review'
Check-Throws {New-GameLaunchPlan -ExistingOptions '-numthreads=16' -CpuPlan $plan} 'conflicting thread budget not silently replaced'
$current='cmd /c "set "OPENSSL_ia32cap=:~0x20000000" && start "" /wait /affinity FFFF %command% -corelimit=8 -dx11"'
$regenerated=New-GameLaunchPlan -ExistingOptions $current -CpuPlan $plan
Check ($regenerated.RecognizedExistingWrapper -and $regenerated.RegeneratedManagedCpu -and $regenerated.GameArguments -eq '-dx11 -corelimit=2' -and $regenerated.SteamLaunchOptions -match '/affinity 2A2') 'known existing wrapper migrated to this hardware'
$old='cmd /c "set OPENSSL_ia32cap=:~0x20000000 && %command%"'
$official=New-ManeaterLaunchOptions -ExistingOptions $old -CpuPlan $plan
Check ($official -match '/affinity 2A2' -and $official -match '-corelimit=2') 'official old OpenSSL-only wrapper accepted'
$oldOrder='cmd /c "set OPENSSL_ia32cap=~0x200000200000000 && start /wait /affinity FFFF "" %command% -corelimit=8 -dx11"'
Check ((New-ManeaterLaunchOptions -ExistingOptions $oldOrder -CpuPlan $plan) -match '/affinity 2A2') 'older mask and title order accepted'
$withoutCpu=New-GameLaunchPlan -ExistingOptions $current -CpuPlan $same
Check (-not $withoutCpu.CpuApplied -and $withoutCpu.SteamLaunchOptions -notmatch '/affinity|-corelimit') 'known stale CPU wrapper removed on homogeneous machine'
Check-Throws {New-ManeaterLaunchOptions -ExistingOptions 'cmd /c "echo changed && %command%"' -CpuPlan $plan} 'arbitrary command wrapper rejected'
Check-Throws {New-ManeaterLaunchOptions -ExistingOptions '-dx11 & echo changed' -CpuPlan $plan} 'shell injection rejected'
Check-Throws {New-ManeaterLaunchOptions -ExistingOptions '-name=%USERPROFILE%' -CpuPlan $plan} 'environment expansion not silently rewritten'
Check-Throws {New-ManeaterLaunchOptions -ExistingOptions '-name="unterminated' -CpuPlan $plan} 'unbalanced quotes rejected'
Check-Throws {New-GameLaunchPlan -CpuPlan $plan -ExePath 'D:\Games\%variable%\game.exe'} 'unsafe percent expansion in executable path rejected'
$noRestriction=New-GameLaunchPlan -CpuPlan $amd -ExistingOptions '-dx11'
Check (-not $noRestriction.CpuApplied -and $noRestriction.GameArguments -ceq '-dx11') 'AMD gets OpenSSL wrapper without invented CPU restriction'
$experiment=New-GameLaunchPlan -CpuPlan $plan -ExistingOptions '-dx11' -AllowUntestedBuild
Check ($experiment.UntestedBuildOptIn -and $experiment.EnvironmentOverrides.MANEATER_FIX_ALLOW_UNTESTED -ceq '1') 'explicit trial generates a game-scoped exact1 flag'
Check ($experiment.SteamLaunchOptions -match 'set "MANEATER_FIX_ALLOW_UNTESTED=1" &&') 'Steam wrapper carries the trial flag into the game'
$again=New-GameLaunchPlan -CpuPlan $plan -ExistingOptions $experiment.SteamLaunchOptions -AllowUntestedBuild
Check ($again.SteamLaunchOptions -ceq $experiment.SteamLaunchOptions) 'experimental wrapper roundtrip is stable'
$normal=New-GameLaunchPlan -CpuPlan $plan -ExistingOptions $experiment.SteamLaunchOptions
Check ($normal.EnvironmentOverrides.MANEATER_FIX_ALLOW_UNTESTED -ceq '0' -and $normal.SteamLaunchOptions -notmatch 'MANEATER_FIX_ALLOW_UNTESTED=1') 'tested mode clears the previous experimental flag'
Check-Throws {New-GameLaunchPlan -CpuPlan $plan -ExistingOptions ($experiment.SteamLaunchOptions.Replace('MANEATER_FIX_ALLOW_UNTESTED=1','MANEATER_FIX_ALLOW_UNTESTED=anything'))} 'arbitrary experiment values or commands are not preserved'
$readOnly=Get-WindowsCpuTopology
Check ($readOnly.Succeeded -and $readOnly.CpuSets.Count -gt 0) 'read-only local native enumeration smoke check'
"PASS: $passed CPU-buffer, topology, launch-merge, and read-only API contracts. No game/process settings changed."
