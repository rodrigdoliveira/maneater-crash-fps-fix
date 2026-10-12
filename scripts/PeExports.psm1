Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ByteRange {
    param([byte[]]$Bytes, [long]$Offset, [long]$Length)
    if ($Offset -lt 0 -or $Length -lt 0 -or $Offset -gt $Bytes.LongLength -or $Length -gt ($Bytes.LongLength - $Offset)) {
        throw 'Malformed PE: a required byte range is outside the file.'
    }
}
function Read-U16 {
    param([byte[]]$Bytes, [long]$Offset)
    Assert-ByteRange $Bytes $Offset 2
    return [BitConverter]::ToUInt16($Bytes, [int]$Offset)
}
function Read-U32 {
    param([byte[]]$Bytes, [long]$Offset)
    Assert-ByteRange $Bytes $Offset 4
    return [BitConverter]::ToUInt32($Bytes, [int]$Offset)
}
function Convert-RvaOffset {
    param([byte[]]$Bytes, [object[]]$Sections, [long]$HeaderSize, [long]$Rva, [long]$Length)
    if ($Rva -lt 0 -or $Length -lt 1) { throw 'Malformed PE: invalid RVA range.' }
    if ($Rva -lt $HeaderSize -and $Length -le ($HeaderSize - $Rva)) {
        Assert-ByteRange $Bytes $Rva $Length
        return $Rva
    }
    foreach ($section in $Sections) {
        $difference = $Rva - $section.VirtualAddress
        if ($difference -ge 0 -and $difference -lt [Math]::Max($section.VirtualSize, $section.RawSize)) {
            if ($difference -gt $section.RawSize -or $Length -gt ($section.RawSize - $difference)) {
                throw 'Malformed PE: RVA points to zero-fill or beyond its raw section.'
            }
            $offset = $section.RawOffset + $difference
            Assert-ByteRange $Bytes $offset $Length
            return $offset
        }
    }
    throw 'Malformed PE: RVA does not map to a file section.'
}
function Read-PeAscii {
    param([byte[]]$Bytes, [object[]]$Sections, [long]$HeaderSize, [long]$Rva)
    $characters = New-Object 'System.Collections.Generic.List[byte]'
    for ($index = 0; $index -lt 4096; ++$index) {
        $offset = Convert-RvaOffset $Bytes $Sections $HeaderSize ($Rva + $index) 1
        $value = $Bytes[[int]$offset]
        if ($value -eq 0) {
            if ($characters.Count -eq 0) { throw 'Malformed PE: empty export string.' }
            return [Text.Encoding]::ASCII.GetString($characters.ToArray())
        }
        if ($value -gt 127) { throw 'Unsupported PE: export strings must be ASCII.' }
        $characters.Add($value)
    }
    throw 'Malformed PE: unterminated export string.'
}
function Get-ExportContractHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Exports)
    $lines = @($Exports | Sort-Object Ordinal, Name | ForEach-Object { "{0}`t{1}" -f $_.Ordinal, $_.Name })
    $canonical = ($lines -join "`n") + "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-', '') }
    finally { $sha.Dispose() }
}
function Get-PeExportTable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    $file = Get-Item -LiteralPath $resolved
    if ($file.PSIsContainer -or $file.Length -gt 33554432) { throw 'Unsupported PE: expected a DLL no larger than 32 MiB.' }
    $bytes = [IO.File]::ReadAllBytes($resolved)
    if ((Read-U16 $bytes 0) -ne 0x5a4d) { throw 'Malformed PE: DOS signature is missing.' }
    $pe = [long](Read-U32 $bytes 60)
    if ((Read-U32 $bytes $pe) -ne 0x4550) { throw 'Malformed PE: NT signature is missing.' }
    $machine = Read-U16 $bytes ($pe + 4)
    $sectionCount = Read-U16 $bytes ($pe + 6)
    $optionalSize = Read-U16 $bytes ($pe + 20)
    $characteristics = Read-U16 $bytes ($pe + 22)
    $optional = $pe + 24
    Assert-ByteRange $bytes $optional $optionalSize
    if ($machine -ne 0x8664 -or (Read-U16 $bytes $optional) -ne 0x20b) { throw 'Unsupported PE: an AMD64 PE32+ DLL is required.' }
    if (($characteristics -band 0x2000) -eq 0 -or $optionalSize -lt 120 -or $sectionCount -lt 1 -or $sectionCount -gt 96) {
        throw 'Malformed or unsupported PE: invalid DLL headers.'
    }
    if ((Read-U32 $bytes ($optional + 108)) -lt 1) { throw 'Malformed PE: export data directory is missing.' }
    $headerSize = [long](Read-U32 $bytes ($optional + 60))
    $imageSize = [long](Read-U32 $bytes ($optional + 56))
    if ($headerSize -lt ($optional + $optionalSize + 40 * $sectionCount) -or $headerSize -gt $bytes.Length -or $imageSize -lt $headerSize) {
        throw 'Malformed PE: invalid image/header sizes.'
    }
    $sections = @()
    for ($index = 0; $index -lt $sectionCount; ++$index) {
        $at = $optional + $optionalSize + $index * 40
        Assert-ByteRange $bytes $at 40
        $section = [pscustomobject]@{
            VirtualSize = [long](Read-U32 $bytes ($at + 8)); VirtualAddress = [long](Read-U32 $bytes ($at + 12))
            RawSize = [long](Read-U32 $bytes ($at + 16)); RawOffset = [long](Read-U32 $bytes ($at + 20))
            Flags = Read-U32 $bytes ($at + 36)
        }
        Assert-ByteRange $bytes $section.RawOffset $section.RawSize
        if ($section.VirtualAddress -lt $headerSize -or $section.VirtualAddress -ge $imageSize -or
            [Math]::Max($section.VirtualSize, $section.RawSize) -gt ($imageSize - $section.VirtualAddress)) {
            throw 'Malformed PE: section exceeds the image.'
        }
        foreach ($previous in $sections) {
            $extent = [Math]::Max($section.VirtualSize, $section.RawSize)
            $previousExtent = [Math]::Max($previous.VirtualSize, $previous.RawSize)
            if ($section.VirtualAddress -lt ($previous.VirtualAddress + $previousExtent) -and
                $previous.VirtualAddress -lt ($section.VirtualAddress + $extent)) { throw 'Malformed PE: overlapping virtual sections.' }
        }
        $sections += $section
    }
    $exportRva = [long](Read-U32 $bytes ($optional + 112))
    $exportSize = [long](Read-U32 $bytes ($optional + 116))
    if ($exportRva -eq 0 -or $exportSize -lt 40 -or $exportSize -gt ($imageSize - $exportRva)) { throw 'Malformed PE: invalid export directory.' }
    $directory = Convert-RvaOffset $bytes $sections $headerSize $exportRva $exportSize
    $ordinalBase = [long](Read-U32 $bytes ($directory + 16))
    $functionCount = [long](Read-U32 $bytes ($directory + 20))
    $nameCount = [long](Read-U32 $bytes ($directory + 24))
    if ($functionCount -lt 1 -or $functionCount -gt 65535 -or $nameCount -lt 1 -or $nameCount -gt $functionCount -or
        $ordinalBase -lt 1 -or ($ordinalBase + $functionCount - 1) -gt 65535) { throw 'Malformed or unsupported PE: export counts/ordinals are invalid.' }
    $functions = Convert-RvaOffset $bytes $sections $headerSize (Read-U32 $bytes ($directory + 28)) ($functionCount * 4)
    $names = Convert-RvaOffset $bytes $sections $headerSize (Read-U32 $bytes ($directory + 32)) ($nameCount * 4)
    $ordinals = Convert-RvaOffset $bytes $sections $headerSize (Read-U32 $bytes ($directory + 36)) ($nameCount * 2)
    $namedOrdinals = @{}; $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $exports = @()
    for ($index = 0; $index -lt $nameCount; ++$index) {
        $name = Read-PeAscii $bytes $sections $headerSize (Read-U32 $bytes ($names + $index * 4))
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Unsupported PE: an export name cannot be represented safely in this forwarder definition.' }
        if (-not $seenNames.Add($name)) { throw 'Malformed PE: duplicate export name.' }
        $ordinalIndex = [long](Read-U16 $bytes ($ordinals + $index * 2))
        if ($ordinalIndex -ge $functionCount) { throw 'Malformed PE: name ordinal is outside the function table.' }
        if ($namedOrdinals.ContainsKey($ordinalIndex)) { throw 'Unsupported PE: multiple names share an ordinal.' }
        $namedOrdinals[$ordinalIndex] = $true
        $functionRva = [long](Read-U32 $bytes ($functions + $ordinalIndex * 4))
        if ($functionRva -eq 0) { throw 'Malformed PE: named export has no function.' }
        $forwarder = $null
        if ($functionRva -ge $exportRva -and $functionRva -lt ($exportRva + $exportSize)) {
            $forwarder = Read-PeAscii $bytes $sections $headerSize $functionRva
        } else {
            $executable = @($sections | Where-Object { $functionRva -ge $_.VirtualAddress -and
                $functionRva -lt ($_.VirtualAddress + [Math]::Max($_.VirtualSize, $_.RawSize)) -and ($_.Flags -band 0x20000000) -ne 0 })
            if ($executable.Count -ne 1) { throw 'Unsupported PE: an exported function is not executable.' }
        }
        $exports += [pscustomobject]@{ Name = $name; Ordinal = $ordinalBase + $ordinalIndex; Forwarder = $forwarder }
    }
    for ($index = 0; $index -lt $functionCount; ++$index) {
        if ((Read-U32 $bytes ($functions + $index * 4)) -ne 0 -and -not $namedOrdinals.ContainsKey([long]$index)) {
            throw 'Unsupported PE: ordinal-only exports cannot be represented by this source-only forwarder.'
        }
    }
    $exports = @($exports | Sort-Object Ordinal)
    return [pscustomobject]@{ Machine = 'AMD64'; Is64Bit = $true; ExportBase = $ordinalBase; Exports = $exports
        FileSHA256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash; ContractSHA256 = Get-ExportContractHash $exports }
}
function New-DxgiForwarderDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Exports, [Parameter(Mandatory = $true)][string]$Path)
    $lines = @('; Generated from the local Windows DXGI named-export contract.', 'LIBRARY dxgi', 'EXPORTS')
    foreach ($entry in @($Exports | Sort-Object Ordinal)) {
        if ($entry.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $entry.Ordinal -lt 1 -or $entry.Ordinal -gt 65535) { throw 'Invalid forwarder export entry.' }
        $lines += '    {0}=dxgi_codex_system.{0} @{1}' -f $entry.Name, $entry.Ordinal
    }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), ($lines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
}
function Assert-DxgiForwarderTable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Proxy, [Parameter(Mandatory = $true)]$System)
    if ($Proxy.ContractSHA256 -cne $System.ContractSHA256 -or $Proxy.Exports.Count -ne $System.Exports.Count) {
        throw 'DXGI export contract differs; rebuild on this Windows installation.'
    }
    foreach ($entry in $Proxy.Exports) {
        if ($entry.Forwarder -cne ('dxgi_codex_system.' + $entry.Name)) { throw 'Proxy contains an unexpected non-forwarded export.' }
    }
}
function Get-VerifiedWindowsDxgi {
    [CmdletBinding()]
    param()
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
        throw 'Use 64-bit PowerShell on 64-bit Windows.'
    }
    $path = Join-Path ([Environment]::SystemDirectory) 'dxgi.dll'
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw 'The local Windows DXGI DLL must have a valid Microsoft signature.'
    }
    $table = Get-PeExportTable -Path $path
    foreach ($required in @('CreateDXGIFactory', 'CreateDXGIFactory1')) {
        if (@($table.Exports | Where-Object { $_.Name -ceq $required }).Count -ne 1) { throw 'The local DXGI DLL lacks a required game factory export.' }
    }
    return [pscustomobject]@{ Path = $path; Table = $table }
}
Export-ModuleMember -Function Get-PeExportTable, Get-ExportContractHash, New-DxgiForwarderDefinition, Assert-DxgiForwarderTable, Get-VerifiedWindowsDxgi
