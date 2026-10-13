# Sweep

macOS 菜单栏小工具：每天自动清理构建缓存和不再更新的 agent 对话。

起因是一个 Next.js 项目的 Turbopack dev 缓存悄悄涨到了 136G，加上 Codex / Claude 的会话记录、各种包缓存，把 1T 的硬盘占到了 97%。

## 组成

| 部分 | 位置 | 作用 |
|---|---|---|
| `SweepCore` | `Sources/SweepCore` | 规则、扫描、删除、标记名单，全部逻辑都在这里 |
| `sweep` | `~/.local/bin/sweep` | 命令行；定时任务和 agent 都调用它 |
| `Sweep.app` | `/Applications/Sweep.app` | 菜单栏界面：看状态、改设置、手动清理 |
| 定时任务 | `~/Library/LaunchAgents/com.jacklee.sweep.daily.plist` | 每天 03:00 运行 `sweep run --scheduled` |

菜单栏 app 只是查看和控制的窗口。它没开的时候，定时清理照常进行。

## 安装与升级

```bash
./scripts/install.sh     # 构建并安装，重复执行即升级
./scripts/uninstall.sh   # 卸载（保留配置、标记名单和日志）
```

需要 Xcode（用到其中的 Swift 工具链和测试框架）。

## 清理规则

每天检查一次，按「多久没更新」判断，而不是按固定周期清空。

| 规则 | 匹配范围 | 清理条件 | 默认 |
|---|---|---|---|
| 构建缓存 | `~/Projects` 下的 `.next`、`.next-*`、`*.bun-build`、`src-tauri/target` | 3 天没更新，或单个超过 10 GB | 开 |
| Agent 临时目录 | `~/.cache/bnbot-*`、`~/Library/Caches/bnbot-*` | 3 天没更新 | 开 |
| Agent 对话 | Codex 的 `sessions`、`archived_sessions`；Claude 的 `projects/*/<uuid>.jsonl` 及同名目录 | 3 天没更新且未标记 | 开 |
| 包管理器缓存 | Yarn、npm、uv、pip、pnpm store | 合计超过 20 GB 时全部清空 | 开 |
| Agent 产物 | `~/.codex/visualizations`、`generated_images` | 30 天没更新 | 关 |
| 工作副本 | `~/Projects/*-worktrees/*`、`~/Projects/*-build*` | 永不自动清理，只显示体积 | — |

阈值和开关在菜单栏的「设置」里改，或直接编辑 `~/Library/Application Support/Sweep/config.json`。

几个取舍：

- **构建缓存有体积上限**。一直在用的项目永远不会「3 天没更新」，那个 136G 的缓存正是这样长出来的。超过上限时如果检测到 dev server 在跑，就不删，改为发通知，等进程停了再清。
- **包缓存按体积而不是按时间**。它们一直在被使用，定期清空只会反复重新下载。
- **工作副本不自动删**。里面可能有未提交的代码。

## 保护规则

这些写死在代码里，不可配置，并且都有测试覆盖：

1. 每一项在删除前重新校验：必须真实存在、本身不是符号链接、解析符号链接后严格位于该规则的根目录内。
2. 路径中含 `memory` 或 `.git` 的一律拒绝。Claude 的记忆目录因此不可能被删。
3. 对话只认 UUID 形态的文件名，同级的其他文件不会命中。
4. 构建缓存里只要有被 git 跟踪的文件就跳过；git 给不出结论时也跳过。
5. 配置文件损坏时整次运行中止，不回退到默认值。
6. 标记名单损坏时，一条对话都不删。
7. 定时任务在用户亲手确认过一次清理之前，只扫描、不删除。

## 标记不想删的对话

在对话里对 agent 说「标记这个对话，别删」。agent 会运行：

```bash
sweep keep "标签"
```

这条规则写在 `~/.claude/CLAUDE.md` 和 `~/.codex/AGENTS.md` 里。

识别方式有两层：

- Claude Code 的环境里有 `CLAUDE_CODE_SESSION_ID`，直接按会话 ID 记入名单。
- 命令会输出一个标记串（`sweep-pin:v1:<uuid>`）。命令输出会被记入会话文件，清理前会在文件里查找名单中登记过的标记串。Codex 靠这一层。

只有名单里登记过的标记串才算数，所以文档或源码里出现这个前缀不会造成误标记。

```bash
sweep pins                 # 列出已标记的对话
sweep unkeep "标签"        # 取消标记
```

## 命令行

```bash
sweep scan [--all]         # 只扫描，列出会清理什么
sweep scan --timing        # 各规则扫描耗时
sweep run [--dry-run]      # 立即清理
sweep status               # 状态
sweep arm | disarm         # 开启 / 关闭自动清理
```

设置 `SWEEP_HOME=/某个目录` 可以把所有路径指向另一个目录，用来演练而不碰真实数据。

## 文件位置

| 内容 | 路径 |
|---|---|
| 配置、标记名单、运行状态、上次扫描结果 | `~/Library/Application Support/Sweep/` |
| 清理日志（每次删了什么、多大、为什么） | `~/Library/Logs/Sweep/sweep.log` |
| 定时任务的输出 | `~/Library/Logs/Sweep/launchd.log` |

## 已知限制

- **Codex 的索引库不会被清理。** `~/.codex/state_5.sqlite` 记录了每个会话文件的路径，`thread_history_1.sqlite` 存着会话内容的另一份投影（目前约 6.6G）。Sweep 只删会话文件，不动这两个库，所以 Codex 的历史列表里可能留下打不开的条目，这个库本身也不会变小。
- **包缓存的实际释放量可能低于显示值。** 体积统计能识别硬链接，但识别不了 APFS 的克隆文件；pnpm 在 macOS 上默认用克隆，被项目引用的那部分删掉后不会释放空间。
- **读不到受系统保护的目录。** 微信、Chrome 配置、邮件、废纸篓等需要「完全磁盘访问权限」，Sweep 不涉及这些。
- **只在本用户的图形会话里运行。** 定时任务是用户级 LaunchAgent，没登录时不会跑。

## 开发

```bash
swift test                                             # 全部测试
.build/release/SweepApp --snapshot out.png --expanded  # 把面板离屏渲染成图片
```
