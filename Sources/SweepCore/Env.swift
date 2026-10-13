import Foundation

public enum CacheKind: Equatable {
    case next
    case cargoTarget
    case bunBuild
    /// 项目的依赖目录（node_modules、虚拟环境）
    case dependencies
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
    /// 当前可用空间。做成闭包是因为清理前后要各读一次。
    public var freeBytes: () -> Int64
    /// 项目目录之外引用到项目的路径：全局 link 的包、PATH 上的命令、技能链接、定时任务。
    public var externalReferences: () -> [String] = { [] }

    public init(home: URL, now: Date, processProbe: ProcessProbe, freeBytes: @escaping () -> Int64 = { .max }) {
        self.home = home
        self.now = now
        self.processProbe = processProbe
        self.freeBytes = freeBytes
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
