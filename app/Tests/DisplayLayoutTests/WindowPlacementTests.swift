import XCTest
@testable import DisplayLayout

final class WindowPlacementTests: XCTestCase {
    let mac = CGRect(x: 0,y: 33,width: 1512,height: 868)
    let external = CGRect(x: -1920,y: 30,width: 1920,height: 1050)
    func testParkedTransportIsNeverReachable() {
        XCTAssertFalse(WindowPlacement.isReachable(.init(x: 1600,y: 40,width: 1200,height: 800),on: [mac,external]))
    }
    func testOffscreenTitlebarIsRescuedButSpanningVisibleWindowsStay() {
        XCTAssertFalse(WindowPlacement.isReachable(.init(x: 100,y: -500,width: 900,height: 800),on: [mac]))
        XCTAssertTrue(WindowPlacement.isReachable(.init(x: -500,y: 50,width: 1600,height: 800),on: [mac,external]))
    }
    func testRecoveryFitsMacAfterExternalUnplug() {
        let result = WindowPlacement.fit(.init(x: -1920,y: 0,width: 1920,height: 1080),inside: mac)
        XCTAssertTrue(mac.contains(result))
        XCTAssertTrue(WindowPlacement.isReachable(result,on: [mac]))
    }
    func testRestoredRelativeFrameWorksAfterDeskRearrangement() {
        let relative = CGRect(x: 100,y: 40,width: 900,height: 700)
        let movedScreen = CGRect(x: 1512,y: -1080,width: 1920,height: 1080)
        let result = WindowPlacement.fit(relative.offsetBy(dx: movedScreen.minX,dy: movedScreen.minY),inside: movedScreen)
        XCTAssertTrue(movedScreen.contains(result))
        XCTAssertEqual(result.minX,1612)
    }
}
