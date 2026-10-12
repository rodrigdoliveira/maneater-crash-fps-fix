Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-CpuPlanNative {
    if ('ManeaterCpuPlan.NativeV1' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace ManeaterCpuPlan {
 public static class NativeV1 {
  [DllImport("kernel32.dll", SetLastError=true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  static extern bool GetSystemCpuSetInformation(IntPtr information, uint length, out uint returned, IntPtr process, uint flags);
  [DllImport("kernel32.dll")] public static extern ushort GetActiveProcessorGroupCount();
  [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr CommandLineToArgvW(string command, out int count);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
  public static byte[] ReadCpuSets() {
   uint required; bool first=GetSystemCpuSetInformation(IntPtr.Zero,0,out required,IntPtr.Zero,0);
   int firstError=Marshal.GetLastWin32Error();
   if (!first && firstError!=122) throw new Win32Exception(firstError);
   if (required==0) return new byte[0];
   for (int attempt=0;attempt<3;attempt++) {
    if (required>1048576) throw new InvalidOperationException("CPU-set buffer exceeds its safety bound.");
    uint allocated=required; IntPtr memory=Marshal.AllocHGlobal(checked((int)allocated));
    try {
     uint returned; bool success=GetSystemCpuSetInformation(memory,allocated,out returned,IntPtr.Zero,0);
     int error=Marshal.GetLastWin32Error();
     if (!success) { if (error==122 && returned>allocated) { required=returned; continue; } throw new Win32Exception(error); }
     if (returned>allocated) throw new InvalidOperationException("CPU-set API returned an invalid length.");
     byte[] data=new byte[checked((int)returned)]; Marshal.Copy(memory,data,0,data.Length); return data;
    } finally { Marshal.FreeHGlobal(memory); }
   }
   throw new InvalidOperationException("CPU topology changed repeatedly during enumeration.");
  }
  public static string[] ParseArguments(string raw) {
   int count; IntPtr memory=CommandLineToArgvW("placeholder.exe "+raw,out count);
   if (memory==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
   try {
    string[] result=new string[Math.Max(count-1,0)];
    for (int i=1;i<count;i++) result[i-1]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory,i*IntPtr.Size));
    return result;
   } finally { LocalFree(memory); }
  }
 }
}
'@
}
function ConvertFrom-CpuSetBuffer {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Buffer)
    $records = @(); $unknown = 0; $offset = 0
    while ($offset -lt $Buffer.Length) {
        if (($Buffer.Length - $offset) -lt 8) { throw 'Malformed CPU-set buffer: incomplete record header.' }
        $size = [long][BitConverter]::ToUInt32($Buffer, $offset)
        $type = [BitConverter]::ToUInt32($Buffer, $offset + 4)
        if ($size -lt 8 -or $size -gt ($Buffer.Length - $offset)) { throw 'Malformed CPU-set buffer: invalid record size.' }
        if ($type -eq 0) {
            if ($size -lt 32) { throw 'Malformed CPU-set buffer: incomplete CpuSet payload.' }
            $flags = $Buffer[$offset + 19]
            $records += [pscustomobject]@{
                Id = [BitConverter]::ToUInt32($Buffer, $offset + 8); Group = [BitConverter]::ToUInt16($Buffer, $offset + 12)
                LogicalProcessorIndex = $Buffer[$offset + 14]; CoreIndex = $Buffer[$offset + 15]
                LastLevelCacheIndex = $Buffer[$offset + 16]; NumaNodeIndex = $Buffer[$offset + 17]
                EfficiencyClass = $Buffer[$offset + 18]; Flags = $flags
                Parked = ($flags -band 1) -ne 0; Allocated = ($flags -band 2) -ne 0
                AllocatedToTargetProcess = ($flags -band 4) -ne 0; RealTime = ($flags -band 8) -ne 0
                SchedulingClass = $Buffer[$offset + 20]
            }
        } else { ++$unknown }
        $offset += [int]$size
    }
    return [pscustomobject]@{ CpuSets = @($records); UnknownRecordTypes = $unknown }
}
function Get-WindowsCpuTopology {
    [CmdletBinding()]
    param()
    try {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
            throw 'CPU planning requires 64-bit PowerShell on Windows.'
        }
        Initialize-CpuPlanNative
        $parsed = ConvertFrom-CpuSetBuffer -Buffer ([ManeaterCpuPlan.NativeV1]::ReadCpuSets())
        $groups = [int][ManeaterCpuPlan.NativeV1]::GetActiveProcessorGroupCount()
        if ($groups -lt 1) { throw 'Windows did not report an active processor group.' }
        $processors = @(Get-CimInstance -ClassName Win32_Processor)
        $vendors = @($processors | Select-Object -ExpandProperty Manufacturer -Unique)
        $names = @($processors | Select-Object -ExpandProperty Name -Unique)
        $vendor = if ($vendors.Count -eq 1) { [string]$vendors[0] } else { '' }
        $name = if ($names.Count -eq 1) { [string]$names[0] } else { '' }
        return [pscustomobject]@{ Succeeded = $true; Manufacturer = $vendor; ProcessorName = $name; ActiveGroupCount = $groups
            CpuSets = $parsed.CpuSets; UnknownRecordTypes = $parsed.UnknownRecordTypes; Error = $null }
    } catch {
        return [pscustomobject]@{ Succeeded = $false; Manufacturer = ''; ProcessorName = ''; ActiveGroupCount = 0; CpuSets = @(); UnknownRecordTypes = 0
            Error = $_.Exception.Message }
    }
}
function New-EmptyCpuPlan {
    param([string]$Manufacturer, [string]$Reason, [int]$GroupCount = 0)
    return [pscustomobject]@{ Apply = $false; ApplyAffinity = $false; Applicable = $false; IsIntelHybrid = $false; IsAmdWorkerBudget = $false; Experimental = $false; Manufacturer = $Manufacturer
        Description = $Reason; Reason = $Reason; GroupCount = $GroupCount; AffinityMask = [uint64]0; AffinityMaskHex = $null
        CoreLimit = $null; PerformancePhysicalCores = 0; PerformanceLogicalProcessors = 0
        TotalPhysicalCores = 0; TotalLogicalProcessors = 0; EfficiencyClass = $null; Notes = @() }
}
function Get-CpuLaunchPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$CpuSets,
          [string]$Manufacturer = '', [int]$ActiveGroupCount = 0, [string]$ProcessorName = '')
    if ($CpuSets.Count -eq 0) { return New-EmptyCpuPlan $Manufacturer 'CPU-set data is unavailable; keep normal game CPU scheduling.' }
    $rows = @(); $seenLogical = @{}; $seenIds = @{}
    try {
        foreach ($row in $CpuSets) {
            foreach ($field in @('Id','Group','LogicalProcessorIndex','CoreIndex','EfficiencyClass')) {
                if ($null -eq $row.PSObject.Properties[$field]) { throw 'Missing CPU-set field.' }
            }
            $id = [long]$row.Id; $group = [long]$row.Group; $logical = [long]$row.LogicalProcessorIndex
            $core = [long]$row.CoreIndex; $efficiency = [long]$row.EfficiencyClass
            $flags = if ($null -ne $row.PSObject.Properties['Flags']) { [long]$row.Flags } else { 0 }
            if ($id -lt 0 -or $id -gt [uint32]::MaxValue -or $group -lt 0 -or $group -gt 65535 -or $logical -lt 0 -or $logical -gt 63 -or
                $core -lt 0 -or $core -gt 255 -or $efficiency -lt 0 -or $efficiency -gt 255 -or $flags -lt 0 -or $flags -gt 15) { throw 'Invalid CPU-set field range.' }
            $key = '{0}:{1}' -f $group,$logical
            if ($seenLogical.ContainsKey($key) -or $seenIds.ContainsKey($id)) { throw 'Duplicate CPU-set identity.' }
            $seenLogical[$key] = $true; $seenIds[$id] = $true
            $rows += [pscustomobject]@{ Group = $group; LogicalProcessorIndex = $logical; CoreIndex = $core; EfficiencyClass = $efficiency; Flags = $flags
                CoreKey = '{0}:{1}' -f $group,$core }
        }
    } catch { return New-EmptyCpuPlan $Manufacturer 'CPU topology is ambiguous or malformed; no CPU restriction will be added.' }
    $groups = @($rows | Select-Object -ExpandProperty Group -Unique)
    if ($ActiveGroupCount -eq 0) { $ActiveGroupCount = $groups.Count }
    if ($ActiveGroupCount -ne 1 -or $groups.Count -ne 1 -or $groups[0] -ne 0) {
        return New-EmptyCpuPlan $Manufacturer 'Multiple or nonzero processor groups need group-aware scheduling; this launcher will not apply affinity or corelimit.' $ActiveGroupCount
    }
    if ($Manufacturer -ieq 'AuthenticAMD') {
        if ($ProcessorName -notmatch '(?i:\bRyzen\b)') {
            return New-EmptyCpuPlan $Manufacturer 'AMD processor is not clearly identified as Ryzen; keep normal scheduling and worker budget.' 1
        }
        foreach ($physical in @($rows | Group-Object CoreKey)) {
            if ($physical.Count -gt 2 -or @($physical.Group | Select-Object -ExpandProperty EfficiencyClass -Unique).Count -ne 1) {
                return New-EmptyCpuPlan $Manufacturer 'Ryzen SMT sibling topology is ambiguous; no AMD worker budget will be added.' 1
            }
        }
        if (@($rows | Where-Object { ($_.Flags -band 14) -ne 0 }).Count -ne 0) {
            return New-EmptyCpuPlan $Manufacturer 'AMD CPU sets are exclusively allocated or real-time; keep normal scheduling and worker budget.' 1
        }
        $physicalCount = @($rows | Select-Object -ExpandProperty CoreKey -Unique).Count
        if ($physicalCount -lt 2 -or $rows.Count -le $physicalCount) {
            return New-EmptyCpuPlan $Manufacturer 'Ryzen SMT is not exposed with at least two physical cores; no worker-budget change is needed.' 1
        }
        $description = 'Experimental AMD Ryzen: {0} physical cores / {1} logical processors; -corelimit={0}, with normal Windows scheduling and no affinity restriction. No AMD gameplay validation yet.' -f $physicalCount,$rows.Count
        return [pscustomobject]@{ Apply = $true; ApplyAffinity = $false; Applicable = $true; IsIntelHybrid = $false; IsAmdWorkerBudget = $true; Experimental = $true; Manufacturer = $Manufacturer; ProcessorName = $ProcessorName
            Description = $description; Reason = $description; GroupCount = 1; AffinityMask = [uint64]0; AffinityMaskHex = $null
            CoreLimit = $physicalCount; PerformancePhysicalCores = 0; PerformanceLogicalProcessors = 0
            TotalPhysicalCores = $physicalCount; TotalLogicalProcessors = $rows.Count; EfficiencyClass = $null
            Notes = @('Experimental Ryzen worker budget based on physical core count; Maneater gameplay has not been tested on AMD hardware.',
                'All cores and SMT siblings remain available to Windows scheduling; no CCD, cache or preferred-core affinity is imposed.',
                'Dynamic parking and differing classes between physical cores do not change the worker budget.',
                'AMD recommends physical core count as an initial worker-pool budget: https://gpuopen.com/learn/cpu-core-count-detection-windows/') }
    }
    if ($Manufacturer -ine 'GenuineIntel') { return New-EmptyCpuPlan $Manufacturer 'CPU vendor is not supported by a hardware-derived plan; keep normal scheduling.' 1 }
    $classes = @($rows | Select-Object -ExpandProperty EfficiencyClass -Unique | Sort-Object)
    if ($classes.Count -lt 2) { return New-EmptyCpuPlan $Manufacturer 'Windows reports a homogeneous CPU layout; no affinity or corelimit is needed.' 1 }
    foreach ($physical in @($rows | Group-Object CoreKey)) {
        if (@($physical.Group | Select-Object -ExpandProperty EfficiencyClass -Unique).Count -ne 1) {
            return New-EmptyCpuPlan $Manufacturer 'SMT siblings disagree on performance class; no CPU restriction will be added.' 1
        }
    }
    $highest = [int]$classes[-1]
    $performance = @($rows | Where-Object { $_.EfficiencyClass -eq $highest })
    if (@($performance | Where-Object { ($_.Flags -band 10) -ne 0 }).Count -ne 0) {
        return New-EmptyCpuPlan $Manufacturer 'Performance CPU sets are exclusively allocated or real-time; keep normal scheduling.' 1
    }
    $physicalCount = @($performance | Select-Object -ExpandProperty CoreKey -Unique).Count
    if ($physicalCount -lt 2) { return New-EmptyCpuPlan $Manufacturer 'Fewer than two performance cores are exposed; a restricted game worker budget is not verified.' 1 }
    $mask = [uint64]0
    foreach ($row in $performance) { $mask = [uint64]($mask -bor ([uint64]1 -shl [int]$row.LogicalProcessorIndex)) }
    $hex = $mask.ToString('X', [Globalization.CultureInfo]::InvariantCulture)
    $notes = @('CPU selection is derived from Windows efficiency classes, not a CPU model name or a fixed mask.',
        'Parking can change dynamically; all performance-core SMT siblings remain selected.',
        'This workaround is optional and does not establish a universal crash or stutter cure.')
    $description = 'Intel hybrid layout: {0} physical performance cores / {1} logical processors; use affinity {2} and -corelimit={0}.' -f $physicalCount,$performance.Count,$hex
    return [pscustomobject]@{ Apply = $true; ApplyAffinity = $true; Applicable = $true; IsIntelHybrid = $true; IsAmdWorkerBudget = $false; Experimental = $false; Manufacturer = $Manufacturer
        Description = $description; Reason = $description; GroupCount = 1; AffinityMask = $mask; AffinityMaskHex = $hex
        CoreLimit = $physicalCount; PerformancePhysicalCores = $physicalCount; PerformanceLogicalProcessors = $performance.Count
        TotalPhysicalCores = @($rows | Select-Object -ExpandProperty CoreKey -Unique).Count; TotalLogicalProcessors = $rows.Count
        EfficiencyClass = $highest; Notes = $notes }
}
function Get-ManeaterCpuPlan {
    [CmdletBinding()]
    param()
    $topology = Get-WindowsCpuTopology
    if (-not $topology.Succeeded) { return New-EmptyCpuPlan '' ('CPU enumeration unavailable: ' + $topology.Error + ' Keep normal scheduling.') }
    return Get-CpuLaunchPlan -CpuSets $topology.CpuSets -Manufacturer $topology.Manufacturer -ActiveGroupCount $topology.ActiveGroupCount -ProcessorName $topology.ProcessorName
}

# Argument spans preserve original game-argument quoting (including UE's
# -ExecCmds="value with spaces"). Native argv parsing is used only to classify
# tokens; arbitrary shell programs/operators are never accepted as wrappers.
function Get-LaunchTokenSpans {
    param([string]$Text)
    Initialize-CpuPlanNative
    $native = @([ManeaterCpuPlan.NativeV1]::ParseArguments($Text)); $spans = @(); $index = 0
    while ($index -lt $Text.Length) {
        while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) { ++$index }
        if ($index -eq $Text.Length) { break }
        $start = $index; $quoted = $false; $slashes = 0
        while ($index -lt $Text.Length) {
            $character = $Text[$index]
            if ($character -eq '"' -and ($slashes % 2) -eq 0) { $quoted = -not $quoted }
            if (-not $quoted -and [char]::IsWhiteSpace($character)) { break }
            if ($character -eq '\') { ++$slashes } else { $slashes = 0 }
            ++$index
        }
        if ($quoted) { throw 'Existing launch arguments have unmatched quotes.' }
        $spans += [pscustomobject]@{ Start = $start; Length = $index - $start; Raw = $Text.Substring($start,$index-$start) }
    }
    if ($spans.Count -ne $native.Count) { throw 'Existing launch arguments use unsupported quoting.' }
    for ($index = 0; $index -lt $spans.Count; ++$index) { $spans[$index] | Add-Member -NotePropertyName Value -NotePropertyValue ([string]$native[$index]) }
    return @($spans)
}
function Get-KnownGameArguments {
    param([string]$ExistingOptions)
    $text = $ExistingOptions.Trim(); $managedCpu = $false; $knownWrapper = $false
    if ($text -match '^(?i:cmd(?:\.exe)?)\s+') {
        if ($text -notmatch '^(?i:cmd(?:\.exe)?)\s+(?:(?i:/d|/s|/v:off)\s+)*(?i:/c)\s+"(?<body>.*)"$') { throw 'Existing command wrapper is unsupported; it will not be overwritten.' }
        $body = $Matches.body
        $maskPattern = '(?::?~0x20000000|~0x200000200000000)'
        if ($body -notmatch ('^(?i:set)\s+(?:"(?i:OPENSSL_ia32cap)=(?<mask>' + $maskPattern + ')"|(?i:OPENSSL_ia32cap)=(?<mask>' + $maskPattern + '))\s*&&\s*(?<launch>.+)$')) {
            throw 'Existing wrapper is not a recognized process-scoped OpenSSL workaround; preserve it for manual review.'
        }
        $launch = $Matches.launch; $knownWrapper = $true
        if($launch -match '^(?i:set)\s+"(?i:MANEATER_FIX_ALLOW_UNTESTED)=(?<optin>[01])"\s*&&\s*(?<game>.+)$'){
            $launch=$Matches.game
            # The untested-build flag existed on wrappers with manual user
            # budgets. Only this dedicated AMD marker owns a worker-only
            # corelimit; older affinity wrappers remain recognized below.
            if($launch -match '^(?i:set)\s+"(?i:MANEATER_FIX_CPU_MANAGED)=1"\s*&&\s*(?<game>.+)$'){$launch=$Matches.game;$managedCpu=$true}
        }
        if ($launch -match '^(?i:start)\s+') {
            $tokens = @(Get-LaunchTokenSpans $launch); $commandIndex = -1; $titleCount = 0; $seenWait = $false; $seenB = $false; $seenAffinity = $false
            for ($index = 1; $index -lt $tokens.Count; ++$index) {
                $value = $tokens[$index].Value
                if ($value -ceq '%command%') { $commandIndex = $index; break }
                if ($value -eq '') { ++$titleCount; if ($titleCount -gt 1) { throw 'Unsupported start wrapper title.' }; continue }
                if ($value -ieq '/wait' -and -not $seenWait) { $seenWait = $true; continue }
                if ($value -ieq '/b' -and -not $seenB) { $seenB = $true; continue }
                if ($value -ieq '/affinity' -and -not $seenAffinity) {
                    ++$index
                    if ($index -ge $tokens.Count -or $tokens[$index].Value -notmatch '^[0-9A-Fa-f]{1,16}$') { throw 'Unsupported start affinity value.' }
                    $seenAffinity = $true; $managedCpu = $true; continue
                }
                throw 'Existing start wrapper contains unsupported switches or commands.'
            }
            if ($commandIndex -lt 0 -or $titleCount -ne 1 -or -not $seenWait) { throw 'Existing start wrapper must have an empty title, /wait, and %command%.' }
            $after = $tokens[$commandIndex].Start + $tokens[$commandIndex].Length
            $text = $launch.Substring($after).Trim()
        } elseif ($launch -match '^%command%(?:\s+(?<args>.*))?$') { $text = if ($Matches.ContainsKey('args')) { [string]$Matches['args'] } else { '' } }
        else { throw 'Existing wrapper contains an unsupported launch command.' }
    } elseif ($text -match '^%command%(?:\s+(?<args>.*))?$') { $text = if ($Matches.ContainsKey('args')) { [string]$Matches['args'] } else { '' } }
    if ($text -match '[&|<>^%!\r\n]') { throw 'Existing game arguments contain shell operators or expansion; they will not be overwritten.' }
    $tokens = @(Get-LaunchTokenSpans $text)
    if ($tokens.Count -gt 0 -and $tokens[0].Value -match '^(?i:cmd(?:\.exe)?|powershell(?:\.exe)?|pwsh(?:\.exe)?)$') { throw 'Existing launch options invoke an unsupported shell program.' }
    $remove = @()
    if ($managedCpu) {
        foreach ($token in $tokens) { if ($token.Value -match '^(?i:-corelimit)=\d+$') { $remove += $token } }
        foreach ($token in @($remove | Sort-Object Start -Descending)) { $text = $text.Remove($token.Start,$token.Length) }
    }
    return [pscustomobject]@{ Arguments = $text.Trim(); KnownWrapper = $knownWrapper; RegeneratedManagedCpu = $managedCpu }
}
function New-GameLaunchPlan {
    [CmdletBinding()]
    param([string]$ExistingOptions = '', [Parameter(Mandatory = $true)]$CpuPlan, [string]$ExePath,
          [bool]$EnableOpenSsl = $true, [bool]$IncludeCpuPlan = $true, [switch]$AllowUntestedBuild)
    $parsed = Get-KnownGameArguments $ExistingOptions
    $arguments = $parsed.Arguments; $cpuApplied = $IncludeCpuPlan -and [bool]$CpuPlan.Apply; $hasCoreLimit = $false
    # Legacy/mocked Intel plans did not expose ApplyAffinity. Preserve their
    # prior behavior, while Ryzen plans explicitly leave placement to Windows.
    $applyAffinity = $true
    if ($cpuApplied -and $null -ne $CpuPlan.PSObject.Properties['ApplyAffinity']) {
        if ($CpuPlan.ApplyAffinity -isnot [bool]) { throw 'CPU affinity choice must be an explicit boolean.' }
        $applyAffinity = $CpuPlan.ApplyAffinity
        if (-not $applyAffinity -and ($null -eq $CpuPlan.PSObject.Properties['IsAmdWorkerBudget'] -or
            $null -eq $CpuPlan.PSObject.Properties['Experimental'] -or $null -eq $CpuPlan.PSObject.Properties['Manufacturer'] -or
            $null -eq $CpuPlan.PSObject.Properties['ProcessorName'] -or $CpuPlan.IsAmdWorkerBudget -isnot [bool] -or
            $CpuPlan.Experimental -isnot [bool] -or -not $CpuPlan.IsAmdWorkerBudget -or -not $CpuPlan.Experimental -or
            $CpuPlan.Manufacturer -ine 'AuthenticAMD' -or $CpuPlan.ProcessorName -notmatch '(?i:\bRyzen\b)')) {
            throw 'Worker-only CPU plan must explicitly identify an experimental AMD Ryzen budget.'
        }
        if (-not $applyAffinity -and ($null -eq $CpuPlan.PSObject.Properties['TotalPhysicalCores'] -or
            $null -eq $CpuPlan.PSObject.Properties['TotalLogicalProcessors'] -or $CpuPlan.TotalPhysicalCores -notmatch '^\d+$' -or
            $CpuPlan.TotalLogicalProcessors -notmatch '^\d+$' -or $CpuPlan.CoreLimit -notmatch '^\d+$' -or
            [long]$CpuPlan.TotalPhysicalCores -ne [long]$CpuPlan.CoreLimit -or [long]$CpuPlan.TotalLogicalProcessors -gt 64 -or
            [long]$CpuPlan.TotalLogicalProcessors -le [long]$CpuPlan.TotalPhysicalCores -or
            [long]$CpuPlan.TotalLogicalProcessors -gt (2 * [long]$CpuPlan.TotalPhysicalCores))) {
            throw 'AMD worker-only plan has inconsistent physical-core and SMT counts.'
        }
    }
    $affinityApplied = $cpuApplied -and $applyAffinity
    if ($cpuApplied) {
        if ($CpuPlan.GroupCount -ne 1 -or $CpuPlan.CoreLimit -notmatch '^\d+$' -or $CpuPlan.CoreLimit -lt 2 -or $CpuPlan.CoreLimit -gt 64) {
            throw 'CPU worker budget is not safe for a single-group launch.'
        }
        if ($affinityApplied -and ($CpuPlan.AffinityMaskHex -notmatch '^[0-9A-Fa-f]{1,16}$' -or
            [Convert]::ToUInt64($CpuPlan.AffinityMaskHex,16) -eq 0)) { throw 'CPU affinity plan is not safe for a single-group launch.' }
        foreach ($token in @(Get-LaunchTokenSpans $arguments)) {
            if ($token.Value -match '^(?i:-corelimit)=(?<limit>\d+)$') {
                if ([long]$Matches.limit -ne $CpuPlan.CoreLimit) { throw 'Existing -corelimit conflicts with the hardware-derived plan; it will not be overwritten.' }
                $hasCoreLimit = $true
            } elseif ($token.Value -match '^(?i:-corelimit|-numthreads|-useallavailablecores|-usehyperthreading|-onethread)(?:=|$)') {
                throw 'Existing thread-budget arguments need review before applying the CPU plan.'
            }
        }
        if (-not $hasCoreLimit) { $arguments = (($arguments + ' -corelimit=' + $CpuPlan.CoreLimit).Trim()) }
    }
    $prefix = if ($EnableOpenSsl) { 'set "OPENSSL_ia32cap=:~0x20000000" && ' } else { '' }
    $experimental=$(if($AllowUntestedBuild){'1'}else{'0'})
    $prefix += 'set "MANEATER_FIX_ALLOW_UNTESTED=' + $experimental + '" && '
    # A matching manual corelimit is borrowed, not claimed. Only limits we
    # appended (including removed/recreated owned limits) get this marker.
    $managedAmdBudget = $cpuApplied -and -not $affinityApplied -and -not $hasCoreLimit
    if ($managedAmdBudget) { $prefix += 'set "MANEATER_FIX_CPU_MANAGED=1" && ' }
    $start = 'start "" /b /wait'
    if ($affinityApplied) { $start += ' /affinity ' + $CpuPlan.AffinityMaskHex.ToUpperInvariant() }
    $tail = if ($arguments.Length -ne 0) { ' ' + $arguments } else { '' }
    $steamBody = $prefix + $start + ' %command%' + $tail
    $steam = 'cmd /d /v:off /s /c "' + $steamBody + '"'
    $direct = $null
    if (-not [string]::IsNullOrWhiteSpace($ExePath)) {
        if (-not [IO.Path]::IsPathRooted($ExePath) -or $ExePath -match '["%\r\n]') { throw 'Game executable path must be absolute and safe for cmd quoting.' }
        $exe = [IO.Path]::GetFullPath($ExePath)
        if ([IO.Path]::GetExtension($exe) -ine '.exe') { throw 'Select the game executable.' }
        $direct = '/d /v:off /s /c "' + $prefix + $start + ' /d "' + [IO.Path]::GetDirectoryName($exe) + '" "' + $exe + '"' + $tail + '"'
    }
    return [pscustomobject]@{ SteamLaunchOptions = $steam; CmdArguments = $direct; CpuApplied = $cpuApplied; AffinityApplied = $affinityApplied
        GameArguments = $arguments; PreservedExistingArguments = $parsed.Arguments; RecognizedExistingWrapper = $parsed.KnownWrapper
        RegeneratedManagedCpu = $parsed.RegeneratedManagedCpu; UntestedBuildOptIn=[bool]$AllowUntestedBuild; EnvironmentOverrides = $(
            $overrides = @{MANEATER_FIX_ALLOW_UNTESTED=$experimental}
            if ($EnableOpenSsl) { $overrides.OPENSSL_ia32cap=':~0x20000000' }
            if ($managedAmdBudget) { $overrides.MANEATER_FIX_CPU_MANAGED='1' }
            $overrides
        )
        Description = 'Changes are scoped to this launched process; no system environment or CPU settings are changed.' }
}
function New-ManeaterLaunchOptions {
    [CmdletBinding()]
    param([string]$ExistingOptions = '', [Parameter(Mandatory = $true)]$CpuPlan, [switch]$AllowUntestedBuild)
    return (New-GameLaunchPlan -ExistingOptions $ExistingOptions -CpuPlan $CpuPlan -AllowUntestedBuild:$AllowUntestedBuild).SteamLaunchOptions
}
Export-ModuleMember -Function ConvertFrom-CpuSetBuffer, Get-WindowsCpuTopology, Get-CpuLaunchPlan, Get-ManeaterCpuPlan, New-GameLaunchPlan, New-ManeaterLaunchOptions
