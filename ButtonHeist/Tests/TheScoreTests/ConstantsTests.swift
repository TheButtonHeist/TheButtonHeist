import XCTest
import TheScore

final class ConstantsTests: XCTestCase {

    func testServiceType() {
        XCTAssertEqual(buttonHeistServiceType, "_buttonheist._tcp")
    }

    func testWireFrameLimitsExposeCurrentDirectionalCaps() {
        XCTAssertEqual(WireFrameLimits.newlineDelimiterByte, 0x0A)
        XCTAssertEqual(WireFrameLimits.receiveChunkBytes, 65_536)
        XCTAssertEqual(WireFrameLimits.clientToServerMaxBufferedBytes, 10_000_000)
        XCTAssertEqual(WireFrameLimits.serverToClientMaxBufferedBytes, 64 * 1024 * 1024)
        XCTAssertEqual(WireFrameLimits.serverToClientMaxPendingSendBytes, 20_000_000)
        XCTAssertGreaterThan(
            WireFrameLimits.serverToClientMaxBufferedBytes,
            WireFrameLimits.clientToServerMaxBufferedBytes,
            "Server-to-client buffering intentionally preserves the larger legacy client cap."
        )
    }

    func testEnvironmentKeyRawValues() {
        XCTAssertEqual(EnvironmentKey.buttonheistDevice.rawValue, "BUTTONHEIST_DEVICE")
        XCTAssertEqual(EnvironmentKey.buttonheistToken.rawValue, "BUTTONHEIST_TOKEN")
        XCTAssertEqual(EnvironmentKey.buttonheistDriverId.rawValue, "BUTTONHEIST_DRIVER_ID")
        XCTAssertEqual(EnvironmentKey.buttonheistResultsDir.rawValue, "BUTTONHEIST_RESULTS_DIR")
        XCTAssertEqual(EnvironmentKey.buttonheistResultsMode.rawValue, "BUTTONHEIST_RESULTS_MODE")
        XCTAssertEqual(EnvironmentKey.buttonheistSessionTimeout.rawValue, "BUTTONHEIST_SESSION_TIMEOUT")
        XCTAssertEqual(EnvironmentKey.buttonheistConnectionTimeout.rawValue, "BUTTONHEIST_CONNECTION_TIMEOUT")
        XCTAssertEqual(EnvironmentKey.insideJobToken.rawValue, "INSIDEJOB_TOKEN")
        XCTAssertEqual(EnvironmentKey.insideJobPort.rawValue, "INSIDEJOB_PORT")
        XCTAssertEqual(EnvironmentKey.insideJobDisable.rawValue, "INSIDEJOB_DISABLE")
        XCTAssertEqual(EnvironmentKey.insideJobId.rawValue, "INSIDEJOB_ID")
        XCTAssertEqual(EnvironmentKey.insideJobScope.rawValue, "INSIDEJOB_SCOPE")
        XCTAssertEqual(EnvironmentKey.insideJobSessionTimeout.rawValue, "INSIDEJOB_SESSION_TIMEOUT")
    }
}
