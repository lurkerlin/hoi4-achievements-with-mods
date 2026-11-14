<#
.SYNOPSIS
  Enable Steam achievements in Hearts of Iron IV while mods are active.

.DESCRIPTION
  Locates the game, downloads and SHA-256 verifies universal-checksum-patcher,
  then runs it. The patcher writes hoi4.exe.backup before changing one byte of
  hoi4.exe, so the change is reversible.

.PARAMETER Action
  patch    apply the patch (default)
  status   show whether the exe is patched
  restore  revert hoi4.exe from hoi4.exe.backup
  verify   byte-level diff check (delegates to Verify-Patch.ps1)

.PARAMETER GameDir
  Game folder containing hoi4.exe. Auto-detected from Steam libraries if omitted.

.PARAMETER ForceDownload
  Re-download the patcher even if a valid copy already exists.

.EXAMPLE
  .\scripts\Patch-Hoi4.ps1 -Action patch

.EXAMPLE
  .\scripts\Patch-Hoi4.ps1 -Action verify
#>
[CmdletBinding()]
param(
    [ValidateSet('patch', 'status', 'restore', 'verify')]
    [string]$Action = 'patch',
    [string]$GameDir,
    [switch]$ForceDownload
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$dir = Find-Hoi4Dir -Hint $GameDir
Write-Host "Game folder: $dir" -ForegroundColor Gray

if ($Action -eq 'verify') {
    & (Join-Path $PSScriptRoot 'Verify-Patch.ps1') -GameDir $dir
    exit $LASTEXITCODE
}

$patcher = Get-PatcherExe -GameDir $dir -Force:$ForceDownload
Write-Host "Patcher: $patcher" -ForegroundColor Gray

# The patcher scans its own working directory; pass the exe explicitly so the
# script works regardless of the caller's cwd.
$exe = Join-Path $dir 'hoi4.exe'
& $patcher $Action $exe
exit $LASTEXITCODE
