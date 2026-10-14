# Sweep

English | [中文](README.zh-CN.md)

A macOS menu bar utility that automatically cleans up build caches, idle dependencies, download caches and stale AI-agent conversations, so your disk always keeps enough free space.

It started when a Next.js project's Turbopack dev cache quietly grew to 136 GB. Together with agent session logs and package caches, that filled a 1 TB disk to 97%.

## Components

| Part | Location | Role |
|---|---|---|
| `SweepCore` | `Sources/SweepCore` | Rules, scanning, deletion, the pin list and scheduling — all the logic lives here |
| `sweep` | `~/.local/bin/sweep` | Command-line tool, called by the scheduled job and by agents |
| `Sweep.app` | `/Applications/Sweep.app` | Menu bar panel: status, per-rule details, settings, manual cleanup |
| Scheduled job | `~/Library/LaunchAgents/com.jacklee.sweep.daily.plist` | Runs `sweep run --scheduled` every 10 minutes |

The menu bar app is only a window for viewing and control. Scheduled cleanup keeps running when it is closed.

## Install and upgrade

From source (recommended — this also installs the CLI and the scheduled job):

```bash
./scripts/install.sh     # build and install; run again to upgrade
./scripts/uninstall.sh   # uninstall (keeps settings, pin list and logs)
```

Requires Xcode (for the Swift toolchain and test frameworks).

You can also download a packaged `Sweep.app` from [Releases](https://github.com/jackleeio/sweep/releases), with three limitations for now: Apple silicon only; not notarized yet, so macOS blocks the first launch and you need to allow it under System Settings › Privacy & Security; and it is only the menu bar app — the CLI and scheduled job still need a source install.

## When it cleans

The scheduled job wakes up every 10 minutes and almost always exits immediately:

- **Daily**: the first wake-up after 03:00 runs a cleanup. If the Mac was asleep, it catches up after waking.
- **Low space**: when free space drops below the floor (100 GB by default), it cleans right away instead of waiting for the next day — at most once an hour.
- **Below target**: if free space is still under the target (300 GB by default) after the daily cleanup, it runs a second pass with tighter rules.
- **Not yet confirmed**: until you confirm a cleanup by hand once, it only scans and notifies; nothing is deleted.

Tighter rules mean: cache rules go from "untouched for 3 days" to "untouched for 1 hour", package caches are emptied regardless of their cap, and the idle-dependency threshold drops to 3 days. Conversation rules are never tightened — low disk space never speeds up conversation deletion.

## Rules

| Rule | Scope | Cleaned when | Default |
|---|---|---|---|
| Build caches | `.next`, `.next-*`, `*.bun-build`, `src-tauri/target` under `~/Projects` | Untouched for 3 days, or a single cache over 10 GB | On |
| Idle project dependencies | `node_modules`, and virtual envs that have a lockfile or requirements file | The project hasn't changed for 14 days | On |
| Worktrees and build copies | `~/Projects/*-worktrees/*`, `~/Projects/*-build*`, `~/.codex/worktrees/*/*` | Clean git worktrees, untouched for 14 days, with all commits on a branch | Off |
| Package and tool caches | Yarn, npm, pnpm, bun, uv and pip download caches; Docker Scout | All emptied once their total exceeds 20 GB | On |
| App caches | Other apps' caches in `~/Library/Caches` | Untouched for 3 days | On |
| Agent temp directories | `~/.cache/bnbot-*`, `~/Library/Caches/bnbot-*` | Untouched for 3 days | On |
| Codex conversations | Session files in `~/.codex/sessions` and `archived_sessions`, including compressed `.jsonl.zst` | See the next section | On |
| Claude conversations | `~/.claude/projects/*/<uuid>.jsonl` and the matching directory | Untouched for 7 days and not pinned | On |
| Agent artifacts | `~/.codex/visualizations`, `generated_images` | Untouched for 30 days | Off |
| Voice-input recordings | Shandianshuo's `workspace/history/recordings` | Older than 7 days | On |
| Other large items | Docker's virtual disk, the Claude desktop VM image, Codex's index database, BNBot's log database | Never cleaned, only shown | — |

These are the built-in defaults. Switches and thresholds can be changed under Settings in the menu bar panel and are stored in `~/Library/Application Support/Sweep/config.json`. Built-in path lists live in the code; the config file only stores additions (`extraPaths` and so on) and `excludes` (paths no rule will ever touch).

Rules that are switched off are still measured during a scan, so the panel shows how much they would free — but they don't clean anything and don't count toward the totals.

Some trade-offs:

- **Build caches have a size cap.** A project you use every day is never "untouched for 3 days", which is exactly how that 136 GB cache grew. When a cache is over the cap but a dev server is running, Sweep leaves it alone and sends a notification instead.
- **Package caches are capped by size, not age.** They are in constant use, so emptying them on a schedule would only cause repeated downloads.
- **Dependencies follow project activity.** A project's activity time is the newest of its source files, git operations and last install; all packages in one git repository share that time, so a monorepo is never half-cleaned.
- **AI tool caches are kept by default.** App caches whose names contain openai, claude, codex, bnbot, cursor and similar keywords are listed with their size but not cleaned.
- **Only safe worktrees are removed.** A worktree must be a git worktree with no uncommitted or untracked changes, and its current commit must be on a branch. Removal only deletes the checked-out files; the branch stays in the main repository. Plain copies that aren't git worktrees are only ever shown.

### How Codex conversations are judged

Sweep reads Codex's own state (`state_5.sqlite` and `.codex-global-state.json`) read-only and sorts conversations into groups, each shown in the panel with its count and size:

| Group | Action |
|---|---|
| Pinned in Codex | Keep |
| In a pinned project (by working directory, assignment or sidebar order) | Keep |
| Marked with `sweep keep` | Keep |
| Updated within 7 days | Keep |
| Untouched for more than 7 days | Delete |
| Archived | Delete after 3 quiet days |
| Sub-agent sessions | Follow their parent conversation: kept if it is kept, deleted if it is deleted |
| Files Codex no longer has a record of | Delete if untouched for more than 7 days |

If Codex's state can't be read, no Codex conversation is deleted.

Codex compresses old sessions into `.jsonl.zst`, and compressed files can't be searched for pin markers. So every scan binds `sweep keep` markers to their session IDs while the session file is still uncompressed. For markers that haven't been bound yet, any compressed file updated after the marker was created is treated as "might be it" and kept.

## Safety rules

These are hard-coded and covered by tests:

1. Every item is re-validated right before deletion: it must exist, must not itself be a symlink, and after resolving symlinks must sit strictly inside its rule's root directory.
2. Any path containing a `memory` or `.git` component is refused, so Claude's memory directory can never be deleted.
3. Conversations are matched only by UUID-shaped file names; other files next to them never match.
4. Build caches and dependencies are skipped if they contain any git-tracked file, and also when git can't give an answer.
5. Projects referenced from outside the project directory keep their dependencies. References include globally linked packages, commands on the PATH, agent skill links and scheduled-job configurations. `sweep refs` lists the references it currently detects.
6. Directories that can't be fully read are kept.
7. A corrupt config file aborts the whole run instead of falling back to defaults.
8. A corrupt pin list means no conversation is deleted.
9. Each deletion is logged immediately, so even an interrupted cleanup leaves a record.

Rules 5 and 9 were added after real mistakes: an early version deleted `bnbot-kit/cli/node_modules`, which the `bnbot` command was npm-linked to; and when that cleanup was interrupted, the log had nothing in it.

## Pinning conversations you want to keep

Tell the agent "pin this conversation, don't delete it". The agent runs:

```bash
sweep keep "label"
```

The instruction for this lives in `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.

Conversations are recognized in two ways:

- Claude Code exposes `CLAUDE_CODE_SESSION_ID`, so the session ID goes straight into the pin list.
- The command prints a marker (`sweep-pin:v1:<uuid>`). Command output is written into the session file, and before deleting, Sweep searches the file for markers in the pin list. This is how Codex conversations are recognized.

Only markers registered in the pin list count, so the prefix appearing in docs or source code never pins anything by accident.

```bash
sweep pins                 # list pinned conversations
sweep unkeep "label"       # unpin
```

## Full disk usage

The "Full disk usage" section of the panel breaks the whole disk down by area: project code, agents and developer tools, caches, app data, app containers, temporary files, your files, applications, the system, and the part that can't be measured. Each area shows its size, how much of it Sweep can clean, and whether it can be deleted and how to deal with it.

Measuring the whole home folder takes two to three minutes, so it runs in the background after a scan and is cached for 6 hours. You can also click Refresh or run `sweep storage`. "Can't be measured" is used space minus everything that could be measured — mostly system-protected folders such as WeChat, browsers, Mail, the Photos library and the Trash.

## Command line

```bash
sweep scan [--all] [--tight]    # scan only and list what would be cleaned
sweep scan --timing             # time each rule's scan
sweep run [--dry-run] [--tight] # clean now
sweep status                    # status
sweep refs                      # project paths referenced from outside
sweep storage                   # full disk usage and what can be deleted
sweep arm | disarm              # turn automatic cleanup on / off
```

Set `SWEEP_HOME=/some/dir` to point every path at another directory, for rehearsals that never touch real data.

## File locations

| Content | Path |
|---|---|
| Settings, pin list, run state, last scan results | `~/Library/Application Support/Sweep/` |
| Cleanup log (what was deleted, how big, and why) | `~/Library/Logs/Sweep/sweep.log` |
| Scheduled-job output | `~/Library/Logs/Sweep/launchd.log` |

## Known limitations

- **Codex's index databases are not cleaned.** `~/.codex/state_5.sqlite` records each session file's path, and `thread_history_1.sqlite` holds another projection of the conversation contents (about 7 GB). Sweep only deletes session files and never touches these databases.
- **Sizes are estimates.** Hard links are handled, but APFS clones can't be detected, so the space actually freed may be less than shown.
- **System-protected folders can't be read.** WeChat, Chrome profiles, Mail, the Trash and similar require Full Disk Access; Sweep doesn't touch them.
- **Runs only in your own graphical session.** The scheduled job is a per-user LaunchAgent and doesn't run while you're logged out.

## Development

```bash
swift test                                                       # all tests
.build/release/SweepApp --snapshot out.png --open conversations  # render the panel offscreen to an image (without the glass window)
SWEEP_DEBUG_FRAME=frame.txt .build/release/SweepApp --show-panel # keep the real panel open and write its frame, for screenshots
```
