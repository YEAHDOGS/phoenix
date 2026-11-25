# Phoenix engine: the free-space cleaner.
#
# Commands: clean-rules, clean-scan, clean-run. See docs/CLEANER.md.
#
# What may be deleted is data, not code: every *.json in config\clean is a rule
# set, and a rule only names folders whose CONTENTS go (the folder stays), plus
# an optional file-name pattern and age. clean-scan is read-only and returns
# what each rule would delete; clean-run deletes only the rule ids it is given.
#
# Three things hold whatever a rule file says (it may come from someone else):
#   1. Test-PhxCleanRootSafe refuses a folder that is, contains, or sits inside
#      a place where people keep their own things or Windows keeps itself.
#   2. Junctions and symbolic links are never followed and never removed.
#   3. Nothing runs from a rule: no commands, no registry, files only.

function Get-PhxCleanRoot {
    if ($env:PHOENIX_CLEAN_RULES) { return $env:PHOENIX_CLEAN_RULES }
    Join-Path (Get-PhxKitRoot) 'config\clean'
}

function Get-PhxCleanRules([string]$Platform) {
    $root = Get-PhxCleanRoot
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $seen = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter '*.json' | Sort-Object Name)) {
        $set = Read-PhxJson $f.FullName
        if (([string]$set['platform']) -ne $Platform) { continue }
        foreach ($r in @($set['rules'])) {
            if (-not $r -or -not $r['id']) { continue }
            $id = [string]$r['id']
            if ($id -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$') { throw "Clean rule id '$id' in $($f.Name) must be lowercase letters, digits, dots and dashes." }
            if ($seen.ContainsKey($id)) { throw "Clean rule id '$id' is in both $($seen[$id]) and $($f.Name)." }
            $seen[$id] = $f.Name
            $r['_set'] = [string]$set['id']
            [void]$out.Add($r)
        }
    }
    @($out.ToArray())
}

function Format-PhxCleanRule($Rule) {
    [ordered]@{
        id      = [string]$Rule['id']
        group   = [string]$Rule['group']
        name    = [string]$Rule['name']
        why     = [string]$Rule['why']
        risk    = $(if ($Rule['risk']) { [string]$Rule['risk'] } else { 'safe' })
        default = [bool]$Rule['default']
        admin   = [bool]$Rule['admin']
        set     = [string]$Rule['_set']
    }
}

# --- Windows ------------------------------------------------------------------

function Get-PhxCleanProtected {
    if ($script:PhxCleanProtected) { return $script:PhxCleanProtected }
    $never = New-Object System.Collections.ArrayList   # never these, nor a folder holding one
    $inside = New-Object System.Collections.ArrayList  # nor anything inside these
    $add = { param($list, $p) if ($p) { try { [void]$list.Add([IO.Path]::GetFullPath([string]$p).TrimEnd('\')) } catch { } } }
    $sysRoot = $env:SystemRoot
    $profileDir = $env:USERPROFILE
    foreach ($p in @(
            $sysRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $profileDir,
            $(if ($profileDir) { Split-Path -Parent $profileDir }),
            $env:APPDATA, $env:LOCALAPPDATA,
            $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Packages' }),
            $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs' }),
            $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft' }),
            $(if ($env:APPDATA) { Join-Path $env:APPDATA 'Microsoft' })
        )) { & $add $never $p }
    foreach ($name in 'Desktop', 'MyDocuments', 'MyPictures', 'MyMusic', 'MyVideos', 'Favorites') {
        $p = $null
        try { $p = [Environment]::GetFolderPath($name) } catch { }
        & $add $never $p; & $add $inside $p
    }
    if ($profileDir) {
        foreach ($n in 'Downloads', 'Documents', 'Desktop', 'Pictures', 'Music', 'Videos', 'OneDrive', 'Saved Games', '.ssh', '.gnupg') {
            $p = Join-Path $profileDir $n
            & $add $never $p; & $add $inside $p
        }
    }
    if ($sysRoot) {
        foreach ($n in 'System32', 'SysWOW64', 'WinSxS', 'Fonts', 'Boot', 'servicing', 'assembly', 'Microsoft.NET', 'Installer') {
            $p = Join-Path $sysRoot $n
            & $add $never $p; & $add $inside $p
        }
    }
    $script:PhxCleanProtected = @{ never = @($never.ToArray() | Select-Object -Unique); inside = @($inside.ToArray() | Select-Object -Unique) }
    $script:PhxCleanProtected
}

# $null when the folder's contents may be deleted, otherwise the reason not.
function Test-PhxCleanRootSafe([string]$Dir) {
    if (-not $Dir) { return 'empty path' }
    if ($Dir.Contains('..')) { return "'..' is not allowed" }
    $full = $null
    try { $full = [IO.Path]::GetFullPath($Dir).TrimEnd('\') } catch { return 'not a valid path' }
    if ($full -notmatch '^[A-Za-z]:\\.+') { return 'not a folder on a local drive' }
    $prot = Get-PhxCleanProtected
    foreach ($p in $prot.never) {
        if ($full -ieq $p) { return "$p is protected" }
        if ($p.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) { return "it holds $p, which is protected" }
    }
    foreach ($p in $prot.inside) {
        if ($full.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { return "it is inside $p, which is yours" }
    }
    return $null
}

# Explicit single files (rule field `files`) may sit in a protected folder, so
# only these kinds, which Windows and programs recreate, and no wildcards.
$script:PhxCleanFileKinds = '.dmp', '.log', '.tmp', '.old', '.bak', '.etl', '.db', '.chk'

function Expand-PhxCleanPath([string]$Path) {
    [Environment]::ExpandEnvironmentVariables($Path)
}

# Folders a rule path names. Wildcards are allowed in any segment but the
# first; a segment that is a link is not walked through.
function Resolve-PhxCleanDirs([string]$Path) {
    $expanded = Expand-PhxCleanPath $Path
    if ($expanded.Contains('%')) { return @() }   # a variable this machine does not have
    $parts = @($expanded.TrimEnd('\').Split('\') | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 2 -or $parts[0] -notmatch '^[A-Za-z]:$') { return @() }
    $current = @($parts[0] + '\')
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $seg = $parts[$i]
        $next = New-Object System.Collections.ArrayList
        foreach ($c in $current) {
            if ($seg.IndexOfAny([char[]]'*?') -ge 0) {
                try {
                    foreach ($d in [IO.Directory]::GetDirectories($c, $seg)) {
                        if (-not ([IO.File]::GetAttributes($d) -band [IO.FileAttributes]::ReparsePoint)) { [void]$next.Add($d) }
                    }
                } catch { }
            } else {
                $d = Join-Path $c $seg
                try {
                    if ([IO.Directory]::Exists($d) -and -not ([IO.File]::GetAttributes($d) -band [IO.FileAttributes]::ReparsePoint)) { [void]$next.Add($d) }
                } catch { }
            }
        }
        $current = @($next.ToArray())
        if ($current.Count -eq 0) { break }
    }
    @($current)
}

function Test-PhxCleanName([string]$Name, $Patterns) {
    if (-not $Patterns) { return $true }
    foreach ($p in @($Patterns)) { if ($Name -like [string]$p) { return $true } }
    return $false
}

# The walk itself is compiled: a Temp folder can hold hundreds of thousands of
# files, and a PowerShell loop over them takes minutes. C# 5 only, so Windows
# PowerShell 5.1's built-in compiler takes it.
$script:PhxCleanWalkSource = @"
using System;
using System.Collections.Generic;
using System.IO;

public class PhxCleanSet {
    public long Bytes;
    public List<string> Paths = new List<string>();
    public List<long> Sizes = new List<long>();
    public List<string> Dirs = new List<string>();
    public long Freed; public int Deleted; public int Failed; public string FirstError;
    public void Add(string path, long size) { Paths.Add(path); Sizes.Add(size); Bytes += size; }
}

public static class PhxCleanWalk {
    static bool Like(string name, string pattern) {
        int n = 0, p = 0, star = -1, mark = 0;
        while (n < name.Length) {
            if (p < pattern.Length && (pattern[p] == '?' || char.ToUpperInvariant(pattern[p]) == char.ToUpperInvariant(name[n]))) { n++; p++; }
            else if (p < pattern.Length && pattern[p] == '*') { star = p++; mark = n; }
            else if (star >= 0) { p = star + 1; n = ++mark; }
            else return false;
        }
        while (p < pattern.Length && pattern[p] == '*') p++;
        return p == pattern.Length;
    }

    static bool Matches(string name, string[] patterns) {
        if (patterns == null || patterns.Length == 0) return true;
        foreach (string p in patterns) if (Like(name, p)) return true;
        return false;
    }

    // A folder met on the way down that is protected, or holds or sits in something protected.
    static bool Protected(string dir, string[] never, string[] inside) {
        foreach (string p in never) {
            if (string.Equals(dir, p, StringComparison.OrdinalIgnoreCase)) return true;
            if (p.StartsWith(dir + "\\", StringComparison.OrdinalIgnoreCase)) return true;
        }
        foreach (string p in inside) if (dir.StartsWith(p + "\\", StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    public static void Walk(string root, bool recurse, string[] patterns, DateTime cutoff, bool skipDesktopIni, string[] never, string[] inside, PhxCleanSet set) {
        Stack<string> stack = new Stack<string>();
        stack.Push(root);
        while (stack.Count > 0) {
            FileSystemInfo[] entries;
            try { entries = new DirectoryInfo(stack.Pop()).GetFileSystemInfos(); } catch { continue; }
            foreach (FileSystemInfo e in entries) {
                try {
                    bool link = (e.Attributes & FileAttributes.ReparsePoint) != 0;
                    if ((e.Attributes & FileAttributes.Directory) != 0) {
                        if (link || !recurse || Protected(e.FullName, never, inside)) continue;
                        set.Dirs.Add(e.FullName);
                        stack.Push(e.FullName);
                        continue;
                    }
                    if (link) continue;
                    if (!Matches(e.Name, patterns)) continue;
                    if (skipDesktopIni && string.Equals(e.Name, "desktop.ini", StringComparison.OrdinalIgnoreCase)) continue;
                    if (cutoff != DateTime.MinValue && e.LastWriteTime > cutoff) continue;
                    set.Add(e.FullName, ((FileInfo)e).Length);
                } catch { }
            }
        }
    }

    public static int[] Biggest(PhxCleanSet set, int top) {
        int[] idx = new int[set.Sizes.Count];
        for (int i = 0; i < idx.Length; i++) idx[i] = i;
        long[] keys = set.Sizes.ToArray();
        Array.Sort(keys, idx);
        int n = Math.Min(top, idx.Length);
        int[] result = new int[n];
        for (int i = 0; i < n; i++) result[i] = idx[idx.Length - 1 - i];
        return result;
    }

    public static void Delete(PhxCleanSet set) {
        for (int i = 0; i < set.Paths.Count; i++) {
            string path = set.Paths[i];
            try {
                FileAttributes a = File.GetAttributes(path);
                if ((a & FileAttributes.ReparsePoint) != 0) continue;
                if ((a & FileAttributes.ReadOnly) != 0) File.SetAttributes(path, a & ~FileAttributes.ReadOnly);
                File.Delete(path);
                set.Freed += set.Sizes[i]; set.Deleted++;
            } catch (Exception ex) {
                set.Failed++;
                if (set.FirstError == null) set.FirstError = ex.Message;
            }
        }
        // Folders that are empty now, deepest first. Without the recursive flag
        // Directory.Delete refuses a folder that still holds anything.
        set.Dirs.Sort(delegate (string x, string y) { return y.Length.CompareTo(x.Length); });
        foreach (string d in set.Dirs) { try { Directory.Delete(d, false); } catch { } }
    }
}
"@

function Initialize-PhxCleanWalk {
    if (-not ('PhxCleanWalk' -as [type])) { Add-Type -TypeDefinition $script:PhxCleanWalkSource -Language CSharp }
}

# Every file a Windows rule covers, as a PhxCleanSet. $Problems collects
# refused folders, $Roots the folders that were walked.
function Get-PhxCleanFiles($Rule, [System.Collections.ArrayList]$Problems, [System.Collections.ArrayList]$Roots) {
    Initialize-PhxCleanWalk
    $set = New-Object PhxCleanSet
    $prot = Get-PhxCleanProtected
    foreach ($t in @($Rule['targets'])) {
        if (-not $t -or -not $t['path']) { continue }
        $recurse = -not ($t.Contains('recurse') -and $t['recurse'] -eq $false)
        $cutoff = if ($t['olderThanHours']) { (Get-Date).AddHours( - [double]$t['olderThanHours']) } else { [DateTime]::MinValue }
        $patterns = [string[]]@($t['match'] | Where-Object { $_ })
        foreach ($root in @(Resolve-PhxCleanDirs ([string]$t['path']))) {
            $why = Test-PhxCleanRootSafe $root
            if ($why) { [void]$Problems.Add("$root is left alone: $why."); continue }
            if ($Roots) { [void]$Roots.Add($root) }
            [PhxCleanWalk]::Walk($root, $recurse, $patterns, $cutoff, $false, [string[]]$prot.never, [string[]]$prot.inside, $set)
        }
    }
    foreach ($f in @($Rule['files'])) {
        if (-not $f) { continue }
        $p = Expand-PhxCleanPath ([string]$f)
        if ($p.IndexOfAny([char[]]'*?%') -ge 0 -or $p.Contains('..')) { [void]$Problems.Add("$f is left alone: a single file has to be named exactly."); continue }
        if ($script:PhxCleanFileKinds -notcontains ([IO.Path]::GetExtension($p).ToLower())) { [void]$Problems.Add("$f is left alone: only $($script:PhxCleanFileKinds -join ' ') files can be named one by one."); continue }
        try {
            $fi = New-Object IO.FileInfo $p
            if ($fi.Exists -and -not ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $set.Add($fi.FullName, [int64]$fi.Length) }
        } catch { }
    }
    , $set
}

# The Recycle Bin of the person running this, on every fixed drive.
function Get-PhxRecycleBinFiles {
    Initialize-PhxCleanWalk
    $set = New-Object PhxCleanSet
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne [IO.DriveType]::Fixed -or -not $d.IsReady) { continue }
        $bin = Join-Path $d.RootDirectory.FullName ('$Recycle.Bin\' + $sid)
        if ([IO.Directory]::Exists($bin)) { [PhxCleanWalk]::Walk($bin, $true, [string[]]@(), [DateTime]::MinValue, $true, [string[]]@(), [string[]]@(), $set) }
    }
    , $set
}

function Get-PhxCleanRunning($Rule) {
    $names = @($Rule['closeFirst'] | Where-Object { $_ })
    if ($names.Count -eq 0) { return @() }
    @(Get-Process -Name $names -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Select-Object -Unique)
}

function Get-PhxCleanWindowsItem($Rule, [int]$Top, [bool]$IsAdmin) {
    $problems = New-Object System.Collections.ArrayList
    $roots = New-Object System.Collections.ArrayList
    $set = if ($Rule['special'] -eq 'recycle-bin') { Get-PhxRecycleBinFiles } else { Get-PhxCleanFiles $Rule $problems $roots }
    $item = Format-PhxCleanRule $Rule
    $item['bytes'] = [int64]$set.Bytes
    $item['files'] = $set.Paths.Count
    $item['biggest'] = @([PhxCleanWalk]::Biggest($set, $Top) | ForEach-Object { [ordered]@{ path = $set.Paths[$_]; bytes = $set.Sizes[$_] } })
    $item['folders'] = @($roots.ToArray() | Select-Object -Unique)
    $item['running'] = @(Get-PhxCleanRunning $Rule)
    $item['blocked'] = $(if ($Rule['admin'] -and -not $IsAdmin) { 'needs-admin' } else { $null })
    $item['notes'] = @($problems.ToArray())
    $item
}

function Remove-PhxCleanWindowsRule($Rule) {
    $problems = New-Object System.Collections.ArrayList
    if ($Rule['special'] -eq 'recycle-bin') {
        $before = Get-PhxRecycleBinFiles
        $err = $null
        try { Clear-RecycleBin -Force -ErrorAction Stop } catch { $err = $_.Exception.Message }
        $after = Get-PhxRecycleBinFiles
        return [ordered]@{ id = [string]$Rule['id']; freedBytes = [Math]::Max([int64]0, $before.Bytes - $after.Bytes); files = [Math]::Max(0, $before.Paths.Count - $after.Paths.Count); failed = $after.Paths.Count; error = $err }
    }
    $set = Get-PhxCleanFiles $Rule $problems $null
    [PhxCleanWalk]::Delete($set)
    [ordered]@{ id = [string]$Rule['id']; freedBytes = [int64]$set.Freed; files = $set.Deleted; failed = $set.Failed; error = $set.FirstError }
}
function Get-PhxCleanFreeBytes {
    $total = [int64]0
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -eq [IO.DriveType]::Fixed -and $d.IsReady) { $total += $d.AvailableFreeSpace }
    }
    $total
}

# --- Android (over adb, no root) ------------------------------------------------

function Find-PhxAdb([hashtable]$A) {
    $candidates = @(
        $A['adbPath'], $env:PHOENIX_ADB
        (Join-Path (Get-PhxKitRoot) 'config\loadout\platform-tools\adb.exe')
        (Join-Path (Get-PhxCacheRoot) 'platform-tools\adb.exe')
    ) | Where-Object { $_ }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path } }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'adb was not found. Fetch "platform-tools" in the loadout, or pass adbPath.'
}

# Runs adb; returns @{ code; out }. Process is used directly so Windows
# PowerShell 5.1 does not turn the phone's stderr into error records.
function Invoke-PhxAdb([string]$Adb, [string[]]$Arguments, [int]$TimeoutSec = 120) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Adb
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        throw "adb did not answer within $TimeoutSec seconds."
    }
    @{ code = $p.ExitCode; out = ([string]$outTask.Result) -replace "`r", ''; err = [string]$errTask.Result }
}

function Get-PhxAndroidDevices([string]$Adb) {
    $r = Invoke-PhxAdb $Adb @('devices', '-l') 30
    $list = New-Object System.Collections.ArrayList
    foreach ($line in $r.out.Split("`n")) {
        if ($line -notmatch '^(\S+)\s+(device|unauthorized|offline)\b(.*)$') { continue }
        $serial = $Matches[1]; $state = $Matches[2]; $rest = $Matches[3]
        $model = ''
        if ($rest -match 'model:(\S+)') { $model = $Matches[1].Replace('_', ' ') }
        [void]$list.Add([ordered]@{ serial = $serial; state = $state; model = $model })
    }
    @($list.ToArray())
}

function Resolve-PhxAndroidSerial([string]$Adb, [string]$Serial) {
    $devices = @(Get-PhxAndroidDevices $Adb)
    if ($Serial) {
        $d = $devices | Where-Object { $_.serial -eq $Serial } | Select-Object -First 1
        if (-not $d) { throw "No Android device '$Serial' is connected." }
    } else {
        $ready = @($devices | Where-Object { $_.state -eq 'device' })
        if ($ready.Count -eq 0) {
            if (@($devices | Where-Object { $_.state -eq 'unauthorized' }).Count -gt 0) { throw 'The phone is connected but has not allowed this computer. Unlock it and accept "Allow USB debugging".' }
            throw 'No Android device is connected. Plug it in with USB debugging on.'
        }
        if ($ready.Count -gt 1) { throw "More than one Android device is connected ($(@($ready | ForEach-Object { $_.serial }) -join ', ')). Say which with serial." }
        $d = $ready[0]
    }
    if ($d.state -ne 'device') { throw "Android device '$($d.serial)' is $($d.state). Unlock it and accept `"Allow USB debugging`"." }
    $d.serial
}

# A rule path on the phone: shared storage only, plain characters and * only,
# so it can go to the phone's shell unquoted (the shell expands the *).
function Test-PhxAndroidPath([string]$Path, $Match) {
    if ($Path -notmatch '^/sdcard(/[A-Za-z0-9._*-]+)+$') { return 'only folders under /sdcard, named with letters, digits, dots, dashes and *' }
    if ($Path.Contains('..')) { return "'..' is not allowed" }
    $whole = '/sdcard', '/sdcard/DCIM', '/sdcard/Pictures', '/sdcard/Movies', '/sdcard/Music', '/sdcard/Download', '/sdcard/Documents', '/sdcard/Android', '/sdcard/Android/data', '/sdcard/Android/media', '/sdcard/Android/obb'
    if (-not $Match) {
        $depth = @($Path.Split('/') | Where-Object { $_ }).Count
        if ($whole -contains $Path -or $depth -lt 3) { return 'a folder that holds your own files needs a file-name pattern' }
        if ($Path -match '^/sdcard/(DCIM|Pictures|Movies|Music|Download|Documents)/[^.]') { return 'a folder that holds your own files needs a file-name pattern' }
    }
    foreach ($m in @($Match)) {
        if ($m -and ([string]$m) -notmatch '^[A-Za-z0-9._*-]+$') { return "the pattern '$m' may only use letters, digits, dots, dashes and *" }
        if ([string]$m -eq '*' -and $whole -contains $Path) { return 'the pattern * would take everything in a folder that is yours' }
    }
    return $null
}

function Get-PhxAndroidFindCommand($Target, [string]$Tail) {
    $path = ([string]$Target['path']).TrimEnd('/')
    $names = @($Target['match'] | Where-Object { $_ })
    $depth = if ($Target.Contains('recurse') -and $Target['recurse'] -eq $false) { '-maxdepth 1 ' } else { '' }
    $nameExpr = ''
    if ($names.Count -gt 0) {
        $nameExpr = '\( ' + ((@($names | ForEach-Object { "-name '$_'" })) -join ' -o ') + ' \) '
    }
    $age = if ($Target['olderThanHours']) { '-mmin +' + [int]([double]$Target['olderThanHours'] * 60) + ' ' } else { '' }
    "find $path/ $depth-type f $nameExpr$age$Tail 2>/dev/null"
}

# App cache sizes from the system's own bookkeeping (dumpsys diskstats).
function Get-PhxAndroidAppCaches([string]$Adb, [string]$Serial) {
    $r = Invoke-PhxAdb $Adb @('-s', $Serial, 'shell', 'dumpsys diskstats') 60
    $names = @(); $sizes = @()
    foreach ($line in $r.out.Split("`n")) {
        if ($line -match '^Package Names:\s*\[(.*)\]') { $names = @($Matches[1].Split(',') | ForEach-Object { $_.Trim().Trim('"') }) }
        elseif ($line -match '^Cache Sizes:\s*\[(.*)\]') { $sizes = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() }) }
    }
    $list = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt [Math]::Min($names.Count, $sizes.Count); $i++) {
        $n = [int64]0
        if ([int64]::TryParse($sizes[$i], [ref]$n) -and $n -gt 0) { [void]$list.Add(@{ path = $names[$i]; bytes = $n }) }
    }
    , $list
}

function Get-PhxAndroidFiles([string]$Adb, [string]$Serial, $Rule, [System.Collections.ArrayList]$Problems) {
    $files = New-Object System.Collections.ArrayList
    foreach ($t in @($Rule['targets'])) {
        if (-not $t -or -not $t['path']) { continue }
        $why = Test-PhxAndroidPath ([string]$t['path']) $t['match']
        if ($why) { [void]$Problems.Add("$($t['path']) is left alone: $why."); continue }
        $cmd = Get-PhxAndroidFindCommand $t "-exec stat -c '%s %n' {} +"
        $r = Invoke-PhxAdb $Adb @('-s', $Serial, 'shell', $cmd) 180
        foreach ($line in $r.out.Split("`n")) {
            if ($line -match '^(\d+) (/.+)$') { [void]$files.Add(@{ path = $Matches[2]; bytes = [int64]$Matches[1] }) }
        }
    }
    , $files
}

function Get-PhxCleanAndroidItem([string]$Adb, [string]$Serial, $Rule, [int]$Top) {
    $problems = New-Object System.Collections.ArrayList
    $files = if ($Rule['special'] -eq 'android-app-caches') { Get-PhxAndroidAppCaches $Adb $Serial } else { Get-PhxAndroidFiles $Adb $Serial $Rule $problems }
    $bytes = [int64]0
    foreach ($f in $files) { $bytes += $f.bytes }
    $item = Format-PhxCleanRule $Rule
    $item['bytes'] = $bytes
    $item['files'] = $files.Count
    $item['biggest'] = @($files | Sort-Object { $_.bytes } -Descending | Select-Object -First $Top | ForEach-Object { [ordered]@{ path = $_.path; bytes = $_.bytes } })
    $item['folders'] = @($Rule['targets'] | Where-Object { $_ } | ForEach-Object { [string]$_['path'] })
    $item['running'] = @()
    $item['blocked'] = $null
    $item['notes'] = @($problems.ToArray())
    $item
}

function Get-PhxAndroidFreeBytes([string]$Adb, [string]$Serial) {
    $r = Invoke-PhxAdb $Adb @('-s', $Serial, 'shell', 'df -k /data') 30
    foreach ($line in $r.out.Split("`n")) {
        $cols = @($line -split '\s+' | Where-Object { $_ })
        if ($cols.Count -ge 4 -and $cols[3] -match '^\d+$' -and $cols[1] -match '^\d+$') { return [int64]$cols[3] * 1024 }
    }
    return $null
}

function Remove-PhxCleanAndroidRule([string]$Adb, [string]$Serial, $Rule) {
    $problems = New-Object System.Collections.ArrayList
    if ($Rule['special'] -eq 'android-app-caches') {
        $before = [int64]0
        foreach ($f in (Get-PhxAndroidAppCaches $Adb $Serial)) { $before += $f.bytes }
        # Asks Android to free "this much", more than any phone has, so it drops every app's cache.
        $r = Invoke-PhxAdb $Adb @('-s', $Serial, 'shell', 'pm trim-caches 999999999999') 300
        $err = if ($r.code -ne 0) { ($r.out + $r.err).Trim() } else { $null }
        return [ordered]@{ id = [string]$Rule['id']; freedBytes = $(if ($err) { [int64]0 } else { $before }); files = 0; failed = 0; error = $err; estimated = $true }
    }
    $before = Get-PhxAndroidFiles $Adb $Serial $Rule $problems
    foreach ($t in @($Rule['targets'])) {
        if (-not $t -or -not $t['path']) { continue }
        if (Test-PhxAndroidPath ([string]$t['path']) $t['match']) { continue }
        [void](Invoke-PhxAdb $Adb @('-s', $Serial, 'shell', (Get-PhxAndroidFindCommand $t '-delete')) 300)
    }
    $after = Get-PhxAndroidFiles $Adb $Serial $Rule $problems
    $b = [int64]0; foreach ($f in $before) { $b += $f.bytes }
    $a = [int64]0; foreach ($f in $after) { $a += $f.bytes }
    [ordered]@{ id = [string]$Rule['id']; freedBytes = [Math]::Max([int64]0, $b - $a); files = [Math]::Max(0, $before.Count - $after.Count); failed = $after.Count; error = $null }
}

# --- Commands -------------------------------------------------------------------

function Get-PhxCleanPlatform([hashtable]$A) {
    $p = if ($A['platform']) { ([string]$A['platform']).ToLower() } else { 'windows' }
    if ($p -ne 'windows' -and $p -ne 'android') { throw "clean: platform must be windows or android, not '$p'." }
    $p
}

function Invoke-PhxCleanRules([hashtable]$A) {
    $platform = Get-PhxCleanPlatform $A
    [ordered]@{ platform = $platform; rules = @(Get-PhxCleanRules $platform | ForEach-Object { Format-PhxCleanRule $_ }) }
}

function Invoke-PhxCleanDevices([hashtable]$A) {
    $adb = Find-PhxAdb $A
    [ordered]@{ adb = $adb; devices = @(Get-PhxAndroidDevices $adb) }
}

function Invoke-PhxCleanScan([hashtable]$A) {
    $platform = Get-PhxCleanPlatform $A
    $top = if ($A['top']) { [int]$A['top'] } else { 25 }
    $want = @($A['ids'] | Where-Object { $_ })
    $rules = @(Get-PhxCleanRules $platform | Where-Object { $want.Count -eq 0 -or $want -contains $_['id'] })
    $items = New-Object System.Collections.ArrayList
    $isAdmin = Test-PhxIsAdmin
    $adb = $null; $serial = $null; $free = $null
    if ($platform -eq 'android') {
        $adb = Find-PhxAdb $A
        $serial = Resolve-PhxAndroidSerial $adb ([string]$A['serial'])
        $free = Get-PhxAndroidFreeBytes $adb $serial
    } else {
        $free = Get-PhxCleanFreeBytes
    }
    $n = 0
    foreach ($r in $rules) {
        $n++
        Write-PhxProgress -Step 'clean-scan' -Pct ([int](100 * $n / [Math]::Max(1, $rules.Count))) -Msg ([string]$r['name'])
        $item = if ($platform -eq 'android') { Get-PhxCleanAndroidItem $adb $serial $r $top } else { Get-PhxCleanWindowsItem $r $top $isAdmin }
        [void]$items.Add($item)
    }
    $total = [int64]0
    foreach ($i in $items) { $total += [int64]$i['bytes'] }
    [ordered]@{ platform = $platform; serial = $serial; isAdmin = $isAdmin; freeBytes = $free; totalBytes = $total; items = @($items.ToArray()) }
}

function Invoke-PhxCleanRun([hashtable]$A) {
    $platform = Get-PhxCleanPlatform $A
    $want = @($A['ids'] | Where-Object { $_ })
    if ($want.Count -eq 0) { throw 'clean-run: say which rules, with ids. Nothing is cleaned by default.' }
    $all = @(Get-PhxCleanRules $platform)
    $unknown = @($want | Where-Object { $id = $_; -not ($all | Where-Object { $_['id'] -eq $id }) })
    if ($unknown.Count -gt 0) { throw "clean-run: no such rule: $($unknown -join ', ')." }
    $rules = @($all | Where-Object { $want -contains $_['id'] })
    $isAdmin = Test-PhxIsAdmin
    $adb = $null; $serial = $null
    if ($platform -eq 'android') {
        $adb = Find-PhxAdb $A
        $serial = Resolve-PhxAndroidSerial $adb ([string]$A['serial'])
    }
    $before = if ($platform -eq 'android') { Get-PhxAndroidFreeBytes $adb $serial } else { Get-PhxCleanFreeBytes }
    $done = New-Object System.Collections.ArrayList
    $freed = [int64]0; $files = 0; $failed = 0; $n = 0
    foreach ($r in $rules) {
        $n++
        Write-PhxProgress -Step 'clean-run' -Pct ([int](100 * ($n - 1) / [Math]::Max(1, $rules.Count))) -Msg ([string]$r['name'])
        if ($platform -eq 'windows' -and $r['admin'] -and -not $isAdmin) {
            [void]$done.Add([ordered]@{ id = [string]$r['id']; freedBytes = [int64]0; files = 0; failed = 0; error = $null; skipped = 'needs-admin' })
            continue
        }
        $res = if ($platform -eq 'android') { Remove-PhxCleanAndroidRule $adb $serial $r } else { Remove-PhxCleanWindowsRule $r }
        $freed += [int64]$res['freedBytes']; $files += [int]$res['files']; $failed += [int]$res['failed']
        Write-PhxLog "Cleaned $($r['name']): $([Math]::Round($res['freedBytes'] / 1MB, 1)) MB in $($res['files']) files, $($res['failed']) left."
        [void]$done.Add($res)
    }
    $after = if ($platform -eq 'android') { Get-PhxAndroidFreeBytes $adb $serial } else { Get-PhxCleanFreeBytes }
    [ordered]@{
        platform = $platform; serial = $serial; isAdmin = $isAdmin
        freedBytes = $freed; files = $files; failed = $failed
        freeBefore = $before; freeAfter = $after
        rules = @($done.ToArray())
    }
}
