import XCTest
@testable import DisplayLayout

final class DockClickRulesTests: XCTestCase {
    func testBackgroundActivationAndNewlyLaunchedAppsPassToAppleDock() {
        XCTAssertEqual(NativeDockClickRules.action(wasFrontmost: false,hasVisible: true,hasCollapsible: true,hasMinimized: false,remembered: false),.pass)
        XCTAssertEqual(NativeDockClickRules.action(wasFrontmost: true,hasVisible: false,hasCollapsible: false,hasMinimized: false,remembered: false,isRunning: false),.pass)
    }
    func testActiveAppMinimizesAndRememberedSetRestoresFirst() {
        XCTAssertEqual(NativeDockClickRules.action(wasFrontmost: true,hasVisible: true,hasCollapsible: true,hasMinimized: false,remembered: false),.minimize)
        XCTAssertEqual(NativeDockClickRules.action(wasFrontmost: true,hasVisible: true,hasCollapsible: true,hasMinimized: true,remembered: true),.restore)
    }
    func testFullscreenOwnAppAndWindowlessAppsAreSkipped() {
        XCTAssertEqual(NativeDockClickRules.action(wasFrontmost: true,hasVisible: true,hasCollapsible: false,hasMinimized: false,remembered: false),.pass)
        XCTAssertEqual(NativeDockClickRules.action(wasFrontmost: true,hasVisible: false,hasCollapsible: false,hasMinimized: false,remembered: true),.pass)
        XCTAssertEqual(NativeDockClickRules.action(wasFrontmost: true,hasVisible: true,hasCollapsible: true,hasMinimized: false,remembered: false,isOwn: true),.pass)
    }
    func testNormalClickCompletesButIconDragDoesNot() {
        var gesture = NativeDockClickGesture()
        gesture.begin(at: .init(x: 10,y: 10),time: 0)
        XCTAssertTrue(gesture.end(at: .init(x: 12,y: 11),time: 0.15))
        gesture.begin(at: .zero,time: 1)
        XCTAssertTrue(gesture.moved(to: .init(x: 30,y: 0)))
        XCTAssertFalse(gesture.end(at: .zero,time: 1.2))
    }
    func testPressHoldAndCancelledClickDoNotMinimize() {
        var gesture = NativeDockClickGesture()
        gesture.begin(at: .zero,time: 0)
        XCTAssertFalse(gesture.end(at: .zero,time: 0.7))
        gesture.begin(at: .zero,time: 1); gesture.cancel()
        XCTAssertFalse(gesture.end(at: .zero,time: 1.1))
    }
}
