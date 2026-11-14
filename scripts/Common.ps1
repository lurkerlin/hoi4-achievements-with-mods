# Shared configuration and Steam/HOI4 discovery for this repo's scripts.
# Dot-source it from a script:  . (Join-Path $PSScriptRoot 'Common.ps1')

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
