import AppKit
import ApplicationServices

/// Optional: shrink only desktop windows that fill a monitor. Window contents
/// are never read. Fullscreen, small, tiled and minimized windows are skipped.
@MainActor
final class WindowFitter {
    private var timer: Timer?
    private let queue = DispatchQueue(label: "lenovosplit.window-fit")
    private var working = false
    var isRunning: () -> Bool = { false }
    var allowedBundleIDs: Set<String> = []

    static var trusted: Bool { AXIsProcessTrusted() }
    static func requestPermission() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func setEnabled(_ enabled: Bool) {
        timer?.invalidate(); timer = nil
        guard enabled else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    private func tick() {
        guard isRunning(), !working, Self.trusted else { return }
        let pids = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier != Bundle.main.bundleIdentifier &&
            allowedBundleIDs.contains($0.bundleIdentifier ?? "")
        }.map(\.processIdentifier)
        guard !pids.isEmpty else { return }
        let mainHeight = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        })?.frame.height ?? 982
        let screens = NSScreen.screens
        let dockHeight = screens.map { max(0, $0.visibleFrame.minY - $0.frame.minY) }.max() ?? 0
        guard dockHeight > 10 else { return }
        func topDown(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
        }
        let areas: [(CGRect, CGRect)] = screens.compactMap { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            guard CGDisplayVendorNumber(id) == DisplayModes.virtualVendorID else { return nil }
            let full = screen.frame; var safe = screen.visibleFrame
            let bottom = max(dockHeight, safe.minY - full.minY)
            safe.size.height -= full.minY + bottom - safe.minY
            safe.origin.y = full.minY + bottom
            return (topDown(full), topDown(safe))
        }
        guard !areas.isEmpty else { return }
        working = true
        queue.async {
            defer { DispatchQueue.main.async { self.working = false } }
            func fitWindow(pid: pid_t) {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.15)
            func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
                return value
            }
            guard let raw = attribute(application, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
            let window = unsafeBitCast(raw, to: AXUIElement.self)
            guard (attribute(window, "AXFullScreen") as? Bool) == false,
                  (attribute(window, kAXMinimizedAttribute) as? Bool) == false,
                  (attribute(window, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole else { return }
            var canMove: DarwinBoolean = false, canResize: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &canMove) == .success,
                  AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &canResize) == .success,
                  canMove.boolValue, canResize.boolValue else { return }
            guard let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute),
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return }
            var origin = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &origin),
                  AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return }
            let current = CGRect(origin: origin, size: size)
            for (full, safe) in areas {
                guard abs(current.minX - safe.minX) < 24,
                      abs(current.width - safe.width) < 24,
                      abs(current.minY - safe.minY) < 32,
                      current.height >= full.maxY - safe.minY - 24,
                      current.maxY > safe.maxY + 4 else { continue }
                var position = safe.origin, dimensions = safe.size
                guard let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &dimensions) else { return }
                let a = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
                let b = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
                Log.write("fit maximized window pid=\(pid) result=\(a.rawValue),\(b.rawValue) safe=\(safe)")
                return
            }
            }
            for pid in pids { fitWindow(pid: pid) }
        }
    }
}
