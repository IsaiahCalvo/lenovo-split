import AppKit
import DisplayLayout
import Darwin

public enum AutoRaisePresence: Equatable {
    case clear, running, unavailable

    /// Includes CLI processes and both upstream app identities. No arguments or
    /// configuration files are read, and no other process is signalled.
    public static func read() -> Self {
        let count = proc_listallpids(nil,0)
        guard count>0 else { return .unavailable }
        var pids = [pid_t](repeating: 0,count: Int(count)+256)
        let capacity = pids.count*MemoryLayout<pid_t>.stride
        let used = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress,Int32(capacity)) }
        guard used>0,Int(used)<pids.count else { return .unavailable }
        for pid in pids.prefix(Int(used)) where pid>0 && pid != getpid() {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { continue }
            guard info.pbi_uid == getuid() else { continue }
            let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 },as: UTF8.self) }
            let comm = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 },as: UTF8.self) }
            if HoverConflictRules.isAutoRaise(executable: name) || HoverConflictRules.isAutoRaise(executable: comm) { return .running }
            var path = [CChar](repeating: 0,count: 4096)
            if proc_pidpath(pid,&path,UInt32(path.count))>0,
               HoverConflictRules.isAutoRaise(executable: String(cString: path)) { return .running }
        }
        return .clear
    }

    @MainActor public static func appIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            HoverConflictRules.isAutoRaise(executable: $0.executableURL?.lastPathComponent ?? "",bundleID: $0.bundleIdentifier)
        }
    }
}
