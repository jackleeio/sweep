import Foundation
import SweepCore

let usage = """
sweep — 定时清理构建缓存和 agent 对话

  sweep scan [--all]              只扫描，列出会清理什么（不删除）
  sweep run [--dry-run]           立即清理
  sweep run --scheduled           定时任务入口；首次清理未确认前只扫描
  sweep keep <标签>               标记当前 agent 对话，不被清理
  sweep unkeep <标签|标记串>      取消标记
  sweep pins                      列出已标记的对话
  sweep status                    查看状态
  sweep arm | disarm              开启 / 关闭自动清理
"""

let args = Array(CommandLine.arguments.dropFirst())
let env = Env.live()
let pins = PinStore(file: env.pinsFile)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func stamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

func scan() throws {
    let config = try Config.load(from: env.configFile)
    let tight = args.contains("--tight")
    let scanner = Scanner(config: config, env: env, pins: pins, tight: tight)
    if args.contains("--timing") {
        for rule in RuleID.allCases {
            let start = Date()
            let count = scanner.scan(rules: [rule]).count
            print(String(format: "%6.1fs  %@（%d 项）", Date().timeIntervalSince(start), rule.title, count))
        }
        return
    }
    let candidates = scanner.scan()
    // 存一份摘要和完整清单，菜单栏 app 会直接读取（收紧模式的预览不存，以免误导）
    if !tight {
        try? ScanSummary.make(from: candidates, date: env.now).save(to: env.scanFile)
        try? ReportText.scan(candidates, limitPerRule: nil).write(to: env.previewFile, atomically: true, encoding: .utf8)
    }
    print(ReportText.scan(candidates, limitPerRule: args.contains("--all") ? nil : 15))
}

func run() throws {
    let scheduled = args.contains("--scheduled")
    let dryRun = args.contains("--dry-run")
    let outcome: RunOutcome
    do {
        outcome = try Runner(env: env).run(mode: scheduled ? .scheduled : .manual, dryRun: dryRun)
    } catch {
        if scheduled { Notifier.post(title: "Sweep 清理失败", body: "配置文件无法读取，本次没有清理任何东西。") }
        throw error
    }

    let free = Format.bytes(Disk.usage(at: env.home).free)
    if let report = outcome.report {
        let verb = report.dryRun ? "将清理" : "已清理"
        print("\(verb) \(report.deleted.count) 项，\(Format.bytes(report.freedBytes))。可用空间 \(free)。")
        for error in report.errors { print("  失败：\(error)") }
        if scheduled, !report.dryRun, report.freedBytes >= 100 << 20 || !report.errors.isEmpty {
            let failed = report.errors.isEmpty ? "" : "，\(report.errors.count) 项失败，详见日志"
            Notifier.post(title: "Sweep 清理完成",
                          body: "清理 \(report.deleted.count) 项，回收 \(Format.bytes(report.freedBytes))\(failed)。可用空间 \(free)。")
        }
    } else {
        print("自动清理尚未开启：有 \(outcome.pendingCount) 项、\(Format.bytes(outcome.pendingBytes)) 可清理。")
        print("先用 sweep scan --all 或菜单栏的 Sweep 查看清单，确认后运行 sweep arm 开启。")
        if scheduled, outcome.pendingBytes > 0 {
            Notifier.post(title: "Sweep 等待确认",
                          body: "有 \(Format.bytes(outcome.pendingBytes)) 可以清理。在菜单栏的 Sweep 里查看清单并确认后，才会开始自动清理。")
        }
    }

    for item in outcome.blocked {
        let project = item.url.deletingLastPathComponent().lastPathComponent
        print("  暂未清理：\(item.url.path)（\(Format.bytes(item.bytes))，\(item.reason)）")
        if scheduled {
            Notifier.post(title: "Sweep：缓存过大但正在使用",
                          body: "\(project) 的 \(item.url.lastPathComponent) 已有 \(Format.bytes(item.bytes))，相关进程停掉后会自动清理。")
        }
    }
}

func keep() throws {
    var label = args.dropFirst().filter { !$0.hasPrefix("--") }.joined(separator: " ")
    if label.isEmpty { label = "未命名 \(stamp(env.now))" }

    let vars = ProcessInfo.processInfo.environment
    let sessionID = vars["CLAUDE_CODE_SESSION_ID"]
    let agent: String?
    if sessionID != nil || vars["CLAUDECODE"] != nil {
        agent = "claude"
    } else if vars.keys.contains(where: { $0.hasPrefix("CODEX_") }) {
        agent = "codex"
    } else {
        agent = nil
    }

    let pin = try pins.add(label: label, sessionID: sessionID, agent: agent,
                           cwd: FileManager.default.currentDirectoryPath, now: env.now)
    // 标记串必须出现在输出里：它会被记入会话文件，清理时靠它认出这个对话
    print("已标记「\(pin.label)」，这个对话不会被 Sweep 自动清理。")
    print("标记串：\(pin.token)")
    print("取消标记：sweep unkeep \"\(pin.label)\"")
}

func unkeep() throws {
    guard args.count >= 2 else { fail("用法：sweep unkeep <标签|标记串>") }
    let removed = try pins.remove(matching: args.dropFirst().joined(separator: " "))
    guard !removed.isEmpty else { fail("没有找到匹配的标记。用 sweep pins 查看全部。") }
    for pin in removed { print("已取消标记「\(pin.label)」") }
}

func listPins() throws {
    let all = try pins.all()
    guard !all.isEmpty else { return print("还没有标记任何对话。") }
    for pin in all {
        print("\(stamp(pin.createdAt))  \(pin.agent ?? "-")  \(pin.label)")
        if let cwd = pin.cwd { print("    目录：\(cwd)") }
        print("    \(pin.token)")
    }
}

func status() throws {
    let state = SweepState.load(from: env.stateFile)
    let disk = Disk.usage(at: env.home)
    print("自动清理：\(state.armed ? "已开启" : "未开启（等待首次确认）")")
    if let last = state.lastRun {
        print("上次清理：\(stamp(last))，\(state.lastDeletedCount) 项，回收 \(Format.bytes(state.lastFreedBytes))"
              + (state.lastErrorCount > 0 ? "，\(state.lastErrorCount) 项失败" : ""))
    } else {
        print("上次清理：还没有运行过")
    }
    print("累计回收：\(Format.bytes(state.totalFreedBytes))")
    print("可用空间：\(Format.bytes(disk.free)) / \(Format.bytes(disk.total))")
    print("已标记对话：\((try? pins.all().count) ?? 0) 个")
}

func setArmed(_ armed: Bool) throws {
    var state = SweepState.load(from: env.stateFile)
    state.armed = armed
    try state.save(to: env.stateFile)
    print(armed ? "已开启自动清理。" : "已关闭自动清理，定时任务将只扫描不删除。")
}

do {
    switch args.first {
    case "scan": try scan()
    case "run": try run()
    case "keep": try keep()
    case "unkeep": try unkeep()
    case "pins": try listPins()
    case "status": try status()
    case "arm": try setArmed(true)
    case "disarm": try setArmed(false)
    default: print(usage)
    }
} catch {
    fail("出错：\(error.localizedDescription)")
}
