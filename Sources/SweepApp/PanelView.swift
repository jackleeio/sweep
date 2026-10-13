import SweepCore
import SwiftUI

struct PanelView: View {
    /// 面板里可以展开的区块。同一时间只展开一个，保证面板高度可控。
    enum Section: Hashable {
        case rule(RuleID)
        case pins
        case history
        case settings
    }

    @EnvironmentObject private var model: AppModel
    @State private var open: Section?

    private static let rules: [RuleID] = [.buildCaches, .dependencies, .packageCaches, .appCaches, .agentTemp, .conversations, .artifacts]
    private static let shownItems = 6

    init(open: Section? = nil) {
        _open = State(initialValue: open)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.rules, id: \.self) { ruleRow($0, toggleable: true) }
                ruleRow(.workCopies, toggleable: false)
                Text(scanCaption).font(.caption).foregroundStyle(.secondary)
            }
            notices
            Divider()
            sectionHeader("已标记的对话", count: model.pins.count, section: .pins)
            if open == .pins { pinList }
            sectionHeader("清理记录", count: model.state.history.count, section: .history)
            if open == .history { historyList }
            sectionHeader("设置", count: nil, section: .settings)
            if open == .settings { settings }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { model.refresh() }
    }

    private func toggle(_ section: Section) {
        open = open == section ? nil : section
    }

    // MARK: - 顶部状态

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sweep").font(.headline)
                Spacer()
                if model.busy != .idle { ProgressView().controlSize(.small) }
                Button(model.busy == .scanning ? "扫描中…" : "重新扫描") { model.scan() }
                    .disabled(model.busy != .idle || model.configError != nil)
            }
            ProgressView(value: model.total > 0 ? Double(model.total - model.free) / Double(model.total) : 0)
                .tint(spaceColor)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("可用 \(Format.bytes(model.free))").font(.title3.weight(.semibold)).monospacedDigit()
                Text("/ \(Format.bytes(model.total))").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if let summary = model.summary, summary.deletableBytes > 0 {
                    Text("清理后约 \(Format.bytes(model.free + summary.deletableBytes))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(spaceNote).font(.caption).foregroundStyle(spaceColor == .accentColor ? Color.secondary : spaceColor)
            row("上次清理", lastRunText)
            row("自动清理", autoText)
            if let error = model.configError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var lowBytes: Int64 { Int64(model.config.lowSpaceGB * Format.gigabyte) }
    private var targetBytes: Int64 { Int64(model.config.targetFreeGB * Format.gigabyte) }

    private var spaceColor: Color {
        if model.free < lowBytes { return .red }
        if model.free < targetBytes { return .orange }
        return .accentColor
    }

    private var spaceNote: String {
        let low = Format.number(model.config.lowSpaceGB)
        let target = Format.number(model.config.targetFreeGB)
        if model.free < lowBytes { return "已低于 \(low) GB 警戒线，会立即按收紧规则清理" }
        if model.free < targetBytes { return "低于 \(target) GB 的目标余量，每日清理会收紧规则；低于 \(low) GB 立即清理" }
        return "目标余量 \(target) GB · 低于 \(low) GB 立即清理"
    }

    private var lastRunText: String {
        guard let last = model.state.lastRun else { return "还没有清理过" }
        return "\(relative(last)) · \(model.state.lastDeletedCount) 项 · 回收 \(Format.bytes(model.state.lastFreedBytes))"
    }

    private var autoText: String {
        guard model.state.armed else { return "未开启，首次清理确认后生效" }
        return String(format: "每天 %02d:00 之后一次，另每 10 分钟查空间", model.config.dailyHour)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    // MARK: - 规则列表

    private func ruleRow(_ rule: RuleID, toggleable: Bool) -> some View {
        let summary = model.summary?[rule]
        let enabled = model.isEnabled(rule)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if toggleable {
                    Toggle("", isOn: Binding(get: { enabled }, set: { model.setEnabled(rule, $0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                } else {
                    Image(systemName: "eye").font(.caption).foregroundStyle(.secondary).frame(width: 16)
                }
                Button {
                    toggle(.rule(rule))
                } label: {
                    HStack {
                        Text(rule.title).foregroundStyle(enabled ? Color.primary : Color.secondary)
                        Spacer()
                        Text(sizeText(rule, summary, enabled: enabled))
                            .monospacedDigit()
                            .foregroundStyle(enabled && (summary?.deletableBytes ?? 0) > 0 ? Color.primary : Color.secondary)
                        Image(systemName: open == .rule(rule) ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary).frame(width: 10)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .font(.callout)
            Text(countText(rule, summary, enabled: enabled))
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            if open == .rule(rule) {
                ruleDetail(rule, summary).padding(.leading, 22).padding(.top, 2)
            }
        }
    }

    private func sizeText(_ rule: RuleID, _ summary: RuleSummary?, enabled: Bool) -> String {
        guard enabled else { return "已关闭" }
        guard let summary else { return model.summary == nil ? "—" : "0 B" }
        return Format.bytes(rule == .workCopies ? summary.keptBytes : summary.deletableBytes)
    }

    private func countText(_ rule: RuleID, _ summary: RuleSummary?, enabled: Bool) -> String {
        guard enabled else { return "已关闭，不会清理" }
        guard let summary else { return model.summary == nil ? "还没有扫描" : "没有命中任何内容" }
        if rule == .workCopies { return "\(summary.keptCount) 个，只显示体积，不自动清理" }
        let kept = summary.keptCount > 0 ? " · 保留 \(summary.keptCount) 项（\(Format.bytes(summary.keptBytes))）" : ""
        return "可清 \(summary.deletableCount) 项\(kept)"
    }

    private func ruleDetail(_ rule: RuleID, _ summary: RuleSummary?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rule.detail(model.config))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let summary {
                ForEach(summary.top.prefix(Self.shownItems), id: \.path) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Format.bytes(item.bytes)).monospacedDigit().frame(width: 58, alignment: .trailing)
                        Text(shortPath(item.path)).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        Spacer(minLength: 4)
                        Text(item.reason).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 104, alignment: .trailing)
                    }
                    .font(.caption)
                }
                if summary.deletableCount > Self.shownItems {
                    Text("… 共 \(summary.deletableCount) 项，点下方「清单」看全部").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(summary.kept, id: \.reason) { group in
                    Text("保留 \(group.count) 项 · \(Format.bytes(group.bytes)) · \(group.reason)")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 把绝对路径缩成适合一行显示的样子：去掉主目录和 Projects 前缀，太深的中间用 … 代替。
    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var text = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        if text.hasPrefix("Projects/") { text = String(text.dropFirst("Projects/".count)) }
        let parts = text.split(separator: "/")
        return parts.count > 4 ? "\(parts[0])/…/\(parts.suffix(2).joined(separator: "/"))" : text
    }

    private var scanCaption: String {
        guard let summary = model.summary else { return "还没有扫描过，点右上角「重新扫描」查看可清理的内容。" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M 月 d 日 HH:mm"
        return "扫描于 \(formatter.string(from: summary.date)) · 合计可清理 \(summary.deletableCount) 项，\(Format.bytes(summary.deletableBytes))"
    }

    @ViewBuilder
    private var notices: some View {
        ForEach(model.blocked, id: \.self) { notice in
            Label(notice, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.pinsError {
            Label("标记名单文件损坏。修复之前不会删除任何对话。", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: - 可展开的区块

    private func sectionHeader(_ title: String, count: Int?, section: Section) -> some View {
        Button {
            toggle(section)
        } label: {
            HStack {
                Image(systemName: open == section ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                Text(title)
                if let count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
                Spacer()
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pinList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.pins.isEmpty {
                Text("在对话里对 agent 说「标记这个对话，别删」，它就会出现在这里。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.pins, id: \.token) { pin in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pin.label).lineLimit(1)
                        Text("\(pin.agent ?? "agent") · \(pin.createdAt.formatted(date: .numeric, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("取消标记") { model.unpin(pin) }.controlSize(.small)
                }
            }
        }
        .font(.callout)
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historyList: some View {
        let recent = Array(model.state.history.suffix(6).reversed().enumerated())
        return VStack(alignment: .leading, spacing: 4) {
            if recent.isEmpty {
                Text("还没有清理记录。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(recent, id: \.offset) { _, record in
                HStack(spacing: 6) {
                    Text(record.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                        .monospacedDigit()
                    Text(kindText(record.kind)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(record.deletedCount) 项 · \(Format.bytes(record.freedBytes))"
                         + (record.errorCount > 0 ? " · \(record.errorCount) 项失败" : ""))
                        .monospacedDigit()
                }
                .font(.caption)
            }
            Text("累计回收 \(Format.bytes(model.state.totalFreedBytes))").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func kindText(_ kind: String) -> String {
        switch kind {
        case "manual": return "手动"
        case "emergency": return "空间不足"
        default: return "每日"
        }
    }

    // MARK: - 设置

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper("缓存和对话闲置 \(Format.number(model.config.idleDays)) 天后清理",
                    value: configBinding(\.idleDays), in: 1...30)
            Stepper("项目闲置 \(Format.number(model.config.dependencies.idleDays)) 天后清它的依赖",
                    value: configBinding(\.dependencies.idleDays), in: 3...90)
            Stepper("单个构建缓存上限 \(Format.number(model.config.buildCaches.sizeCapGB)) GB",
                    value: configBinding(\.buildCaches.sizeCapGB), in: 1...100)
            Stepper("包缓存合计上限 \(Format.number(model.config.packageCaches.totalCapGB)) GB",
                    value: configBinding(\.packageCaches.totalCapGB), in: 5...200, step: 5)
            Stepper("可用空间低于 \(Format.number(model.config.lowSpaceGB)) GB 时立即清理",
                    value: configBinding(\.lowSpaceGB), in: 0...500, step: 10)
            Stepper("每日清理的目标余量 \(Format.number(model.config.targetFreeGB)) GB",
                    value: configBinding(\.targetFreeGB), in: 0...800, step: 50)
            Toggle("保留 AI 工具的缓存", isOn: configBinding(\.appCaches.keepAITools))
            Toggle("自动清理", isOn: Binding(get: { model.state.armed }, set: { model.setArmed($0) }))
            Toggle("开机时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        }
        .font(.callout)
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func configBinding<Value>(_ keyPath: WritableKeyPath<Config, Value>) -> Binding<Value> {
        Binding(get: { model.config[keyPath: keyPath] }, set: {
            model.config[keyPath: keyPath] = $0
            model.saveConfig()
        })
    }

    // MARK: - 底部操作

    @ViewBuilder
    private var footer: some View {
        if model.confirming, let summary = model.summary {
            VStack(alignment: .leading, spacing: 8) {
                Text("将清理 \(summary.deletableCount) 项，共 \(Format.bytes(summary.deletableBytes))。删除后无法恢复。"
                     + (model.state.armed ? "" : "确认后同时开启自动清理。"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("查看清单") { model.openPreview() }
                    Spacer()
                    Button("取消") { model.confirming = false }
                    Button("确认清理") { model.confirmClean() }
                        .buttonStyle(.borderedProminent)
                        .disabled(summary.deletableCount == 0)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(model.busy == .cleaning ? "清理中…" : "立即清理") { model.requestClean() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy != .idle || model.configError != nil)
                    Button("清单") { model.openPreview() }.disabled(model.busy != .idle)
                    Button("日志") { model.openLog() }
                    Spacer()
                    Button("退出") { NSApplication.shared.terminate(nil) }
                }
            }
        }
    }
}
