import XCTest
import TheScore

final class ServerInfoTests: XCTestCase {

    private func makeServerInfo(
        appName: String = "TestApp",
        bundleIdentifier: BundleIdentifier = "com.test.app",
        deviceName: String = "iPhone 15",
        systemVersion: String = "17.2",
        screenWidth: Double = 393,
        screenHeight: Double = 852,
        instanceId: ServerLaunchID = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
        instanceIdentifier: InsideJobInstanceID = "test-instance",
        listeningPort: UInt16 = 49152,
        simulatorUDID: SimulatorUDID? = nil,
        vendorIdentifier: VendorIdentifier? = nil,
        tlsActive: Bool = true
    ) -> ServerInfo {
        ServerInfo(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            deviceName: deviceName,
            systemVersion: systemVersion,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            instanceId: instanceId,
            instanceIdentifier: instanceIdentifier,
            listeningPort: listeningPort,
            simulatorUDID: simulatorUDID,
            vendorIdentifier: vendorIdentifier,
            tlsActive: tlsActive
        )
    }

    func testEncodingRoundTrip() throws {
        let info = makeServerInfo()

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ServerInfo.self, from: data)

        XCTAssertEqual(info.appName, decoded.appName)
        XCTAssertEqual(info.bundleIdentifier, decoded.bundleIdentifier)
        XCTAssertEqual(info.deviceName, decoded.deviceName)
        XCTAssertEqual(info.systemVersion, decoded.systemVersion)
        XCTAssertEqual(info.screenWidth, decoded.screenWidth)
        XCTAssertEqual(info.screenHeight, decoded.screenHeight)
    }

    func testEncodingRoundTripWithCurrentIdentity() throws {
        let info = makeServerInfo(deviceName: "iPhone 16 Pro", systemVersion: "18.0")

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ServerInfo.self, from: data)

        XCTAssertEqual(decoded.instanceId, "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
        XCTAssertEqual(decoded.instanceIdentifier, "test-instance")
        XCTAssertEqual(decoded.listeningPort, 49152)
        XCTAssertEqual(decoded.tlsActive, true)
    }

    func testDecodingWithoutCurrentIdentityFails() throws {
        let json = """
        {
            "appName": "MissingIdentity",
            "bundleIdentifier": "com.missing",
            "deviceName": "iPhone 15",
            "systemVersion": "17.0",
            "screenWidth": 390,
            "screenHeight": 844
        }
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ServerInfo.self, from: data))
    }

    func testEncodingRoundTripWithDeviceIdentifiers() throws {
        let info = makeServerInfo(
            deviceName: "iPhone 16 Pro",
            systemVersion: "18.0",
            simulatorUDID: "DEADBEEF-1234-5678-9ABC-DEF012345678",
            vendorIdentifier: "CAFE0000-BABE-FACE-DEAD-BEEF12345678"
        )

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ServerInfo.self, from: data)

        XCTAssertEqual(decoded.simulatorUDID, "DEADBEEF-1234-5678-9ABC-DEF012345678")
        XCTAssertEqual(decoded.vendorIdentifier, "CAFE0000-BABE-FACE-DEAD-BEEF12345678")
    }

    func testDecodingWithoutDeviceIdentifiers() throws {
        let json = """
        {
            "appName": "CurrentApp",
            "bundleIdentifier": "com.current",
            "deviceName": "iPhone 15",
            "systemVersion": "17.0",
            "screenWidth": 390,
            "screenHeight": 844,
            "instanceId": "12345",
            "instanceIdentifier": "current",
            "listeningPort": 49152,
            "tlsActive": true
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ServerInfo.self, from: data)

        XCTAssertEqual(decoded.instanceId, "12345")
        XCTAssertEqual(decoded.instanceIdentifier, "current")
        XCTAssertEqual(decoded.listeningPort, 49152)
        XCTAssertNil(decoded.simulatorUDID)
        XCTAssertNil(decoded.vendorIdentifier)
    }

    func testAdmissionRejectsInvalidNumericValues() {
        let invalidValues: [(width: Double, height: Double, port: UInt16)] = [
            (.nan, 852, 49152),
            (.infinity, 852, 49152),
            (0, 852, 49152),
            (-1, 852, 49152),
            (393, .nan, 49152),
            (393, 0, 49152),
            (393, 852, 0),
        ]

        for value in invalidValues {
            XCTAssertNil(admitServerInfo(width: value.width, height: value.height, port: value.port))
        }
    }

    func testDecodingRejectsInvalidNumericValues() {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let invalidValues = [
            (width: "0", height: "852", port: "49152"),
            (width: "-1", height: "852", port: "49152"),
            (width: #""NaN""#, height: "852", port: "49152"),
            (width: "393", height: #""Infinity""#, port: "49152"),
            (width: "393", height: "852", port: "0"),
        ]

        for value in invalidValues {
            XCTAssertThrowsError(try decoder.decode(
                ServerInfo.self,
                from: Data(serverInfoJSON(width: value.width, height: value.height, port: value.port).utf8)
            ))
        }
    }

    private func admitServerInfo(width: Double, height: Double, port: UInt16) -> ServerInfo? {
        ServerInfo(
            admitting: "TestApp",
            bundleIdentifier: "com.test.app",
            deviceName: "iPhone",
            systemVersion: "18.0",
            screenWidth: width,
            screenHeight: height,
            instanceId: "test-session",
            instanceIdentifier: "test",
            listeningPort: port,
            tlsActive: true
        )
    }

    private func serverInfoJSON(width: String, height: String, port: String) -> String {
        """
        {
          "appName":"TestApp",
          "bundleIdentifier":"com.test.app",
          "deviceName":"iPhone",
          "systemVersion":"18.0",
          "screenWidth":\(width),
          "screenHeight":\(height),
          "instanceId":"test-session",
          "instanceIdentifier":"test",
          "listeningPort":\(port),
          "tlsActive":true
        }
        """
    }
}
