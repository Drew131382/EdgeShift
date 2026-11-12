import XCTest

final class DisplayModeTests: XCTestCase {
    func testTopologyClassification() {
        DisplayModeChecks.classification { XCTAssertTrue($0, $1) }
    }
    func testSelectedDisplayConfiguration() {
        DisplayModeChecks.configuration { XCTAssertTrue($0, $1) }
    }
    func testModeSwitchLifecycle() {
        DisplayModeChecks.model { XCTAssertTrue($0, $1) }
    }
    func testMainDisplayConfiguration() {
        DisplayModeChecks.mainDisplayConfiguration { XCTAssertTrue($0, $1) }
    }
    func testMainDisplayLifecycle() {
        DisplayModeChecks.mainDisplayModel { XCTAssertTrue($0, $1) }
    }
}
