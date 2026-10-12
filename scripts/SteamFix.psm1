# Only app 629820 is edited. Context, plans, journals and VDF backups contain
# private paths/account data: keep them local and never include them in reports.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('ManeaterCrashFpsFix.SteamVdf' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
namespace ManeaterCrashFpsFix {
 public sealed class VdfToken {
  public int Start, End; public string Value; public bool UnknownEscape;
 }
 public sealed class VdfPair {
  public VdfToken Key, Value; public VdfNode Child; public int Start, End;
 }
 public sealed class VdfNode {
  public List<VdfPair> Pairs = new List<VdfPair>(); public int OpenStart, CloseStart, End;
 }
 public sealed class VdfPatch {
  public int Start, DeleteCount; public byte[] Replacement;
  public VdfPatch(int start, int count, byte[] replacement) { Start=start; DeleteCount=count; Replacement=replacement; }
 }
 public static class SteamVdf {
  static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
  sealed class Parser {
   readonly byte[] Bytes; int At, Count;
   public Parser(byte[] bytes) {
    if(bytes==null || bytes.Length==0 || bytes.Length>33554432) throw new FormatException("Unsupported VDF size.");
    Bytes=bytes; Utf8.GetString(bytes);
    for(int i=0;i<bytes.Length;i++) if(bytes[i]==0) throw new FormatException("NUL bytes are not supported in VDF.");
    if(bytes.Length>=3 && bytes[0]==239 && bytes[1]==187 && bytes[2]==191) At=3;
   }
   FormatException Bad(string reason) { return new FormatException("VDF parse error at byte "+At+": "+reason); }
   bool Space(byte b) { return b==32 || (b>=9 && b<=13); }
   void Skip() {
    while(At<Bytes.Length) {
     if(Space(Bytes[At])) { At++; continue; }
     if(At+1<Bytes.Length && Bytes[At]==47 && Bytes[At+1]==47) {
      At+=2; while(At<Bytes.Length && Bytes[At]!=10 && Bytes[At]!=13) At++; continue;
     }
     if(At+1<Bytes.Length && Bytes[At]==47 && Bytes[At+1]==42) throw Bad("block comments are unsupported; no file changed");
     break;
    }
   }
   VdfToken Token() {
    Skip(); if(At>=Bytes.Length) throw Bad("missing token");
    if(++Count>500000) throw Bad("too many tokens");
    int begin=At; string raw;
    if(Bytes[At]==34) {
     At++; int content=At; bool closed=false;
     while(At<Bytes.Length) {
      if(Bytes[At]==92) { At++; if(At>=Bytes.Length) throw Bad("trailing escape"); At++; continue; }
      if(Bytes[At]==34) { closed=true; break; } At++;
     }
     if(!closed) throw Bad("unterminated quoted token");
     raw=Utf8.GetString(Bytes,content,At-content); At++;
     StringBuilder decoded=new StringBuilder(); bool unknown=false;
     for(int i=0;i<raw.Length;i++) {
      char c=raw[i]; if(c!='\\') { decoded.Append(c); continue; }
      if(++i>=raw.Length) throw Bad("trailing escape");
      switch(raw[i]) {
       case '\\': decoded.Append('\\'); break; case '"': decoded.Append('"'); break;
       case 'n': decoded.Append('\n'); break; case 'r': decoded.Append('\r'); break;
       case 't': decoded.Append('\t'); break; case 'v': decoded.Append('\v'); break;
       case 'b': decoded.Append('\b'); break; case 'f': decoded.Append('\f'); break;
       case 'a': decoded.Append('\a'); break;
       default: unknown=true; decoded.Append('\\'); decoded.Append(raw[i]); break;
      }
     }
     return new VdfToken {Start=begin,End=At,Value=decoded.ToString(),UnknownEscape=unknown};
    }
    while(At<Bytes.Length && !Space(Bytes[At]) && Bytes[At]!=123 && Bytes[At]!=125 && Bytes[At]!=34) At++;
    if(At==begin) throw Bad("unexpected delimiter");
    raw=Utf8.GetString(Bytes,begin,At-begin);
    if(raw.StartsWith("[",StringComparison.Ordinal) || raw.IndexOf(']')>=0) throw Bad("conditional tokens are unsupported; no file changed");
    return new VdfToken {Start=begin,End=At,Value=raw};
   }
   VdfNode Node(int depth, bool nested) {
    if(depth>64) throw Bad("nesting too deep");
    VdfNode node=new VdfNode();
    if(nested) { node.OpenStart=At; At++; }
    while(true) {
     Skip(); if(At>=Bytes.Length) { if(nested) throw Bad("missing closing brace"); node.End=At; return node; }
     if(Bytes[At]==125) { if(!nested) throw Bad("unexpected closing brace"); node.CloseStart=At; node.End=++At; return node; }
     if(Bytes[At]==123) throw Bad("block without key");
     VdfToken key=Token(); if(key.UnknownEscape) throw Bad("unsupported escape in a key");
     if(String.Equals(key.Value,"#include",StringComparison.OrdinalIgnoreCase) || String.Equals(key.Value,"#base",StringComparison.OrdinalIgnoreCase)) throw Bad("external VDF directives are unsupported; no file changed");
     Skip(); if(At>=Bytes.Length) throw Bad("key without value");
     VdfPair pair=new VdfPair {Key=key,Start=key.Start};
     if(Bytes[At]==123) { pair.Child=Node(depth+1,true); pair.End=pair.Child.End; }
     else { pair.Value=Token(); pair.End=pair.Value.End; }
     node.Pairs.Add(pair);
    }
   }
   public VdfNode Read() { return Node(0,false); }
  }
  public static VdfNode Parse(byte[] bytes) { return new Parser(bytes).Read(); }
  public static VdfPair Unique(VdfNode node, string key, bool required) {
   VdfPair found=null;
   foreach(VdfPair pair in node.Pairs) if(String.Equals(pair.Key.Value,key,StringComparison.OrdinalIgnoreCase)) {
    if(found!=null) throw new FormatException("Ambiguous duplicate VDF key in the selected settings path."); found=pair;
   }
   if(found==null && required) throw new FormatException("A required Steam settings container is missing.");
   return found;
  }
  public static VdfNode Container(VdfNode node, string key) {
   VdfPair pair=Unique(node,key,true); if(pair.Child==null) throw new FormatException("Expected a Steam settings container."); return pair.Child;
  }
  public static VdfNode Apps(VdfNode root) {
   return Container(Container(Container(Container(Container(root,"UserLocalConfigStore"),"Software"),"Valve"),"Steam"),"apps");
  }
  public static byte[] Quote(string value) {
   if(value==null || value.IndexOf('\0')>=0 || value.Length>32767) throw new FormatException("Invalid settings value.");
   StringBuilder result=new StringBuilder("\"");
   foreach(char c in value) {
    switch(c) {
     case '\\': result.Append("\\\\"); break; case '"': result.Append("\\\""); break;
     case '\n': result.Append("\\n"); break; case '\r': result.Append("\\r"); break;
     case '\t': result.Append("\\t"); break; case '\v': result.Append("\\v"); break;
     case '\b': result.Append("\\b"); break; case '\f': result.Append("\\f"); break;
     case '\a': result.Append("\\a"); break;
     default: if(c<32) throw new FormatException("Unsupported control character in settings value."); result.Append(c); break;
    }
   }
   result.Append('"'); return Utf8.GetBytes(result.ToString());
  }
  public static byte[] Slice(byte[] bytes,int start,int count) { byte[] result=new byte[count]; Buffer.BlockCopy(bytes,start,result,0,count); return result; }
  public static string Indent(byte[] bytes,int at) {
   int start=at; while(start>0 && bytes[start-1]!=10 && bytes[start-1]!=13) start--;
   int end=start; while(end<at && (bytes[end]==9 || bytes[end]==32)) end++;
   return Utf8.GetString(bytes,start,end-start);
  }
  public static int CloseLineStart(byte[] bytes,VdfNode node) {
   int start=node.CloseStart; while(start>0 && (bytes[start-1]==9 || bytes[start-1]==32)) start--;
   if(start==0 || bytes[start-1]==10 || bytes[start-1]==13) return start; return node.CloseStart;
  }
  public static string Newline(byte[] bytes) {
   for(int i=0;i<bytes.Length;i++) if(bytes[i]==10) return i>0 && bytes[i-1]==13 ? "\r\n" : "\n";
   return "\r\n";
  }
  public static byte[] Encode(string value) { return Utf8.GetBytes(value); }
  public static byte[] Apply(byte[] bytes,VdfPatch[] patches) {
   Array.Sort(patches,delegate(VdfPatch a,VdfPatch b) { return a.Start.CompareTo(b.Start); });
   using(MemoryStream output=new MemoryStream()) {
    int end=0;
    foreach(VdfPatch patch in patches) {
     if(patch.Start<end || patch.Start<0 || patch.DeleteCount<0 || patch.Start>bytes.Length || patch.DeleteCount>bytes.Length-patch.Start) throw new FormatException("Overlapping or invalid settings patches.");
     output.Write(bytes,end,patch.Start-end); output.Write(patch.Replacement,0,patch.Replacement.Length); end=patch.Start+patch.DeleteCount;
    }
    output.Write(bytes,end,bytes.Length-end); return output.ToArray();
   }
  }
 }
}
'@
}

function Get-SteamFixHash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}
function Read-SteamFixFile {
    param([string]$ConfigPath)
    $path = [IO.Path]::GetFullPath($ConfigPath)
    $item = Get-Item -LiteralPath $path
    if ($item.PSIsContainer -or $item.Length -gt 33554432 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsupported Steam configuration file.' }
    $bytes = [IO.File]::ReadAllBytes($path)
    $tree = [ManeaterCrashFpsFix.SteamVdf]::Parse($bytes)
    return [pscustomobject]@{ Path=$path; Bytes=$bytes; Tree=$tree; Hash=Get-SteamFixHash $bytes }
}
function Get-SteamFixRunningProcesses {
    return @(Get-Process -Name 'steam','steamwebhelper','Maneater','Maneater-Win64-Shipping' -ErrorAction SilentlyContinue)
}
function Assert-SteamFixClosed {
    if (@(Get-SteamFixRunningProcesses).Count -ne 0) { throw 'Steam and Maneater must be completely closed before changing Steam settings.' }
}
function Normalize-SteamFixDirectory {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $volume=[IO.Path]::GetPathRoot($full)
    if ($full -ieq $volume) { return $volume }
    return $full.TrimEnd('\','/')
}
function Get-SteamFixMostRecentAccount {
    param([string]$SteamDirectory)
    $users=Read-SteamFixFile (Join-Path $SteamDirectory 'config\loginusers.vdf')
    $userRoot=[ManeaterCrashFpsFix.SteamVdf]::Container($users.Tree,'users')
    $recent=@(); $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($pair in $userRoot.Pairs) {
        if ($pair.Key.Value -notmatch '^\d+$' -or $null -eq $pair.Child) { throw 'Unrecognized Steam account metadata.' }
        if (-not $seen.Add($pair.Key.Value)) { throw 'Ambiguous duplicate Steam account metadata.' }
        $most=[ManeaterCrashFpsFix.SteamVdf]::Unique($pair.Child,'MostRecent',$false)
        if ($null -ne $most -and ($null -eq $most.Value -or $most.Value.UnknownEscape -or $most.Value.Value -notin @('0','1'))) { throw 'Unsupported Steam account-selection metadata.' }
        if ($null -ne $most -and $most.Value.Value -eq '1') { $recent += $pair }
    }
    if ($recent.Count -ne 1) { throw 'Current Steam account is ambiguous. Capture context while Steam is signed in.' }
    $account=[uint32]([uint64]$recent[0].Key.Value -band [uint64]4294967295)
    if ($account -eq 0) { throw 'Steam account metadata does not identify a usable account.' }
    return $account
}
function Get-SteamFixContext {
    [CmdletBinding()]
    param($Context)
    if ($null -ne $Context) {
        $steam = [IO.Path]::GetFullPath([string]$Context.SteamDirectory)
        $account = [uint32]$Context.AccountId
        if ($account -eq 0) { throw 'The saved Steam account context is invalid.' }
    } else {
        $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Valve\Steam')
        if ($null -eq $registry) { throw 'Steam was not found for the current Windows user.' }
        try { $steamValue=[string]$registry.GetValue('SteamPath'); $active=$registry.OpenSubKey('ActiveProcess'); $account=[uint32]0
            if ($null -ne $active) { try { $account=[uint32]([long]$active.GetValue('ActiveUser',0) -band [long]4294967295) } finally { $active.Dispose() } }
        } finally { $registry.Dispose() }
        if ([string]::IsNullOrWhiteSpace($steamValue)) { throw 'Steam directory was not found.' }
        $steam = [IO.Path]::GetFullPath($steamValue)
        if ($account -eq 0) {
            # Account IDs are the low 32 bits of an individual SteamID. This
            # private value is used only to locate that user's settings file.
            $account=Get-SteamFixMostRecentAccount $steam
        }
    }
    $exe = Join-Path $steam 'steam.exe'
    $config = Join-Path $steam ('userdata\' + $account.ToString([Globalization.CultureInfo]::InvariantCulture) + '\config\localconfig.vdf')
    if (-not [IO.File]::Exists($exe) -or -not [IO.File]::Exists($config)) { throw 'Steam executable or current-account settings file was not found.' }
    if ($null -ne $Context -and [IO.Path]::GetFullPath([string]$Context.ConfigPath) -ine [IO.Path]::GetFullPath($config)) { throw 'The saved Steam account context does not match its settings path.' }
    return [pscustomobject]@{ SteamDirectory=$steam; SteamExe=$exe; ConfigPath=[IO.Path]::GetFullPath($config); AccountId=$account }
}
function Get-SteamFixField {
    param($Node,[string]$Name,[byte[]]$Bytes)
    $pair = $null
    if ($null -ne $Node) { $pair=[ManeaterCrashFpsFix.SteamVdf]::Unique($Node,$Name,$false) }
    if ($null -eq $pair) { return [pscustomobject]@{ Name=$Name; Exists=$false; Value=$null; RawTokenBase64=$null; Pair=$null } }
    if ($null -eq $pair.Value -or $pair.Value.UnknownEscape) { throw 'A selected Steam app value has an unsupported type or escape.' }
    return [pscustomobject]@{ Name=$Name; Exists=$true; Value=$pair.Value.Value; RawTokenBase64=[Convert]::ToBase64String([ManeaterCrashFpsFix.SteamVdf]::Slice($Bytes,$pair.Value.Start,$pair.Value.End-$pair.Value.Start)); Pair=$pair }
}
function Get-SteamFixSnapshot {
    param([string]$ConfigPath)
    $file=Read-SteamFixFile $ConfigPath
    $apps=[ManeaterCrashFpsFix.SteamVdf]::Apps($file.Tree)
    $app=[ManeaterCrashFpsFix.SteamVdf]::Unique($apps,'629820',$false)
    if ($null -ne $app -and $null -eq $app.Child) { throw 'Maneater app settings must be a VDF container.' }
    $node=$null; if ($null -ne $app) { $node=$app.Child }
    $root=[ManeaterCrashFpsFix.SteamVdf]::Container($file.Tree,'UserLocalConfigStore')
    $overlayAppsPair=[ManeaterCrashFpsFix.SteamVdf]::Unique($root,'apps',$false)
    $overlayApps=$null; $overlayApp=$null; $overlayNode=$null
    if ($null -ne $overlayAppsPair) {
        if ($null -eq $overlayAppsPair.Child) { throw 'Steam overlay app settings must be a VDF container.' }
        $overlayApps=$overlayAppsPair.Child
        $overlayApp=[ManeaterCrashFpsFix.SteamVdf]::Unique($overlayApps,'629820',$false)
        if ($null -ne $overlayApp) {
            if ($null -eq $overlayApp.Child) { throw 'Maneater overlay app settings must be a VDF container.' }
            $overlayNode=$overlayApp.Child
        }
    }
    return [pscustomobject]@{ File=$file; Root=$root; Apps=$apps; App=$app; Node=$node;
        OverlayApps=$overlayApps; OverlayApp=$overlayApp; OverlayNode=$overlayNode;
        Launch=Get-SteamFixField $node 'LaunchOptions' $file.Bytes; Overlay=Get-SteamFixField $overlayNode 'OverlayAppEnable' $file.Bytes }
}
function Get-SteamFixStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ConfigPath)
    $snapshot=Get-SteamFixSnapshot $ConfigPath
    $running=@(Get-SteamFixRunningProcesses)
    return [pscustomobject]@{ AppId='629820'; AppNodeExists=$null -ne $snapshot.App; ConfigSHA256=$snapshot.File.Hash;
        LaunchOptionsPresent=$snapshot.Launch.Exists; ExistingLaunchOptions=$snapshot.Launch.Value;
        OverlayPresent=$snapshot.Overlay.Exists; ExistingOverlay=$snapshot.Overlay.Value;
        SteamRunning=@($running | Where-Object { $_.ProcessName -in @('steam','steamwebhelper') }).Count -ne 0;
        GameRunning=@($running | Where-Object { $_.ProcessName -in @('Maneater','Maneater-Win64-Shipping') }).Count -ne 0 }
}
function New-SteamFixMissingPatch {
    param($Snapshot,[string]$Scope,[object[]]$Fields)
    $bytes=$Snapshot.File.Bytes; $newline=[ManeaterCrashFpsFix.SteamVdf]::Newline($bytes)
    $parent=$Snapshot.Apps; $app=$Snapshot.App; $node=$Snapshot.Node
    if ($Scope -eq 'overlay') { $parent=$Snapshot.OverlayApps; $app=$Snapshot.OverlayApp; $node=$Snapshot.OverlayNode }
    if ($null -ne $node) {
        $indent=[ManeaterCrashFpsFix.SteamVdf]::Indent($bytes,$app.Key.Start) + "`t"
        if ($node.Pairs.Count -ne 0) { $indent=[ManeaterCrashFpsFix.SteamVdf]::Indent($bytes,$node.Pairs[0].Key.Start) }
        $at=[ManeaterCrashFpsFix.SteamVdf]::CloseLineStart($bytes,$node)
        $insert=''; if ($at -eq $node.CloseStart) { $insert=$newline }
        foreach ($field in $Fields) { $insert += $indent + '"' + $field.Name + '"' + "`t`t" + $field.Token + $newline }
        if ($at -eq $node.CloseStart) { $insert += [ManeaterCrashFpsFix.SteamVdf]::Indent($bytes,$app.Key.Start) }
    } else {
        $addApps=$null -eq $parent
        if ($addApps) { $parent=$Snapshot.Root }
        $at=[ManeaterCrashFpsFix.SteamVdf]::CloseLineStart($bytes,$parent)
        $parentIndent=[ManeaterCrashFpsFix.SteamVdf]::Indent($bytes,$parent.CloseStart)
        $indent=$parentIndent + "`t"; $insert=''; if ($at -eq $parent.CloseStart) { $insert=$newline }
        if ($addApps) { $insert += $indent + '"apps"' + $newline + $indent + '{' + $newline; $indent += "`t" }
        $insert += $indent + '"629820"' + $newline + $indent + '{' + $newline
        foreach ($field in $Fields) { $insert += $indent + "`t" + '"' + $field.Name + '"' + "`t`t" + $field.Token + $newline }
        $insert += $indent + '}' + $newline
        if ($addApps) { $insert += $parentIndent + "`t" + '}' + $newline }
        if ($at -eq $parent.CloseStart) { $insert += $parentIndent }
    }
    return [ManeaterCrashFpsFix.VdfPatch]::new($at,0,[ManeaterCrashFpsFix.SteamVdf]::Encode($insert))
}
function New-SteamFixPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ConfigPath,[Parameter(Mandatory=$true)][AllowEmptyString()][string]$LaunchOptions)
    $snapshot=Get-SteamFixSnapshot $ConfigPath
    $patches=New-Object 'System.Collections.Generic.List[ManeaterCrashFpsFix.VdfPatch]'
    $fields=@(); $missing=@{launch=@();overlay=@()}
    foreach ($entry in @(@{ Original=$snapshot.Launch; Applied=$LaunchOptions; Scope='launch' },@{ Original=$snapshot.Overlay; Applied='0'; Scope='overlay' })) {
        $old=$entry.Original; $new=[string]$entry.Applied
        $quoted=[ManeaterCrashFpsFix.SteamVdf]::Quote($new)
        $changed=(-not $old.Exists) -or $old.Value -cne $new
        $fields += [pscustomobject]@{ Name=$old.Name; Scope=$entry.Scope; Changed=$changed;
            Original=[pscustomobject]@{ Exists=$old.Exists; Value=$old.Value; RawTokenBase64=$old.RawTokenBase64 };
            Applied=[pscustomobject]@{ Exists=$true; Value=$new } }
        if ($changed -and $old.Exists) { $patches.Add([ManeaterCrashFpsFix.VdfPatch]::new($old.Pair.Value.Start,$old.Pair.Value.End-$old.Pair.Value.Start,$quoted)) }
        elseif ($changed) { $missing[$entry.Scope] += [pscustomobject]@{ Name=$old.Name; Token=[Text.Encoding]::UTF8.GetString($quoted) } }
    }
    foreach ($scope in @('launch','overlay')) { if ($missing[$scope].Count -ne 0) { $patches.Add((New-SteamFixMissingPatch $snapshot $scope $missing[$scope])) } }
    $applied=[ManeaterCrashFpsFix.SteamVdf]::Apply($snapshot.File.Bytes,$patches.ToArray())
    # Validate generated VDF before offering the plan to a caller.
    [ManeaterCrashFpsFix.SteamVdf]::Parse($applied) | Out-Null
    return [pscustomobject]@{ SchemaVersion=2; AppId='629820'; ConfigPath=$snapshot.File.Path;
        OriginalSHA256=$snapshot.File.Hash; AppliedSHA256=Get-SteamFixHash $applied;
        AppNodeOriginallyPresent=$null -ne $snapshot.App; OverlayAppNodeOriginallyPresent=$null -ne $snapshot.OverlayApp; Fields=$fields; HasChanges=$patches.Count -ne 0;
        Patches=@($patches | ForEach-Object { [pscustomobject]@{ Start=$_.Start; DeleteCount=$_.DeleteCount; ReplacementBase64=[Convert]::ToBase64String($_.Replacement) } }) }
}
function Write-SteamFixJournal {
    param($Record,[string]$Path)
    $temporary=$Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($Record | ConvertTo-Json -Depth 10) + "`n",[Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) } else { [IO.File]::Move($temporary,$Path) }
    } finally { if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary } }
}
function Set-SteamFixBytes {
    param([string]$Path,[byte[]]$Bytes,[string]$ExpectedHash)
    $temporary=Join-Path ([IO.Path]::GetDirectoryName($Path)) ('localconfig.fix-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporary,$Bytes)
        Assert-SteamFixClosed
        if ((Get-SteamFixHash ([IO.File]::ReadAllBytes($Path))) -cne $ExpectedHash) { throw 'Steam configuration changed concurrently; no replacement made.' }
        [IO.File]::Replace($temporary,$Path,[NullString]::Value)
    } finally { if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary } }
}
function Invoke-SteamFixPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Plan,[Parameter(Mandatory=$true)][string]$BackupDirectory)
    Assert-SteamFixClosed
    if ($Plan.SchemaVersion -ne 2 -or $Plan.AppId -ne '629820') { throw 'Unsupported Steam fix plan.' }
    $snapshot=Get-SteamFixSnapshot ([string]$Plan.ConfigPath)
    if ($snapshot.File.Hash -cne $Plan.OriginalSHA256) { throw 'Steam configuration changed since planning; create a new plan.' }
    # Recompute the plan from semantic values instead of trusting serialized offsets.
    $launch=@($Plan.Fields | Where-Object { $_.Name -ceq 'LaunchOptions' })
    if ($launch.Count -ne 1) { throw 'Invalid Steam fix field plan.' }
    $verified=New-SteamFixPlan $snapshot.File.Path ([string]$launch[0].Applied.Value)
    if ($verified.AppliedSHA256 -cne $Plan.AppliedSHA256) { throw 'Steam fix plan does not match the current configuration.' }
    $patches=@($verified.Patches | ForEach-Object { [ManeaterCrashFpsFix.VdfPatch]::new([int]$_.Start,[int]$_.DeleteCount,[Convert]::FromBase64String($_.ReplacementBase64)) })
    $bytes=[ManeaterCrashFpsFix.SteamVdf]::Apply($snapshot.File.Bytes,[ManeaterCrashFpsFix.VdfPatch[]]$patches)
    $directory=[IO.Path]::GetFullPath($BackupDirectory)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $backup=Join-Path $directory 'steam-localconfig.original.vdf'; $journal=Join-Path $directory 'steam-fix.json'
    if (Test-Path -LiteralPath $backup) { throw 'Existing Steam backup preserved; use a fresh recovery directory.' }
    if (Test-Path -LiteralPath $journal) { throw 'Existing Steam recovery journal preserved; use a fresh recovery directory.' }
    [IO.File]::WriteAllBytes($backup,$snapshot.File.Bytes)
    if ((Get-SteamFixHash ([IO.File]::ReadAllBytes($backup))) -cne $verified.OriginalSHA256) { throw 'Steam backup verification failed; configuration unchanged.' }
    $record=[pscustomobject]@{ SchemaVersion=2; AppId='629820'; State='prepared'; ConfigPath=$snapshot.File.Path;
        OriginalSHA256=$verified.OriginalSHA256; AppliedSHA256=$verified.AppliedSHA256;
        BackupPath=$backup; JournalPath=$journal; Fields=$verified.Fields; HasChanges=$verified.HasChanges;
        AppNodeOriginallyPresent=$verified.AppNodeOriginallyPresent; PreparedUTC=[DateTime]::UtcNow.ToString('o') }
    Write-SteamFixJournal $record $journal  # must succeed before Steam mutation
    if ($verified.HasChanges) { Set-SteamFixBytes $snapshot.File.Path $bytes $verified.OriginalSHA256 }
    $record.State='applied'; Write-SteamFixJournal $record $journal
    return $record
}
function Restore-SteamFix {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Record)
    Assert-SteamFixClosed
    if ($Record -is [string]) { $Record=Get-Content -LiteralPath $Record -Raw | ConvertFrom-Json }
    if ($Record.SchemaVersion -ne 2 -or $Record.AppId -ne '629820' -or $Record.OriginalSHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or $Record.AppliedSHA256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Unsupported Steam recovery record.' }
    $snapshot=Get-SteamFixSnapshot ([string]$Record.ConfigPath)
    $backup=[IO.File]::ReadAllBytes([string]$Record.BackupPath)
    if ((Get-SteamFixHash $backup) -ine $Record.OriginalSHA256) { throw 'Steam backup changed; no configuration restored.' }
    $launch=@($Record.Fields | Where-Object { $_.Name -ceq 'LaunchOptions' })
    if ($launch.Count -ne 1) { throw 'Invalid Steam recovery field plan.' }
    $verified=New-SteamFixPlan ([string]$Record.BackupPath) ([string]$launch[0].Applied.Value)
    if ($verified.OriginalSHA256 -cne $Record.OriginalSHA256 -or $verified.AppliedSHA256 -cne $Record.AppliedSHA256) { throw 'Steam recovery values do not match the verified backup and applied configuration.' }
    if ($snapshot.File.Hash -ieq $Record.OriginalSHA256) { $Record.State='restored'; Write-SteamFixJournal $Record ([string]$Record.JournalPath); return [pscustomobject]@{ State='restored'; Mode='already-original'; PreservedForeignFields=@(); Record=$Record } }
    if ($snapshot.File.Hash -ieq $Record.AppliedSHA256) {
        Set-SteamFixBytes $snapshot.File.Path $backup $snapshot.File.Hash
        $Record.State='restored'; Write-SteamFixJournal $Record ([string]$Record.JournalPath)
        return [pscustomobject]@{ State='restored'; Mode='exact-backup'; PreservedForeignFields=@(); Record=$Record }
    }
    $patches=New-Object 'System.Collections.Generic.List[ManeaterCrashFpsFix.VdfPatch]'; $foreign=@()
    foreach ($field in @($verified.Fields)) {
        if ($field.Name -cne 'LaunchOptions' -and $field.Name -cne 'OverlayAppEnable') { throw 'Unrecognized Steam recovery field.' }
        if (-not $field.Changed) { continue }
        $targetNode=$snapshot.Node; if ($field.Scope -eq 'overlay') { $targetNode=$snapshot.OverlayNode }
        $current=Get-SteamFixField $targetNode ([string]$field.Name) $snapshot.File.Bytes
        if ((-not $current.Exists -and -not $field.Original.Exists) -or ($current.Exists -and $field.Original.Exists -and $current.Value -ceq [string]$field.Original.Value)) { continue }
        if (-not $current.Exists -or $current.Value -cne [string]$field.Applied.Value) { $foreign += $field.Name; continue }
        if ($field.Original.Exists) {
            $replacement=[Convert]::FromBase64String([string]$field.Original.RawTokenBase64)
            $patches.Add([ManeaterCrashFpsFix.VdfPatch]::new($current.Pair.Value.Start,$current.Pair.Value.End-$current.Pair.Value.Start,$replacement))
        } else { $patches.Add([ManeaterCrashFpsFix.VdfPatch]::new($current.Pair.Start,$current.Pair.End-$current.Pair.Start,[byte[]]@())) }
    }
    if ($patches.Count -ne 0) {
        $restored=[ManeaterCrashFpsFix.SteamVdf]::Apply($snapshot.File.Bytes,$patches.ToArray())
        [ManeaterCrashFpsFix.SteamVdf]::Parse($restored) | Out-Null
        Set-SteamFixBytes $snapshot.File.Path $restored $snapshot.File.Hash
    }
    $Record.State=$(if ($foreign.Count -eq 0) { 'restored' } else { 'partial-restored-foreign-preserved' })
    Write-SteamFixJournal $Record ([string]$Record.JournalPath)
    return [pscustomobject]@{ State=$Record.State; Mode='owned-values-only'; PreservedForeignFields=$foreign; Record=$Record }
}
function Assert-SteamManeaterInstallation {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)][string]$GameRoot)
    $context=Get-SteamFixContext -Context $Context
    $selected=Normalize-SteamFixDirectory (Resolve-Path -LiteralPath $GameRoot).ProviderPath
    if (-not [IO.Directory]::Exists($selected)) { throw 'Selected game root must be a directory.' }
    $libraryFile=Join-Path $context.SteamDirectory 'steamapps\libraryfolders.vdf'
    $libraries=@(); $libraryHash=$null; $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ([IO.File]::Exists($libraryFile)) {
        $file=Read-SteamFixFile $libraryFile; $libraryHash=$file.Hash
        $node=[ManeaterCrashFpsFix.SteamVdf]::Container($file.Tree,'libraryfolders')
        $indexes=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($pair in $node.Pairs) {
            if ($pair.Key.Value -notmatch '^\d+$') { continue }
            if (-not $indexes.Add($pair.Key.Value)) { throw 'Ambiguous duplicate Steam library index.' }
            $registeredApp=$null
            if ($null -ne $pair.Child) {
                $pathPair=[ManeaterCrashFpsFix.SteamVdf]::Unique($pair.Child,'path',$true)
                if ($null -eq $pathPair.Value -or $pathPair.Value.UnknownEscape) { throw 'Unsupported Steam library path.' }
                $path=Normalize-SteamFixDirectory $pathPair.Value.Value
                $appsPair=[ManeaterCrashFpsFix.SteamVdf]::Unique($pair.Child,'apps',$true)
                if ($null -eq $appsPair.Child) { throw 'Unsupported Steam library app list.' }
                $registeredPair=[ManeaterCrashFpsFix.SteamVdf]::Unique($appsPair.Child,'629820',$false)
                if ($null -ne $registeredPair -and ($null -eq $registeredPair.Value -or $registeredPair.Value.UnknownEscape -or $registeredPair.Value.Value -notmatch '^\d+$')) { throw 'Unsupported Steam library app registration.' }
                $registeredApp=$null -ne $registeredPair
            } else {
                if ($null -eq $pair.Value -or $pair.Value.UnknownEscape) { throw 'Unsupported legacy Steam library path.' }
                $path=Normalize-SteamFixDirectory $pair.Value.Value
            }
            if (-not $seen.Add($path)) { throw 'Ambiguous duplicate Steam library path.' }
            $libraries += [pscustomobject]@{ Path=$path; RegisteredApp=$registeredApp }
        }
    }
    $default=Normalize-SteamFixDirectory $context.SteamDirectory
    if ($seen.Add($default)) { $libraries += [pscustomobject]@{ Path=$default; RegisteredApp=$null } }
    $matches=@()
    foreach ($library in $libraries) {
        if ($null -ne $library.RegisteredApp -and -not $library.RegisteredApp) { continue }
        $manifestPath=Join-Path $library.Path 'steamapps\appmanifest_629820.acf'
        if (-not [IO.File]::Exists($manifestPath)) { continue }
        $manifest=Read-SteamFixFile $manifestPath
        $app=[ManeaterCrashFpsFix.SteamVdf]::Container($manifest.Tree,'AppState')
        $id=[ManeaterCrashFpsFix.SteamVdf]::Unique($app,'appid',$true)
        $install=[ManeaterCrashFpsFix.SteamVdf]::Unique($app,'installdir',$true)
        if ($null -eq $id.Value -or $id.Value.UnknownEscape -or $id.Value.Value -cne '629820' -or
            $null -eq $install.Value -or $install.Value.UnknownEscape) { throw 'Steam app manifest does not match Maneater.' }
        $directory=$install.Value.Value
        if ([string]::IsNullOrWhiteSpace($directory) -or $directory -in @('.','..') -or $directory.IndexOfAny([char[]]'\/') -ge 0 -or [IO.Path]::IsPathRooted($directory)) { throw 'Unsupported Steam installation directory in manifest.' }
        $actual=Normalize-SteamFixDirectory (Join-Path $library.Path ('steamapps\common\' + $directory))
        if ([IO.Directory]::Exists($actual)) { $matches += [pscustomobject]@{ GameRoot=$actual; LibraryPath=$library.Path; ManifestPath=$manifestPath; ManifestSHA256=$manifest.Hash } }
    }
    if ($matches.Count -ne 1) { throw 'Maneater installation is missing or ambiguous across registered Steam libraries.' }
    if ($matches[0].GameRoot -ine $selected) { throw 'Selected executable is not the Maneater installation Steam will launch.' }
    return [pscustomobject]@{ Validated=$true; AppId='629820'; GameRoot=$selected; LibraryPath=$matches[0].LibraryPath;
        AppManifestPath=$matches[0].ManifestPath; AppManifestSHA256=$matches[0].ManifestSHA256; LibraryFoldersSHA256=$libraryHash }
}
Export-ModuleMember -Function Get-SteamFixContext,Get-SteamFixStatus,New-SteamFixPlan,Invoke-SteamFixPlan,Restore-SteamFix,Assert-SteamManeaterInstallation
