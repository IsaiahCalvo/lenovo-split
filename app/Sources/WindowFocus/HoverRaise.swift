import AppKit
import ApplicationServices
import DisplayLayout

/// Independent implementation of delayed hover-to-focus/raise. No AutoRaise
/// source is linked or copied. No mouse/keyboard events are injected or blocked.
@MainActor
public final class HoverRaise {
    public var onDiagnostic: (@Sendable (String) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var isBlocked: () -> Bool = { false }
    public var delay: TimeInterval = 0.5
    private var enabled = false
    private var timer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var dwell = HoverDwell<HoverTarget>()
    private var lastPoint: CGPoint?
    private var armed = false
    private var blockedUntil: TimeInterval = 0
    private var nextPresenceCheck: TimeInterval = 0
    private var presence = AutoRaisePresence.unavailable
    private var status = ""
    private var working = false
    private let queue = DispatchQueue(label: "lenovosplit.hover-raise")
    private let gate = HoverGate()
    private let action = HoverAction()
    public var allowedProcessIDs: Set<pid_t>?
    private let requirePointerMovement: Bool
    public init(requirePointerMovement: Bool = true) { self.requirePointerMovement = requirePointerMovement }

    public func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; cancel()
        if !value {
            timer?.invalidate(); timer = nil
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
            observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
            setStatus("Off"); return
        }
        nextPresenceCheck = 0
        let events: NSEvent.EventTypeMask = [.leftMouseDown,.rightMouseDown,.otherMouseDown,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForInteraction() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.pauseForInteraction() }; return event
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,NSWorkspace.activeSpaceDidChangeNotification,NSWorkspace.willSleepNotification,NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name,object: nil,queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pauseForInteraction() }
            })
        }
        let timer = Timer(timeInterval: 0.1,repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer,forMode: .common); self.timer = timer; tick()
    }
    private func setStatus(_ text: String) { if text != status { status = text; onStatus?(text) } }
    private func cancel() { gate.invalidate(); dwell.reset(); armed = false; lastPoint = CGEvent(source: nil)?.location }
    private func pauseForInteraction() { cancel(); blockedUntil = ProcessInfo.processInfo.systemUptime+0.7 }
    private func tick() {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now>=nextPresenceCheck {
            presence = AutoRaisePresence.appIsRunning() ? .running : AutoRaisePresence.read()
            nextPresenceCheck = now+1
        }
        guard presence == .clear else {
            cancel(); setStatus(presence == .running ? "Paused — standalone AutoRaise is running" : "Paused — cannot check for AutoRaise"); return
        }
        guard AXIsProcessTrusted() else { cancel(); setStatus("Needs Accessibility permission"); return }
        setStatus("On — hold Control to pause")
        guard !isBlocked(),now>=blockedUntil,NSEvent.pressedMouseButtons == 0,
              NSEvent.modifierFlags.intersection([.control,.option,.command,.shift]).isEmpty,
              RunLoop.current.currentMode != .eventTracking,
              let point = CGEvent(source: nil)?.location else { cancel(); return }
        if working {
            if let lastPoint,hypot(point.x-lastPoint.x,point.y-lastPoint.y)>4 { cancel() }
            return
        }
        if let lastPoint,hypot(point.x-lastPoint.x,point.y-lastPoint.y)>2 { armed = true }
        lastPoint = point
        onDiagnostic?("sample target=\(Self.target(at: point)?.id ?? 0) armed=\(armed) front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
        guard armed || !requirePointerMovement,let target = Self.target(at: point),target.pid != getpid(),
              allowedProcessIDs == nil || allowedProcessIDs!.contains(target.pid),
              let app = NSRunningApplication(processIdentifier: target.pid),app.activationPolicy == .regular,!app.isHidden,
              let front = NSWorkspace.shared.frontmostApplication,front.processIdentifier != getpid(),
              !["com.apple.SecurityAgent","com.apple.loginwindow","com.apple.screencaptureui","com.apple.ScreenSaver.Engine"].contains(front.bundleIdentifier ?? "") else { dwell.reset(); return }
        guard dwell.update(target: target,point: point,now: now,delay: delay) else { return }
        // A full process scan immediately before every action closes the normal
        // one-second status-poll gap when a standalone helper starts.
        guard AutoRaisePresence.read() == .clear,!AutoRaisePresence.appIsRunning() else { cancel(); nextPresenceCheck = 0; return }
        let ticket = gate.ticket,gate = gate,action = action,frontPID = front.processIdentifier
        action.diagnostic = onDiagnostic
        working = true
        queue.async { [weak self] in
            action.raise(target: target,point: point,frontPID: frontPID,gate: gate,ticket: ticket)
            DispatchQueue.main.async { self?.working = false }
        }
    }
    fileprivate static func target(at point: CGPoint) -> HoverTarget? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let hits = list.compactMap { item -> HoverWindowHit? in
            guard let bounds = item[kCGWindowBounds as String] as? [String:Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let layer = item[kCGWindowLayer as String] as? Int,
                  let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return HoverWindowHit(pid: pid,id: id,layer: layer,frame: frame,
                                  alpha: (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
        guard let hit = HoverWindowHit.target(at: point,in: hits,cursorLayer: Int(CGWindowLevelForKey(.cursorWindow))) else { return nil }
        return HoverTarget(pid: hit.pid,id: hit.id,frame: hit.frame)
    }
}

private struct HoverTarget: Equatable { let pid: pid_t; let id: CGWindowID; let frame: CGRect }
private final class HoverGate: @unchecked Sendable {
    private let lock = NSLock(); private var epoch = 0
    var ticket: Int { lock.lock(); defer { lock.unlock() }; return epoch }
    func invalidate() { lock.lock(); epoch += 1; lock.unlock() }
    func valid(_ ticket: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return epoch == ticket }
}
private final class HoverAction: @unchecked Sendable {
    var diagnostic: (@Sendable (String) -> Void)?
    private let system = AXUIElementCreateSystemWide()
    init() { AXUIElementSetMessagingTimeout(system,0.15) }
    func attribute(_ element: AXUIElement,_ key: String) -> CFTypeRef? {
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
    func raise(target: HoverTarget,point: CGPoint,frontPID: pid_t,gate: HoverGate,ticket: Int) {
        guard gate.valid(ticket),AXIsProcessTrusted(),AutoRaisePresence.read() == .clear else { return }
        let front = AXUIElementCreateApplication(frontPID); AXUIElementSetMessagingTimeout(front,0.12)
        if let raw = attribute(front,kAXFocusedWindowAttribute),CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let focused = unsafeBitCast(raw,to: AXUIElement.self)
            if attribute(focused,kAXModalAttribute) as? Bool == true || !(attribute(focused,"AXSheets") as? [AXUIElement] ?? []).isEmpty { return }
        }
        var hit: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(system,Float(point.x),Float(point.y),&hit)
        diagnostic?("hit result=\(hitResult.rawValue)")
        guard hitResult == .success,let hit else { return }
        let raw = attribute(hit,kAXWindowAttribute) ?? hit
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
        let window = unsafeBitCast(raw,to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window,0.12)
        var pid: pid_t = 0
        diagnostic?("subrole=\(attribute(window,kAXSubroleAttribute) ?? "nil" as CFString) minimized=\(attribute(window,kAXMinimizedAttribute) ?? "nil" as CFString)")
        guard AXUIElementGetPid(window,&pid) == .success,pid == target.pid,
              attribute(window,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              attribute(window,kAXMinimizedAttribute) as? Bool == false,
              attribute(window,"AXFullScreen") as? Bool != true,
              attribute(window,kAXModalAttribute) as? Bool != true,
              (attribute(window,"AXSheets") as? [AXUIElement] ?? []).isEmpty else { return }
        guard let frame = frame(window),frame.contains(point),
              abs(frame.minX-target.frame.minX)<8,abs(frame.minY-target.frame.minY)<8,
              abs(frame.width-target.frame.width)<8,abs(frame.height-target.frame.height)<8 else { return }
        // Recheck on the main thread after AX queries, since they can be slow.
        let allowed = DispatchQueue.main.sync { () -> Bool in
            guard gate.valid(ticket),let current = CGEvent(source: nil)?.location,
                  hypot(current.x-point.x,current.y-point.y)<=4,
                  NSEvent.pressedMouseButtons == 0,NSEvent.modifierFlags.intersection([.control,.option,.command,.shift]).isEmpty,
                  HoverRaise.target(at: current) == target,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID,
                  !AutoRaisePresence.appIsRunning(),AutoRaisePresence.read() == .clear else { return false }
            return true
        }
        diagnostic?("allowed=\(allowed) valid=\(gate.valid(ticket))")
        guard allowed,gate.valid(ticket),AutoRaisePresence.read() == .clear else { return }
        let mainResult = AXUIElementSetAttributeValue(window,kAXMainAttribute as CFString,kCFBooleanTrue)
        let raiseResult = AXUIElementPerformAction(window,kAXRaiseAction as CFString)
        diagnostic?("raise=\(raiseResult.rawValue) main=\(mainResult.rawValue)")
        DispatchQueue.main.async {
            guard gate.valid(ticket),HoverRaise.target(at: CGEvent(source: nil)?.location ?? point) == target,
                  !AutoRaisePresence.appIsRunning() else { return }
            NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
        }
    }
}
