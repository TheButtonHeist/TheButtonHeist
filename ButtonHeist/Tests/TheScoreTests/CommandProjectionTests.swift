import XCTest
import ThePlans
@testable import TheScore

final class CommandProjectionTests: XCTestCase {
    func testScrollTargetDefaultsToVisibleContainer() {
        XCTAssertEqual(ScrollTarget().selection, .visibleContainer)
    }
}
