# Sweep 开发约定

这是一个会删除文件的工具。改动时守住两条：先写测试再实现；任何新规则都要有「读不懂、拿不准就不删」的兜底。

## 常用命令

```bash
swift test                 # 全部测试
./scripts/install.sh       # 构建并安装到本机（app、命令行、定时任务）
sweep scan                 # 只读扫描，验证规则在真实数据上的结果
```

## 提交与发版

- **每次改动都提交**：测试通过、并在本机装上验证过之后立即提交，然后 `git push`。提交说明用中文，遵循 conventional commits（`feat:` / `fix:` / `refactor:` / `docs:` / `chore:`）。
- **适时发版**：用户能感知到的改动攒成一个完整可用的单元，就发一版：

  ```bash
  ./scripts/release.sh <x.y.z> <发版说明文件>
  ```

  新功能升次版本号（0.2.0 → 0.3.0），只有修复升修订号（0.2.0 → 0.2.1）。发版说明用中文，写给使用者看：这版能做什么、改了什么、需要注意什么。
  脚本会编译通用二进制、用 Developer ID 签名、提交 Apple 公证并打成 DMG，需要钥匙串里的证书和 `sweep-notary` 公证配置（见脚本开头）。
- 仓库：<https://github.com/jackleeio/sweep>。

## 结构

| 位置 | 内容 |
|---|---|
| `Sources/SweepCore` | 规则、扫描、删除、调度，全部逻辑 |
| `Sources/sweep` | 命令行 |
| `Sources/SweepApp` | 菜单栏界面 |
| `Tests/SweepCoreTests` | 测试；`TestSupport.swift` 里有假 home 和假 Codex 目录的搭建工具 |
| `scripts` | 安装、卸载、发版脚本，app 的 Info.plist，定时任务模板 |

规则和保护机制的完整说明见 README。README 有中英两版（`README.md` 英文、`README.zh-CN.md` 中文），改动行为时两份要一起更新。
