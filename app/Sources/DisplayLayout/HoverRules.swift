import Foundation

/// One action after dwelling on one target. Motion or an unsafe state cancels it.
public struct HoverDwell<Target: Equatable> {
    private var target: Target?
    private var anchor = CGPoint.zero
    private var since: TimeInterval = 0
    private var fired = false
    public init() {}
    public mutating func reset() { target = nil; fired = false }
    public mutating func update(target next: Target?,point: CGPoint,now: TimeInterval,delay: TimeInterval) -> Bool {
        guard let next,point.x.isFinite,point.y.isFinite,now.isFinite,delay.isFinite else { reset(); return false }
        if target != next || hypot(point.x-anchor.x,point.y-anchor.y)>4 || now<since {
            target = next; anchor = point; since = now; fired = false; return false
        }
        guard !fired,now-since >= max(0.2,delay) else { return false }
        fired = true; return true
    }
}

public enum HoverConflictRules {
    public static func isAutoRaise(executable: String,bundleID: String? = nil) -> Bool {
        let name = (executable as NSString).lastPathComponent.lowercased()
        let id = bundleID?.lowercased() ?? ""
        return ["autoraise","autoraise-ui","autoraiseui"].contains(name) ||
            id == "nl.postware.autoraise" || id.hasPrefix("nl.postware.autoraise.") ||
            id == "com.sbmpost.autoraise" || id.hasPrefix("com.sbmpost.autoraise.")
    }
}

public struct HoverWindowHit: Equatable {
    public let pid: Int32
    public let id: UInt32
    public let layer: Int
    public let frame: CGRect
    public let alpha: Double
    public init(pid: Int32,id: UInt32,layer: Int,frame: CGRect,alpha: Double = 1) {
        self.pid = pid; self.id = id; self.layer = layer; self.frame = frame; self.alpha = alpha
    }
    /// Input is in front-to-back order. Only the cursor may be looked through.
    public static func target(at point: CGPoint,in windows: [Self],cursorLayer: Int) -> Self? {
        for window in windows where window.alpha>0.01 && window.frame.contains(point) {
            if window.layer == cursorLayer { continue }
            return window.layer == 0 ? window : nil
        }
        return nil
    }
}
