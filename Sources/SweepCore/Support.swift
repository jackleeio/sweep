import Foundation

public enum Format {
    public static func bytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(n)
        var i = 0
        while value >= 1024, i < units.count - 1 {
            value /= 1024
            i += 1
        }
        return i == 0 ? "\(n) B" : String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[i])
    }

    public static func gb(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))G" : "\(value)G"
    }
}

extension Array {
    /// 并行执行 transform，结果顺序与输入一致。用于磁盘遍历这类各项互不相干的慢操作。
    func parallelMap<R>(_ transform: (Element) -> R) -> [R] {
        guard count > 1 else { return map(transform) }
        return [R](unsafeUninitializedCapacity: count) { buffer, initialized in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: count) { i in
                (base + i).initialize(to: transform(self[i]))
            }
            initialized = count
        }
    }
}

enum Git {
    enum Tracking {
        case tracked
        case untracked
        /// git 无法给出结论。调用方应按「受跟踪」处理，宁可不删。
        case unknown
    }

    /// url 自身或其内部是否有被 git 跟踪的文件。
    static func tracking(of url: URL) -> Tracking {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.deletingLastPathComponent().path, "ls-files", "--", url.lastPathComponent]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return .unknown }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        if process.terminationStatus == 0 { return output.isEmpty ? .untracked : .tracked }
        return errors.contains("not a git repository") ? .untracked : .unknown
    }
}

enum Glob {
    struct Match {
        let url: URL
        /// 模式里第一个通配符之前的目录，用作删除校验的根。
        let root: URL
    }

    /// 逐段展开只含 `*` 的简单通配模式，不跟随符号链接。
    static func expand(_ pattern: String, env: Env) -> [Match] {
        let parts = env.expand(pattern).pathComponents
        var current = [URL(fileURLWithPath: "/")]
        var root: URL?
        let fm = FileManager.default

        for part in parts.dropFirst() {
            if part.contains("*") {
                if root == nil { root = current.first }
                current = current.flatMap { dir -> [URL] in
                    let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                    return names.filter { fnmatch(part, $0, 0) == 0 }.sorted().map { dir.appendingPathComponent($0) }
                }
            } else {
                current = current.map { $0.appendingPathComponent(part) }
            }
        }
        guard let root else { return [] }
        return current.filter { FileKind.of($0) != nil && FileKind.of($0) != .symlink }.map { Match(url: $0, root: root) }
    }
}

enum FileKind {
    case file
    case directory
    case symlink
    case other

    /// 不跟随符号链接；路径不存在返回 nil。
    static func of(_ url: URL) -> FileKind? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }
}
