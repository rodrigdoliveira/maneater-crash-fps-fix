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

# Ryzen worker-budget fixtures count physical cores without constraining
# logical placement, CCDs, cache indices or heterogeneous core classes.
function Ryzen-Rows { param([int]$Cores,[switch]$Noncontiguous,[switch]$DifferentClasses)
    $rows=@()
    for($core=0;$core -lt $Cores;++$core){
        for($sibling=0;$sibling -lt 2;++$sibling){
            $logical=if($Noncontiguous){$core+($sibling*$Cores)}else{($core*2)+$sibling}
            $class=if($DifferentClasses -and $core -ge ($Cores/2)){1}else{0}
            $row=Row (200+$logical) $logical $core $class
            $row|Add-Member -NotePropertyName LastLevelCacheIndex -NotePropertyValue $(if($core -ge ($Cores/2)){1}else{0})
            $rows+=$row
        }
    }
    return $rows
}
$ryzen6=Get-CpuLaunchPlan -CpuSets (Ryzen-Rows 6) -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5 5600 6-Core Processor' -ActiveGroupCount 1
Check ($ryzen6.Apply -and $ryzen6.IsAmdWorkerBudget -and $ryzen6.Experimental -and -not $ryzen6.ApplyAffinity -and -not $ryzen6.IsIntelHybrid) 'Ryzen SMT budget explicitly experimental and distinct from Intel affinity'
Check ($ryzen6.CoreLimit -eq 6 -and $ryzen6.TotalPhysicalCores -eq 6 -and $ryzen6.TotalLogicalProcessors -eq 12 -and $null -eq $ryzen6.AffinityMaskHex -and $ryzen6.AffinityMask -eq 0) '6-core12-thread Ryzen budget counts physical cores and leaves affinity unset'
$ryzen8=Get-CpuLaunchPlan -CpuSets (Ryzen-Rows 8) -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 7 7800X3D 8-Core Processor'
Check ($ryzen8.Apply -and $ryzen8.CoreLimit -eq 8 -and $ryzen8.TotalLogicalProcessors -eq 16) '8-core16-thread Ryzen X3D uses all physical cores'
$ryzen16=Get-CpuLaunchPlan -CpuSets (Ryzen-Rows 16) -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 9 9950X3D 16-Core Processor'
Check ($ryzen16.Apply -and $ryzen16.CoreLimit -eq 16 -and $ryzen16.TotalPhysicalCores -eq 16 -and $null -eq $ryzen16.EfficiencyClass) 'dual-cache/CCD fixture counts all16 cores without selecting a CCD'
$noncontiguousRyzen=Get-CpuLaunchPlan -CpuSets (Ryzen-Rows 6 -Noncontiguous) -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5 5600'
Check ($noncontiguousRyzen.Apply -and $noncontiguousRyzen.CoreLimit -eq 6 -and -not $noncontiguousRyzen.ApplyAffinity) 'noncontiguous Ryzen SMT siblings need no bitmask or ordering assumption'
$mixedClassRyzen=Get-CpuLaunchPlan -CpuSets (Ryzen-Rows 6 -DifferentClasses) -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5'
Check ($mixedClassRyzen.Apply -and $mixedClassRyzen.CoreLimit -eq 6) 'classes may differ across Ryzen physical cores; all are counted'
$ryzenNoSmt=@(Ryzen-Rows 6|Where-Object {($_.LogicalProcessorIndex%2)-eq 0})
Check (-not (Get-CpuLaunchPlan -CpuSets $ryzenNoSmt -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5').Apply) 'Ryzen without exposed SMT keeps normal worker budget'
Check (-not (Get-CpuLaunchPlan -CpuSets (Ryzen-Rows 1) -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5').Apply) 'fewer than two Ryzen physical cores declined'
$partialSmt=@(Ryzen-Rows 6);$partialSmt=$partialSmt[0..10]
Check ((Get-CpuLaunchPlan -CpuSets $partialSmt -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5').CoreLimit -eq 6) 'partially exposed SMT retains all physical cores'
$parkedRyzen=@(Ryzen-Rows 6);$parkedRyzen[0].Flags=1
Check ((Get-CpuLaunchPlan -CpuSets $parkedRyzen -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5').CoreLimit -eq 6) 'dynamic Ryzen parking does not erase a physical core'
foreach($flag in @(2,4,8)){
    $restrictedRyzen=@(Ryzen-Rows 6);$restrictedRyzen[0].Flags=$flag
    Check (-not (Get-CpuLaunchPlan -CpuSets $restrictedRyzen -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5').Apply) "Ryzen allocation/realtime flag$flag declines budget"
}
$inconsistentRyzen=@(Ryzen-Rows 6);$inconsistentRyzen[1].EfficiencyClass=1
Check (-not (Get-CpuLaunchPlan -CpuSets $inconsistentRyzen -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5').Apply) 'Ryzen sibling class disagreement declined'
$impossibleSmt=@(Ryzen-Rows 6)+@(Row 999 12 0 0)
Check (-not (Get-CpuLaunchPlan -CpuSets $impossibleSmt -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5').Apply) 'impossible Ryzen3-way sibling topology declined'
$malformedRyzen=@(Ryzen-Rows 6);$malformedRyzen[0].Id='not-an-id'
Check (-not (Get-CpuLaunchPlan -CpuSets $malformedRyzen -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5').Apply) 'malformed Ryzen topology declined'
$duplicateRyzen=@(Ryzen-Rows 6);$duplicateRyzen+=$duplicateRyzen[0]
Check (-not (Get-CpuLaunchPlan -CpuSets $duplicateRyzen -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5').Apply) 'duplicate Ryzen topology declined'
Check (-not (Get-CpuLaunchPlan -CpuSets (Ryzen-Rows 6) -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen Threadripper' -ActiveGroupCount 2).Apply) 'multi-group Ryzen system declined even if visible records are group0'
$nonzeroRyzen=@(Ryzen-Rows 6);foreach($row in $nonzeroRyzen){$row.Group=1}
Check (-not (Get-CpuLaunchPlan -CpuSets $nonzeroRyzen -Manufacturer AuthenticAMD -ProcessorName 'AMD Ryzen 5' -ActiveGroupCount 1).Apply) 'nonzero processor-group Ryzen topology declined'
foreach($processorName in @('AMD FX-8350 Eight-Core Processor','AMD EPYC 7502','Ryzenish','')){
    Check (-not (Get-CpuLaunchPlan -CpuSets (Ryzen-Rows 6) -Manufacturer AuthenticAMD -ProcessorName $processorName).Apply) "unknown or non-Ryzen AMD processor '$processorName' left unchanged"
}
Check (-not (Get-CpuLaunchPlan -CpuSets (Ryzen-Rows 6) -Manufacturer UnknownVendor -ProcessorName 'AMD Ryzen 5').Apply) 'Ryzen name alone does not bypass the AuthenticAMD manufacturer guard'
Check ($plan.ApplyAffinity -and -not $plan.IsAmdWorkerBudget -and -not $plan.Experimental) 'existing Intel hybrid mode has explicit affinity flags and unchanged budget'

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
$amdLaunch=New-GameLaunchPlan -CpuPlan $ryzen6 -ExistingOptions $plain -AllowUntestedBuild
Check ($amdLaunch.CpuApplied -and -not $amdLaunch.AffinityApplied -and $amdLaunch.GameArguments -ceq ($plain+' -corelimit=6') -and $amdLaunch.SteamLaunchOptions -notmatch '/affinity') 'AMD launch changes only the worker budget and preserves graphics arguments'
Check ($amdLaunch.SteamLaunchOptions -match 'set "MANEATER_FIX_CPU_MANAGED=1" &&' -and $amdLaunch.EnvironmentOverrides.MANEATER_FIX_CPU_MANAGED -ceq '1') 'AMD worker-only wrapper carries its dedicated ownership marker'
$amdAgain=New-GameLaunchPlan -CpuPlan $ryzen6 -ExistingOptions $amdLaunch.SteamLaunchOptions -AllowUntestedBuild
Check ($amdAgain.SteamLaunchOptions -ceq $amdLaunch.SteamLaunchOptions -and $amdAgain.RegeneratedManagedCpu) 'AMD managed worker-only roundtrip is stable'
$amdChanged=New-GameLaunchPlan -CpuPlan $ryzen8 -ExistingOptions $amdLaunch.SteamLaunchOptions -AllowUntestedBuild
Check ($amdChanged.GameArguments -ceq ($plain+' -corelimit=8') -and $amdChanged.SteamLaunchOptions -notmatch '/affinity|-corelimit=6') 'AMD managed budget is regenerated when detected physical core count changes'
$amdRemoved=New-GameLaunchPlan -CpuPlan $same -ExistingOptions $amdLaunch.SteamLaunchOptions
Check (-not $amdRemoved.CpuApplied -and $amdRemoved.GameArguments -ceq $plain -and $amdRemoved.SteamLaunchOptions -notmatch '/affinity|-corelimit|MANEATER_FIX_CPU_MANAGED') 'owned AMD budget removed when topology is no longer eligible'
$disabledAmd=New-GameLaunchPlan -CpuPlan $ryzen6 -ExistingOptions $amdLaunch.SteamLaunchOptions -IncludeCpuPlan $false
Check (-not $disabledAmd.CpuApplied -and $disabledAmd.GameArguments -ceq $plain -and $disabledAmd.SteamLaunchOptions -notmatch 'MANEATER_FIX_CPU_MANAGED|-corelimit|/affinity') 'disabling CPU plan removes only its owned AMD budget'
$intelToAmd=New-GameLaunchPlan -CpuPlan $ryzen6 -ExistingOptions $launch.SteamLaunchOptions
Check ($intelToAmd.GameArguments -ceq ($plain+' -corelimit=6') -and $intelToAmd.SteamLaunchOptions -notmatch '/affinity') 'Intel-to-AMD transition removes old affinity and regenerates physical budget'
$amdToIntel=New-GameLaunchPlan -CpuPlan $plan -ExistingOptions $amdLaunch.SteamLaunchOptions
Check ($amdToIntel.GameArguments -ceq ($plain+' -corelimit=2') -and $amdToIntel.SteamLaunchOptions -match '/affinity 2A2' -and $amdToIntel.SteamLaunchOptions -notmatch 'MANEATER_FIX_CPU_MANAGED') 'AMD-to-Intel transition regenerates affinity and clears the AMD marker'
Check-Throws {New-GameLaunchPlan -CpuPlan $ryzen6 -ExistingOptions '-corelimit=8'} 'conflicting plain user corelimit is not claimed by AMD plan'
Check-Throws {New-GameLaunchPlan -CpuPlan $ryzen6 -ExistingOptions '-numthreads=12'} 'AMD does not replace conflicting plain thread arguments'
$manualCompatible=New-GameLaunchPlan -CpuPlan $ryzen6 -ExistingOptions '-dx11 -corelimit=6'
Check ([regex]::Matches($manualCompatible.GameArguments,'-corelimit=6').Count -eq 1) 'matching plain AMD corelimit is not duplicated'
Check ($manualCompatible.SteamLaunchOptions -notmatch 'MANEATER_FIX_CPU_MANAGED' -and -not $manualCompatible.RegeneratedManagedCpu) 'borrowed matching manual AMD corelimit is not claimed by the ownership marker'
$borrowedAgain=New-GameLaunchPlan -CpuPlan $ryzen6 -ExistingOptions $manualCompatible.SteamLaunchOptions
Check ($borrowedAgain.SteamLaunchOptions -ceq $manualCompatible.SteamLaunchOptions -and -not $borrowedAgain.RegeneratedManagedCpu) 'matching manual AMD budget roundtrip stays stable and unowned'
$borrowedDisabled=New-GameLaunchPlan -CpuPlan $ryzen6 -ExistingOptions $manualCompatible.SteamLaunchOptions -IncludeCpuPlan $false
Check ($borrowedDisabled.GameArguments -ceq '-dx11 -corelimit=6' -and -not $borrowedDisabled.CpuApplied) 'disabling CPU plan preserves a borrowed manual AMD budget'
Check-Throws {New-GameLaunchPlan -CpuPlan $ryzen8 -ExistingOptions $manualCompatible.SteamLaunchOptions} 'a later conflicting AMD physical count does not overwrite borrowed manual budget'
$manualUnrestricted=New-GameLaunchPlan -CpuPlan $amd -ExistingOptions '-dx11 -corelimit=8'
Check ($manualUnrestricted.GameArguments -ceq '-dx11 -corelimit=8' -and $manualUnrestricted.SteamLaunchOptions -notmatch 'MANEATER_FIX_CPU_MANAGED') 'ineligible AMD preserves an unowned plain user corelimit'
$oldMarkerManual='cmd /d /v:off /s /c "set "OPENSSL_ia32cap=:~0x20000000" && set "MANEATER_FIX_ALLOW_UNTESTED=0" && start "" /b /wait %command% -dx11 -corelimit=8"'
Check-Throws {New-GameLaunchPlan -CpuPlan $ryzen6 -ExistingOptions $oldMarkerManual} 'old untested marker alone does not own a manual budget or suppress its conflict'
$oldMarkerBorrowed=New-GameLaunchPlan -CpuPlan $ryzen8 -ExistingOptions $oldMarkerManual
Check ($oldMarkerBorrowed.GameArguments -ceq '-dx11 -corelimit=8' -and $oldMarkerBorrowed.SteamLaunchOptions -notmatch 'MANEATER_FIX_CPU_MANAGED' -and -not $oldMarkerBorrowed.RegeneratedManagedCpu) 'old marker-only matching manual budget stays unowned when applied on AMD'
$oldMarkerPreserved=New-GameLaunchPlan -CpuPlan $amd -ExistingOptions $oldMarkerManual
Check ($oldMarkerPreserved.GameArguments -ceq '-dx11 -corelimit=8' -and -not $oldMarkerPreserved.RegeneratedManagedCpu) 'old no-affinity marker wrapper preserves its user budget on an ineligible machine'
Check ($launch.SteamLaunchOptions -notmatch 'MANEATER_FIX_CPU_MANAGED' -and $launch.AffinityApplied) 'Intel wrapper unchanged by the new AMD-only ownership marker'
Check-Throws {New-GameLaunchPlan -CpuPlan $ryzen6 -ExistingOptions ($amdLaunch.SteamLaunchOptions.Replace('MANEATER_FIX_CPU_MANAGED=1','MANEATER_FIX_CPU_MANAGED=anything'))} 'malformed AMD ownership marker declined without rewriting'
$legacyIntel=[pscustomobject]@{Apply=$true;GroupCount=1;CoreLimit=2;AffinityMaskHex='2A2'}
Check ((New-GameLaunchPlan -CpuPlan $legacyIntel).AffinityApplied) 'legacy Intel plans without the new field retain affinity validation and behavior'
$falseAffinity=[pscustomobject]@{Apply=$true;ApplyAffinity=$false;GroupCount=1;CoreLimit=2;AffinityMaskHex=$null}
Check-Throws {New-GameLaunchPlan -CpuPlan $falseAffinity} 'generic false-affinity plan cannot bypass the explicit AMD mode guards'
$badChoice=[pscustomobject]@{Apply=$true;ApplyAffinity='false';GroupCount=1;CoreLimit=2;AffinityMaskHex='2A2'}
Check-Throws {New-GameLaunchPlan -CpuPlan $badChoice} 'string affinity choice is not silently coerced into a boolean'
$badCount=$ryzen6.PSObject.Copy();$badCount.CoreLimit=7
Check-Throws {New-GameLaunchPlan -CpuPlan $badCount} 'AMD physical budget mismatch declined'
$badCount=$ryzen6.PSObject.Copy();$badCount.TotalLogicalProcessors=65
Check-Throws {New-GameLaunchPlan -CpuPlan $badCount} 'AMD count outside the single-group logical bound declined'
$badCount=$ryzen6.PSObject.Copy();$badCount.TotalLogicalProcessors=6
Check-Throws {New-GameLaunchPlan -CpuPlan $badCount} 'AMD plan without actual SMT count declined'
$badCount=$ryzen6.PSObject.Copy();$badCount.CoreLimit=6.5
Check-Throws {New-GameLaunchPlan -CpuPlan $badCount} 'fractional AMD worker budget declined'
$readOnly=Get-WindowsCpuTopology
Check ($readOnly.Succeeded -and $readOnly.CpuSets.Count -gt 0) 'read-only local native enumeration smoke check'
Check ($null -ne $readOnly.PSObject.Properties['ProcessorName'] -and -not [string]::IsNullOrWhiteSpace($readOnly.ProcessorName)) 'read-only topology includes actual processor model name from WMI'
"PASS: $passed CPU-buffer, topology, launch-merge, and read-only API contracts. No game/process settings changed."
