# HOI4 成就 + Mod 解锁

让启用 mod 的《钢铁雄心 IV》继续解锁 Steam 成就。修补 `hoi4.exe` 里的 checksum 门，使 mod 改变校验和时不再禁用成就。**不改变游戏规则。**

> 仍然需要 **铁人模式（Ironman）+ 单人游戏**。不解除控制台/作弊/多人限制。

## 已验证

| 项目 | 值 |
|---|---|
| 游戏 | Operation Postern v1.20.0.0.8873 (0c4f) |
| `hoi4.exe` 大小 | 56,556,664 字节 |
| 补丁差异 | 恰好 1 字节：偏移 `0x1767AA`（0-based），`0x85 → 0x31` |
| 备份 | `hoi4.exe.backup`，与原文件逐字节一致 |
| 验证 | `fc /b` 只报告这一处差异 |

补丁按“签名 + 锚点”定位，不依赖固定偏移；上表偏移仅用于复核。`status` 会直接解析 PE 的 `.pdata` 与锚点函数，离线判断补丁是否真正生效；同时读取 exe 内嵌的 `Operation Postern v<版本>` 字符串，与备份的版本比对，因此**同尺寸的 Steam 更新也能识别为旧备份**。

## 图形界面（双击）

双击仓库根目录的 **`启动.bat`**，窗口里会显示：

- 游戏目录、游戏版本（含 exe 内嵌版本）、`hoi4.exe` 大小与修改时间、启用 Mod 数、当前补丁状态、备份状态（含版本比对）；
- 点 **打补丁**：自动下载并 SHA-256 校验 patcher、备份 exe、应用补丁、字节级复核，全过程逐行写入日志；旧版本备份会自动保留并重建当前版本备份；
- **还原原版** / **刷新信息** / **打开游戏目录**。

下载在后台异步进行，窗口不会冻结；GitHub 失败时自动切换 gh-proxy / ghfast 镜像。

也可以不开窗口：

```powershell
.\scripts\Hoi4AchievementsGui.ps1 -RunAction patch     # 直接打补丁
.\scripts\Hoi4AchievementsGui.ps1 -RunAction restore   # 直接还原
.\scripts\Hoi4AchievementsGui.ps1 -SelfTest            # 只打印版本与状态
```

## 命令行

```powershell
# 1. 打补丁：自动定位游戏、下载并 SHA-256 校验 patcher、备份 exe
.\scripts\Patch-Hoi4.ps1 -Action patch

# 2. 字节级验证：应只有 1 字节变化（85 -> 31）
.\scripts\Patch-Hoi4.ps1 -Action verify

# 3. 查看状态 / 还原
.\scripts\Patch-Hoi4.ps1 -Action status
.\scripts\Patch-Hoi4.ps1 -Action restore
```

被 PowerShell 执行策略拦截时：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Patch-Hoi4.ps1 -Action patch
```

游戏不在默认 Steam 库时，显式指定：

```powershell
.\scripts\Patch-Hoi4.ps1 -Action patch -GameDir 'E:\SteamLibrary\steamapps\common\Hearts of Iron IV'
```

## Action

| Action | 作用 |
|---|---|
| `patch` | 应用补丁；旧版本备份自动保留为 `.backup.old-*`，备份缺失/不可用时从已打补丁的 exe 重建 |
| `status` | 离线检查 gate 与备份状态（不需要 patcher） |
| `restore` | 从 `.backup` 还原；备份与当前 exe 大小或 gate 偏移不符时拒绝 |
| `verify` | 比较 exe 与 backup，要求恰好 1 字节 `0x85 → 0x31` |
| `rebuild-backup` | 在已打补丁状态下，从 exe 逆向重建正确的 `.backup` |

## 前置条件

- Windows 10/11，Steam 版 HOI4
- 铁人模式 + 单人
- 首次运行需联网获取 patcher（GitHub 直连或内置镜像，均校验 SHA-256）

## 目录

```
启动.bat                          双击启动图形界面
scripts/Hoi4AchievementsGui.ps1   图形界面（含 -SelfTest / -RunAction 无窗口模式）
scripts/Common.ps1                共享：Steam 库探测、SHA-256、下载、gate 定位、备份维护
scripts/Patch-Hoi4.ps1            命令行入口（patch/status/restore/verify/rebuild-backup）
scripts/Verify-Patch.ps1          字节级差异验证
docs/how-it-works.md              原理、1.20 实测偏移、备份/还原、版本适配
```

仓库不含任何二进制。patcher 在运行时下载，校验哈希后放在游戏目录复用。

## 更新后必须重打

Steam 更新、验证文件完整性、重装都会替换 `hoi4.exe`：

```powershell
.\scripts\Patch-Hoi4.ps1 -Action status   # 显示“未打补丁”即需要重打
.\scripts\Patch-Hoi4.ps1 -Action patch
```

旧版本的 `.backup` 不会被 patcher 覆盖。`patch` 会先把不可用的旧备份（大小、内嵌版本或 gate 偏移不一致）改名为 `hoi4.exe.backup.old-<时间>`，再让 patcher 写入当前版本的备份；若 exe 已经是补丁状态但没有可用备份，则直接从 exe 逆向重建（gate 只差 1 字节，可精确还原）。`restore` 会拒绝版本或 gate 偏移不一致的备份，避免把游戏降级到旧版本。

## 故障排查

| 现象 | 处理 |
|---|---|
| `not supported on this version` | 上游签名未覆盖该版本，见 `docs/how-it-works.md` 的版本适配 |
| 状态显示“已打补丁”但备份是旧版本 | 运行 `-Action patch`：自动保留旧备份并重建当前版本备份 |
| `restore` 提示拒绝还原 | 备份来自旧版本；先 `-Action patch` 重建，或用 Steam 验证完整性 |
| 下载失败 | 脚本依次尝试 GitHub 与 gh-proxy/ghfast 镜像并校验哈希；仍失败可手动下载 patcher 放进游戏目录，脚本校验后复用 |
| 找不到游戏 | 加 `-GameDir '<含 hoi4.exe 的目录>'` |
| 杀软/EDR 报警 | 修改可执行文件属预期行为，本地单机修改 |

## 风险与合规

- 只改本地 `hoi4.exe`，只影响单人铁人成就；不开控制台、不碰多人、不改游戏规则。
- HOI4 无 VAC，但修改可执行文件属于灰色地带；Paradox 未来若加检测可能失效。
- 不要分发修改后的 `hoi4.exe`（版权）。本仓库只分发脚本。
- 使用后果自负。

## 分发与创意工坊

发布包（源码，无二进制）：

```powershell
.\scripts\Build-Release.ps1 -Version 1.0.1
# -> dist/hoi4-achievements-with-mods-v1.0.1.zip，并输出 SHA-256
```

**这个工具不能做成 HOI4 创意工坊 mod。** 原因：

- 创意工坊 mod 只能提供游戏数据（`common/`、`gfx/`、`localisation/` 等），不能修改 `hoi4.exe`；
- 成就的 checksum 验证在引擎可执行文件内，mod 脚本无权绕过；
- Steam 工坊不允许分发修改游戏的可执行补丁，订阅者也不会自动得到补丁。

工坊条目最多只能做一个"说明/辅助"的空 mod，无法真正解锁成就。因此本工具通过 zip / GitHub Releases 分发，每位玩家在本地运行。

## 致谢

- [IlliaYalovoi/universal-checksum-patcher](https://github.com/IlliaYalovoi/universal-checksum-patcher)（MIT）：实际打补丁的官方工具，本仓库脚本封装并校验它。
- 社区 Ghidra 逆向研究（Steam 指南 "How to Play with Mods and Get Achievements"）。
