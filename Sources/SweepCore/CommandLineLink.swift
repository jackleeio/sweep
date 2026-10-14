import Foundation

/// 下载版 app 首次启动时，把 app 里自带的命令行链接到 ~/.local/bin/sweep，
/// 这样 agent 才能运行 `sweep keep`。
public enum CommandLineLink {
    public enum Outcome: Equatable {
        case created
        case updated
        case alreadyLinked
        /// 那里已经有一个普通文件（通常是从源码安装的命令行），不动它。
        case keptExistingFile
        /// 那里的链接指向别的东西，不动它。
        case keptForeignLink
        case failed(String)
    }

    /// 只在路径空着、或原来就是指向某个 Sweep.app 里命令行的链接时才动手。
    public static func install(target: URL, at link: URL) -> Outcome {
        let fm = FileManager.default
        switch FileKind.of(link) {
        case nil:
            do {
                try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
                return .created
            } catch {
                return .failed(error.localizedDescription)
            }
        case .symlink:
            let current = (try? fm.destinationOfSymbolicLink(atPath: link.path)) ?? ""
            if current == target.path { return .alreadyLinked }
            guard current.hasSuffix("/Sweep.app/Contents/Helpers/sweep") else { return .keptForeignLink }
            do {
                try fm.removeItem(at: link)
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
                return .updated
            } catch {
                return .failed(error.localizedDescription)
            }
        default:
            return .keptExistingFile
        }
    }
}
