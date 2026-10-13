import Foundation

public struct Measurement: Equatable {
    /// 实际占用的磁盘空间（按分配块计，与 du 口径一致）。
    public var bytes: Int64
    /// 树内最新的修改时间，含目录自身。
    public var latest: Date?
}

public enum Measure {
    /// 遍历 url（文件或目录），不跟随符号链接，不跨文件系统。
    public static func measure(_ url: URL) -> Measurement {
        var bytes: Int64 = 0
        var latest: Double = -1

        guard let cpath = strdup(url.path) else { return Measurement(bytes: 0, latest: nil) }
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return Measurement(bytes: 0, latest: nil)
        }
        defer { fts_close(fts) }

        while let ent = fts_read(fts) {
            switch Int32(ent.pointee.fts_info) {
            case FTS_F, FTS_D, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = ent.pointee.fts_statp else { continue }
                bytes += Int64(st.pointee.st_blocks) * 512
                let t = Double(st.pointee.st_mtimespec.tv_sec) + Double(st.pointee.st_mtimespec.tv_nsec) / 1e9
                if t > latest { latest = t }
            default:
                continue
            }
        }
        return Measurement(bytes: bytes, latest: latest < 0 ? nil : Date(timeIntervalSince1970: latest))
    }
}
