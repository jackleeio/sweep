import Darwin
import Foundation

/// 用 libproc 直接读进程表。不用 ps：它是 setuid 程序，有的环境里不让执行。
public struct LiveProcessSystem: ProcessSystem {
    /// SIGTERM 之后等这么久，还没退出的再发 SIGKILL。
    let grace: TimeInterval
    /// 为 false 时只读进程表，end 什么都不做。
    let canEnd: Bool

    public init(grace: TimeInterval = 5, canEnd: Bool = true) {
        self.grace = grace
        self.canEnd = canEnd
    }

    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    private static let argumentLimit: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctl(&mib, 2, &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : 1 << 20
    }()

    public func snapshot() -> ProcessSnapshot? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard listed > 0 else { return nil }

        let uid = getuid()
        var buffer = [UInt8](repeating: 0, count: Self.argumentLimit)
        var processes: [ProcessEntry] = []
        for pid in pids.prefix(Int(listed)) where pid > 0 {
            guard let info = Self.bsdInfo(pid) else { continue }
            let name = Self.text(info.pbi_name).isEmpty ? Self.text(info.pbi_comm) : Self.text(info.pbi_name)
            var entry = ProcessEntry(pid: pid, ppid: Int32(info.pbi_ppid), uid: info.pbi_uid, name: name, executable: "",
                                     arguments: [], startMicros: Self.startMicros(info), cpuSeconds: 0, memory: 0,
                                     tty: Self.terminal(info))
            // 别的用户的进程只需要知道父子关系，读不到命令行和用量也无妨
            if info.pbi_uid == uid {
                if let (executable, arguments) = Self.arguments(pid, buffer: &buffer) {
                    entry.executable = executable
                    entry.arguments = arguments
                }
                if let usage = Self.usage(pid) {
                    entry.cpuSeconds = Double(usage.ri_user_time + usage.ri_system_time) * Self.secondsPerTick
                    entry.memory = Int64(usage.ri_phys_footprint)
                }
            }
            processes.append(entry)
        }

        var ttyInput: [String: Date] = [:]
        for tty in Set(processes.compactMap(\.tty)) {
            var st = stat()
            if stat("/dev/\(tty)", &st) == 0 {
                ttyInput[tty] = Date(timeIntervalSince1970: Double(st.st_atimespec.tv_sec) + Double(st.st_atimespec.tv_nsec) / 1e9)
            }
        }
        return ProcessSnapshot(processes: processes, userID: uid, selfPID: getpid(), launchdPIDs: Self.launchdPIDs(uid: uid),
                               underMemoryPressure: Self.memoryPressure(), ttyInput: ttyInput)
    }

    public func end(_ processes: [ProcessEntry]) -> [ProcessEntry] {
        guard canEnd else { return [] }
        let targets = processes.filter(Self.isAlive)
        for p in targets { kill(p.pid, SIGTERM) }
        Self.wait(for: targets, upTo: grace)
        for p in targets where Self.isAlive(p) { kill(p.pid, SIGKILL) }
        Self.wait(for: targets, upTo: 2)
        return targets.filter { !Self.isAlive($0) }
    }

    private static func wait(for targets: [ProcessEntry], upTo seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, targets.contains(where: isAlive) { usleep(100_000) }
    }

    /// 还在运行，并且还是当初那个进程（启动时间对得上）。僵尸进程算已经结束。
    static func isAlive(_ p: ProcessEntry) -> Bool {
        guard let info = bsdInfo(p.pid) else { return false }
        let zombie: UInt32 = 5  // SZOMB
        return startMicros(info) == p.startMicros && info.pbi_status != zombie
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func startMicros(_ info: proc_bsdinfo) -> Int64 {
        Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec)
    }

    private static func usage(_ pid: pid_t) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return status == 0 ? info : nil
    }

    private static func terminal(_ info: proc_bsdinfo) -> String? {
        guard info.e_tdev != UInt32.max, let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty.isEmpty || tty == "??" ? nil : tty
    }

    /// 定长 C 字符数组转成字符串，最多读到数组末尾。
    private static func text<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// KERN_PROCARGS2：argc，可执行文件路径，若干个 \0，然后是 argc 个参数。
    private static func arguments(_ pid: pid_t, buffer: inout [UInt8]) -> (String, [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        func string(from start: Int) -> (String, Int) {
            let end = buffer[start..<size].firstIndex(of: 0) ?? size
            return (String(decoding: buffer[start..<end], as: UTF8.self), end)
        }
        var (executable, index) = string(from: 4)
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let (argument, end) = string(from: index)
            arguments.append(argument)
            index = end + 1
        }
        return (executable, arguments)
    }

    /// 本用户 gui 域里 launchd 托管、正在运行的服务。读不到返回 nil。
    static func launchdPIDs(uid: uid_t) -> Set<Int32>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(uid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let pids = parseLaunchdServices(String(decoding: data, as: UTF8.self))
        // 一个都没有不正常（总有系统服务在跑），当作没读到
        return pids.isEmpty ? nil : pids
    }

    /// 取 `services = { … }` 一节里每行第一列的 pid（0 表示没在运行）。
    static func parseLaunchdServices(_ output: String) -> Set<Int32> {
        var pids: Set<Int32> = []
        var inServices = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\tservices = {") { inServices = true; continue }
            guard inServices else { continue }
            if line.hasPrefix("\t}") { break }
            if let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first, let pid = Int32(first), pid > 0 {
                pids.insert(pid)
            }
        }
        return pids
    }

    /// 系统的内存压力到了「警告」或更严重。
    static func memoryPressure() -> Bool {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return false }
        return level >= 2
    }
}
