import AppKit
import ApplicationServices
import DisplayLayout
import Darwin

@MainActor
final class WindowRecovery {
    struct Surface { let key: String; let full: CGRect; let safe: CGRect }
    struct App { let pid: pid_t; let born: TimeInterval }
    struct Placement { let app: App; let surface: String; let relative: CGRect }
    private var enabled = false
    private var suspended = false
    private var hidden: CGDirectDisplayID?
    private var panelKeys: [CGDirectDisplayID:String] = [:]
    private var observers: [NSObjectProtocol] = []
    private var memoryTimer: Timer?
    private var rememberAfter = Date.distantPast
    private var saved: [CGWindowID:Placement] = [:]
    private let queue = DispatchQueue(label: "lenovosplit.window-recovery")
    private let worker = RecoveryWorker()
    private var pending = Set<pid_t>()

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value; worker.invalidate()
        if !value {
            observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
            memoryTimer?.invalidate(); memoryTimer = nil; saved = [:]; return
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name,object: nil,queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    for delay in [0.15,0.8] {
                        DispatchQueue.main.asyncAfter(deadline: .now()+delay) { [weak self] in self?.recover(pid: app.processIdentifier,restoreSaved: false) }
                    }
                }
            })
        }
        configure(hidden: hidden,panelKeys: panelKeys,restore: false)
    }
    func pause() { suspended = true; worker.invalidate(); pending = [] }
    func configure(hidden: CGDirectDisplayID?,panelKeys: [CGDirectDisplayID:String],restore: Bool) {
        self.hidden = hidden; self.panelKeys = panelKeys; suspended = false; worker.invalidate(); pending = []
        memoryTimer?.invalidate(); memoryTimer = nil
        guard enabled else { return }
        if hidden != nil {
            rememberAfter = Date().addingTimeInterval(9)
            let timer = Timer(timeInterval: 3,repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.remember(force: false)
                    if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { self?.recover(pid: pid,restoreSaved: false) }
                }
            }
            RunLoop.main.add(timer,forMode: .common); memoryTimer = timer
        }
        if restore || hidden == nil {
            let ticket = worker.ticket
            for delay in [0.3,1.2,3,7] {
                DispatchQueue.main.asyncAfter(deadline: .now()+delay) { [weak self] in
                    guard let self,self.worker.valid(ticket) else { return }
                    self.recover(pid: nil,restoreSaved: restore)
                }
            }
        }
    }
    private var apps: [App] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,app.processIdentifier != getpid(),let born = app.launchDate else { return nil }
            return App(pid: app.processIdentifier,born: born.timeIntervalSince1970)
        }
    }
    private var surfaces: [Surface] {
        let mainTop = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }?.frame.maxY ?? 982
        return NSScreen.screens.compactMap { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            guard id != hidden,CGDisplayIsOnline(id) != 0,
                  CGDisplayVendorNumber(id) != DisplayModes.virtualVendorID || panelKeys[id] != nil else { return nil }
            let visible = screen.visibleFrame
            let safe = CGRect(x: visible.minX,y: mainTop-visible.maxY,width: visible.width,height: visible.height)
            let key = panelKeys[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "builtin" : "external-\(id)")
            return Surface(key: key,full: CGDisplayBounds(id),safe: safe)
        }
    }
    private func windows() -> [(CGWindowID,pid_t,CGRect)] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        return info.compactMap { item in
            guard item[kCGWindowLayer as String] as? Int == 0,
                  let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,pid != getpid(),
                  let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let dict = item[kCGWindowBounds as String] as? [String:Any],let frame = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  frame.width>=80,frame.height>=60 else { return nil }
            return (id,pid,frame)
        }
    }
    func remember(force: Bool) {
        guard enabled,!suspended,hidden != nil else { return }
        let surfaces = surfaces,apps = apps
        for (id,pid,frame) in windows() {
            guard let app = apps.first(where: { $0.pid == pid }),
                  let surface = surfaces.first(where: { $0.full.contains(CGPoint(x: frame.midX,y: frame.midY)) }),
                  WindowPlacement.isReachable(frame,on: [surface.full]),
                  frame.width<=surface.full.width+8,frame.height<=surface.full.height+8 else { continue }
            if Date()<rememberAfter && (!force || (saved[id]?.surface.hasPrefix("output") == true && surface.key == "builtin")) { continue }
            saved[id] = Placement(app: app,surface: surface.key,relative: frame.offsetBy(dx: -surface.full.minX,dy: -surface.full.minY))
        }
        if saved.count>512 { saved = saved.filter { item in apps.contains { $0.pid == item.value.app.pid && $0.born == item.value.app.born } } }
    }
    /// Used by the Dock click handler: reveal an unreachable window before
    /// treating another click as a request to minimize it.
    func revealIfNeeded(pid: pid_t) -> Bool {
        guard enabled,!suspended else { return false }
        let areas = surfaces.map(\.full)
        guard windows().contains(where: { $0.1 == pid && !WindowPlacement.isReachable($0.2,on: areas) }) else { return false }
        recover(pid: pid,restoreSaved: false); return true
    }
    func recover(pid: pid_t?,restoreSaved: Bool) {
        guard enabled,!suspended,AXIsProcessTrusted() else { return }
        let surfaces = surfaces
        guard !surfaces.isEmpty else { return }
        let apps = apps.filter { pid == nil || $0.pid == pid }
        let point = CGEvent(source: nil)?.location
        let fallback = point.flatMap { p in surfaces.first { $0.full.contains(p) } } ?? surfaces.first { $0.key == "builtin" } ?? surfaces[0]
        let saved = saved,worker = worker,ticket = worker.ticket
        let key = pid ?? 0
        guard pending.insert(key).inserted else { return }
        queue.async { [weak self] in
            worker.recover(apps: apps,surfaces: surfaces,fallback: fallback,saved: saved,restoreSaved: restoreSaved,ticket: ticket)
            DispatchQueue.main.async {
                guard worker.valid(ticket) else { return }
                self?.pending.remove(key)
            }
        }
    }
}

private final class RecoveryWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = 0
    private var restored = Set<CGWindowID>()
    private var restoredEpoch = -1
    var ticket: Int { lock.lock(); defer { lock.unlock() }; return epoch }
    func invalidate() { lock.lock(); epoch += 1; lock.unlock() }
    func valid(_ ticket: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return epoch == ticket }
    private typealias WindowIDFn = @convention(c) (AXUIElement,UnsafeMutablePointer<CGWindowID>) -> Int32
    private static let windowID: WindowIDFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),"_AXUIElementGetWindow").map { unsafeBitCast($0,to: WindowIDFn.self) }
    func recover(apps: [WindowRecovery.App],surfaces: [WindowRecovery.Surface],fallback: WindowRecovery.Surface,
                 saved: [CGWindowID:WindowRecovery.Placement],restoreSaved: Bool,ticket: Int) {
        guard valid(ticket) else { return }
        if restoredEpoch != ticket { restoredEpoch = ticket; restored = [] }
        for app in apps where valid(ticket) {
            var info = proc_bsdinfo()
            guard proc_pidinfo(app.pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  abs(Double(info.pbi_start_tvsec)+Double(info.pbi_start_tvusec)/1_000_000-app.born)<0.01 else { continue }
            let application = AXUIElementCreateApplication(app.pid); AXUIElementSetMessagingTimeout(application,0.12)
            for window in attribute(application,kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                guard valid(ticket),attribute(window,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                      attribute(window,kAXMinimizedAttribute) as? Bool == false,
                      attribute(window,"AXFullScreen") as? Bool != true,let frame = frame(window) else { continue }
                var id: CGWindowID = 0
                if Self.windowID?(window,&id) != 0 { id = 0 }
                let remembered = saved[id].flatMap { $0.app.pid == app.pid && $0.app.born == app.born ? $0 : nil }
                let targetSurface = remembered.flatMap { old in surfaces.first { $0.key == old.surface } }
                let returnToExternal = restoreSaved && id != 0 && !restored.contains(id) && remembered?.surface.hasPrefix("output") == true && targetSurface != nil
                guard returnToExternal || !WindowPlacement.isReachable(frame,on: surfaces.map(\.full)) else { continue }
                let target = targetSurface ?? fallback
                let desired = remembered.flatMap { old in targetSurface.map { old.relative.offsetBy(dx: $0.full.minX,dy: $0.full.minY) } } ??
                    CGRect(x: target.safe.minX+40,y: target.safe.minY+40,width: frame.width,height: frame.height)
                let fitted = WindowPlacement.fit(desired,inside: target.safe)
                var position = fitted.origin,size = fitted.size
                guard valid(ticket),let p = AXValueCreate(.cgPoint,&position),let s = AXValueCreate(.cgSize,&size) else { continue }
                AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,s)
                let result = AXUIElementSetAttributeValue(window,kAXPositionAttribute as CFString,p)
                if result == .success {
                    if id != 0 { restored.insert(id) }
                    Log.write("window recovery pid=\(app.pid) display=\(target.key) restored=\(returnToExternal)")
                }
            }
        }
    }
    private func attribute(_ element: AXUIElement,_ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success ? value : nil
    }
    private func frame(_ window: AXUIElement) -> CGRect? {
        guard let p = attribute(window,kAXPositionAttribute),let s = attribute(window,kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(),CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero,size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p,to: AXValue.self),.cgPoint,&point),
              AXValueGetValue(unsafeBitCast(s,to: AXValue.self),.cgSize,&size) else { return nil }
        return CGRect(origin: point,size: size)
    }
}
