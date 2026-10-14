import Foundation

public enum Format {
    /// 与「系统设置 › 储存空间」和访达一致，按 1000 进制。
    public static let gigabyte: Double = 1_000_000_000

    public static func bytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(n)
        var i = 0
        while value >= 1000, i < units.count - 1 {
            value /= 1000
            i += 1
        }
        return i == 0 ? "\(n) B" : String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[i])
    }

    /// 整数不带小数点，其余保留原样。
    public static func number(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : "\(value)"
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
    /// 执行 git 并返回去掉首尾空白的标准输出；命令失败返回 nil。
    static func output(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
    static func of(_ url: URL) -> FileKind? { info(url.path)?.kind }

    /// 一次 lstat 同时取类型和修改时间（epoch 秒）。
    static func info(_ path: String) -> (kind: FileKind, mtime: Double)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let kind: FileKind
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return (kind, Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
    }
}
