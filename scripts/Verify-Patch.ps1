<#
.SYNOPSIS
  Byte-level verification that hoi4.exe differs from hoi4.exe.backup by exactly
  the expected single byte (0x85 -> 0x31).

.DESCRIPTION
  Uses the native fc.exe /b diff (fast, no full-file memory load). Exits 0 when
  exactly one byte changed and it is the expected one, 1 when not patched or the
  diff is unexpected, 2 on tooling errors.

.PARAMETER GameDir
  Game folder containing hoi4.exe. Auto-detected from Steam libraries if omitted.
#>
[CmdletBinding()]
param([string]$GameDir)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$dir = Find-Hoi4Dir -Hint $GameDir
$exe = Join-Path $dir 'hoi4.exe'
$bak = "$exe.backup"

$bakState = Get-Hoi4BackupState -ExePath $exe
if (-not $bakState.Exists) {
    Write-Error "Backup not found: $bak. Run Patch-Hoi4.ps1 -Action patch first."
    exit 1
}
if (-not $bakState.Usable) {
    Write-Error "无法验证：$($bakState.Reason)。运行 Patch-Hoi4.ps1 -Action patch 重建备份。"
    exit 1
}

$fc = Join-Path $env:SystemRoot 'System32\fc.exe'
$lines = @(& $fc /b $bak $exe 2>&1)
$code = $LASTEXITCODE

if ($code -eq 0) {
    Write-Host "NOT PATCHED: backup and hoi4.exe are identical." -ForegroundColor Yellow
    exit 1
}
if ($code -ne 1) {
    Write-Error "fc failed (exit $code): $($lines -join ' ')"
    exit 2
}

$diffs = @()
foreach ($ln in $lines) {
    $s = [string]$ln
    if ($s -match '^\s*([0-9A-Fa-f]+):\s+([0-9A-Fa-f]{2})\s+([0-9A-Fa-f]{2})\s*$') {
        $diffs += [pscustomobject]@{
            Offset = [Convert]::ToInt64($matches[1], 16)
            Old    = [Convert]::ToByte($matches[2], 16)
            New    = [Convert]::ToByte($matches[3], 16)
        }
    }
}

if ($diffs.Count -eq 1 -and $diffs[0].Old -eq 0x85 -and $diffs[0].New -eq 0x31) {
    Write-Host ("OK: exactly 1 byte changed (0x85 -> 0x31) at 0x{0:X}." -f $diffs[0].Offset) -ForegroundColor Green
    exit 0
}

$sample = ($diffs | Select-Object -First 5 | ForEach-Object { "0x{0:X}: {1:X2}->{2:X2}" -f $_.Offset, $_.Old, $_.New }) -join ', '
Write-Error ("Unexpected patch state: {0} differing byte(s).{1}" -f $diffs.Count, $(if ($sample) { " First: $sample" } else { '' }))
exit 1
