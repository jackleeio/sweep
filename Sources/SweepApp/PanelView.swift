import SweepCore
import SwiftUI

struct PanelView: View {
    /// 面板里可以展开的区块。同一时间只展开一个。
    enum Section: Hashable {
        case rule(RuleID)
        case pins
        case history
        case settings
    }

    @EnvironmentObject private var model: AppModel
    @State private var open: Section?

    private static let rules: [RuleID] = [.buildCaches, .dependencies, .workCopies, .packageCaches, .appCaches, .agentTemp,
                                          .conversations, .claudeConversations, .artifacts, .recordings, .bigItems]
    private static let shownItems = 5

    init(open: Section? = nil) {
        _open = State(initialValue: open)
    }

    var body: some View {
        // 规则多、又能展开，内容可能比屏幕高：超过上限时滚动
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                Divider()
                scanTotals
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Self.rules, id: \.self) { ruleRow($0) }
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
        }
        .frame(width: 420)
        .frame(maxHeight: Self.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { model.panelHeight = $0 }
        .onAppear { model.refresh() }
    }

    private static var maxHeight: CGFloat {
        max(480, (NSScreen.main?.visibleFrame.height ?? 900) - 40)
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
                    .glassButton()
                    .disabled(model.busy != .idle || model.configError != nil)
            }
            ProgressView(value: model.total > 0 ? Double(model.total - model.free) / Double(model.total) : 0)
                .tint(spaceColor)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("可用 \(Format.bytes(model.free))").font(.title3.weight(.semibold)).monospacedDigit()
                Text("/ \(Format.bytes(model.total))").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                // 差不到 1 GB 时这个数字和「可用」一样，显示出来只会添乱
                if model.cleanable.bytes >= Int64(Format.gigabyte) {
                    Text("清理后约 \(Format.bytes(model.free + model.cleanable.bytes))")
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

    /// 「工作树」关着时仍然列出体积，「其他大户」根本没有开关：这两条始终显示内容。
    private func alwaysListed(_ rule: RuleID) -> Bool { rule == .workCopies || rule == .bigItems }

    private func ruleRow(_ rule: RuleID) -> some View {
        let summary = model.summary?[rule]
        let enabled = model.isEnabled(rule)
        let listed = enabled || alwaysListed(rule)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if rule == .bigItems {
                    Image(systemName: "eye").font(.caption).foregroundStyle(.secondary).frame(width: 16)
                } else {
                    Toggle("", isOn: Binding(get: { enabled }, set: { model.setEnabled(rule, $0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                Button {
                    toggle(.rule(rule))
                } label: {
                    HStack(spacing: 6) {
                        Text(rule.title).foregroundStyle(listed ? Color.primary : Color.secondary).layoutPriority(2)
                        Text(countText(rule, summary, enabled: enabled))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(sizeText(rule, summary, enabled: enabled))
                            .monospacedDigit().layoutPriority(1)
                            .foregroundStyle(enabled && (summary?.deletableBytes ?? 0) > 0 ? Color.primary : Color.secondary)
                            .strikethrough(!enabled && rule != .bigItems && (summary?.deletableBytes ?? 0) > 0, color: .secondary)
                        Image(systemName: open == .rule(rule) ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary).frame(width: 10)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .font(.callout)
            if open == .rule(rule) {
                ruleDetail(rule, summary).padding(.leading, 22).padding(.bottom, 4)
            }
        }
    }

    /// 右侧的体积：开着的规则是「会清多少」，关着的是「打开后能清多少」，大户是它一共占多少。
    private func sizeText(_ rule: RuleID, _ summary: RuleSummary?, enabled: Bool) -> String {
        guard let summary else { return model.summary == nil ? "—" : "0 B" }
        return Format.bytes(rule == .bigItems ? summary.keptBytes : summary.deletableBytes)
    }

    private func countText(_ rule: RuleID, _ summary: RuleSummary?, enabled: Bool) -> String {
        guard let summary else { return model.summary == nil ? "未扫描" : (enabled ? "无" : "已关闭") }
        if rule == .bigItems { return "\(summary.keptCount) 项，仅展示" }
        let kept = summary.keptCount > 0 ? " · 留 \(summary.keptCount)" : ""
        // 关着的规则也量过了：数字是真实的，只是不会清
        return enabled ? "清 \(summary.deletableCount)\(kept)" : "已关闭 · 打开可清 \(summary.deletableCount)"
    }

    private func ruleDetail(_ rule: RuleID, _ summary: RuleSummary?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rule.detail(model.config))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let summary {
                // 分类：这一类有多少、占多大、会清还是会留
                ForEach(summary.groups, id: \.self.label) { group in
                    HStack(spacing: 6) {
                        Text(group.deletable ? "清" : "留")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(group.deletable ? Color.orange : Color.secondary)
                            .frame(width: 14)
                        Text(group.label).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text("\(group.count) 项").foregroundStyle(.secondary).monospacedDigit()
                        Text(Format.bytes(group.bytes)).monospacedDigit().frame(width: 62, alignment: .trailing)
                    }
                    .font(.caption)
                }
                if !summary.top.isEmpty {
                    Text("其中最大的").font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
                    ForEach(summary.top.prefix(Self.shownItems), id: \.path) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Format.bytes(item.bytes)).monospacedDigit().frame(width: 58, alignment: .trailing)
                            // 路径可以被压缩，右边的原因固定留出位置
                            Text(shortPath(item.path)).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.reason).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                                .frame(width: 92, alignment: .trailing)
                        }
                        .font(.caption)
                    }
                    if summary.deletableCount > Self.shownItems {
                        Text("… 共 \(summary.deletableCount) 项，点下方「清单」看全部").font(.caption).foregroundStyle(.tertiary)
                    }
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

    // MARK: - 扫描总账

    /// 一共扫描了多少，其中多少会清、多少因为规则关着不会清、多少保留。
    @ViewBuilder
    private var scanTotals: some View {
        if let summary = model.summary {
            let totals = summary.totals(disabled: model.config.disabledRules)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("已扫描 \(Format.bytes(totals.scanned))").font(.callout.weight(.semibold)).monospacedDigit()
                    Spacer()
                    Text(scanTime(summary.date)).font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    HStack(spacing: 1) {
                        segment(totals.cleanable, of: totals.scanned, width: proxy.size.width, color: .orange)
                        segment(totals.switchedOff, of: totals.scanned, width: proxy.size.width, color: .orange.opacity(0.35))
                        segment(totals.kept, of: totals.scanned, width: proxy.size.width, color: .secondary.opacity(0.45))
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())
                HStack(spacing: 12) {
                    legend(.orange, "可清理", totals.cleanable)
                    legend(.orange.opacity(0.35), "规则关着", totals.switchedOff)
                    legend(.secondary.opacity(0.45), "保留", totals.kept)
                    Spacer(minLength: 0)
                }
                .font(.caption)
            }
            .padding(.bottom, 2)
        } else {
            Text(scanCaption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func segment(_ part: Int64, of whole: Int64, width: CGFloat, color: Color) -> some View {
        color.frame(width: whole > 0 ? max(part > 0 ? 2 : 0, width * CGFloat(part) / CGFloat(whole)) : 0)
    }

    private func legend(_ color: Color, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Text(Format.bytes(bytes)).monospacedDigit()
        }
    }

    private func scanTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M 月 d 日 HH:mm"
        return "\(model.busy == .scanning ? "正在重新扫描 · 上次 " : "扫描于 ")\(formatter.string(from: date))"
    }

    private var scanCaption: String {
        guard let summary = model.summary else { return "还没有扫描过，点右上角「重新扫描」查看可清理的内容。" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M 月 d 日 HH:mm"
        let total = model.cleanable
        return "扫描于 \(formatter.string(from: summary.date)) · 开着的规则合计可清理 \(total.count) 项，\(Format.bytes(total.bytes))"
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
            Text("这里是用 sweep keep 标记的对话。你在 Codex 里 pin 的对话也会自动保留，见「Codex 对话」。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Text("还没有通过 Sweep 清理过。").font(.caption).foregroundStyle(.secondary)
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
            Stepper("缓存闲置 \(Format.number(model.config.idleDays)) 天后清理",
                    value: configBinding(\.idleDays), in: 1...30)
            Stepper("对话闲置 \(Format.number(model.config.conversations.idleDays)) 天后删除",
                    value: Binding(get: { model.config.conversations.idleDays }, set: {
                        // 两种对话共用一个门槛，界面上只留一个旋钮
                        model.config.conversations.idleDays = $0
                        model.config.claudeConversations.idleDays = $0
                        model.saveConfig()
                    }), in: 3...90)
            Stepper("项目或工作树闲置 \(Format.number(model.config.dependencies.idleDays)) 天后清理",
                    value: Binding(get: { model.config.dependencies.idleDays }, set: {
                        model.config.dependencies.idleDays = $0
                        model.config.workCopies.idleDays = $0
                        model.saveConfig()
                    }), in: 3...90)
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
        if model.confirming {
            let total = model.cleanable
            VStack(alignment: .leading, spacing: 8) {
                Text("将清理 \(total.count) 项，共 \(Format.bytes(total.bytes))。删除后无法恢复。"
                     + (model.state.armed ? "" : "确认后同时开启自动清理。"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("查看清单") { model.openPreview() }.glassButton()
                    Spacer()
                    Button("取消") { model.confirming = false }.glassButton()
                    Button("确认清理") { model.confirmClean() }
                        .glassButton(prominent: true)
                        .disabled(total.count == 0)
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
                        .glassButton(prominent: true)
                        .disabled(model.busy != .idle || model.configError != nil)
                    Button("清单") { model.openPreview() }.glassButton().disabled(model.busy != .idle)
                    Button("日志") { model.openLog() }.glassButton()
                    Spacer()
                    Button("退出") { NSApplication.shared.terminate(nil) }.glassButton()
                }
            }
        }
    }
}

struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// macOS 26 起用液态玻璃样式的按钮，更早的系统退回普通的带边框按钮。
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}
