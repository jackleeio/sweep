import Foundation

func realPath(_ url: URL) -> String? {
    guard let p = realpath(url.path, nil) else { return nil }
    defer { free(p) }
    return String(cString: p)
}

/// 删除前的最后一道校验：目标必须真实存在、本身不是符号链接、
/// 且解析符号链接后严格位于 root 内部。
public enum PathGuard {
    public enum Rejection: Equatable {
        case missing
        case symlink
        case isRoot
        case outsideRoot
        case tooShallow
        case forbiddenComponent(String)
    }

    public static let forbiddenNames: Set<String> = ["memory", ".git"]

    public static func validate(_ url: URL, root: URL, minDepth: Int = 1) -> Rejection? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return .missing }
        if (st.st_mode & S_IFMT) == S_IFLNK { return .symlink }

        guard let realParent = realPath(url.deletingLastPathComponent()),
              let realRoot = realPath(root) else { return .missing }
        let rootComps = URL(fileURLWithPath: realRoot).pathComponents
        let comps = URL(fileURLWithPath: realParent).appendingPathComponent(url.lastPathComponent).pathComponents

        if comps == rootComps { return .isRoot }
        guard comps.count > rootComps.count, Array(comps.prefix(rootComps.count)) == rootComps else {
            return .outsideRoot
        }
        let rel = comps.dropFirst(rootComps.count)
        if let bad = rel.first(where: { forbiddenNames.contains($0) }) { return .forbiddenComponent(bad) }
        if rel.count < minDepth { return .tooShallow }
        return nil
    }
}
