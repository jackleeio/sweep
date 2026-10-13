import AppKit
import ServiceManagement
import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        // 调试入口：Sweep --snapshot <png 路径> [--expanded]，把面板离屏渲染成图片后退出
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.render(to: args[i + 1], expanded: args.contains("--expanded"), confirming: args.contains("--confirming"))
            return
        }
        // 调试入口：打印登录项注册状态
        if args.contains("--login-status") {
            print(LoginItem.statusText)
            return
        }
        SweepMenuApp.main()
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

struct SweepMenuApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            Label(model.menuTitle, systemImage: "internaldrive")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
enum Snapshot {
    static func render(to path: String, expanded: Bool, confirming: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let model = AppModel(live: false)
        model.confirming = confirming
        let content = PanelView(expanded: expanded)
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
