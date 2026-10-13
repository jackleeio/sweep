import Foundation

public struct Measurement: Equatable {
    /// 删掉这棵树实际能释放的空间：按分配块计，硬链接只算一次，
    /// 在树外还有硬链接的文件（如 pnpm store 里被项目引用的包）不计入。
    public var bytes: Int64
    /// 树内最新的修改时间，含目录自身。
    public var latest: Date?
    /// 树里有读不了的部分。此时体积和时间都不完整，调用方不应据此删除。
    public var unreadable = false
}

public enum Measure {
    private struct Inode: Hashable {
        let device: dev_t
        let number: ino_t
    }

    private struct Links {
        var seen = 0
        let total: Int
        let bytes: Int64
    }

    /// 遍历 url（文件或目录），不跟随符号链接，不跨文件系统。
    public static func measure(_ url: URL) -> Measurement {
        var bytes: Int64 = 0
        var latest: Double = -1
        var shared: [Inode: Links] = [:]
        var unreadable = false

        guard let cpath = strdup(url.path) else { return Measurement(bytes: 0, latest: nil) }
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return Measurement(bytes: 0, latest: nil)
        }
        defer { fts_close(fts) }

        while let ent = fts_read(fts) {
            let kind = Int32(ent.pointee.fts_info)
            switch kind {
            case FTS_F, FTS_D, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = ent.pointee.fts_statp else { continue }
                let size = Int64(st.pointee.st_blocks) * 512
                if kind == FTS_F, st.pointee.st_nlink > 1 {
                    let key = Inode(device: st.pointee.st_dev, number: st.pointee.st_ino)
                    shared[key, default: Links(total: Int(st.pointee.st_nlink), bytes: size)].seen += 1
                } else {
                    bytes += size
                }
                let t = Double(st.pointee.st_mtimespec.tv_sec) + Double(st.pointee.st_mtimespec.tv_nsec) / 1e9
                if t > latest { latest = t }
            case FTS_DNR, FTS_ERR, FTS_NS:
                unreadable = true
            default:
                continue
            }
        }

        for links in shared.values where links.seen >= links.total { bytes += links.bytes }
        return Measurement(bytes: bytes, latest: latest < 0 ? nil : Date(timeIntervalSince1970: latest), unreadable: unreadable)
    }
}
