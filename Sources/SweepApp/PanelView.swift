import SweepCore
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showPins: Bool
    @State private var showSettings: Bool

    private static let toggleable: [RuleID] = [.buildCaches, .agentTemp, .conversations, .packageCaches, .artifacts]

    init(expanded: Bool = false) {
        _showPins = State(initialValue: expanded)
        _showSettings = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            rules
            ForEach(model.blocked, id: \.self) { notice in
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider()
            DisclosureGroup("已标记的对话（\(model.pins.count)）", isExpanded: $showPins) { pinList }
            DisclosureGroup("设置", isExpanded: $showSettings) { settings }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { model.refresh() }
    }

    // MARK: - 顶部状态

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sweep").font(.headline)
                Spacer()
                if model.busy != .idle { ProgressView().controlSize(.small) }
                Button(model.busy == .scanning ? "扫描中…" : "扫描") { model.scan() }
                    .disabled(model.busy != .idle || model.configError != nil)
            }
            row("可用空间", "\(Format.bytes(model.free)) / \(Format.bytes(model.total))")
            ProgressView(value: model.total > 0 ? Double(model.total - model.free) / Double(model.total) : 0)
            row("上次清理", lastRunText)
            row("自动清理", model.state.armed ? "每天 03:00" : "未开启，首次清理确认后生效")
            if let error = model.configError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var lastRunText: String {
        guard let last = model.state.lastRun else { return "还没有清理过" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return "\(formatter.localizedString(for: last, relativeTo: Date())) · 回收 \(Format.bytes(model.state.lastFreedBytes))"
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

    private var rules: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Self.toggleable, id: \.self) { rule in
                Toggle(isOn: Binding(get: { model.isEnabled(rule) }, set: { model.setEnabled(rule, $0) })) {
                    HStack {
                        Text(rule.title)
                        Spacer()
                        Text(sizeText(rule)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Text("工作副本（仅展示，不自动清理）").foregroundStyle(.secondary)
                Spacer()
                Text(model.summary?[.workCopies].map { Format.bytes($0.keptBytes) } ?? "—")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.leading, 20)
            Text(scanCaption).font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func sizeText(_ rule: RuleID) -> String {
        guard model.isEnabled(rule) else { return "已关闭" }
        guard let summary = model.summary else { return "—" }
        return Format.bytes(summary[rule]?.deletableBytes ?? 0)
    }

    private var scanCaption: String {
        guard let summary = model.summary else { return "还没有扫描过，点右上角「扫描」查看可清理的内容。" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M 月 d 日 HH:mm"
        return "扫描于 \(formatter.string(from: summary.date)) · 合计可清理 \(Format.bytes(summary.deletableBytes))"
    }

    // MARK: - 标记列表

    @ViewBuilder
    private var pinList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.pinsError {
                Text("标记名单文件损坏。修复之前不会删除任何对话。").font(.caption).foregroundStyle(.red)
            } else if model.pins.isEmpty {
                Text("在对话里对 agent 说「标记这个对话，别删」，它就会出现在这里。")
                    .font(.caption).foregroundStyle(.secondary)
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
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 设置

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper("闲置 \(Int(model.config.idleDays)) 天后清理", value: configBinding(\.idleDays), in: 1...30)
            Stepper("单个构建缓存上限 \(Int(model.config.buildCaches.sizeCapGB)) GB",
                    value: configBinding(\.buildCaches.sizeCapGB), in: 1...100)
            Stepper("包缓存合计上限 \(Int(model.config.packageCaches.totalCapGB)) GB",
                    value: configBinding(\.packageCaches.totalCapGB), in: 5...200, step: 5)
            Toggle("每日自动清理", isOn: Binding(get: { model.state.armed }, set: { model.setArmed($0) }))
            Toggle("开机时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        }
        .font(.callout)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func configBinding(_ keyPath: WritableKeyPath<Config, Double>) -> Binding<Double> {
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
                     + (model.state.armed ? "" : "确认后同时开启每日自动清理。"))
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
