// Dock icon resolution, gesture policy and minimize retry flow adapted from
// Light Stats (MIT), Copyright (c) 2026 EvilIrving. See LICENSE and NOTICE.md.
import AppKit
import ApplicationServices
import DisplayLayout
import Darwin

@MainActor
final class NativeDockClick {
    private let queue = DispatchQueue(label: "lenovosplit.native-dock-click")
    private let windows = DockClickWindows()
    private var monitor: Any?
    var isRunning: Bool { monitor != nil }
    var recoverWindows: ((pid_t) -> Bool)?
    private var gesture = NativeDockClickGesture()
    private var generation = 0
    private var resolved: DockClickWindows.Snapshot?
    private var release: (CGPoint,TimeInterval)?
    private var lastAction: (pid_t,TimeInterval)?

    func setEnabled(_ enabled: Bool) {
        if enabled,monitor != nil { return }
        if !enabled {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            reset(); windows.invalidate()
            let windows = windows; queue.async { windows.forgetAll() }
            return
        }
        guard AXIsProcessTrusted() else { return }
        windows.enable()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,.leftMouseDragged,.leftMouseUp,.rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        Log.write("native Dock click monitor enabled=\(monitor != nil)")
    }

    private func reset() {
        generation += 1; gesture.cancel(); resolved = nil; release = nil
    }
    private func handle(_ event: NSEvent) {
        guard monitor != nil else { return }
        if (event.type == .leftMouseDragged || event.type == .leftMouseUp) && !gesture.isPending { return }
        let mainHeight = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }?.frame.maxY ?? 982
        let point = event.cgEvent?.location ?? CGPoint(x: event.locationInWindow.x,y: mainHeight-event.locationInWindow.y)
        let cocoa = CGPoint(x: point.x,y: mainHeight-point.y)
        let now = event.timestamp
        switch event.type {
        case .rightMouseDown: reset()
        case .leftMouseDragged:
            if gesture.moved(to: point) { reset() }
        case .leftMouseDown:
            reset()
            guard event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty,
                  nearDock(cocoa),let front = NSWorkspace.shared.frontmostApplication,
                  let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
            gesture.begin(at: point,time: now)
            let token = generation
            // Capture frontmost PID before Apple processes the mouse-up.
            let frontPID = front.processIdentifier
            let frontHadVisibleWindow = Self.hasVisibleWindow(frontPID)
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app -> DockClickWindows.App? in
                guard let url = app.bundleURL,let launch = app.launchDate else { return nil }
                return .init(pid: app.processIdentifier,url: url.standardizedFileURL,launch: launch.timeIntervalSince1970)
            }
            let dockPID = dock.processIdentifier,windows = windows
            let ticket = windows.ticket
            queue.async { [weak self] in
                let snapshot = windows.snapshot(point: point,dockPID: dockPID,frontPID: frontPID,frontHadVisibleWindow: frontHadVisibleWindow,apps: apps,ticket: ticket)
                DispatchQueue.main.async {
                    guard let self,self.generation == token,self.gesture.isPending else { return }
                    self.resolved = snapshot; self.evaluate()
                }
            }
        case .leftMouseUp:
            guard event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty else { reset(); return }
            release = (point,now); evaluate()
        default: break
        }
    }

    private static func hasVisibleWindow(_ pid: pid_t) -> Bool {
        // Read before mouse-up: AX may answer after the Dock has restored a
        // minimized window. Without this snapshot that first restore can be
        // mistaken for a click on an already-visible app and minimized again.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        return list.contains { item in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  item[kCGWindowLayer as String] as? Int == 0,
                  let raw = item[kCGWindowBounds as String] as? [String:Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
            return rect.width > 80 && rect.height > 80
        }
    }

    private func nearDock(_ point: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        let orientation = UserDefaults.standard.persistentDomain(forName: "com.apple.dock")?["orientation"] as? String ?? "bottom"
        // 192pt also covers auto-hide and magnification; the Dock AX hit test
        // below, rather than this coarse band, decides whether it is an icon.
        let frame = screen.frame,visible = screen.visibleFrame
        switch orientation {
        case "left": return point.x < frame.minX+max(192,visible.minX-frame.minX)
        case "right": return point.x > frame.maxX-max(192,frame.maxX-visible.maxX)
        default: return point.y < frame.minY+max(192,visible.minY-frame.minY)
        }
    }

    private func evaluate() {
        guard gesture.isPending,let release,let snapshot = resolved else { return }
        guard gesture.end(at: release.0,time: release.1) else { reset(); return }
        let now = ProcessInfo.processInfo.systemUptime
        reset()
        if recoverWindows?(snapshot.app.pid) == true { return }
        if let lastAction,lastAction.0 == snapshot.app.pid,now-lastAction.1 < NativeDockClickRules.repeatTolerance { return }
        let action = NativeDockClickRules.action(wasFrontmost: snapshot.wasFrontmost,hasVisible: snapshot.hasVisible,
            hasCollapsible: !snapshot.collapsible.isEmpty,hasMinimized: snapshot.hasMinimized,remembered: snapshot.remembered,
            isOwn: snapshot.app.pid == getpid())
        guard action != .pass else { return }
        let windows = windows,ticket = windows.ticket
        queue.async { [weak self] in
            let changed = windows.perform(action,snapshot: snapshot,ticket: ticket)
            DispatchQueue.main.async {
                guard let self,changed > 0,self.monitor != nil else { return }
                self.lastAction = (snapshot.app.pid,ProcessInfo.processInfo.systemUptime)
                Log.write("native Dock \(action) pid=\(snapshot.app.pid) windows=\(changed)")
            }
        }
    }
}

/// Accessibility work runs on one queue. The lock only cancels a queued
/// action when the user turns the feature off; no window titles are logged.
private final class DockClickWindows: @unchecked Sendable {
    struct App { let pid: pid_t; let url: URL; let launch: TimeInterval }
    struct Snapshot {
        let app: App
        let wasFrontmost: Bool
        let hasVisible: Bool
        let hasMinimized: Bool
        let remembered: Bool
        let collapsible: [AXUIElement]
    }
    private struct Record { let launch: TimeInterval; let titles: [String]; let elements: [AXUIElement] }
    private let lock = NSLock()
    private var enabled = false
    private var epoch = 0
    private var records: [pid_t:Record] = [:] // accessed only by the serial AX queue
    var ticket: Int { lock.lock(); defer { lock.unlock() }; return epoch }
    func enable() { lock.lock(); enabled = true; epoch += 1; lock.unlock() }
    func invalidate() { lock.lock(); enabled = false; epoch += 1; lock.unlock() }
    func forgetAll() { records.removeAll() }
    private func valid(_ ticket: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return enabled && epoch == ticket }

    func snapshot(point: CGPoint,dockPID: pid_t,frontPID: pid_t,frontHadVisibleWindow: Bool,apps: [App],ticket: Int) -> Snapshot? {
        guard valid(ticket) else { return nil }
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system,0.12)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system,Float(point.x),Float(point.y),&element) == .success else { return nil }
        var item: AXUIElement?
        for _ in 0..<6 {
            guard let current = element else { break }
            var owner: pid_t = 0
            guard AXUIElementGetPid(current,&owner) == .success,owner == dockPID else { return nil }
            if attribute(current,kAXSubroleAttribute) as? String == "AXApplicationDockItem" { item = current; break }
            element = elementAttribute(current,kAXParentAttribute)
        }
        guard let item,let raw = attribute(item,"AXURL") else { return nil }
        let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
        guard let url,url.isFileURL,url.pathExtension.lowercased() == "app",
              let app = apps.first(where: { $0.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path }) else { return nil }
        let all = standardWindows(app.pid)
        let minimized = all.contains { attribute($0,kAXMinimizedAttribute) as? Bool == true }
        let visible = all.contains { attribute($0,kAXMinimizedAttribute) as? Bool == false }
        let collapsible = (app.pid != frontPID || frontHadVisibleWindow) ? all.filter {
            attribute($0,kAXMinimizedAttribute) as? Bool == false && attribute($0,"AXFullScreen") as? Bool == false
        } : []
        if records[app.pid]?.launch != app.launch { records[app.pid] = nil }
        return Snapshot(app: app,wasFrontmost: app.pid == frontPID,hasVisible: visible,hasMinimized: minimized,
                        remembered: records[app.pid] != nil,collapsible: collapsible)
    }

    func perform(_ action: NativeDockClickAction,snapshot: Snapshot,ticket: Int) -> Int {
        guard valid(ticket),sameProcess(snapshot.app) else { return 0 }
        if action == .minimize {
            let targets = snapshot.collapsible
            var changed = Set<Int>()
            for (index,window) in targets.enumerated() where valid(ticket) {
                if setMinimized(window,true) { changed.insert(index) }
            }
            usleep(90_000)
            for (index,window) in targets.enumerated() where valid(ticket) && attribute(window,kAXMinimizedAttribute) as? Bool != true {
                if setMinimized(window,true) || pressMinimize(window) { changed.insert(index) }
            }
            let accepted = changed.sorted().map { targets[$0] }
            if !accepted.isEmpty,valid(ticket) {
                if records.count >= 16 { records.removeValue(forKey: records.keys.first!) }
                records[snapshot.app.pid] = Record(launch: snapshot.app.launch,
                    titles: accepted.compactMap { attribute($0,kAXTitleAttribute) as? String },elements: accepted)
            }
            return accepted.count
        }
        guard action == .restore,let record = records.removeValue(forKey: snapshot.app.pid),record.launch == snapshot.app.launch else { return 0 }
        // Re-query after animation; some apps replace their AX window objects.
        let current = standardWindows(snapshot.app.pid)
        let candidates = current.filter { window in
            if record.elements.contains(where: { CFEqual($0,window) }) { return true }
            guard let title = attribute(window,kAXTitleAttribute) as? String,
                  record.titles.filter({ $0 == title }).count == 1 else { return false }
            return current.filter { attribute($0,kAXTitleAttribute) as? String == title }.count == 1
        }
        var changed = 0
        for window in candidates where valid(ticket) && attribute(window,kAXMinimizedAttribute) as? Bool == true {
            if setMinimized(window,false) { changed += 1 }
        }
        return changed
    }
    private func sameProcess(_ app: App) -> Bool {
        // NSWorkspace snapshots are captured on the main thread. libproc
        // verifies that the PID has not been reused before an AX write.
        var info = proc_bsdinfo()
        let result = proc_pidinfo(app.pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size))
        guard result == MemoryLayout<proc_bsdinfo>.size else { return false }
        let born = Double(info.pbi_start_tvsec)+Double(info.pbi_start_tvusec)/1_000_000
        return abs(born-app.launch) < 0.01
    }
    private func standardWindows(_ pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app,0.12)
        return (attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            attribute($0,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
        }
    }
    private func attribute(_ element: AXUIElement,_ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success ? value : nil
    }
    private func setMinimized(_ window: AXUIElement,_ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(window,kAXMinimizedAttribute as CFString,value ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }
    private func pressMinimize(_ window: AXUIElement) -> Bool {
        let children = attribute(window,kAXChildrenAttribute) as? [AXUIElement] ?? []
        let button = elementAttribute(window,"AXMinimizeButton") ?? children.first { attribute($0,kAXSubroleAttribute) as? String == "AXMinimizeButton" }
        guard let button else { return false }
        return AXUIElementPerformAction(button,kAXPressAction as CFString) == .success
    }
    private func elementAttribute(_ element: AXUIElement,_ key: String) -> AXUIElement? {
        guard let value = attribute(element,key),CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value,to: AXUIElement.self)
    }
}
