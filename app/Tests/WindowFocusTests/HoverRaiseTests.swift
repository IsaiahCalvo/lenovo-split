import XCTest
import DisplayLayout
@testable import WindowFocus

final class HoverRaiseTests: XCTestCase {
    func testDwellRaisesOnceAndMotionRestartsDelay() {
        var dwell = HoverDwell<Int>()
        XCTAssertFalse(dwell.update(target: 1,point: .zero,now: 0,delay: 0.5))
        XCTAssertFalse(dwell.update(target: 1,point: .zero,now: 0.49,delay: 0.5))
        XCTAssertTrue(dwell.update(target: 1,point: .zero,now: 0.5,delay: 0.5))
        XCTAssertFalse(dwell.update(target: 1,point: .zero,now: 2,delay: 0.5))
        XCTAssertFalse(dwell.update(target: 1,point: .init(x: 10,y: 0),now: 3,delay: 0.5))
        XCTAssertTrue(dwell.update(target: 1,point: .init(x: 10,y: 0),now: 3.5,delay: 0.5))
    }
    func testDifferentWindowAndCancellationCannotUseOldTimer() {
        var dwell = HoverDwell<Int>()
        _ = dwell.update(target: 1,point: .zero,now: 0,delay: 0.5)
        XCTAssertFalse(dwell.update(target: 2,point: .zero,now: 1,delay: 0.5))
        dwell.reset() // Conflict, click, modifier or a display preview.
        XCTAssertFalse(dwell.update(target: 2,point: .zero,now: 3,delay: 0.5))
        XCTAssertFalse(dwell.update(target: nil,point: .zero,now: 4,delay: 0.5))
        XCTAssertFalse(dwell.update(target: 2,point: .zero,now: 5,delay: 0.5))
    }
    func testRecognizesUpstreamAppsCLIAndHelpersWithoutMatchingOtherTools() {
        for name in ["AutoRaise","/opt/homebrew/bin/autoraise","AutoRaise-UI","AutoRaiseUI"] {
            XCTAssertTrue(HoverConflictRules.isAutoRaise(executable: name))
        }
        XCTAssertTrue(HoverConflictRules.isAutoRaise(executable: "renamed",bundleID: "nl.postware.autoraise"))
        XCTAssertTrue(HoverConflictRules.isAutoRaise(executable: "renamed",bundleID: "com.sbmpost.AutoRaise.Launcher"))
        XCTAssertFalse(HoverConflictRules.isAutoRaise(executable: "LenovoSplit"))
        XCTAssertFalse(HoverConflictRules.isAutoRaise(executable: "AutoRaise-notes.txt"))
    }
    func testRealCLIProcessIsDetectedWithoutStartingAutoRaiseItself() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lenovosplit-process-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("AutoRaise")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"),to: executable)
        let before = AutoRaisePresence.read()
        let process = Process(); process.executableURL = executable; process.arguments = ["10"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        XCTAssertEqual(AutoRaisePresence.read(),.running)
        process.terminate(); process.waitUntilExit()
        if before == .clear { XCTAssertEqual(AutoRaisePresence.read(),.clear) }
    }
    func testCursorLayerDoesNotHideTheWindowButMenusAndTransportDo() {
        let frame = CGRect(x: 0,y: 0,width: 100,height: 100)
        let window = HoverWindowHit(pid: 1,id: 2,layer: 0,frame: frame)
        let cursor = HoverWindowHit(pid: 9,id: 10,layer: 1000,frame: frame)
        XCTAssertEqual(HoverWindowHit.target(at: .init(x: 20,y: 20),in: [cursor,window],cursorLayer: 1000),window)
        for layer in [20,500,999] {
            let overlay = HoverWindowHit(pid: 3,id: 4,layer: layer,frame: frame)
            XCTAssertNil(HoverWindowHit.target(at: .init(x: 20,y: 20),in: [cursor,overlay,window],cursorLayer: 1000))
        }
    }

}
