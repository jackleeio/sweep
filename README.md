# Sweep

macOS 菜单栏小工具：自动清理构建缓存、闲置依赖、各类下载缓存和不再更新的 agent 对话，目标是让磁盘始终留有足够的余量。

起因是一个 Next.js 项目的 Turbopack dev 缓存悄悄涨到了 136G，加上 agent 的会话记录、各种包缓存，把 1T 的硬盘占到了 97%。

## 组成

| 部分 | 位置 | 作用 |
|---|---|---|
| `SweepCore` | `Sources/SweepCore` | 规则、扫描、删除、标记名单、调度，全部逻辑都在这里 |
| `sweep` | `~/.local/bin/sweep` | 命令行；定时任务和 agent 都调用它 |
| `Sweep.app` | `/Applications/Sweep.app` | 菜单栏界面：看状态、展开明细、改设置、手动清理 |
| 定时任务 | `~/Library/LaunchAgents/com.jacklee.sweep.daily.plist` | 每 10 分钟调用一次 `sweep run --scheduled` |

菜单栏 app 只是查看和控制的窗口。它没开的时候，定时清理照常进行。

## 安装与升级

```bash
./scripts/install.sh     # 构建并安装，重复执行即升级
./scripts/uninstall.sh   # 卸载（保留配置、标记名单和日志）
```

需要 Xcode（用到其中的 Swift 工具链和测试框架）。

## 什么时候清理

定时任务每 10 分钟被唤起一次，绝大多数时候什么都不做、立刻退出：

- **每日例行**：每天 03:00 之后的第一次唤起做一次清理。当时在睡眠就等唤醒后补上。
- **空间不足**：可用空间低于警戒线（默认 100 GB）时立即清理，不等第二天；每小时最多一次。
- **达不到目标余量**：每日清理后可用空间仍低于目标（默认 300 GB），就按收紧规则再清一遍。
- **尚未确认**：用户亲手确认过一次清理之前，只扫描并提醒，不删除任何东西。

收紧规则指：缓存类规则从「3 天没更新」收紧到「1 小时没更新」，包缓存不看上限直接清空，闲置依赖的门槛降到 3 天。对话规则不受影响，空间再紧张也不会加快删除对话。

## 清理规则

| 规则 | 匹配范围 | 清理条件 | 默认 |
|---|---|---|---|
| 构建缓存 | `~/Projects` 下的 `.next`、`.next-*`、`*.bun-build`、`src-tauri/target` | 3 天没更新，或单个超过 10 GB | 开 |
| 闲置项目的依赖 | `node_modules`，以及有锁文件或 requirements 的虚拟环境 | 所在项目 14 天没有改动 | 开 |
| 工作树和构建副本 | `~/Projects/*-worktrees/*`、`~/Projects/*-build*`、`~/.codex/worktrees/*/*` | 干净、14 天没动、提交都在分支上的 git 工作树 | 关 |
| 包与工具缓存 | Yarn、npm、pnpm、bun、uv、pip 的下载缓存，Docker Scout | 合计超过 20 GB 时全部清空 | 开 |
| 应用缓存 | `~/Library/Caches` 下其他应用的缓存 | 3 天没更新 | 开 |
| Agent 临时目录 | `~/.cache/bnbot-*`、`~/Library/Caches/bnbot-*` | 3 天没更新 | 开 |
| Codex 对话 | `~/.codex/sessions`、`archived_sessions` 里的会话文件，含压缩后的 `.jsonl.zst` | 见下一节 | 开 |
| Claude 对话 | `~/.claude/projects/*/<uuid>.jsonl` 及同名目录 | 7 天没更新且未标记 | 开 |
| Agent 产物 | `~/.codex/visualizations`、`generated_images` | 30 天没更新 | 关 |
| 语音输入的录音 | 闪电说的 `workspace/history/recordings` | 7 天前的 | 开 |
| 其他大户 | Docker 虚拟磁盘、Claude 虚拟机镜像、Codex 索引库、BNBot 日志库 | 永不清理，只显示体积 | — |

上表是程序的默认值。开关和阈值在菜单栏的「设置」里改，保存在 `~/Library/Application Support/Sweep/config.json`。内置的路径列表写在代码里，配置文件只保存额外添加的（`extraPaths` 等）和 `excludes`（任何规则都不碰的路径）。

扫描时关着的规则也会量出来，界面上照常显示「打开后能清多少」，但不会清理，也不计入合计。

几个取舍：

- **构建缓存有体积上限**。一直在用的项目永远不会「3 天没更新」，那个 136G 的缓存正是这样长出来的。超过上限时如果检测到 dev server 在跑，就不删，改为发通知。
- **包缓存按体积而不是按时间**。它们一直在被使用，定期清空只会反复重新下载。
- **依赖按项目是否活跃判断**。项目的活跃时间取源码、git 操作和最近一次安装三者中最新的；同一个 git 仓库里的包共用一个时间，避免只清掉 monorepo 的一部分。
- **应用缓存默认保留 AI 工具的**。名字里含 openai、claude、codex、bnbot、cursor 等关键词的照常列出体积，但不清理。
- **工作树只移除有把握的**。必须是 git 工作树、没有任何未提交或未跟踪的改动、当前提交在某个分支上。移除的只是检出的文件，分支留在主仓库里。不是 git 工作树的普通副本永远只展示。

### Codex 对话怎么判断

Sweep 只读地查看 Codex 自己的状态（`state_5.sqlite` 和 `.codex-global-state.json`），把对话分成几类，界面上逐类显示数量和体积：

| 类别 | 处理 |
|---|---|
| 在 Codex 里 pin 的 | 保留 |
| 在置顶项目里的（按工作目录、分配记录或侧栏顺序判断） | 保留 |
| 用 `sweep keep` 标记的 | 保留 |
| 7 天内更新过的 | 保留 |
| 7 天以上没更新的 | 删除 |
| 已归档的 | 安静 3 天后删除 |
| 子 agent 的会话 | 跟随所属对话：所属对话保留它就保留，所属对话删除它也删除 |
| 文件还在、但 Codex 里已经没有记录的 | 7 天以上没更新则删除 |

读不懂 Codex 的状态时，一条 Codex 对话都不删。

Codex 会把旧会话压缩成 `.jsonl.zst`，压缩后的内容无法搜索标记串。所以每次扫描都会趁会话文件还没被压缩，把 `sweep keep` 的标记串对上会话 ID 并写进名单；对于还没对上号的标记，任何在它之后更新过的压缩文件都按「可能是它」保留。

## 保护规则

这些写死在代码里，并且都有测试覆盖：

1. 每一项在删除前重新校验：必须真实存在、本身不是符号链接、解析符号链接后严格位于该规则的根目录内。
2. 路径中含 `memory` 或 `.git` 的一律拒绝。Claude 的记忆目录因此不可能被删。
3. 对话只认 UUID 形态的文件名，同级的其他文件不会命中。
4. 构建缓存和依赖里只要有被 git 跟踪的文件就跳过；git 给不出结论时也跳过。
5. 被项目目录之外引用的项目，依赖一律保留。引用来源包括全局 link 的包、PATH 上的命令、各 agent 的技能链接、定时任务配置。`sweep refs` 可以查看当前识别到的引用。
6. 读不全的目录一律保留。
7. 配置文件损坏时整次运行中止，不回退到默认值。
8. 标记名单损坏时，一条对话都不删。
9. 每删完一项立即写日志。清理中途被终止，已删的部分也有记录。

第 5 条和第 9 条是吃过亏之后补的：早期版本删掉了 `bnbot-kit/cli` 的 `node_modules`，而 `bnbot` 命令是 npm link 到那里的；同一次清理被中途终止后，日志里什么都没留下。

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
sweep scan [--all] [--tight]    # 只扫描，列出会清理什么
sweep scan --timing             # 各规则扫描耗时
sweep run [--dry-run] [--tight] # 立即清理
sweep status                    # 状态
sweep refs                      # 被外部引用的项目路径
sweep arm | disarm              # 开启 / 关闭自动清理
```

设置 `SWEEP_HOME=/某个目录` 可以把所有路径指向另一个目录，用来演练而不碰真实数据。

## 文件位置

| 内容 | 路径 |
|---|---|
| 配置、标记名单、运行状态、上次扫描结果 | `~/Library/Application Support/Sweep/` |
| 清理日志（每次删了什么、多大、为什么） | `~/Library/Logs/Sweep/sweep.log` |
| 定时任务的输出 | `~/Library/Logs/Sweep/launchd.log` |

## 已知限制

- **Codex 的索引库不会被清理。** `~/.codex/state_5.sqlite` 记录了每个会话文件的路径，`thread_history_1.sqlite` 存着会话内容的另一份投影（约 7G）。Sweep 只删会话文件，不动这两个库。
- **体积是估算。** 能识别硬链接，但识别不了 APFS 的克隆文件；实际释放量可能低于显示值。
- **读不到受系统保护的目录。** 微信、Chrome 配置、邮件、废纸篓等需要「完全磁盘访问权限」，Sweep 不涉及这些。
- **只在本用户的图形会话里运行。** 定时任务是用户级 LaunchAgent，没登录时不会跑。

## 开发

```bash
swift test                                                       # 全部测试
.build/release/SweepApp --snapshot out.png --open conversations  # 把面板内容离屏渲染成图片（不含玻璃外壳）
SWEEP_DEBUG_FRAME=frame.txt .build/release/SweepApp --show-panel # 固定显示真实面板并写出窗口位置，供截屏核对
```
