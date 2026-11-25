#Requires -Version 5.1
<#
.SYNOPSIS
  Click-to-patch GUI for HOI4 achievements with mods.

.DESCRIPTION
  Auto-detects the Steam install, reports game version / exe size / enabled mods,
  shows patch state, and patches or restores hoi4.exe with progress logging.
  Downloads universal-checksum-patcher on demand and verifies its SHA-256.

.PARAMETER SelfTest
  Print collected game info to stdout and exit (no window).

.PARAMETER RunAction
  Run one action headlessly (no window): patch or restore. Used for scripting
  and smoke tests.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [ValidateSet('patch', 'restore')]
    [string]$RunAction
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $PSScriptRoot 'Common.ps1')

$script:LogBox      = $null
$script:StatusLabel = $null
$script:IsWorking   = $false

function Write-UiLog {
    param([string]$Message)
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + "`r`n")
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
    Write-Host $line
}

function Get-PatchState {
    param([string]$Dir)

    $exe = Join-Path $Dir 'hoi4.exe'
    try {
        return (Format-Hoi4GateState (Get-Hoi4GateState -ExePath $exe))
    } catch {
        return "无法检查：$($_.Exception.Message)"
    }
}

function Get-GameInfo {
    param([string]$Dir)

    $exe = Join-Path $Dir 'hoi4.exe'
    $info = [ordered]@{
        Dir        = $Dir
        Exe        = $exe
        Version    = '未知'
        RawVersion = ''
        ExeSize    = 0
        ExeTime    = $null
        Mods       = 0
        State      = '未知'
        Backup     = '未知'
        Patcher    = '未下载'
    }

    $ls = Join-Path $Dir 'launcher-settings.json'
    if (Test-Path -LiteralPath $ls) {
        try {
            $j = Get-Content -LiteralPath $ls -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.version)    { $info.Version = [string]$j.version }
            if ($j.rawVersion) { $info.RawVersion = [string]$j.rawVersion }
        } catch { }
    }

    if (Test-Path -LiteralPath $exe) {
        $fi = Get-Item -LiteralPath $exe
        $info.ExeSize = $fi.Length
        $info.ExeTime = $fi.LastWriteTime
    }

    $dl = Join-Path $env:USERPROFILE 'Documents\Paradox Interactive\Hearts of Iron IV\dlc_load.json'
    if (Test-Path -LiteralPath $dl) {
        try {
            $dj = Get-Content -LiteralPath $dl -Raw -Encoding UTF8 | ConvertFrom-Json
            $info.Mods = @($dj.enabled_mods).Count
        } catch { }
    }

    $p = Join-Path $Dir $PatcherAsset
    if (Test-Path -LiteralPath $p) {
        $info.Patcher = "$PatcherVersion（已缓存）"
    }

    $info.State = Get-PatchState -Dir $Dir
    if (Test-Path -LiteralPath $exe) {
        try { $info.Backup = (Get-Hoi4BackupState -ExePath $exe).Reason } catch { $info.Backup = "无法检查：$($_.Exception.Message)" }
    }
    return $info
}

function Assert-NotRunning {
    $p = @(Get-Process -Name 'hoi4' -ErrorAction SilentlyContinue)
    if ($p.Count -gt 0) {
        Write-UiLog '检测到 hoi4 正在运行，请先完全退出游戏再操作。'
        return $false
    }
    return $true
}

function Get-PatcherWithUi {
    param([string]$GameDir)

    $dest = Join-Path $GameDir $PatcherAsset
    if (Test-Path -LiteralPath $dest) {
        $h = Get-Sha256Hex -Path $dest
        if ($h -eq $PatcherSha256) {
            Write-UiLog "复用已校验的 patcher：$dest"
            return $dest
        }
        Write-UiLog '现有 patcher 哈希不匹配，重新下载。'
    }

    $urls = @($PatcherRelease) + $PatcherMirrors
    $tmp = Join-Path $env:TEMP ("ucp-gui-{0}.exe" -f [guid]::NewGuid().ToString('N'))

    foreach ($u in $urls) {
        Write-UiLog "下载：$u"
        if ($script:StatusLabel) { $script:StatusLabel.Text = '正在下载 patcher…' }
        [System.Windows.Forms.Application]::DoEvents()
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
        try {
            $task = $wc.DownloadFileTaskAsync([uri]$u, $tmp)
            while (-not $task.IsCompleted) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 80
            }
            if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
            $h = Get-Sha256Hex -Path $tmp
            if ($h -eq $PatcherSha256) {
                Move-Item -LiteralPath $tmp -Destination $dest -Force
                Write-UiLog "SHA-256 校验通过：$h"
                return $dest
            }
            Write-UiLog "哈希不匹配（$h），尝试下一个源。"
        } catch {
            Write-UiLog "下载失败：$($_.Exception.Message)"
        } finally {
            $wc.Dispose()
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
    throw '无法获取校验通过的 patcher。可手动下载后放进游戏目录。'
}

function Invoke-Workflow {
    param([ValidateSet('patch', 'restore')][string]$Action)

    if (-not (Assert-NotRunning)) { return 1 }
    $dir = Find-Hoi4Dir
    $exe = Join-Path $dir 'hoi4.exe'
    Write-UiLog "游戏目录：$dir"

    if ($Action -eq 'restore') {
        $bak = Get-Hoi4BackupState -ExePath $exe
        if (-not $bak.Usable) {
            Write-UiLog "拒绝还原：$($bak.Reason)"
            Write-UiLog '请用 Steam 验证游戏完整性恢复原版，或先点“打补丁”重建备份。'
            return 1
        }
    } else {
        $null = Move-Hoi4StaleBackup -ExePath $exe -Log { param($m) Write-UiLog $m }
    }

    $patcher = Get-PatcherWithUi -GameDir $dir
    Write-UiLog "执行：universal-checksum-patcher.exe $Action"
    $out = @(& $patcher $Action $exe 2>&1)
    foreach ($line in $out) {
        $clean = (Remove-AnsiText ([string]$line)).TrimEnd()
        if ($clean) { Write-UiLog $clean }
    }

    $gate = Get-Hoi4GateState -ExePath $exe

    if ($Action -eq 'patch') {
        if ($gate.Status -ne 'patched') {
            Write-UiLog "补丁未生效：$(Format-Hoi4GateState $gate)"
            return 1
        }
        $bak = Get-Hoi4BackupState -ExePath $exe
        if (-not $bak.Usable) {
            Write-UiLog "备份不可用：$($bak.Reason)；正在从已打补丁的 exe 重建。"
            New-Hoi4BackupFromPatched -ExePath $exe -Log { param($m) Write-UiLog $m }
            $bak = Get-Hoi4BackupState -ExePath $exe
        }
        Write-UiLog "补丁状态：$(Format-Hoi4GateState $gate)"
        Write-UiLog "备份状态：$($bak.Reason)"
        Write-UiLog '完成。以铁人模式 + 单人启动游戏即可继续解成就。'
        return 0
    }

    if ($gate.Status -ne 'unpatched') {
        Write-UiLog "还原后检查失败：$(Format-Hoi4GateState $gate)"
        return 1
    }
    Write-UiLog '已还原为原版。'
    return 0
}

# ------------------------------------------------------- headless modes ---

if ($SelfTest) {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $dir = Find-Hoi4Dir
    $info = Get-GameInfo -Dir $dir
    "GameDir    = $($info.Dir)"
    "Version    = $($info.Version)"
    "RawVersion = $($info.RawVersion)"
    "ExeSize    = $($info.ExeSize)"
    "ExeTime    = $($info.ExeTime)"
    "Mods       = $($info.Mods)"
    "State      = $($info.State)"
    "Backup     = $($info.Backup)"
    "Patcher    = $($info.Patcher)"
    exit 0
}

if ($RunAction) {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try {
        exit (Invoke-Workflow -Action $RunAction)
    } catch {
        Write-Host "错误：$($_.Exception.Message)"
        exit 1
    }
}

# ---------------------------------------------------------------- UI ------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'HOI4 成就 + Mod 解锁'
$form.ClientSize = New-Object System.Drawing.Size(780, 680)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$grpInfo = New-Object System.Windows.Forms.GroupBox
$grpInfo.Text = '游戏信息'
$grpInfo.Location = New-Object System.Drawing.Point(12, 10)
$grpInfo.Size = New-Object System.Drawing.Size(756, 206)
$form.Controls.Add($grpInfo)

function New-InfoRow {
    param($Parent, [int]$Y, [string]$Caption)
    $cap = New-Object System.Windows.Forms.Label
    $cap.Text = $Caption
    $cap.Location = New-Object System.Drawing.Point(12, $Y)
    $cap.Size = New-Object System.Drawing.Size(92, 20)
    $cap.ForeColor = [System.Drawing.Color]::DimGray
    $Parent.Controls.Add($cap)

    $val = New-Object System.Windows.Forms.Label
    $val.Location = New-Object System.Drawing.Point(108, $Y)
    $val.Size = New-Object System.Drawing.Size(632, 20)
    $val.AutoEllipsis = $true
    $Parent.Controls.Add($val)
    return $val
}

$lblGame    = New-InfoRow $grpInfo 26 '游戏目录'
$lblVersion = New-InfoRow $grpInfo 52 '游戏版本'
$lblExe     = New-InfoRow $grpInfo 78 'hoi4.exe'
$lblMods    = New-InfoRow $grpInfo 104 '启用 Mod'
$lblState   = New-InfoRow $grpInfo 130 '补丁状态'
$lblTool    = New-InfoRow $grpInfo 156 '工具 / 签名'
$lblBackup  = New-InfoRow $grpInfo 182 '备份状态'

$btnPatch = New-Object System.Windows.Forms.Button
$btnPatch.Text = '打补丁'
$btnPatch.Location = New-Object System.Drawing.Point(12, 226)
$btnPatch.Size = New-Object System.Drawing.Size(150, 38)
$btnPatch.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnPatch)

$btnRestore = New-Object System.Windows.Forms.Button
$btnRestore.Text = '还原原版'
$btnRestore.Location = New-Object System.Drawing.Point(172, 226)
$btnRestore.Size = New-Object System.Drawing.Size(120, 38)
$form.Controls.Add($btnRestore)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新信息'
$btnRefresh.Location = New-Object System.Drawing.Point(302, 226)
$btnRefresh.Size = New-Object System.Drawing.Size(110, 38)
$form.Controls.Add($btnRefresh)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = '打开游戏目录'
$btnOpen.Location = New-Object System.Drawing.Point(422, 226)
$btnOpen.Size = New-Object System.Drawing.Size(140, 38)
$form.Controls.Add($btnOpen)

$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = '执行日志'
$grpLog.Location = New-Object System.Drawing.Point(12, 274)
$grpLog.Size = New-Object System.Drawing.Size(756, 370)
$grpLog.Anchor = 'Top,Left,Right,Bottom'
$form.Controls.Add($grpLog)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.WordWrap = $false
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.Location = New-Object System.Drawing.Point(10, 20)
$logBox.Size = New-Object System.Drawing.Size(736, 338)
$logBox.Anchor = 'Top,Left,Right,Top'
$grpLog.Controls.Add($logBox)
$logBox.Anchor = 'Top,Left,Right,Bottom'
$script:LogBox = $logBox

$status = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = '就绪'
$status.Items.Add($statusLabel) | Out-Null
$form.Controls.Add($status)
$script:StatusLabel = $statusLabel

# ----------------------------------------------------------- behavior ------

function Update-GameInfo {
    try {
        $dir = Find-Hoi4Dir
        $info = Get-GameInfo -Dir $dir
        $lblGame.Text = $info.Dir
        $lblVersion.Text = "$($info.Version)（raw $($info.RawVersion)）"
        $lblExe.Text = ('{0:N0} 字节 · {1:yyyy-MM-dd HH:mm}' -f $info.ExeSize, $info.ExeTime)
        $lblMods.Text = "$($info.Mods) 个"
        $lblState.Text = $info.State
        $lblTool.Text = "universal-checksum-patcher $PatcherVersion（内置签名：hoi4 / eu4 / eu5）"
        $lblBackup.Text = $info.Backup
        return $info
    } catch {
        $lblGame.Text = $_.Exception.Message
        $lblVersion.Text = '-'
        $lblExe.Text = '-'
        $lblMods.Text = '-'
        $lblState.Text = '无法定位游戏'
        $lblTool.Text = "universal-checksum-patcher $PatcherVersion"
        $lblBackup.Text = '-'
        return $null
    }
}

function Set-Busy {
    param([bool]$Busy)
    $script:IsWorking = $Busy
    $btnPatch.Enabled = -not $Busy
    $btnRestore.Enabled = -not $Busy
    $btnRefresh.Enabled = -not $Busy
    $form.UseWaitCursor = $Busy
}

function Start-Patch {
    if ($script:IsWorking) { return }
    Set-Busy $true
    $script:StatusLabel.Text = '正在打补丁…'
    try {
        $rc = Invoke-Workflow -Action 'patch'
        $script:StatusLabel.Text = if ($rc -eq 0) { '完成：补丁已生效' } else { '完成，但状态需要检查' }
        Update-GameInfo | Out-Null
    } catch {
        Write-UiLog "错误：$($_.Exception.Message)"
        $script:StatusLabel.Text = '失败'
    } finally {
        Set-Busy $false
    }
}

function Start-Restore {
    if ($script:IsWorking) { return }
    Set-Busy $true
    $script:StatusLabel.Text = '正在还原…'
    try {
        $rc = Invoke-Workflow -Action 'restore'
        $script:StatusLabel.Text = if ($rc -eq 0) { '已还原' } else { '还原失败，请查看日志' }
        Update-GameInfo | Out-Null
    } catch {
        Write-UiLog "错误：$($_.Exception.Message)"
        $script:StatusLabel.Text = '失败'
    } finally {
        Set-Busy $false
    }
}

$btnPatch.Add_Click({ Start-Patch })
$btnRestore.Add_Click({ Start-Restore })
$btnRefresh.Add_Click({ Update-GameInfo | Out-Null; Write-UiLog '已刷新游戏信息。'; $script:StatusLabel.Text = '就绪' })
$btnOpen.Add_Click({
    try { Start-Process explorer.exe (Find-Hoi4Dir) } catch { Write-UiLog "错误：$($_.Exception.Message)" }
})

$form.Add_Shown({
    Write-UiLog "HOI4 成就 + Mod 解锁 · patcher $PatcherVersion"
    Write-UiLog '启动即自动检测游戏；点“打补丁”执行。'
    Update-GameInfo | Out-Null
    $script:StatusLabel.Text = '就绪'
})

[void]$form.ShowDialog()
