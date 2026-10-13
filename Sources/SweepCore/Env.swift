import Foundation

public enum CacheKind: Equatable {
    case next
    case cargoTarget
    case bunBuild
}

/// 判断某个项目目录下的构建缓存是否正被运行中的进程使用。
public protocol ProcessProbe {
    func isInUse(projectDir: URL, kind: CacheKind) -> Bool
}

/// 运行环境。所有路径都从 home 派生，测试时注入假 home。
public struct Env {
    public var home: URL
    public var now: Date
    public var processProbe: ProcessProbe

    public init(home: URL, now: Date, processProbe: ProcessProbe) {
        self.home = home
        self.now = now
        self.processProbe = processProbe
    }

    public var supportDir: URL { home.appendingPathComponent("Library/Application Support/Sweep") }
    public var logDir: URL { home.appendingPathComponent("Library/Logs/Sweep") }
    public var configFile: URL { supportDir.appendingPathComponent("config.json") }
    public var pinsFile: URL { supportDir.appendingPathComponent("pins.json") }
    public var stateFile: URL { supportDir.appendingPathComponent("state.json") }
    public var logFile: URL { logDir.appendingPathComponent("sweep.log") }

    /// 展开以 ~ 开头的路径。
    public func expand(_ path: String) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }
}
