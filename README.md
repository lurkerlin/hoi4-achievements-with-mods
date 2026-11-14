# HOI4 成就 + Mod 解锁

让启用 mod 的《钢铁雄心 IV》继续解锁 Steam 成就。修补 `hoi4.exe` 里的 checksum 门，使 mod 改变校验和时不再禁用成就。**不改变游戏规则。**

> 仍然需要 **铁人模式（Ironman）+ 单人游戏**。不解除控制台/作弊/多人限制。

## 已验证

| 项目 | 值 |
|---|---|
| 游戏 | Operation Postern v1.19.5.0.7c6c (c184) |
| `hoi4.exe` 大小 | 56,535,160 字节 |
| 补丁差异 | 恰好 1 字节：偏移 `0x17671A`（0-based），`0x85 → 0x31` |
| 备份 | `hoi4.exe.backup`，与原文件逐字节一致 |
| 验证 | `fc /b` 只报告这一处差异 |

## 快速开始

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
| `patch` | 应用补丁；首次会写 `hoi4.exe.backup` |
| `status` | 工具自检：`already patched` / `ready to patch` |
| `restore` | 从 `.backup` 还原原版 `hoi4.exe` |
| `verify` | 比较 exe 与 backup，要求恰好 1 字节 `0x85 → 0x31` |

## 前置条件

- Windows 10/11，Steam 版 HOI4
- 铁人模式 + 单人
- 首次运行需联网获取 patcher（GitHub 直连或内置镜像，均校验 SHA-256）

## 目录

```
scripts/Common.ps1        共享：Steam 库探测、SHA-256、下载
scripts/Patch-Hoi4.ps1    一键入口（patch/status/restore/verify）
scripts/Verify-Patch.ps1  字节级差异验证
docs/how-it-works.md      原理、1.19.5 实测偏移、版本适配
```

仓库不含任何二进制。patcher 在运行时下载，校验哈希后放在游戏目录复用。

## 更新后必须重打

Steam 更新、验证文件完整性、重装都会替换 `hoi4.exe`：

```powershell
.\scripts\Patch-Hoi4.ps1 -Action status   # 显示 ready to patch 即需要重打
.\scripts\Patch-Hoi4.ps1 -Action patch
```

旧版本的 `.backup` 不会被覆盖。若备份大小与当前 exe 不同（旧版本备份），`restore` 会拒绝，直接重新 `patch` 即可。

## 故障排查

| 现象 | 处理 |
|---|---|
| `not supported on this version` | 上游签名未覆盖该版本，见 `docs/how-it-works.md` 的版本适配 |
| 下载失败 | 脚本依次尝试 GitHub 与 gh-proxy/ghfast 镜像并校验哈希；仍失败可手动下载 patcher 放进游戏目录，脚本校验后复用 |
| 找不到游戏 | 加 `-GameDir '<含 hoi4.exe 的目录>'` |
| 杀软/EDR 报警 | 修改可执行文件属预期行为，本地单机修改 |

## 风险与合规

- 只改本地 `hoi4.exe`，只影响单人铁人成就；不开控制台、不碰多人、不改游戏规则。
- HOI4 无 VAC，但修改可执行文件属于灰色地带；Paradox 未来若加检测可能失效。
- 不要分发修改后的 `hoi4.exe`（版权）。本仓库只分发脚本。
- 使用后果自负。

## 致谢

- [IlliaYalovoi/universal-checksum-patcher](https://github.com/IlliaYalovoi/universal-checksum-patcher)（MIT）：实际打补丁的官方工具，本仓库脚本封装并校验它。
- 社区 Ghidra 逆向研究（Steam 指南 "How to Play with Mods and Get Achievements"）。
