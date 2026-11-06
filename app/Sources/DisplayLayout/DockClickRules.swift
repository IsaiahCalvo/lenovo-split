// Adapted from Light Stats DockClickPolicy.swift, MIT, Copyright (c) 2026 EvilIrving.
import Foundation
import CoreGraphics

public enum NativeDockClickAction: Equatable, Sendable { case minimize, restore, pass }

public enum NativeDockClickRules {
    public static let movementTolerance: CGFloat = 6
    public static let clickValidity: TimeInterval = 0.6
    public static let repeatTolerance: TimeInterval = 0.35

    public static func action(wasFrontmost: Bool,hasVisible: Bool,hasCollapsible: Bool,
                              hasMinimized: Bool,remembered: Bool,isOwn: Bool = false,
                              isRunning: Bool = true,isRegular: Bool = true) -> NativeDockClickAction {
        guard isRunning,isRegular,!isOwn else { return .pass }
        if remembered && hasMinimized { return .restore }
        if remembered && !hasVisible { return .pass }
        return wasFrontmost && hasCollapsible ? .minimize : .pass
    }
}

public struct NativeDockClickGesture {
    private var down: CGPoint?
    private var started: TimeInterval = 0
    public init() {}
    public var isPending: Bool { down != nil }
    public mutating func begin(at point: CGPoint,time: TimeInterval) { down = point; started = time }
    @discardableResult public mutating func moved(to point: CGPoint) -> Bool {
        guard let down,hypot(point.x-down.x,point.y-down.y)>NativeDockClickRules.movementTolerance else { return false }
        cancel(); return true
    }
    public mutating func end(at point: CGPoint,time: TimeInterval) -> Bool {
        defer { cancel() }
        guard let down,time>=started,time-started<=NativeDockClickRules.clickValidity else { return false }
        return hypot(point.x-down.x,point.y-down.y)<=NativeDockClickRules.movementTolerance
    }
    public mutating func cancel() { down = nil; started = 0 }
}
