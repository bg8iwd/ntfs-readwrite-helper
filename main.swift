// NTFS 读写助手 — macOS 菜单栏应用 v1.4
// 底层：FUSE-T + ntfs-3g；本应用负责磁盘检测与读写挂载编排。
// 核心策略（对齐竞品体验）：
//   1. 周期对账（reconcile）：每 3 秒核对全部 NTFS 分区，不依赖单次事件通知
//   2. 系统只读抢占（macOS 26/27 FSKit 内置驱动）一旦出现 → 强制卸载并转为读写
//   3. 新盘插入 / 拔盘重插 / 睡眠唤醒重枚举 → 自动读写挂载
//   4. 用户主动卸载的盘不再自动重挂（尊重用户意图）
//   5. 僵尸 fuse-t 挂载（盘已拔但挂载残留）自动清理
//   6. 失败指数退避，避免打转刷日志
// Build: swiftc -O -swift-version 5 main.swift -o NTFSHelper -framework AppKit

import AppKit
import ServiceManagement
import IOKit.pwr_mgt

// MARK: - 日志

final class AppLog {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("NTFSReadWriteHelper.log")
    }()

    static func line(_ s: String) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = "[\(df.string(from: Date()))] \(s)\n"
        if let fh = FileHandle(forWritingAtPath: url.path) {
            fh.seekToEndOfFile()
            fh.write(text.data(using: .utf8)!)
            fh.closeFile()
        } else {
            try? text.data(using: .utf8)?.write(to: url)
        }
    }
}

// MARK: - 命令执行

@discardableResult
func runCommand(_ path: String, _ args: [String]) -> (exit: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (127, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - 磁盘拓扑（diskutil list -plist）

struct NTFSPartition {
    var deviceID: String     // disk6s1
    var volumeName: String   // Untitled（可能为空）
    var uuid: String         // VolumeUUID（可能为空）
    var key: String { uuid.isEmpty ? "dev:" + deviceID : "uuid:" + uuid }
    var safeVolname: String {
        let base = volumeName.isEmpty ? "Untitled" : volumeName
        return base.replacingOccurrences(of: ",", with: "_")
                   .replacingOccurrences(of: "/", with: "_")
    }
}

enum DiskTopology {
    /// 枚举所有 NTFS 分区（无论是否挂载）
    static func ntfsPartitions() -> [NTFSPartition] {
        let (code, out) = runCommand("/usr/sbin/diskutil", ["list", "-plist"])
        guard code == 0,
              let plist = try? PropertyListSerialization.propertyList(from: out.data(using: .utf8)!, options: [], format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        var result: [NTFSPartition] = []
        for disk in disks {
            let parts = (disk["Partitions"] as? [[String: Any]]) ?? []
            // 整盘无分区表的 NTFS（磁盘镜像场景）
            if parts.isEmpty,
               let content = disk["Content"] as? String, content.contains("NTFS"),
               let devID = disk["DeviceIdentifier"] as? String {
                result.append(NTFSPartition(deviceID: devID,
                                            volumeName: disk["VolumeName"] as? String ?? "",
                                            uuid: disk["VolumeUUID"] as? String ?? ""))
            }
            for p in parts {
                let content = (p["Content"] as? String ?? "").uppercased()
                let fsType  = (p["FilesystemType"] as? String ?? "").uppercased()
                guard content.contains("NTFS") || fsType.contains("NTFS") else { continue }
                guard let devID = p["DeviceIdentifier"] as? String else { continue }
                result.append(NTFSPartition(deviceID: devID,
                                            volumeName: p["VolumeName"] as? String ?? "",
                                            uuid: p["VolumeUUID"] as? String ?? ""))
            }
        }
        return result
    }

    /// 全部当前挂载：mountPoint -> (类型, 是否只读)
    static func currentMounts() -> [String: (type: String, readOnly: Bool)] {
        let (code, out) = runCommand("/sbin/mount", [])
        guard code == 0 else { return [:] }
        var result: [String: (String, Bool)] = [:]
        for line in out.split(separator: "\n") {
            guard let onRange = line.range(of: " on ") else { continue }
            let dev = String(line[line.startIndex..<onRange.lowerBound])
            let rest = line[onRange.upperBound...]
            guard let paren = rest.range(of: " (") else { continue }
            let mp = String(rest[rest.startIndex..<paren.lowerBound])
            var flags = String(rest[paren.upperBound...])
            // mount 输出形如 "fuse-t:/Vol on /Volumes/X (nfs)"，flags 起始带结尾的 ")"
            // 必须剥掉，否则 type 会解析成 "nfs)"，导致所有 type 比较恒为 false
            if flags.hasSuffix(")") { flags.removeLast() }
            let type = flags.split(separator: ",").first.map(String.init) ?? ""
            let ro = flags.contains("read-only") || flags.contains("(ro,") || flags.contains(",ro,") || flags.hasSuffix("(ro)")
            result[mp] = (type.isEmpty ? dev : type, ro)
        }
        return result
    }

    /// diskutil info 反查挂载点对应的设备标识
    static func deviceOfMount(_ mp: String) -> String {
        let (code, out) = runCommand("/usr/sbin/diskutil", ["info", "-plist", mp])
        guard code == 0,
              let plist = try? PropertyListSerialization.propertyList(from: out.data(using: .utf8)!, options: [], format: nil) as? [String: Any]
        else { return "" }
        return plist["DeviceIdentifier"] as? String ?? ""
    }
}

// MARK: - 卷扫描（菜单展示用）

struct VolumeInfo {
    var deviceID: String
    var mountPoint: String
    var name: String
    var kind: Kind

    enum Kind { case ntfsReadOnly, ntfsReadWrite, other }
    var isNTFS: Bool { kind != .other }
}

enum VolumeScanner {
    /// 我们通过 ntfs-3g 挂载的挂载点 -> (卷名, 设备)（跨启动记忆）
    static var managedNames: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "managedNames") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "managedNames") }
    }
    static var managedDevs: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "managedDevs") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "managedDevs") }
    }

    static func markManaged(_ mp: String, name: String, dev: String) {
        var n = managedNames; n[mp] = name; managedNames = n
        var d = managedDevs;  d[mp] = dev; managedDevs = d
    }

    static func unmarkManaged(_ mp: String) {
        var n = managedNames; n.removeValue(forKey: mp); managedNames = n
        var d = managedDevs;  d.removeValue(forKey: mp); managedDevs = d
    }

    static func scan() -> [VolumeInfo] {
        var result: [VolumeInfo] = []
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []
        let mounts = DiskTopology.currentMounts()
        for entry in entries where !entry.hasPrefix(".") {
            let mp = "/Volumes/" + entry
            var st = stat()
            guard lstat(mp, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_dev != 0 else { continue }
            guard let m = mounts[mp] else { continue }

            if m.readOnly && m.type == "ntfs" {
                let (code, out) = runCommand("/usr/sbin/diskutil", ["info", "-plist", mp])
                var name = entry
                var dev = ""
                if code == 0,
                   let plist = try? PropertyListSerialization.propertyList(from: out.data(using: .utf8)!, options: [], format: nil) as? [String: Any] {
                    name = (plist["VolumeName"] as? String) ?? entry
                    dev = plist["DeviceIdentifier"] as? String ?? ""
                }
                result.append(VolumeInfo(deviceID: dev, mountPoint: mp, name: name, kind: .ntfsReadOnly))
            } else if !m.readOnly && (m.type == "nfs" || m.type == "fusefs_ntfs" || m.type == "ntfs-3g") {
                result.append(VolumeInfo(deviceID: managedDevs[mp] ?? "",
                                         mountPoint: mp,
                                         name: managedNames[mp] ?? entry,
                                         kind: .ntfsReadWrite))
            }
        }
        return result
    }
}

// MARK: - USB 链路保活

/// 防止 macOS 对空闲 USB 存储做低功耗挂起（部分移动硬盘桥接芯片被挂起后唤醒失败，
/// 会导致 USB 链路复位重连 → 盘「自动消失又重连」）。双保险：
///   1. NoDiskSleep 电源断言：有受管卷挂载时阻止磁盘休眠
///   2. 每 5 秒对每个受管读写卷做一次轻量 I/O，让链路保持活跃
final class USBKeepAlive {
    static let shared = USBKeepAlive()
    private var timer: Timer?
    private var assertionID: IOPMAssertionID = 0
    private var assertionActive = false

    func start() {
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.pulse()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func activeMounts() -> [String] {
        let mounts = DiskTopology.currentMounts()
        return VolumeScanner.managedDevs.keys.filter { mp in
            guard let m = mounts[mp] else { return false }
            guard !m.readOnly && m.type == "nfs" else { return false }
            // 僵尸挂载同样出现在 mount 表里，但 statvfs 会立刻失败（ENXIO）
            var s = statvfs()
            return statvfs(mp, &s) == 0 && s.f_blocks > 0
        }
    }

    private var lastIdleLog: Date = .distantPast

    private func pulse() {
        let actives = activeMounts()
        if actives.isEmpty {
            // 只在状态切换时记一次，避免每 5 秒刷屏淹没真正的问题记录
            if caffeinate != nil || assertionActive {
                AppLog.line("保活: 当前无活跃受管卷 (managed=\(VolumeScanner.managedDevs.count))")
            } else if Date().timeIntervalSince(lastIdleLog) > 300 {
                lastIdleLog = Date()
                AppLog.line("保活: 待机（无读写挂载卷）")
            }
            releaseCaffeinate()
            return
        }
        ensureCaffeinate()
        for mp in actives { touch(mp) }
        devicePulse(actives)
    }

    /// 设备级保活：每轮读一次裸设备（512 字节丢弃，开销可忽略）。
    /// 文件系统层操作会命中 ntfs-3g 缓存，真正防 USB selective suspend 必须动到设备。
    private func devicePulse(_ mounts: [String]) {
        guard MountManager.helperAvailable else { return }
        let targets = mounts.compactMap { mp -> String? in
            guard let d = VolumeScanner.managedDevs[mp], !d.isEmpty else { return nil }
            return d
        }
        guard !targets.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for d in targets {
                _ = runCommand("/usr/bin/sudo", ["-n", MountManager.helperPath, "keepalive", d])
            }
        }
    }

    /// 对挂载点做一次轻量 I/O（根目录属性 + 目录枚举 + 随机条目 stat）
    /// 随机条目是为了降低 ntfs-3g 元数据缓存命中率——只反复 stat 根目录会全部命中缓存，
    /// 根本不产生设备读取，也就起不到让 USB 链路保持活跃的作用。
    private func touch(_ mp: String) {
        var st = stat()
        _ = stat(mp, &st)
        guard let dir = opendir(mp) else { return }
        var names: [String] = []
        while let e = readdir(dir) {
            let n = withUnsafePointer(to: e.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if n != "." && n != ".." && !n.hasPrefix("._") { names.append(n) }
            if names.count >= 64 { break }
        }
        closedir(dir)
        guard !names.isEmpty else { return }
        let pick = names[Int.random(in: 0..<names.count)]
        var st2 = stat()
        _ = lstat(mp + "/" + pick, &st2)
    }

    /// 阻止磁盘空转休眠。
    /// IOPMAssertion 在本机被系统拒绝（kIOReturnNotPermitted，ad-hoc 签名无电源管理授权），
    /// 因此主通道改为系统自带的 caffeinate 子进程：-i 阻止空闲休眠、-m 阻止磁盘休眠
    /// （man 明确 -m 需要配合 -i/-s），-w 绑定本进程 PID，App 退出时自动结束。
    private var caffeinate: Process?

    private func ensureCaffeinate() {
        if let p = caffeinate, p.isRunning { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-i", "-m", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            caffeinate = p
            AppLog.line("保活: 已启动 caffeinate(-i -m) pid=\(p.processIdentifier)")
        } catch {
            AppLog.line("保活: caffeinate 启动失败 \(error.localizedDescription)")
            ensureAssertion()
        }
    }

    private func releaseCaffeinate() {
        guard let p = caffeinate else { return }
        if p.isRunning { p.terminate() }
        caffeinate = nil
        AppLog.line("保活: 已停止 caffeinate")
        releaseAssertion()
    }

    private func ensureAssertion() {
        guard !assertionActive else { return }
        var id: IOPMAssertionID = 0
        let rc = IOPMAssertionCreateWithName(
            "NoDiskSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "NTFS 读写助手保活" as CFString,
            &id)
        if rc == kIOReturnSuccess {
            assertionID = id
            assertionActive = true
            AppLog.line("保活: NoDiskSleep 断言已创建")
        } else {
            AppLog.line("保活: NoDiskSleep 断言不可用 rc=\(rc)（已用 caffeinate 兜底）")
        }
    }

    private func releaseAssertion() {
        guard assertionActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionActive = false
    }
}

// MARK: - 挂载管理

enum MountManager {
    static var ntfs3gPath: String {
        if let p = Bundle.main.path(forResource: "ntfs-3g", ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/local/bin/ntfs-3g"
    }

    static var ntfsfixPath: String {
        if let p = Bundle.main.path(forResource: "ntfsfix", ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/local/bin/ntfsfix"
    }

    static func isUnsafeStateError(_ out: String) -> Bool {
        out.contains("unsafe state") || out.contains("hibernat")
    }

    static let writeDeniedMarker = "__WRITE_DENIED__"
    static func isWriteDeniedError(_ out: String) -> Bool {
        out.contains(writeDeniedMarker)
    }

    private static func shq(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func runAsRoot(_ shell: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let esc = shell.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"\(esc)\" with administrator privileges"
            let (code, out) = runCommand("/usr/bin/osascript", ["-e", script])
            DispatchQueue.main.async { completion(code == 0, out) }
        }
    }

    static let helperPath = "/usr/local/lib/ntfs-rw-helper/bin/ntfs-rw-mount"

    /// 我们自己的卸载操作时间戳。用于区分「用户主动推出」和「程序内部重挂时的卸载」，
    /// 前者不应该被自动挂回去，后者必须能继续重挂。
    static var lastInternalUnmount = Date.distantPast

    static func markInternalUnmount() { lastInternalUnmount = Date() }

    static var helperAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: helperPath)
    }

    /// 免密通道是否真正可用：sudo 免密放行 + 引擎能真正加载运行。
    /// 只测 sudo 权限不够——运行库丢失时 sudo 仍放行，但 ntfs-3g 会 dyld 崩溃，
    /// 用户看到的就是「插上盘没反应」。selftest 会真实跑一次引擎版本查询。
    static func freePasswordWorks() -> Bool {
        let (code, _) = runCommand("/usr/bin/sudo", ["-n", helperPath, "selftest"])
        return code == 0
    }

    static var helperInstallAttempted = false

    /// 首启自检：免密通道不可用时，用一次管理员授权自动装好
    /// （helper + sudoers），之后永久免密。用户取消授权则静默降级为逐次授权模式。
    static func ensureHelperInstalled() {
        guard !helperInstallAttempted else { return }
        helperInstallAttempted = true
        guard !freePasswordWorks() else { return }
        guard let resDir = Bundle.main.resourcePath,
              let macDir = Bundle.main.executableURL?.deletingLastPathComponent().path,
              FileManager.default.fileExists(atPath: resDir + "/install_helper.sh"),
              FileManager.default.fileExists(atPath: macDir + "/ntfs-3g")
        else {
            AppLog.line("免密通道缺失且安装资源不全，降级为逐次管理员授权模式")
            return
        }
        AppLog.line("免密通道未配置，请求一次管理员授权以自动安装")
        let cmd = "/bin/bash '\(resDir)/install_helper.sh' '\(macDir)' '\(resDir)'"
        runAsRoot(cmd) { ok, out in
            if ok, out.contains("HELPER_INSTALL_OK") {
                AppLog.line("免密通道自动安装成功，后续挂载不再需要密码")
                // 之前失败的挂载要立刻补上：清掉退避计数，马上对账一轮
                AutoMountEngine.shared.resetAndReconcile()
            } else {
                AppLog.line("免密通道自动安装未完成（用户取消或失败），降级为逐次授权: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    static func runViaHelper(_ args: [String]) -> (ok: Bool, out: String)? {
        guard helperAvailable else { return nil }
        let (code, out) = runCommand("/usr/bin/sudo", ["-n", helperPath] + args)
        guard code != 126 && code != 127 else { return nil }
        return (code == 0, out)
    }

    /// 把 NTFS 分区挂为读写（先清掉该设备与挂载点上的旧挂载，包括系统只读抢占）
    /// 重要：全程异步执行，绝不阻塞主线程。diskutil 卸载需要等待全部 DiskArbitration
    /// 会话确认（含本应用的 NSWorkspace 会话），主线程若被同步调用卡住会形成三方死锁。
    static func remountReadWrite(_ dev: String, _ displayName: String, completion: @escaping (Bool, String) -> Void) {
        guard !dev.isEmpty else {
            completion(false, "未获取到设备标识")
            return
        }
        let base = displayName.isEmpty ? "Untitled" : displayName
        let volname = base.replacingOccurrences(of: ",", with: "_")
                          .replacingOccurrences(of: "/", with: "_")
        let mp = "/Volumes/" + volname
        AppLog.line("开始读写挂载 \(displayName)(\(dev)) → \(mp)")
        markInternalUnmount()   // 下面的强卸属于内部操作，不当作「用户推出」

        guard helperAvailable else {
            fallbackMountViaOsascript(dev, mp: mp, volname: volname, displayName: displayName, completion: completion)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, out) = runCommand("/usr/bin/sudo", ["-n", helperPath, "mount", dev, mp, volname])
            DispatchQueue.main.async {
                if code == 0 {
                    VolumeScanner.markManaged(mp, name: volname, dev: dev)
                    AppLog.line("读写挂载成功(免密通道): \(volname) -> \(mp)")
                    completion(true, out)
                } else if code == 126 || code == 127 {
                    AppLog.line("免密通道不可用，改走管理员授权")
                    fallbackMountViaOsascript(dev, mp: mp, volname: volname, displayName: displayName, completion: completion)
                } else {
                    AppLog.line("免密通道挂载失败: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
                    completion(false, out)
                }
            }
        }
    }

    private static func fallbackMountViaOsascript(_ dev: String, mp: String, volname: String, displayName: String, completion: @escaping (Bool, String) -> Void) {
        let mountCmd = "\(shq(ntfs3gPath)) \(shq("/dev/" + dev)) \(shq(mp)) -o volname=\(volname),local,noowners,noatime"
        let cmd = [
            "/usr/sbin/diskutil unmount force \(shq(dev)) || /usr/sbin/diskutil unmount \(shq(dev))",
            "/usr/sbin/diskutil unmount force \(shq(mp))",
            "/bin/mkdir -p \(shq(mp))",
            "dd if=/dev/zero of=/dev/r\(dev) bs=1 count=0 2>/dev/null || { echo \(writeDeniedMarker); exit 1; }",
            mountCmd
        ].joined(separator: " ; ")
        runAsRoot(cmd) { ok, out in
            if ok {
                VolumeScanner.markManaged(mp, name: volname, dev: dev)
                AppLog.line("读写挂载成功: \(volname) -> \(mp)")
            } else {
                AppLog.line("读写挂载失败: \(volname) — \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            completion(ok, out)
        }
    }

    /// 清理 NTFS 卷的「不安全状态」脏标记（异步，避免阻塞主线程）
    static func fixUnsafeState(_ dev: String, completion: @escaping (Bool, String) -> Void) {
        AppLog.line("清理脏标记 ntfsfix -d /dev/\(dev)")
        guard helperAvailable else {
            let cmd = "dd if=/dev/zero of=/dev/r\(dev) bs=1 count=0 2>/dev/null || { echo \(writeDeniedMarker); exit 1; }; \(shq(ntfsfixPath)) -d \(shq("/dev/" + dev)) 2>&1"
            runAsRoot(cmd) { ok, out in
                AppLog.line("脏标记清理\(ok ? "完成" : "失败"): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
                completion(ok, out)
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, out) = runCommand("/usr/bin/sudo", ["-n", helperPath, "fix", dev])
            DispatchQueue.main.async {
                AppLog.line("脏标记清理\(code == 0 ? "完成(免密通道)" : "失败"): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
                completion(code == 0, out)
            }
        }
    }

    /// 卸载读写卷（用户主动操作，异步）
    static func unmount(_ v: VolumeInfo, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, out) = runCommand("/usr/sbin/diskutil", ["unmount", v.mountPoint])
            let ok = code == 0
            DispatchQueue.main.async {
                if ok { VolumeScanner.unmarkManaged(v.mountPoint) }
                AppLog.line(ok ? "已卸载 \(v.name)（用户操作）" : "卸载失败 \(v.name): \(out)")
                completion(ok, out)
            }
        }
    }
}

// MARK: - 自动挂载引擎（周期对账）

final class AutoMountEngine {
    static let shared = AutoMountEngine()
    weak var uiDelegate: AppDelegate?

    struct PartState {
        var lastAttempt: Date = .distantPast
        var failCount: Int = 0
        var inFlight = false
    }

    var states: [String: PartState] = [:]
    var seenKeys: Set<String> = []          // 本会话见过的分区
    var presentLastRound: Set<String> = []  // 上轮存在的分区（识别拔盘/重插）
    var userEjected: Set<String> = []       // 用户主动卸载的分区（盘还在时不重挂）
    var probingZombies: Set<String> = []    // 正在探测可达性的挂载点
    var purgingZombies: Set<String> = []    // 正在清理的僵尸挂载点
    var everManaged: Set<String> = []       // 本会话成功挂载过的分区（按 uuid/dev key）
    var dropTimes: [String: [Date]] = [:]   // 各分区挂载丢失的时间点（抖动保护用）

    let minRetryInterval: TimeInterval = 12

    /// 记录「用户主动推出」，本次会话内不再自动挂回
    func markUserEjectedForMountPoint(_ mp: String) {
        userEjected.insert("mp:" + mp)
        if let dev = VolumeScanner.managedDevs[mp], !dev.isEmpty {
            userEjected.insert("dev:" + dev)
        }
    }

    func backoff(for key: String) -> TimeInterval {
        let n = states[key]?.failCount ?? 0
        guard n > 0 else { return 0 }
        return min(60.0 * pow(2, Double(n - 1)), 600)
    }

    /// 免密通道刚装好/修好时调用：清空失败退避，立刻重挂一轮
    func resetAndReconcile() {
        DispatchQueue.main.async {
            for (k, var st) in self.states {
                st.failCount = 0
                st.lastAttempt = .distantPast
                st.inFlight = false
                self.states[k] = st
            }
            self.dropTimes.removeAll()
            self.reconcile()
        }
    }

    /// 主对账入口：每 3 秒 + 挂载/卸载事件触发
    func reconcile() {
        let parts = DiskTopology.ntfsPartitions()
        let mounts = DiskTopology.currentMounts()
        let nowKeys = Set(parts.map { $0.key })

        // ---- 1. 拔盘检测：本轮消失的 key 记为离开；重插视为新盘 ----
        let vanished = presentLastRound.subtracting(nowKeys)
        for k in vanished {
            userEjected.remove(k)
            // 拔盘等于用户明确要断开，清掉所有相关标记，重插后可以重新自动挂载
            userEjected = userEjected.filter { !$0.hasPrefix("mp:") }
            states.removeValue(forKey: k)
            dropTimes.removeValue(forKey: k)
            AppLog.line("分区移除: \(k)")
        }
        let reappeared = nowKeys.subtracting(presentLastRound).intersection(seenKeys)
        let isFirstRound = presentLastRound.isEmpty && !parts.isEmpty

        // ---- 2. 僵尸 fuse-t 挂载清理（盘已不在但挂载残留）----
        cleanupZombies(presentParts: parts, mounts: mounts)

        // ---- 3. 分区当前状态归类 ----
        // 设备 -> (RO 挂载点, RW 挂载点)
        var roByDev: [String: String] = [:]
        var rwByDev: [String: String] = [:]
        for (mp, info) in mounts {
            if info.type == "ntfs" && info.readOnly {
                let dev = DiskTopology.deviceOfMount(mp)
                if !dev.isEmpty { roByDev[dev] = mp }
            } else if !info.readOnly && (info.type == "nfs" || info.type == "fusefs_ntfs" || info.type == "ntfs-3g") {
                if let dev = VolumeScanner.managedDevs[mp], !dev.isEmpty {
                    rwByDev[dev] = mp
                }
            }
        }

        // ---- 4. 逐分区决策（尊重用户设置的总开关）----
        let autoOn = UserDefaults.standard.object(forKey: "autoMount") as? Bool ?? true
        for p in parts {
            seenKeys.insert(p.key)

            // 兜底：旧实例的记忆丢失时，按「挂载点=卷名 + fuse-t 类型」识别已是读写的卷，
            // 避免启动时对已经挂载好的盘做多余的重挂（重挂会触发卸载→死锁风险）
            if rwByDev[p.deviceID] == nil, !p.volumeName.isEmpty {
                let guessMp = "/Volumes/\(p.volumeName)"
                if let m = mounts[guessMp], !m.readOnly && m.type == "nfs" {
                    rwByDev[p.deviceID] = guessMp
                    VolumeScanner.markManaged(guessMp, name: p.volumeName, dev: p.deviceID)
                }
            }

            if let rw = rwByDev[p.deviceID] {
                // 已是读写挂载：正常。若挂载点目录消失（异常），由下轮处理
                var st = states[p.key] ?? PartState()
                st.failCount = 0
                states[p.key] = st
                _ = rw
                continue
            }
            guard autoOn else { continue }

            if let ro = roByDev[p.deviceID] {
                // 系统只读抢占 → 转读写（用户主动推出的除外）
                guard !userEjected.contains(p.key), !userEjected.contains("dev:" + p.deviceID),
                      !userEjected.contains("mp:/Volumes/" + p.safeVolname) else { continue }
                guard canAttempt(p.key) else { continue }
                startAttempt(p.key, reason: "检测到只读抢占") {
                    self.fixToReadWrite(p)
                }
                _ = ro
                continue
            }

            // 未挂载：三种情况都要自动挂
            //   ① 新到达 / 首次见到 / 启动首轮
            //   ② 本会话曾挂载成功过但现在不在了（USB 掉线、驱动崩溃、被系统摘掉）
            //      —— 这种「静默掉挂载」如果不主动恢复，用户看到的就是「插着但盘没反应」
            if userEjected.contains(p.key) || userEjected.contains("dev:" + p.deviceID)
                || userEjected.contains("mp:/Volumes/" + p.safeVolname) {
                everManaged.remove(p.key)   // 用户主动推出的，不参与「掉挂载自动恢复」
                continue
            }
            let isNew = reappeared.contains(p.key) || !seenKeys.contains(p.key) || isFirstRound
            let lostMount = everManaged.contains(p.key)
            guard isNew || lostMount else { continue }
            // 抖动保护：短时间内反复掉挂载时，放慢重挂节奏。
            // 每次重挂都要先强卸设备，对正在恢复的 USB 设备是额外压力，
            // 一味狂重挂反而会把 USB 存储栈拖垮。
            if lostMount && !isNew {
                let now = Date()
                var times = (dropTimes[p.key] ?? []).filter { now.timeIntervalSince($0) < 120 }
                if times.isEmpty { times = [now] } else if times.last.map({ now.timeIntervalSince($0) > 8 }) ?? true { times.append(now) }
                dropTimes[p.key] = times
                if times.count >= 3 {
                    let last = states[p.key]?.lastAttempt ?? .distantPast
                    guard now.timeIntervalSince(last) >= 45 else { continue }
                }
            }
            guard canAttempt(p.key) else { continue }
            let reason: String
            if reappeared.contains(p.key) {
                reason = "重新插入"
            } else if isNew && isFirstRound {
                reason = "启动时已连接"
            } else if isNew {
                reason = "新插入"
            } else {
                reason = "挂载意外丢失，自动恢复"
            }
            startAttempt(p.key, reason: "检测到\(reason)") {
                self.fixToReadWrite(p)
            }
        }

        presentLastRound = nowKeys
    }

    func canAttempt(_ key: String) -> Bool {
        guard let st = states[key] else { return true }
        if st.inFlight { return false }
        return Date().timeIntervalSince(st.lastAttempt) >= (minRetryInterval + backoff(for: key))
    }

    func startAttempt(_ key: String, reason: String, _ work: @escaping () -> Void) {
        var st = states[key] ?? PartState()
        st.inFlight = true
        st.lastAttempt = Date()
        states[key] = st
        AppLog.line("\(reason)，自动处理")
        work()
    }

    /// 挂载结束回调（成功或失败）
    func attemptFinished(_ key: String, ok: Bool, volname: String? = nil) {
        var st = states[key] ?? PartState()
        st.inFlight = false
        if ok {
            let isFirstMount = !everManaged.contains(key)
            st.failCount = 0
            everManaged.insert(key)   // 记住「这盘我挂成功过」，掉了要主动恢复
            // 首次挂载成功（插盘/重插）→ 自动弹出访达窗口，用户不用再去侧边栏翻 fuse-t 条目。
            // 掉线自愈（everManaged 已含 key）时不弹，避免反复打扰。
            if isFirstMount, let volname = volname, !volname.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.openVolumeInFinder(volname)
                }
            }
        } else {
            st.failCount += 1
        }
        states[key] = st
        DispatchQueue.main.async { self.uiDelegate?.refreshIcon() }
    }

    /// 在访达中打开挂载好的卷（确认可达后再开，避免弹出失效窗口）
    private func openVolumeInFinder(_ volname: String) {
        let mp = "/Volumes/" + volname
        var st = stat()
        guard lstat(mp, &st) == 0,
              VolumeScanner.managedDevs[mp] != nil || FileManager.default.isReadableFile(atPath: mp)
        else {
            AppLog.line("自动打开访达跳过：\(mp) 暂不可达")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: mp))
        AppLog.line("已自动在访达中打开 \(mp)")
    }

    /// 只读 → 读写（不安全状态时自动 ntfsfix -d 后重试一次）
    func fixToReadWrite(_ p: NTFSPartition) {
        MountManager.remountReadWrite(p.deviceID, p.volumeName) { [weak self] ok, out in
            guard let self else { return }
            if ok { self.attemptFinished(p.key, ok: true, volname: p.safeVolname); return }
            if MountManager.isUnsafeStateError(out) {
                AppLog.line("不安全状态，自动清理脏标记后重试")
                MountManager.fixUnsafeState(p.deviceID) { [weak self] fixed, _ in
                    guard let self else { return }
                    guard fixed else { self.attemptFinished(p.key, ok: false); return }
                    MountManager.remountReadWrite(p.deviceID, p.volumeName) { [weak self] ok2, _ in
                        self?.attemptFinished(p.key, ok: ok2, volname: p.safeVolname)
                    }
                }
            } else {
                if MountManager.isWriteDeniedError(out) {
                    AppLog.line("写权限被系统拦截，需用户授予完全磁盘访问权限")
                }
                self.attemptFinished(p.key, ok: false)
            }
        }
    }

    /// 清理僵尸 fuse-t 挂载，两种成因都要处理：
    /// ① 设备已从系统消失（拔盘），但挂载记录残留
    /// ② 设备还在，但挂载点访问不到（Device not configured）——USB 掉线重新枚举后
    ///    旧 ntfs-3g 进程未退出的典型状态，用户看到的就是「盘在但打不开」
    func cleanupZombies(presentParts: [NTFSPartition], mounts: [String: (type: String, readOnly: Bool)]) {
        let presentDevs = Set(presentParts.map { $0.deviceID })
        for (mp, dev) in VolumeScanner.managedDevs {
            guard mounts[mp]?.type == "nfs" else {
                // 挂载已经不在了（正常卸载过），清掉记忆
                if mounts[mp] == nil {
                    var st = stat()
                    if lstat(mp, &st) != 0 { VolumeScanner.unmarkManaged(mp) }
                }
                continue
            }
            if !presentDevs.contains(dev) {
                purgeZombieMount(mp, dev: dev, reason: "设备 \(dev) 已不在")
            } else {
                probeZombieMount(mp, dev: dev)
            }
        }
    }

    /// 后台探测挂载点是否真的可达（statvfs 对僵尸 NFS 会返回 ENXIO）
    private func probeZombieMount(_ mp: String, dev: String) {
        guard !probingZombies.contains(mp) else { return }
        probingZombies.insert(mp)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var s = statvfs()
            let ok = (statvfs(mp, &s) == 0 && s.f_blocks > 0)
            DispatchQueue.main.async {
                guard let self else { return }
                self.probingZombies.remove(mp)
                if !ok { self.purgeZombieMount(mp, dev: dev, reason: "挂载不可访问") }
            }
        }
    }

    /// 强制清掉僵尸挂载并忘记该挂载点，让下一轮对账重新挂载
    private func purgeZombieMount(_ mp: String, dev: String, reason: String) {
        guard !purgingZombies.contains(mp) else { return }
        purgingZombies.insert(mp)
        AppLog.line("清理僵尸挂载: \(mp)（\(reason)）")
        VolumeScanner.unmarkManaged(mp)
        MountManager.markInternalUnmount()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var ok = false
            var detail = ""
            if MountManager.helperAvailable {
                let (code, out) = runCommand("/usr/bin/sudo", ["-n", MountManager.helperPath, "unmount", mp])
                ok = (code == 0)
                detail = out
            } else {
                let (code, out) = runCommand("/usr/sbin/diskutil", ["unmount", "force", mp])
                ok = (code == 0)
                detail = out
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.purgingZombies.remove(mp)
                AppLog.line(ok ? "僵尸挂载已清理: \(mp)" : "僵尸清理失败 \(mp): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
                if ok {
                    // 重置退避，让该盘可以立即重新挂载
                    for k in Array(self.states.keys) {
                        self.states[k]?.lastAttempt = .distantPast
                        self.states[k]?.failCount = 0
                    }
                }
                self.reconcile()
            }
        }
    }
}

// MARK: - 应用委托

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let defaults = UserDefaults.standard

    var autoMount: Bool {
        get { defaults.object(forKey: "autoMount") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoMount") }
    }

    var reconcileTimer: Timer?
    var engine: AutoMountEngine { AutoMountEngine.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "NTFS 读写助手")

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        AppLog.line("NTFS 读写助手 v1.4 已启动")
        engine.uiDelegate = self

        // 首启自检：免密通道坏了就请求一次管理员授权自动修复（后台执行，不阻塞启动）
        DispatchQueue.global(qos: .utility).async {
            MountManager.ensureHelperInstalled()
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.engine.reconcile()
                self?.refreshIcon()
            }
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            // 不是我们自己的卸载（Finder 推出 / 系统卸载）→ 记住这是用户意图，
            // 不要过几秒又把盘挂回去，否则用户会觉得「推出根本没用」
            if Date().timeIntervalSince(MountManager.lastInternalUnmount) > 6 {
                let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                let mp = url?.path ?? ""
                if !mp.isEmpty, VolumeScanner.managedDevs[mp] != nil {
                    self?.engine.markUserEjectedForMountPoint(mp)
                    AppLog.line("检测到外部卸载（用户推出）: \(mp)，本次不再自动重挂")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.engine.reconcile()
                self?.refreshIcon()
            }
        }

        // 周期对账
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.engine.reconcile()
        }
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer

        // USB 链路保活，防止空闲挂起导致移动硬盘掉线
        USBKeepAlive.shared.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.engine.reconcile()
            self?.refreshIcon()
        }
    }

    func refreshIcon() {
        let vols = VolumeScanner.scan()
        let hasRW = vols.contains { $0.kind == .ntfsReadWrite }
        let hasNTFS = vols.contains { $0.isNTFS }
        statusItem.button?.image = NSImage(systemSymbolName: hasRW ? "externaldrive.badge.timemachine" :
                                            (hasNTFS ? "externaldrive.fill" : "externaldrive"),
                                           accessibilityDescription: "NTFS 读写助手")
    }

    // MARK: 菜单构建

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let vols = VolumeScanner.scan().filter { $0.isNTFS }

        if vols.isEmpty {
            let item = NSMenuItem(title: "未检测到 NTFS 磁盘", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for v in vols {
                let title: String
                var action: Selector? = nil
                switch v.kind {
                case .ntfsReadOnly:
                    title = "「\(v.name)」 当前只读 — 点击转为读写"
                    action = #selector(mountReadWrite(_:))
                case .ntfsReadWrite:
                    title = "「\(v.name)」 ✓ 读写中 — 点击弹出磁盘"
                    action = #selector(ejectVolume(_:))
                case .other:
                    continue
                }
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.isEnabled = true
                item.representedObject = v
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let auto = NSMenuItem(title: "插入 NTFS 磁盘时自动转为读写", action: #selector(toggleAuto(_:)), keyEquivalent: "")
        auto.state = autoMount ? .on : .off
        auto.target = self
        menu.addItem(auto)

        let launch = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLaunch(_:)), keyEquivalent: "")
        launch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        launch.target = self
        menu.addItem(launch)

        menu.addItem(.separator())
        let home = NSMenuItem(title: "产品主页（教程与下载）", action: #selector(openProductPage(_:)), keyEquivalent: "")
        home.target = self
        menu.addItem(home)
        let about = NSMenuItem(title: "关于 NTFS 读写助手", action: #selector(about(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: 动作

    @objc func mountReadWrite(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? VolumeInfo else { return }
        if !v.deviceID.isEmpty { engine.userEjected.remove("dev:" + v.deviceID) }
        MountManager.remountReadWrite(v.deviceID, v.name) { [weak self] ok, out in
            self?.handleMountResult(v, ok: ok, out: out)
        }
    }

    func handleMountResult(_ v: VolumeInfo, ok: Bool, out: String) {
        if ok { refreshIcon(); return }
        if MountManager.isWriteDeniedError(out) {
            offerFullDiskAccess(v)
        } else if MountManager.isUnsafeStateError(out) {
            offerUnsafeStateFix(v)
        } else {
            notify("挂载失败", "「\(v.name)」未能转为读写模式，点菜单栏图标查看日志。")
        }
        refreshIcon()
    }

    func offerFullDiskAccess(_ v: VolumeInfo) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要授予磁盘访问权限"
        alert.informativeText = """
        macOS 的隐私保护拦截了本工具对磁盘的写入，即使是管理员身份也会被拒绝。

        请授权一次（约 30 秒）：
        1. 点下方按钮打开系统设置
        2. 在「完全磁盘访问权限」列表里找到「NTFS 读写助手」并打开开关
           （列表里没有就点 +，从「应用程序」里添加）
        3. 重新插拔一次磁盘即可

        这是 macOS 的安全机制，授权只影响本工具读写你的外接磁盘。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后再说")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func offerUnsafeStateFix(_ v: VolumeInfo) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "磁盘处于「不安全状态」"
        alert.informativeText = """
        「\(v.name)」上次在 Windows 上是通过「快速启动」或「睡眠」断开的，NTFS 卷上留有使用中标记，直接读写有数据风险。

        可以自动清理这个标记（只清标志位，不删除、不修改任何文件），清理后即可正常读写。

        更彻底的做法：把盘插回 Windows 完全关机（不是睡眠/快速启动）后再拔下来。
        """
        alert.addButton(withTitle: "清理标记并挂载")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            MountManager.fixUnsafeState(v.deviceID) { [weak self] fixed, _ in
                guard let self else { return }
                if fixed {
                    MountManager.remountReadWrite(v.deviceID, v.name) { ok, out in
                        self.handleMountResult(v, ok: ok, out: out)
                    }
                } else {
                    self.notify("修复失败", "标记清理未成功，建议插回 Windows 完全关机后再试，或换一条 USB 线/接口。")
                }
            }
        }
    }

    @objc func ejectVolume(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? VolumeInfo else { return }
        // 记住用户意图：分区还在但不重挂
        if !v.deviceID.isEmpty {
            engine.userEjected.insert("dev:" + v.deviceID)
        } else if let dev = VolumeScanner.managedDevs[v.mountPoint] {
            engine.userEjected.insert("dev:" + dev)
        }
        MountManager.unmount(v) { [weak self] _, _ in self?.refreshIcon() }
    }

    @objc func toggleAuto(_ sender: NSMenuItem) {
        autoMount.toggle()
    }

    @objc func toggleLaunch(_ sender: NSMenuItem) {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            default:
                try SMAppService.mainApp.register()
            }
        } catch {
            AppLog.line("登录自启设置失败: \(error)")
            notify("设置失败", error.localizedDescription)
        }
    }

    @objc func openProductPage(_ sender: NSMenuItem) {
        openURL("https://杨杨.xyz/ntfs/")
    }

    private func openURL(_ s: String) {
        let target = s.replacingOccurrences(of: "杨杨.xyz", with: "xn--yrva.xyz")
        if let url = URL(string: target) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func about(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "NTFS 读写助手 v1.4.0"
        alert.informativeText = """
        让 macOS 直接读写 NTFS 磁盘的菜单栏工具。

        引擎：ntfs-3g + FUSE-T 已内置于本应用，
        无需安装任何额外组件，拖入「应用程序」即可使用。

        使用：插入 NTFS 磁盘后几秒内自动转为读写，无需任何操作。
        日志：~/Library/Logs/NTFSReadWriteHelper.log

        ────────────────────
        作者：杨杨
        产品主页：杨杨.xyz/ntfs
        博客：杨杨.xyz
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开产品主页")
        alert.addButton(withTitle: "打开作者博客")
        alert.addButton(withTitle: "好")
        let choice = alert.runModal()
        if choice == .alertFirstButtonReturn {
            openURL("https://杨杨.xyz/ntfs/")
        } else if choice == .alertSecondButtonReturn {
            openURL("https://杨杨.xyz")
        }
    }

    func notify(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
