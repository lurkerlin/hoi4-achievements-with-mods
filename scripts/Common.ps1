# Shared configuration and Steam/HOI4 discovery for this repo's scripts.
# Dot-source it from a script:  . (Join-Path $PSScriptRoot 'Common.ps1')

# The patcher writes UTF-8 (box drawing, check marks). Keep PowerShell's
# native-command decoding in sync so its output is not mangled on CP936.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$PatcherVersion = 'v1.0.1'
$PatcherAsset   = 'universal-checksum-patcher.exe'
$PatcherSha256  = '8effc011e77b6059fc462cd331b9eec1bbcf83cc75fac1d1f7db23fa3cd2e63c'
$PatcherRelease = "https://github.com/IlliaYalovoi/universal-checksum-patcher/releases/download/$PatcherVersion/$PatcherAsset"
$PatcherMirrors = @(
    "https://gh-proxy.com/$PatcherRelease",
    "https://ghfast.top/$PatcherRelease"
)

function Get-Sha256Hex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    # Get-FileHash is missing on some trimmed Windows PowerShell installs.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($fs)
            return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLower()
        } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

function Get-SteamLibraries {
    [CmdletBinding()]
    param()

    $libs = [System.Collections.Generic.List[string]]::new()

    $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) {
        $steam = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath
    }
    if (-not $steam) { $steam = 'C:\Program Files (x86)\Steam' }
    if ($steam -and -not $libs.Contains($steam)) { $libs.Add($steam) }

    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $txt = Get-Content -LiteralPath $vdf -Raw
        foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
            $p = $m.Groups[1].Value -replace '\\\\', '\'
            if ($p -and -not $libs.Contains($p)) { $libs.Add($p) }
        }
    }

    # Last-resort scan of common library locations on fixed drives.
    foreach ($d in @('C', 'D', 'E', 'F', 'G')) {
        foreach ($sub in @('SteamLibrary', 'Steam', 'Games\Steam')) {
            $p = "${d}:\$sub"
            if ((Test-Path -LiteralPath $p) -and -not $libs.Contains($p)) { $libs.Add($p) }
        }
    }

    return $libs
}

function Find-Hoi4Dir {
    [CmdletBinding()]
    param([string]$Hint)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Hint) { $candidates.Add($Hint) }
    foreach ($lib in Get-SteamLibraries) {
        $candidates.Add((Join-Path $lib 'steamapps\common\Hearts of Iron IV'))
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'hoi4.exe'))) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    throw "Hearts of Iron IV not found. Pass -GameDir '<game folder>' (the one containing hoi4.exe)."
}

function Get-PatcherExe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GameDir,
        [switch]$Force
    )

    $dest = Join-Path $GameDir $PatcherAsset
    if (-not $Force -and (Test-Path -LiteralPath $dest)) {
        $h = Get-Sha256Hex -Path $dest
        if ($h -eq $PatcherSha256) { return $dest }
        Write-Warning "Existing $PatcherAsset has the wrong hash; re-downloading."
    }

    $urls = @($PatcherRelease) + $PatcherMirrors
    $tmp = Join-Path $env:TEMP ("ucp-{0}.exe" -f [guid]::NewGuid().ToString('N'))

    foreach ($u in $urls) {
        try {
            Write-Host "Downloading $u" -ForegroundColor Cyan
            Invoke-WebRequest -Uri $u -OutFile $tmp -UseBasicParsing -TimeoutSec 180
            $h = Get-Sha256Hex -Path $tmp
            if ($h -eq $PatcherSha256) {
                Move-Item -LiteralPath $tmp -Destination $dest -Force
                Write-Host "Verified SHA-256: $h" -ForegroundColor Green
                return $dest
            }
            Write-Warning "Hash mismatch from $u (got $h)"
        } catch {
            Write-Warning "Download failed from $u : $($_.Exception.Message)"
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    throw "Could not obtain a verified $PatcherAsset. Download it manually from $PatcherRelease and place it in '$GameDir'."
}

# ---------------------------------------------------------------------------
# Local gate inspection. Mirrors universal-checksum-patcher's signature for
# hoi4.exe (anchor "Active Mod Count:", find "85 C0 0F 94 ?? E8", replace
# "31 C0", requireInFunc, expectMatches 1), so status/verify work offline and
# never depend on an outdated .backup.
# ---------------------------------------------------------------------------

if (-not ('Hoi4Patch.GateInspector' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;

namespace Hoi4Patch
{
    public sealed class GateResult
    {
        public string Status;        // patched | unpatched | unsupported | ambiguous | error
        public string Version = "";  // embedded "Operation Postern v..." build string
        public long GateOffset = -1; // file offset of the located gate
        public int PatchedMatches;
        public int UnpatchedMatches;
        public string Message = "";
    }

    internal sealed class Sec
    {
        public string Name;
        public uint VA;
        public uint VSize;
        public uint RawSize;
        public uint RawPtr;
    }

    internal struct Fn
    {
        public uint Begin;
        public uint End;
    }

    public static class GateInspector
    {
        const string Anchor = "Active Mod Count:";

        public static GateResult InspectFile(string path)
        {
            return Inspect(System.IO.File.ReadAllBytes(path));
        }

        public static GateResult Inspect(byte[] d)
        {
            GateResult r = new GateResult();
            try
            {
                if (d == null || d.Length < 0x40) { r.Status = "error"; r.Message = "file too small"; return r; }
                r.Version = FindVersion(d);
                int pe = BitConverter.ToInt32(d, 0x3C);
                if (pe <= 0 || pe + 24 > d.Length || d[pe] != 0x50 || d[pe + 1] != 0x45 || d[pe + 2] != 0 || d[pe + 3] != 0)
                { r.Status = "error"; r.Message = "not a PE file"; return r; }

                ushort machine = BitConverter.ToUInt16(d, pe + 4);
                int nsec = BitConverter.ToUInt16(d, pe + 6);
                int optsz = BitConverter.ToUInt16(d, pe + 20);
                int opt = pe + 24;
                if (optsz <= 0 || opt + optsz > d.Length) { r.Status = "error"; r.Message = "truncated optional header"; return r; }
                ushort magic = BitConverter.ToUInt16(d, opt);
                if (magic != 0x20B) { r.Status = "error"; r.Message = "not PE32+ (x64)"; return r; }
                if (machine != 0x8664) { r.Status = "error"; r.Message = "machine is not x64"; return r; }
                if (opt + 112 + 32 > d.Length) { r.Status = "error"; r.Message = "truncated data directory"; return r; }

                ulong imageBase = BitConverter.ToUInt64(d, opt + 24);

                List<Sec> secs = new List<Sec>();
                int so = opt + optsz;
                for (int i = 0; i < nsec; i++)
                {
                    int o = so + i * 40;
                    if (o + 40 > d.Length) break;
                    Sec s = new Sec();
                    s.Name = Encoding.ASCII.GetString(d, o, 8).TrimEnd('\0');
                    s.VSize = BitConverter.ToUInt32(d, o + 8);
                    s.VA = BitConverter.ToUInt32(d, o + 12);
                    s.RawSize = BitConverter.ToUInt32(d, o + 16);
                    s.RawPtr = BitConverter.ToUInt32(d, o + 20);
                    secs.Add(s);
                }

                Sec text = Find(secs, ".text");
                if (text == null) { r.Status = "error"; r.Message = "no .text section"; return r; }
                int textStart = (int)text.RawPtr;
                int textLen = Math.Min((int)text.RawSize, d.Length - textStart);
                if (textStart < 0 || textLen <= 0) { r.Status = "error"; r.Message = "bad .text section"; return r; }

                List<Fn> funcs = new List<Fn>();
                Sec pdata = Find(secs, ".pdata");
                if (pdata != null)
                {
                    int po = RvaToOff(secs, pdata.VA);
                    if (po >= 0)
                    {
                        long pend = Math.Min((long)d.Length, (long)po + pdata.RawSize);
                        for (long o = po; o + 12 <= pend; o += 12)
                        {
                            uint b = BitConverter.ToUInt32(d, (int)o);
                            uint e = BitConverter.ToUInt32(d, (int)o + 4);
                            if (b < e) { Fn f; f.Begin = b; f.End = e; funcs.Add(f); }
                        }
                        funcs.Sort(delegate(Fn a, Fn b) { return a.Begin.CompareTo(b.Begin); });
                    }
                }

                HashSet<long> anchorRanges = new HashSet<long>();
                foreach (ulong va in StringVAs(d, secs, imageBase, Anchor))
                {
                    for (int i = 0; i + 7 <= textLen; i++)
                    {
                        int p = textStart + i;
                        byte b0 = d[p];
                        if (b0 != 0x48 && b0 != 0x49 && b0 != 0x4C && b0 != 0x4D) continue;
                        if (d[p + 1] != 0x8D || (d[p + 2] & 0xC7) != 0x05) continue;
                        int disp = BitConverter.ToInt32(d, p + 3);
                        long targetRva = (long)text.VA + i + 7 + disp;
                        if (imageBase + (ulong)targetRva != va) continue;
                        Fn fr;
                        if (FuncContains(funcs, text.VA + (uint)i, out fr))
                            anchorRanges.Add(((long)fr.Begin << 32) | fr.End);
                    }
                }

                if (anchorRanges.Count == 0)
                {
                    r.Status = "unsupported";
                    r.Message = "anchor \"" + Anchor + "\" not referenced by any .pdata function";
                    return r;
                }

                int patched = 0, unpatched = 0;
                long patchedOff = -1, unpatchedOff = -1;
                for (int i = 0; i + 6 <= textLen; i++)
                {
                    int p = textStart + i;
                    if (d[p] != 0x31 || d[p + 1] != 0xC0 || d[p + 2] != 0x0F || d[p + 3] != 0x94 || d[p + 5] != 0xE8) continue;
                    Fn fr;
                    if (!FuncContains(funcs, text.VA + (uint)i, out fr)) continue;
                    if (!anchorRanges.Contains(((long)fr.Begin << 32) | fr.End)) continue;
                    patched++;
                    if (patchedOff < 0) patchedOff = p;
                }
                for (int i = 0; i + 6 <= textLen; i++)
                {
                    int p = textStart + i;
                    if (d[p] != 0x85 || d[p + 1] != 0xC0 || d[p + 2] != 0x0F || d[p + 3] != 0x94 || d[p + 5] != 0xE8) continue;
                    Fn fr;
                    if (!FuncContains(funcs, text.VA + (uint)i, out fr)) continue;
                    if (!anchorRanges.Contains(((long)fr.Begin << 32) | fr.End)) continue;
                    unpatched++;
                    if (unpatchedOff < 0) unpatchedOff = p;
                }

                r.PatchedMatches = patched;
                r.UnpatchedMatches = unpatched;

                if (unpatched == 0)
                {
                    if (patched == 1) { r.Status = "patched"; r.GateOffset = patchedOff; }
                    else if (patched > 1) { r.Status = "ambiguous"; r.Message = "found " + patched + " patched gates, expected 1"; }
                    else { r.Status = "unsupported"; r.Message = "no patched or unpatched gate in the anchored function"; }
                }
                else if (unpatched != 1)
                {
                    r.Status = "ambiguous"; r.Message = "found " + unpatched + " unpatched gates, expected 1";
                }
                else
                {
                    r.Status = "unpatched"; r.GateOffset = unpatchedOff;
                }
                return r;
            }
            catch (Exception ex)
            {
                r.Status = "error"; r.Message = ex.Message; return r;
            }
        }

        // The game embeds its build string as "Operation Postern v<version>".
        // Return the most frequent token (ties broken by length) so stray
        // changelog mentions of older builds do not win.
        static string FindVersion(byte[] d)
        {
            byte[] prefix = Encoding.ASCII.GetBytes("Operation Postern v");
            Dictionary<string, int> counts = new Dictionary<string, int>();
            int n = d.Length;
            int plen = prefix.Length;
            for (int i = 0; i + plen < n; i++)
            {
                if (d[i] != prefix[0]) continue;
                bool ok = true;
                for (int k = 1; k < plen; k++) { if (d[i + k] != prefix[k]) { ok = false; break; } }
                if (!ok) continue;

                int start = i + plen;
                int p = start;
                while (p < n && p - start < 48)
                {
                    byte b = d[p];
                    bool valid = (b >= (byte)'0' && b <= (byte)'9')
                              || (b >= (byte)'a' && b <= (byte)'z')
                              || (b >= (byte)'A' && b <= (byte)'Z')
                              || b == (byte)'.';
                    if (!valid) break;
                    p++;
                }
                if (p <= start) continue;
                string v = Encoding.ASCII.GetString(d, start, p - start).TrimEnd('.');
                if (v.IndexOf('.') < 0 || v[0] < '0' || v[0] > '9') continue;

                int c;
                counts.TryGetValue(v, out c);
                counts[v] = c + 1;
            }

            string best = "";
            int bestCount = 0;
            foreach (KeyValuePair<string, int> kv in counts)
            {
                if (kv.Value > bestCount || (kv.Value == bestCount && kv.Key.Length > best.Length))
                {
                    best = kv.Key;
                    bestCount = kv.Value;
                }
            }
            return best;
        }

        static Sec Find(List<Sec> secs, string name)
        {
            foreach (Sec s in secs) if (s.Name == name) return s;
            return null;
        }

        static int RvaToOff(List<Sec> secs, uint rva)
        {
            foreach (Sec s in secs)
            {
                uint span = Math.Max(s.VSize, s.RawSize);
                if (rva >= s.VA && rva < s.VA + span)
                    return (int)(s.RawPtr + (rva - s.VA));
            }
            return -1;
        }

        static bool FuncContains(List<Fn> funcs, uint rva, out Fn found)
        {
            int lo = 0, hi = funcs.Count - 1, ans = -1;
            while (lo <= hi)
            {
                int mid = (lo + hi) / 2;
                if (funcs[mid].End > rva) { ans = mid; hi = mid - 1; } else lo = mid + 1;
            }
            if (ans >= 0 && rva >= funcs[ans].Begin && rva < funcs[ans].End) { found = funcs[ans]; return true; }
            found = new Fn(); return false;
        }

        static List<ulong> StringVAs(byte[] d, List<Sec> secs, ulong imageBase, string s)
        {
            List<ulong> outv = new List<ulong>();
            byte[] needle = Encoding.ASCII.GetBytes(s);
            foreach (Sec sec in secs)
            {
                int start = (int)sec.RawPtr;
                int end = Math.Min(d.Length, start + (int)sec.RawSize);
                for (int at = start; at + needle.Length <= end; at++)
                {
                    bool ok = true;
                    for (int k = 0; k < needle.Length; k++) if (d[at + k] != needle[k]) { ok = false; break; }
                    if (!ok) continue;
                    if (at == 0 || d[at - 1] == 0)
                        outv.Add(imageBase + (ulong)sec.VA + (ulong)(at - start));
                }
            }
            return outv;
        }
    }
}
'@
}

function Get-Hoi4GateState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExePath)

    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        throw "File not found: $ExePath"
    }
    $full = (Resolve-Path -LiteralPath $ExePath).Path
    return [Hoi4Patch.GateInspector]::InspectFile($full)
}

function Format-Hoi4GateState {
    param([Parameter(Mandatory)]$Gate)

    switch ([string]$Gate.Status) {
        'patched'     { return '已打补丁（gate 签名验证通过）' }
        'unpatched'   { return '未打补丁' }
        'unsupported' { return '版本不支持（未找到唯一 gate）' }
        'ambiguous'   { return "异常：$($Gate.Message)" }
        'error'       { return "无法检查：$($Gate.Message)" }
        default       { return [string]$Gate.Status }
    }
}

function Get-Hoi4BackupState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath,
        $ExeGate
    )

    $bak = "$ExePath.backup"
    $state = [pscustomobject]@{
        Path   = $bak
        Exists = $false
        Usable = $false
        Reason = '无备份'
        Gate   = $null
    }
    if (-not (Test-Path -LiteralPath $bak -PathType Leaf)) { return $state }

    $state.Exists = $true
    $exeGate = if ($null -ne $ExeGate) { $ExeGate } else { Get-Hoi4GateState -ExePath $ExePath }
    $bakGate = Get-Hoi4GateState -ExePath $bak
    $state.Gate = $bakGate

    $exeVer = [string]$exeGate.Version
    $bakVer = [string]$bakGate.Version
    $verNote = ''
    if ($exeVer -and $bakVer) {
        $verNote = if ($exeVer -eq $bakVer) { "版本 $exeVer" } else { "备份 $bakVer，当前 $exeVer" }
    }

    $exeLen = (Get-Item -LiteralPath $ExePath).Length
    $bakLen = (Get-Item -LiteralPath $bak).Length
    if ($bakLen -ne $exeLen) {
        $state.Reason =
            if ($exeVer -and $bakVer -and $exeVer -ne $bakVer) { "旧版本备份（$verNote；大小不同）" }
            elseif ($exeVer -and $bakVer) { "备份大小不同（版本均为 $exeVer，可能损坏或不同安装）" }
            else { '旧版本备份（大小不同，还原会降级游戏）' }
        return $state
    }

    if ($bakGate.Status -ne 'unpatched') {
        $state.Reason = "备份不可用于还原：$(Format-Hoi4GateState $bakGate)"
        return $state
    }

    if ($exeVer -and $bakVer -and $exeVer -ne $bakVer) {
        $state.Reason = "旧版本备份（$verNote）"
        return $state
    }

    if ($exeGate.Status -ne 'patched' -and $exeGate.Status -ne 'unpatched') {
        $state.Reason = "无法验证当前 exe：$(Format-Hoi4GateState $exeGate)"
        return $state
    }
    if ($exeGate.GateOffset -ne $bakGate.GateOffset) {
        $state.Reason = '备份来自另一构建（gate 偏移不同，拒绝还原）'
        return $state
    }

    $state.Usable = $true
    $state.Reason = if ($verNote -and $exeVer -eq $bakVer) { "与当前版本匹配（$verNote，可还原）" } else { '与当前版本匹配（可还原）' }
    return $state
}

function Move-Hoi4StaleBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [scriptblock]$Log
    )

    $bak = "$ExePath.backup"
    if (-not (Test-Path -LiteralPath $bak -PathType Leaf)) { return $null }

    $state = Get-Hoi4BackupState -ExePath $ExePath
    if ($state.Usable) { return $null }

    $dest = "$bak.old-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    if (Test-Path -LiteralPath $dest) { $dest = "$dest-$([guid]::NewGuid().ToString('N').Substring(0, 6))" }
    Move-Item -LiteralPath $bak -Destination $dest
    if ($Log) { & $Log "旧备份不可用（$($state.Reason)），已保留为 $(Split-Path $dest -Leaf)" }
    return $dest
}

function New-Hoi4BackupFromPatched {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [scriptblock]$Log
    )

    $gate = Get-Hoi4GateState -ExePath $ExePath
    if ($gate.Status -ne 'patched') {
        throw "hoi4.exe 不是已打补丁状态（$(Format-Hoi4GateState $gate)），无法据此重建备份。"
    }

    $off = [int]$gate.GateOffset
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ExePath).Path)
    if ($off -lt 0 -or $off + 2 -gt $bytes.Length) { throw 'gate 偏移越界，拒绝重建备份。' }
    if ($bytes[$off] -ne 0x31 -or $bytes[$off + 1] -ne 0xC0) { throw 'gate 字节不是 31 C0，拒绝重建备份。' }
    $bytes[$off] = 0x85

    $dir = Split-Path -Parent (Resolve-Path -LiteralPath $ExePath).Path
    $bak = "$ExePath.backup"
    $tmp = Join-Path $dir ('.ucp-backup-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
        $check = Get-Hoi4GateState -ExePath $tmp
        if ($check.Status -ne 'unpatched' -or $check.GateOffset -ne $off) {
            throw '重建备份自检失败：gate 未能还原为 85 C0。'
        }
        if (Test-Path -LiteralPath $bak -PathType Leaf) {
            $dest = "$bak.old-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            if (Test-Path -LiteralPath $dest) { $dest = "$dest-$([guid]::NewGuid().ToString('N').Substring(0, 6))" }
            Move-Item -LiteralPath $bak -Destination $dest
            if ($Log) { & $Log "原有备份已保留为 $(Split-Path $dest -Leaf)" }
        }
        Move-Item -LiteralPath $tmp -Destination $bak
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    if ($Log) { & $Log ("已重建 hoi4.exe.backup（偏移 0x{0:X}：31 C0 → 85 C0）" -f $off) }
}

function Remove-AnsiText {
    param([string]$Text)
    $esc = [regex]::Escape([string][char]27)
    return (($Text -replace ($esc + '\[[0-9;?]*[ -/]*[@-~]'), '') -replace "`r", '')
}

function Assert-Hoi4NotRunning {
    $p = @(Get-Process -Name 'hoi4' -ErrorAction SilentlyContinue)
    if ($p.Count -gt 0) {
        throw '检测到 hoi4 正在运行，请先完全退出游戏再操作。'
    }
}
