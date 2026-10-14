import AppKit
import Combine
import ServiceManagement
import SweepCore
import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        // 调试入口：Sweep --snapshot <png 路径> [--open <规则名|pins|history|settings>] [--confirming]
        // 把面板内容离屏渲染成图片后退出（不含窗口外壳和玻璃效果）
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.render(to: args[i + 1], open: section(from: args), confirming: args.contains("--confirming"))
            return
        }
        // 调试入口：打印登录项注册状态
        if args.contains("--login-status") {
            print(LoginItem.statusText)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate(initiallyOpen: section(from: args), showOnLaunch: args.contains("--show-panel"))
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func section(from args: [String]) -> PanelView.Section? {
        guard let i = args.firstIndex(of: "--open"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "pins": return .pins
        case "history": return .history
        case "settings": return .settings
        case "storage": return .storage
        default: return RuleID(rawValue: args[i + 1]).map { .rule($0) }
        }
    }
}

enum LoginItem {
    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}

/// 能成为 key window 的无边框面板。不这样的话，面板里的步进器和开关收不到键盘焦点。
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 菜单栏图标和它下面的面板。
///
/// 不用 SwiftUI 的 MenuBarExtra：它的窗口是系统给的方角样式，改不了。
/// 这里自己管理一个透明的无边框面板，外观交给液态玻璃。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let cornerRadius: CGFloat = 26
    private static let gap: CGFloat = 6

    private let model = AppModel()
    private let initiallyOpen: PanelView.Section?
    private let showOnLaunch: Bool
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var host: NSHostingView<AnyView>!
    private var clickMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []
    /// 面板顶边的位置。内容变高变矮时保持顶边不动，只向下伸缩。
    private var anchorTop: CGFloat = 0

    init(initiallyOpen: PanelView.Section?, showOnLaunch: Bool) {
        self.initiallyOpen = initiallyOpen
        self.showOnLaunch = showOnLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Sweep")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel)
        }
        panel = makePanel()

        model.$free.combineLatest(model.$total)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.statusItem.button?.title = " \(self?.model.menuTitle ?? "")" }
            .store(in: &subscriptions)
        model.$panelHeight.removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.fitPanelToContent() }
            .store(in: &subscriptions)

        if showOnLaunch { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showPanel() } }
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        host = NSHostingView(rootView: AnyView(PanelView(open: initiallyOpen).environmentObject(model)))
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = host
            panel.contentView = glass
        } else {
            // 更早的系统没有液态玻璃，退回毛玻璃材质加圆角
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 16
            blur.layer?.masksToBounds = true
            host.frame = blur.bounds
            host.autoresizingMask = [.width, .height]
            blur.addSubview(host)
            panel.contentView = blur
        }
        return panel
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        model.refresh()
        model.scanIfStale()

        let screen = NSScreen.main?.visibleFrame ?? .zero
        let size = host.fittingSize
        var x = screen.maxX - size.width - 8
        anchorTop = screen.maxY - Self.gap
        // 图标可见时对齐到它下面。菜单栏管理工具把图标收进折叠区时，它的位置在屏幕外，这时退回屏幕右上角。
        if let button = statusItem.button, let buttonWindow = button.window {
            let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if let visible = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) {
                let area = visible.visibleFrame
                anchorTop = anchor.minY - Self.gap
                x = min(max(anchor.midX - size.width / 2, area.minX + 8), area.maxX - size.width - 8)
            }
        }
        panel.setFrame(NSRect(x: x, y: anchorTop - size.height, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)

        // 调试时由 --show-panel 打开：不随点击收起，并把窗口位置写出来供截图核对
        if showOnLaunch {
            if let path = ProcessInfo.processInfo.environment["SWEEP_DEBUG_FRAME"] {
                let f = panel.frame
                let top = (NSScreen.screens.first?.frame.maxY ?? 0) - f.maxY
                try? "\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height)) \(panel.windowNumber)".write(toFile: path, atomically: true, encoding: .utf8)
            }
            return
        }
        // 点到面板以外的任何地方就收起
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func fitPanelToContent() {
        guard panel.isVisible else { return }
        let size = host.fittingSize
        var frame = panel.frame
        frame.origin.y = anchorTop - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
        if showOnLaunch, let path = ProcessInfo.processInfo.environment["SWEEP_DEBUG_FRAME"] {
            let top = (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY
            try? "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height)) \(panel.windowNumber)".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

@MainActor
enum Snapshot {
    static func render(to path: String, open: PanelView.Section?, confirming: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let model = AppModel(live: false)
        model.confirming = confirming
        let content = PanelView(open: open)
            .environmentObject(model)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
