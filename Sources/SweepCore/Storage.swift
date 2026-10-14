import Foundation

public struct StorageItem: Codable, Equatable {
    public var path: String
    public var bytes: Int64
}

/// 硬盘占用的一块区域，以及其中 Sweep 能清掉多少。
public struct StorageArea: Codable, Equatable {
    public var id: String
    public var title: String
    public var bytes: Int64
    /// Sweep 的规则能清掉的部分（含关着的规则打开后能清的）。
    public var cleanable: Int64
    /// 这块能不能删、该怎么处理。
    public var note: String
    public var largest: [StorageItem]
}

/// APFS 容器里各个卷的占用。
public struct VolumeUsage: Equatable {
    public var total: Int64
    public var dataUsed: Int64
    public var system: Int64
    public var preboot: Int64
    public var recovery: Int64
    public var vm: Int64

    public init(total: Int64, dataUsed: Int64, system: Int64, preboot: Int64, recovery: Int64, vm: Int64) {
        self.total = total
        self.dataUsed = dataUsed
        self.system = system
        self.preboot = preboot
        self.recovery = recovery
        self.vm = vm
    }

    /// 解析 `diskutil apfs list -plist` 的输出，取含 Data 卷的那个容器。
    public static func parse(_ data: Data) -> VolumeUsage? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else { return nil }
        for container in containers {
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            func used(_ role: String) -> Int64? {
                volumes.first { ($0["Roles"] as? [String] ?? []).contains(role) }
                    .flatMap { ($0["CapacityInUse"] as? NSNumber)?.int64Value }
            }
            guard let data = used("Data") else { continue }
            return VolumeUsage(total: (container["CapacityCeiling"] as? NSNumber)?.int64Value ?? 0, dataUsed: data,
                               system: used("System") ?? 0, preboot: used("Preboot") ?? 0,
                               recovery: used("Recovery") ?? 0, vm: used("VM") ?? 0)
        }
        return nil
    }

    public static func current() -> VolumeUsage? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "list", "-plist"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? parse(data) : nil
    }
}

/// 整块硬盘的占用，按区域划分，类似「系统设置 › 储存空间」，但说明每块能不能删。
public struct StorageReport: Codable, Equatable {
    public var date: Date
    public var total: Int64
    public var used: Int64
    public var areas: [StorageArea]

    public static let defaultApplications = [URL(fileURLWithPath: "/Applications")]
    /// 系统和开发环境。临时目录（/private/var/folders）单列，不算在这里。
    public static let defaultSystemPaths = ["/private/var/db", "/private/var/vm", "/private/var/log", "/Library", "/opt/homebrew",
                                            "/usr/local", "/System/Volumes/Data/System"].map { URL(fileURLWithPath: $0) }
    /// 当前用户的临时目录：T（临时文件）、C（缓存）、X（如 Chrome 的签名副本）。
    public static var defaultTempDirs: [URL] {
        [URL(fileURLWithPath: NSTemporaryDirectory()).deletingLastPathComponent()]
    }

    private struct Definition {
        let id: String
        let title: String
        let note: String
        let entries: [URL]
    }

    /// 测量整个主目录，比较慢（几分钟），应在后台调用。
    /// candidates 是一次扫描（含关着的规则）的结果，用来算每块里有多少能清。
    public static func build(env: Env, candidates: [Candidate], volumes: VolumeUsage,
                             applications: [URL] = defaultApplications, systemPaths: [URL] = defaultSystemPaths,
                             tempDirs: [URL] = defaultTempDirs) -> StorageReport {
        let fm = FileManager.default
        func children(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" }
                .map { dir.appendingPathComponent($0) }
                .filter { FileKind.of($0) == .directory || FileKind.of($0) == .file }
        }
        let home = env.home
        let library = home.appendingPathComponent("Library")
        let homeEntries = children(home)
        let librarySplit: Set<String> = ["Caches", "Application Support", "Containers", "Group Containers"]

        let definitions = [
            Definition(id: "projects", title: "项目代码",
                       note: "源码和 git 历史是你的工作成果，Sweep 不会删；能清的是里面的构建缓存、闲置依赖和旧工作树。",
                       entries: children(home.appendingPathComponent("Projects"))),
            Definition(id: "agentData", title: "Agent 与开发工具",
                       note: "Codex、Claude 等 agent 的对话和缓存，以及 node、rust 等工具链。对话和缓存按规则清；工具链删了需要重装。",
                       entries: homeEntries.filter { $0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != ".Trash" }),
            Definition(id: "caches", title: "缓存",
                       note: "缓存，大多可以删，应用会自己重建。agent 的构建副本也在这里；AI 工具的缓存默认保留。",
                       entries: children(library.appendingPathComponent("Caches"))),
            Definition(id: "appSupport", title: "应用数据",
                       note: "各应用自己的数据：设置、登录状态、下载的内容。一般不要删；其中的缓存子目录可在退出应用后清理。",
                       entries: children(library.appendingPathComponent("Application Support"))),
            Definition(id: "containers", title: "应用容器",
                       note: "沙盒应用的数据。Docker 的虚拟磁盘在这里，要在 Docker 里清理，不能直接删文件。",
                       entries: children(library.appendingPathComponent("Containers")) + children(library.appendingPathComponent("Group Containers"))),
            Definition(id: "libraryOther", title: "资源库其他",
                       note: "日志、iCloud 文稿等。日志可以删，其余一般不动。",
                       entries: children(library).filter { !librarySplit.contains($0.lastPathComponent) }),
            Definition(id: "personal", title: "你的文件",
                       note: "你自己的文件。Sweep 不会删；照片、录像可以挪到移动硬盘。",
                       entries: homeEntries.filter { !$0.lastPathComponent.hasPrefix(".") && !["Projects", "Library"].contains($0.lastPathComponent) }),
            Definition(id: "applications", title: "应用程序",
                       note: "卸载不用的应用可以腾出空间。",
                       entries: applications.flatMap(children)),
            Definition(id: "temp", title: "临时文件",
                       note: "应用和 agent 的临时文件。Chrome 每次启动会在这里复制一份自己（code_sign_clone），被强制结束时就留了下来，没在运行的可以删；这些副本共享磁盘块，实际占用可能远小于显示值。",
                       entries: tempDirs.flatMap(children)),
        ]

        // 所有条目一起并行测量，再按区域汇总
        let all = definitions.flatMap { def in def.entries.map { (def.id, $0) } }
        let sizes = all.parallelMap { Measure.measure($0.1).bytes }
        var byArea: [String: [StorageItem]] = [:]
        var areaOf: [String: String] = [:]
        for ((id, url), bytes) in zip(all, sizes) {
            byArea[id, default: []].append(StorageItem(path: url.path, bytes: bytes))
            areaOf[url.path] = id
        }
        let cleanable = attribute(candidates, to: areaOf)

        var areas = definitions.map { def -> StorageArea in
            let items = byArea[def.id] ?? []
            return StorageArea(id: def.id, title: def.title, bytes: items.reduce(0) { $0 + $1.bytes },
                               cleanable: cleanable[def.id] ?? 0, note: def.note,
                               largest: Array(items.sorted { $0.bytes > $1.bytes }.prefix(5)))
        }

        let systemExtra = systemPaths.parallelMap { Measure.measure($0).bytes }.reduce(0, +)
        areas.append(StorageArea(id: "system", title: "系统",
                                 bytes: volumes.system + volumes.preboot + volumes.recovery + volumes.vm + systemExtra,
                                 cleanable: 0, note: "macOS 本身、虚拟内存、Homebrew 等系统和开发环境，不能删。", largest: []))

        // 数据卷里量不到的部分：受系统保护、没有权限读取的目录
        let measuredOnData = areas.filter { $0.id != "system" }.reduce(Int64(0)) { $0 + $1.bytes } + systemExtra
        areas.append(StorageArea(id: "protected", title: "读不到的部分",
                                 bytes: max(0, volumes.dataUsed - measuredOnData), cleanable: 0,
                                 note: "微信、浏览器、邮件、照片图库、废纸篓等受系统保护的数据，Sweep 读不到。给终端开「完全磁盘访问权限」后才能细看；微信可以在它自己的存储管理里清理。",
                                 largest: []))

        return StorageReport(date: env.now, total: volumes.total,
                             used: volumes.dataUsed + volumes.system + volumes.preboot + volumes.recovery + volumes.vm,
                             areas: areas)
    }

    /// 把可清理的项归到它所在的区域。嵌套在另一个可清理项里的不重复计算。
    private static func attribute(_ candidates: [Candidate], to areaOf: [String: String]) -> [String: Int64] {
        let deletable = candidates.filter(\.isDelete).sorted { $0.url.path.count < $1.url.path.count }
        var taken: [String] = []
        var out: [String: Int64] = [:]
        for candidate in deletable {
            let path = candidate.url.path
            if taken.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            taken.append(path)
            // 从自身往上逐级找它属于哪个条目
            var probe = URL(fileURLWithPath: path)
            while probe.path != "/" {
                if let id = areaOf[probe.path] {
                    out[id, default: 0] += candidate.bytes
                    break
                }
                probe.deleteLastPathComponent()
            }
        }
        return out
    }

    public static func load(from url: URL) -> StorageReport? {
        (try? JSONFiles.read(StorageReport.self, from: url)) ?? nil
    }

    public func save(to url: URL) throws {
        try JSONFiles.write(self, to: url)
    }
}

extension Env {
    public var storageFile: URL { supportDir.appendingPathComponent("storage.json") }
}
