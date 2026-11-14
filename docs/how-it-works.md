# 原理：为什么 1 个字节就能解锁成就

## 问题

HOI4 的 Steam 成就在铁人单人下解锁。游戏启动时计算文件校验和；任何改变校验和的 mod 会把"游戏未被修改"置为 false，成就被禁用。

## 门（checksum gate）

`hoi4.exe` 中 `gameapplication.cpp` 的判断形状：

```asm
test eax, eax      ; 85 C0    eax = 是否被修改
setz r8b           ; 0F 94 /r 未修改（eax==0）时 r8b = 1
call ...
```

把 `test eax,eax` 换成 `xor eax,eax`（`31 C0`）：eax 恒为 0，`setz` 恒为 1，"未修改"恒为真。
`85 C0` → `31 C0`，第二个字节不变，所以实际只改 **1 字节**。

## 定位：pattern + anchor，不硬编码地址

官方 patcher 的定位规则（`internal/core/signatures.json`）：

```json
"hoi4.exe": {
  "sites": [{
    "id": "checksum_gate",
    "anchor": "Active Mod Count:",
    "find": "85 C0 0F 94 ?? E8",
    "patchOffset": 0,
    "expect": "85 C0",
    "replace": "31 C0",
    "requireInFunc": true,
    "expectMatches": 1
  }]
}
```

约束：

1. `find` 匹配 `test eax,eax; setz r8b; call`，寄存器字节通配。
2. 匹配必须位于引用字符串 `Active Mod Count:` 的 `.pdata` 函数内 —— 排除误匹配。
3. 匹配数必须恰好 1，否则拒绝写入。
4. 写入前校验 `expect` 字节；先备份、原子写入；运行两次为 no-op。

## 1.19.5 实测

| 项 | 值 |
|---|---|
| 版本 | Operation Postern v1.19.5.0.7c6c (c184) |
| `hoi4.exe` 大小 | 56,535,160 字节 |
| 差异偏移 | `0x17671A`（0-based，= 1533722） |
| 变化 | `0x85 → 0x31` |
| 差异字节数 | 1 |

复核：

```powershell
fc /b hoi4.exe.backup hoi4.exe
# 00017671A: 85 31
```

## 版本适配

`status` 报 `not supported on this version` 时，说明上游签名未覆盖当前版本：

1. 用上游 `cmd/toolkit` 重新定位 gate；或按上面的 pattern/anchor 规则人工确认。
2. 必须验证：锚点函数引用、唯一匹配、`expect` 字节。
3. 不要盲目改偏移或猜测字节。

## 局限

- 只解除 checksum 门；铁人、单人、无作弊规则仍然生效。
- 游戏更新会覆盖 `hoi4.exe`，需重打。
- 不影响多人/联机成就（本就禁用）。
- mod 自己无法实现该功能：验证在引擎 exe 内，mod 脚本无权修改。
