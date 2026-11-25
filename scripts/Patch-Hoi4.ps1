<#
.SYNOPSIS
  Enable Steam achievements in Hearts of Iron IV while mods are active.

.DESCRIPTION
  Locates the game, downloads and SHA-256 verifies universal-checksum-patcher,
  then runs it. The patcher writes hoi4.exe.backup before changing one byte of
  hoi4.exe, so the change is reversible.

.PARAMETER Action
  patch           apply the patch (default); also rebuilds a missing/stale backup
  status          show gate state and backup state (offline, no patcher needed)
  restore         revert hoi4.exe from hoi4.exe.backup (refuses stale backups)
  verify          byte-level diff check (delegates to Verify-Patch.ps1)
  rebuild-backup  rebuild hoi4.exe.backup from an already-patched exe

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
    [ValidateSet('patch', 'status', 'restore', 'verify', 'rebuild-backup')]
    [string]$Action = 'patch',
    [string]$GameDir,
    [switch]$ForceDownload
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$dir = Find-Hoi4Dir -Hint $GameDir
$exe = Join-Path $dir 'hoi4.exe'
Write-Host "Game folder: $dir" -ForegroundColor Gray

$log = { param($m) Write-Host $m }

switch ($Action) {
    'status' {
        $gate = Get-Hoi4GateState -ExePath $exe
        $bak = Get-Hoi4BackupState -ExePath $exe
        Write-Host ("hoi4.exe : {0}" -f (Format-Hoi4GateState $gate))
        if ($gate.Status -eq 'patched' -or $gate.Status -eq 'unpatched') {
            Write-Host ("gate     : 0x{0:X}" -f $gate.GateOffset) -ForegroundColor DarkGray
        }
        Write-Host ("backup   : {0}" -f $bak.Reason)
        if ($bak.Exists) { Write-Host "           $($bak.Path)" -ForegroundColor DarkGray }
        exit 0
    }

    'verify' {
        & (Join-Path $PSScriptRoot 'Verify-Patch.ps1') -GameDir $dir
        exit $LASTEXITCODE
    }

    'rebuild-backup' {
        $gate = Get-Hoi4GateState -ExePath $exe
        if ($gate.Status -ne 'patched') {
            Write-Host "hoi4.exe 不是已打补丁状态（$(Format-Hoi4GateState $gate)），无法据此重建备份。先运行 -Action patch。" -ForegroundColor Red
            exit 1
        }
        New-Hoi4BackupFromPatched -ExePath $exe -Log $log
        $bak = Get-Hoi4BackupState -ExePath $exe
        Write-Host ("backup   : {0}" -f $bak.Reason) -ForegroundColor Green
        exit 0
    }

    'restore' {
        $bak = Get-Hoi4BackupState -ExePath $exe
        if (-not $bak.Usable) {
            Write-Host "拒绝还原：$($bak.Reason)。" -ForegroundColor Red
            Write-Host "请用 Steam 验证游戏完整性恢复原版，或先运行 -Action patch 重建备份。" -ForegroundColor Yellow
            exit 1
        }
        Assert-Hoi4NotRunning
        $patcher = Get-PatcherExe -GameDir $dir -Force:$ForceDownload
        Write-Host "Patcher: $patcher" -ForegroundColor Gray
        & $patcher restore $exe
        $after = Get-Hoi4GateState -ExePath $exe
        if ($after.Status -ne 'unpatched') {
            Write-Host "还原后检查失败：$(Format-Hoi4GateState $after)" -ForegroundColor Red
            exit 1
        }
        Write-Host "Restored: 未打补丁" -ForegroundColor Green
        exit 0
    }

    default { # patch
        Assert-Hoi4NotRunning
        Move-Hoi4StaleBackup -ExePath $exe -Log $log | Out-Null

        $patcher = Get-PatcherExe -GameDir $dir -Force:$ForceDownload
        Write-Host "Patcher: $patcher" -ForegroundColor Gray

        $out = @(& $patcher patch $exe 2>&1)
        foreach ($line in $out) {
            $clean = (Remove-AnsiText ([string]$line)).TrimEnd()
            if ($clean) { Write-Host $clean }
        }

        $gate = Get-Hoi4GateState -ExePath $exe
        if ($gate.Status -ne 'patched') {
            Write-Host ("补丁未生效：{0}" -f (Format-Hoi4GateState $gate)) -ForegroundColor Red
            exit 1
        }

        $bak = Get-Hoi4BackupState -ExePath $exe
        if (-not $bak.Usable) {
            Write-Host "备份不可用：$($bak.Reason)；正在从已打补丁的 exe 重建。" -ForegroundColor Yellow
            New-Hoi4BackupFromPatched -ExePath $exe -Log $log
            $bak = Get-Hoi4BackupState -ExePath $exe
        }

        Write-Host ("gate     : {0}（0x{1:X}）" -f (Format-Hoi4GateState $gate), $gate.GateOffset) -ForegroundColor Green
        Write-Host ("backup   : {0}" -f $bak.Reason) -ForegroundColor Green
        exit 0
    }
}
