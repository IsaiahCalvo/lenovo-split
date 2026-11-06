import Foundation
import CoreGraphics

public struct ScreenPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct ScreenSize: Equatable, Sendable {
    public let id: String
    public let width: Double
    public let height: Double
    public init(id: String, width: Double, height: Double) {
        self.id = id; self.width = width; self.height = height
    }
}

/// Coordinates use macOS display space: x goes right, y goes down.
/// Keys are stable panel slots, never transient CG display IDs or serials.
public struct ScreenLayout: Codable, Equatable, Sendable {
    public var origins: [String: ScreenPoint]
    public init(origins: [String: ScreenPoint]) { self.origins = origins }

    public static func defaultLayout(sizes: [ScreenSize]) -> Self {
        let w1 = sizes.first { $0.id == "panel1" }?.width ?? 1920
        let w2 = sizes.first { $0.id == "panel2" }?.width ?? 1920
        if sizes.contains(where: { $0.id == "builtin" }) {
            return Self(origins: ["panel1": .init(x: -w1-w2, y: 0),
                                  "panel2": .init(x: -w2, y: 0), "builtin": .init(x: 0, y: 0)])
        }
        return Self(origins: ["panel1": .init(x: 0, y: 0), "panel2": .init(x: w1, y: 0)])
    }

    public func normalized(anchor: String) -> Self {
        guard let a = origins[anchor] else { return self }
        return Self(origins: origins.mapValues { .init(x: ($0.x-a.x).rounded(), y: ($0.y-a.y).rounded()) })
    }

    public func rect(for size: ScreenSize) -> CGRect {
        let p = origins[size.id] ?? .init(x: 0, y: 0)
        return CGRect(x: p.x, y: p.y, width: size.width, height: size.height)
    }

    public func validationError(sizes: [ScreenSize]) -> String? {
        guard sizes.count >= 2, Set(origins.keys) == Set(sizes.map(\.id)),
              sizes.allSatisfy({ $0.width > 0 && $0.height > 0 }),
              origins.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 20_000 && abs($0.y) < 20_000 })
        else { return "The saved layout does not match the connected screens." }
        let rects = sizes.map { rect(for: $0) }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                if !overlap.isNull && overlap.width > 0 && overlap.height > 0 {
                    return "Screens cannot overlap. Drag them so their edges meet."
                }
            }
        }
        var reached: Set<Int> = [0]
        for _ in sizes.indices {
            for i in rects.indices where reached.contains(i) {
                for j in rects.indices where !reached.contains(j) {
                    let a = rects[i], b = rects[j]
                    let vertical = abs(a.maxX-b.minX) < 1 || abs(b.maxX-a.minX) < 1
                    let horizontal = abs(a.maxY-b.minY) < 1 || abs(b.maxY-a.minY) < 1
                    if (vertical && min(a.maxY,b.maxY)-max(a.minY,b.minY) > 1) ||
                       (horizontal && min(a.maxX,b.maxX)-max(a.minX,b.minX) > 1) { reached.insert(j) }
                }
            }
        }
        return reached.count == sizes.count ? nil : "Each screen needs a shared edge so the pointer can reach it."
    }

    /// Snap to a whole edge; reject placements that overlap or isolate a screen.
    public func moving(_ id: String, to point: ScreenPoint, sizes: [ScreenSize]) -> Self {
        guard let own = sizes.first(where: { $0.id == id }) else { return self }
        var candidates: [ScreenPoint] = []
        for other in sizes where other.id != id {
            let r = rect(for: other)
            let y = min(max(point.y, r.minY-own.height+40), r.maxY-40)
            let x = min(max(point.x, r.minX-own.width+40), r.maxX-40)
            candidates += [.init(x: r.minX-own.width,y: y), .init(x: r.maxX,y: y),
                           .init(x: x,y: r.minY-own.height), .init(x: x,y: r.maxY)]
        }
        let anchor = sizes.contains { $0.id == "builtin" } ? "builtin" : "panel1"
        return candidates.sorted {
            pow($0.x-point.x,2)+pow($0.y-point.y,2) < pow($1.x-point.x,2)+pow($1.y-point.y,2)
        }.compactMap { p -> Self? in
            var proposed = self; proposed.origins[id] = p
            proposed = proposed.normalized(anchor: anchor)
            return proposed.validationError(sizes: sizes) == nil ? proposed : nil
        }.first ?? self
    }
}
