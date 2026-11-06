import XCTest
@testable import DisplayLayout

final class PanelAssignmentTests: XCTestCase {
    func testNamesFollowThePhysicalOutputInBothSwapStates() {
        let assignment = PanelAssignment(outputNames: ["ViewSonic", "Philips"])
        XCTAssertEqual(assignment.panelNames(swapped: false),["ViewSonic", "Philips"])
        XCTAssertEqual(assignment.panelNames(swapped: true),["Philips", "ViewSonic"])
        XCTAssertEqual(assignment.panelNames(swapped: false),["ViewSonic", "Philips"])
    }
    func testSavingNamesInEitherStatePreservesOutputIdentity() {
        let assignment = PanelAssignment(outputNames: ["A", "B"])
        for swapped in [false,true] {
            let saved = PanelAssignment.fromPanelNames(assignment.panelNames(swapped: swapped),swapped: swapped)
            XCTAssertEqual(saved,assignment)
        }
        let renamed = PanelAssignment.fromPanelNames(["Left monitor", "Middle monitor"],swapped: true)
        XCTAssertEqual(renamed.panelNames(swapped: false),["Middle monitor", "Left monitor"])
    }
    func testInvalidStoredNameCountUsesSafeLabels() {
        XCTAssertEqual(PanelAssignment(outputNames: []).outputNames,["Display 1", "Display 2"])
    }
}
