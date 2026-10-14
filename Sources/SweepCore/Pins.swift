import Foundation

/// 在会话文件里查找 `sweep keep` 输出的标记串。
public enum TokenScanner {
    public static let prefix = "sweep-pin:v1:"

    public static func tokens(in url: URL, chunkSize: Int = 4 << 20) -> Set<String> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let needle = Array(prefix.utf8)
        let tokenLength = needle.count + 36
        var found = Set<String>()
        var carry = Data()
        var done = false

        while !done {
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    done = true
                    return
                }
                var buffer = carry
                buffer.append(chunk)
                buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    var offset = 0
                    while offset + needle.count <= raw.count {
                        guard let hit = memmem(base + offset, raw.count - offset, needle, needle.count) else { break }
                        let pos = base.distance(to: UnsafeRawPointer(hit))
                        if pos + tokenLength <= raw.count {
                            let tail = UnsafeRawBufferPointer(start: base + pos + needle.count, count: 36)
                            if let s = String(bytes: tail, encoding: .ascii), UUID(uuidString: s) != nil {
                                found.insert(prefix + s.lowercased())
                            }
                        }
                        offset = pos + needle.count
                    }
                }
                // 保留尾部，接上下一块后能找到跨块的标记
                carry = Data(buffer.suffix(tokenLength - 1))
            }
        }
        return found
    }
}

public struct Pin: Codable, Equatable {
    public var token: String
    public var label: String
    public var createdAt: Date
    public var agent: String?
    public var sessionID: String?
    public var cwd: String?
}

/// 用户标记为「不要删」的对话名单。
public final class PinStore {
    private let file: URL

    public init(file: URL) { self.file = file }

    /// 名单文件不存在时为空；存在但损坏时抛错，调用方必须因此停止删除对话。
    public func all() throws -> [Pin] {
        try JSONFiles.read([Pin].self, from: file) ?? []
    }

    @discardableResult
    public func add(label: String, sessionID: String?, agent: String?, cwd: String?, now: Date) throws -> Pin {
        var pins = try all()
        let pin = Pin(token: TokenScanner.prefix + UUID().uuidString.lowercased(), label: label,
                      createdAt: now.wholeSeconds, agent: agent, sessionID: sessionID, cwd: cwd)
        pins.append(pin)
        try JSONFiles.write(pins, to: file)
        return pin
    }

    /// 按标签或标记串移除，返回被移除的项。
    @discardableResult
    public func remove(matching key: String) throws -> [Pin] {
        let pins = try all()
        let removed = pins.filter { $0.label == key || $0.token == key }
        guard !removed.isEmpty else { return [] }
        try JSONFiles.write(pins.filter { !removed.contains($0) }, to: file)
        return removed
    }

    /// 把标记串对应的会话 ID 记下来。之后即使会话文件被压缩、搜不到标记串，也能按 ID 认出它。
    public func bind(_ sessionIDs: [String: String]) throws {
        guard !sessionIDs.isEmpty else { return }
        var pins = try all()
        var changed = false
        for i in pins.indices where pins[i].sessionID == nil {
            if let id = sessionIDs[pins[i].token] {
                pins[i].sessionID = id
                changed = true
            }
        }
        if changed { try JSONFiles.write(pins, to: file) }
    }

    public func match(file: URL, sessionID: String?) throws -> Pin? {
        Self.match(pins: try all(), file: file, sessionID: sessionID)
    }

    public static func match(pins: [Pin], file: URL, sessionID: String?) -> Pin? {
        guard !pins.isEmpty else { return nil }
        if let sessionID, let pin = pins.first(where: { $0.sessionID == sessionID }) { return pin }
        let found = TokenScanner.tokens(in: file)
        guard !found.isEmpty else { return nil }
        return pins.first { found.contains($0.token) }
    }
}
