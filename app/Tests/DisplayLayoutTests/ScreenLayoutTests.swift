import XCTest
@testable import DisplayLayout

final class ScreenLayoutTests: XCTestCase {
    let sizes = [ScreenSize(id: "panel1",width: 1920,height: 1080),
                 ScreenSize(id: "panel2",width: 1920,height: 1080),
                 ScreenSize(id: "builtin",width: 1512,height: 982)]
    func testDefaultDeskIsConnectedAndMacRemainsAnchor() {
        let layout = ScreenLayout.defaultLayout(sizes: sizes)
        XCTAssertNil(layout.validationError(sizes: sizes))
        XCTAssertEqual(layout.origins["builtin"],.init(x: 0,y: 0))
    }
    func testRejectsOverlapCornerOnlyAndUnreachableScreen() {
        var layout = ScreenLayout.defaultLayout(sizes: sizes)
        layout.origins["panel1"] = .init(x: -2000,y: 0)
        XCTAssertNotNil(layout.validationError(sizes: sizes))
        layout.origins["panel1"] = .init(x: -3840,y: 1080)
        XCTAssertNotNil(layout.validationError(sizes: sizes))
        layout.origins["panel1"] = .init(x: -8000,y: 0)
        XCTAssertNotNil(layout.validationError(sizes: sizes))
    }
    func testSnapCanMoveLeftScreenAboveAndBelowMac() {
        let layout = ScreenLayout.defaultLayout(sizes: sizes)
        for y in [-1080.0,982.0] {
            let next = layout.moving("panel1",to: .init(x: 0,y: y),sizes: sizes)
            XCTAssertNil(next.validationError(sizes: sizes))
            XCTAssertEqual(next.origins["panel1"],.init(x: 0,y: y))
        }
    }
    func testMovingMacNormalizesEveryScreenWithoutChangingRelations() {
        let original = ScreenLayout.defaultLayout(sizes: sizes)
        let next = original.moving("builtin",to: .init(x: -1800,y: 1080),sizes: sizes)
        XCTAssertNil(next.validationError(sizes: sizes))
        XCTAssertEqual(next.origins["builtin"],.init(x: 0,y: 0))
        XCTAssertNotEqual(original,next)
    }
    func testBadSavedProfileAndNonFiniteCoordinatesAreRejected() {
        XCTAssertNotNil(ScreenLayout(origins: [:]).validationError(sizes: sizes))
        var layout = ScreenLayout.defaultLayout(sizes: sizes)
        layout.origins["panel1"] = .init(x: .infinity,y: 0)
        XCTAssertNotNil(layout.validationError(sizes: sizes))
    }
    func testManyDragsAlwaysLeaveReachableScreens() {
        var layout = ScreenLayout.defaultLayout(sizes: sizes)
        for i in 0..<400 {
            let id = sizes[i % sizes.count].id
            layout = layout.moving(id,to: .init(x: Double((i*937)%12000-6000),y: Double((i*541)%8000-4000)),sizes: sizes)
            XCTAssertNil(layout.validationError(sizes: sizes),"drag \(i)")
            XCTAssertEqual(layout.origins["builtin"],.init(x: 0,y: 0))
        }
    }
    func testStoredLayoutRoundTripAndExternalOnlyDefault() throws {
        let layout = ScreenLayout.defaultLayout(sizes: sizes)
        XCTAssertEqual(try JSONDecoder().decode(ScreenLayout.self,from: JSONEncoder().encode(layout)),layout)
        let external = Array(sizes.prefix(2))
        XCTAssertNil(ScreenLayout.defaultLayout(sizes: external).validationError(sizes: external))
    }
    func testMiddleScreenCanMoveToEitherEndWithoutRenumbering() {
        let original = ScreenLayout.defaultLayout(sizes: sizes)
        for (x,expected) in [(-6000.0,["panel2","panel1","builtin"]),
                             (3000.0,["panel1","builtin","panel2"])] {
            let next = original.moving("panel2",to: .init(x: x,y: 0),sizes: sizes)
            XCTAssertNil(next.validationError(sizes: sizes))
            XCTAssertEqual(sizes.sorted { next.rect(for: $0).minX < next.rect(for: $1).minX }.map(\.id),expected)
            XCTAssertEqual(next.origins["builtin"],.init(x: 0,y: 0))
        }
    }
    func testEveryRowOrderIsReachableAndSurvivesSaving() throws {
        let orders = [["panel1","panel2","builtin"],["panel1","builtin","panel2"],
                      ["panel2","panel1","builtin"],["panel2","builtin","panel1"],
                      ["builtin","panel1","panel2"],["builtin","panel2","panel1"]]
        for expected in orders {
            var layout = ScreenLayout.defaultLayout(sizes: sizes)
            for id in expected.reversed() {
                if sizes.min(by: { layout.rect(for: $0).minX < layout.rect(for: $1).minX })?.id == id { continue }
                layout = layout.moving(id,to: .init(x: -6000,y: layout.origins[id]!.y),sizes: sizes)
            }
            let stored = try JSONDecoder().decode(ScreenLayout.self,from: JSONEncoder().encode(layout))
            XCTAssertEqual(sizes.sorted { stored.rect(for: $0).minX < stored.rect(for: $1).minX }.map(\.id),expected)
            XCTAssertNil(stored.validationError(sizes: sizes))
        }
    }

}
