import XCTest
import Network
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import TheScore

final class DiscoveredDeviceTests: XCTestCase {

    private let endpoint = DiscoveredDeviceEndpoint.service(
        name: "test",
        type: "_test._tcp",
        domain: "local."
    )

    private func makeResolutionQuery(
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> DiscoveryResolutionQuery {
        guard let query = DiscoveryResolutionQuery(value) else {
            XCTFail("Expected valid discovery resolution query for \(value)", file: file, line: line)
            return DiscoveryResolutionQuery("fallback")!
        }
        return query
    }

    private func XCTAssertMatches(
        _ device: DiscoveredDevice,
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            device.matches(resolutionQuery: makeResolutionQuery(value, file: file, line: line)),
            file: file,
            line: line
        )
    }

    private func XCTAssertDoesNotMatch(
        _ device: DiscoveredDevice,
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            device.matches(resolutionQuery: makeResolutionQuery(value, file: file, line: line)),
            file: file,
            line: line
        )
    }

    func testEqualityById() {
        // Devices with same ID but different names should be equal (ID is the identity)
        let device1 = DiscoveredDevice(id: "same-id", name: "Device A", endpoint: endpoint)
        let device2 = DiscoveredDevice(id: "same-id", name: "Device B", endpoint: endpoint)

        XCTAssertEqual(device1, device2)
    }

    // MARK: - Typed Discovery Identifiers

    func testDiscoveryWrappersEncodeAsSingleJSONStringValues() throws {
        let encoder = JSONEncoder()
        let deviceID: DiscoveryDeviceID = "DemoApp#abc123"
        XCTAssertEqual(String(data: try encoder.encode(deviceID), encoding: .utf8), #""DemoApp#abc123""#)
    }

    func testDiscoveryDeviceIDFactoriesPreserveRawValues() throws {
        let hostPort = DiscoveryDeviceID.hostPort(host: "127.0.0.1", port: 5555)
        let usb = DiscoveryDeviceID.usbIdentifier("00008120")

        XCTAssertEqual(hostPort, "127.0.0.1:5555")
        XCTAssertEqual(usb, "usb-00008120")
        XCTAssertEqual(String(data: try JSONEncoder().encode(usb), encoding: .utf8), #""usb-00008120""#)
    }

    func testDeviceResolutionTargetTrimsQueryAndTreatsBlankAsAutomatic() {
        let queryTarget = DeviceResolutionTarget(filter: " DemoApp ")
        guard case .query(let query) = queryTarget.kind else {
            return XCTFail("Expected query target, got \(queryTarget)")
        }
        XCTAssertEqual(query.rawValue, "DemoApp")
        XCTAssertEqual(query.normalizedValue, "demoapp")

        XCTAssertEqual(DeviceResolutionTarget(filter: nil).kind, .automatic)
        XCTAssertEqual(DeviceResolutionTarget(filter: "   ").kind, .automatic)
    }

    // MARK: - Short ID Parsing

    func testShortIdParsing() {
        let device = DiscoveredDevice(id: "test", name: "TestApp#a1b2c3d4", endpoint: endpoint)

        XCTAssertEqual(device.shortId, "a1b2c3d4")
    }

    func testShortIdNilWithoutHash() {
        let device = DiscoveredDevice(id: "test", name: "TestApp", endpoint: endpoint)

        XCTAssertNil(device.shortId)
    }

    func testShortIdNilWithEmptyHash() {
        let device = DiscoveredDevice(id: "test", name: "TestApp#", endpoint: endpoint)

        XCTAssertNil(device.shortId)
    }

    // MARK: - Service Name Identity

    func testAppNameUsesServiceNameWithoutInstanceId() {
        let device = DiscoveredDevice(id: "test", name: "TestApp#a1b2c3d4", endpoint: endpoint)

        XCTAssertEqual(device.appName, "TestApp")
        XCTAssertEqual(device.deviceName, "")
        XCTAssertEqual(device.shortId, "a1b2c3d4")
    }

    func testAppNameWithoutShortIdUsesServiceName() {
        let device = DiscoveredDevice(id: "test", name: "TestApp", endpoint: endpoint)

        XCTAssertEqual(device.appName, "TestApp")
        XCTAssertEqual(device.deviceName, "")
        XCTAssertNil(device.shortId)
    }

    func testAppNameStripsInstanceIdSuffix() {
        let device = DiscoveredDevice(id: "test", name: "NoDashName#abc123", endpoint: endpoint)

        XCTAssertEqual(device.appName, "NoDashName")
        XCTAssertEqual(device.deviceName, "")
        XCTAssertEqual(device.shortId, "abc123")
    }

    func testAppNameMayContainDashes() {
        let device = DiscoveredDevice(id: "test", name: "My-App#ff00ff00", endpoint: endpoint)

        XCTAssertEqual(device.appName, "My-App")
        XCTAssertEqual(device.deviceName, "")
        XCTAssertEqual(device.shortId, "ff00ff00")
    }

    // MARK: - Device Identifiers

    func testDefaultIdentifiersNil() {
        let device = DiscoveredDevice(id: "test", name: "TestApp", endpoint: endpoint)

        XCTAssertNil(device.simulatorUDID)
        XCTAssertNil(device.installationId)
        XCTAssertNil(device.instanceId)
    }

    func testAllStoredTXTRecordFields() {
        let device = DiscoveredDevice(
            id: "test", name: "TestApp#abc",
            endpoint: endpoint,
            simulatorUDID: "SIM-UUID",
            installationId: "install-1",
            displayDeviceName: "Chris's iPhone",
            instanceId: "my-instance"
        )

        XCTAssertEqual(device.simulatorUDID, "SIM-UUID")
        XCTAssertEqual(device.installationId, "install-1")
        XCTAssertEqual(device.deviceName, "Chris's iPhone")
        XCTAssertEqual(device.instanceId, "my-instance")
    }

    func testDeviceNamePrefersBroadcastDeviceName() {
        let device = DiscoveredDevice(
            id: "test",
            name: "AccessibilityTestApp#abc123",
            endpoint: endpoint,
            displayDeviceName: "Office iPhone"
        )

        XCTAssertEqual(device.appName, "AccessibilityTestApp")
        XCTAssertEqual(device.deviceName, "Office iPhone")
    }

    func testExplicitConnectionTypeDoesNotDependOnIdPrefix() {
        let endpoint = DiscoveredDeviceEndpoint.hostPort(host: "::1", port: 1234)
        let device = DiscoveredDevice(
            id: "00008120-1111111111111111",
            name: "Alpha Phone (USB)",
            endpoint: endpoint,
            displayDeviceName: "Alpha Phone",
            connectionType: .usb
        )

        XCTAssertEqual(device.connectionType, .usb)
        XCTAssertEqual(device.deviceName, "Alpha Phone")
    }

    func testDisplayNameDisambiguatesWithoutChangingResolutionIdentity() {
        let first = DiscoveredDevice(
            id: "first",
            name: "DemoApp#abc123",
            endpoint: endpoint,
            displayDeviceName: "Office iPhone"
        )
        let second = DiscoveredDevice(
            id: "second",
            name: "DemoApp#def456",
            endpoint: endpoint,
            displayDeviceName: "Office iPhone"
        )

        XCTAssertEqual(first.displayName(among: [first, second]), "DemoApp (Office iPhone) [abc123]")
        XCTAssertMatches(first, "DemoApp")
        XCTAssertMatches(first, "Office iPhone")
        XCTAssertMatches(first, "abc")
    }

    // MARK: - Filter Matching

    func testMatchesByName() {
        let device = DiscoveredDevice(id: "test", name: "TestApp#abc123", endpoint: endpoint)

        XCTAssertMatches(device, "TestApp")
        XCTAssertMatches(device, "testapp") // case-insensitive
        XCTAssertMatches(device, " TestApp ")
        XCTAssertNil(DiscoveryResolutionQuery("   "))
    }

    func testMatchesByAppName() {
        let device = DiscoveredDevice(id: "test", name: "MyApp#abc", endpoint: endpoint)

        XCTAssertMatches(device, "MyApp")
        XCTAssertMatches(device, "myapp")
        XCTAssertDoesNotMatch(device, "OtherApp")
    }

    func testMatchesByDeviceName() {
        let device = DiscoveredDevice(
            id: "test",
            name: "TestApp#abc",
            endpoint: endpoint,
            displayDeviceName: "iPhone 16 Pro"
        )

        XCTAssertMatches(device, "iPhone 16")
        XCTAssertMatches(device, "iphone 16 pro")
    }

    func testMatchesByShortIdPrefix() {
        let device = DiscoveredDevice(id: "test", name: "TestApp#abc123", endpoint: endpoint)

        XCTAssertMatches(device, "abc")
        XCTAssertMatches(device, "abc123")
        // "123" still matches via name.contains (full name includes "abc123")
        XCTAssertMatches(device, "123")
    }

    func testMatchesByInstanceIdPrefix() {
        let device = DiscoveredDevice(
            id: "test", name: "TestApp",
            endpoint: endpoint,
            instanceId: "my-instance-42"
        )

        XCTAssertMatches(device, "my-instance")
        XCTAssertDoesNotMatch(device, "instance-42")
    }

    func testMatchesBySimulatorUDIDPrefix() {
        let device = DiscoveredDevice(
            id: "test", name: "TestApp",
            endpoint: endpoint,
            simulatorUDID: "DEADBEEF-1234-5678-9ABC-DEF012345678"
        )

        XCTAssertMatches(device, "DEADBEEF")
        XCTAssertMatches(device, "deadbeef")
        XCTAssertDoesNotMatch(device, "1234-5678")
    }

    func testMatchesByDiscoveryDeviceIDPrefix() {
        let device = DiscoveredDevice(
            id: "network-device-42",
            name: "TestApp",
            endpoint: endpoint
        )

        XCTAssertMatches(device, "network-device")
        XCTAssertMatches(device, "network-device-42")
        XCTAssertDoesNotMatch(device, "device-42")
    }

    func testNoMatch() {
        let device = DiscoveredDevice(id: "test", name: "TestApp#abc", endpoint: endpoint)

        XCTAssertDoesNotMatch(device, "Android")
        XCTAssertDoesNotMatch(device, "zzzzz")
    }

    func testDiscoveryIdentityPrefersInstallationId() {
        let oldDevice = DiscoveredDevice(
            id: "old",
            name: "AccessibilityTestApp#a18032ae",
            endpoint: endpoint,

            installationId: "install-1",
            instanceId: "a18032ae"
        )
        let newDevice = DiscoveredDevice(
            id: "new",
            name: "AccessibilityTestApp#841803ea",
            endpoint: endpoint,

            installationId: "install-1",
            instanceId: "841803ea"
        )

        XCTAssertEqual(oldDevice.discoveryIdentity, newDevice.discoveryIdentity)
        XCTAssertEqual(
            oldDevice.discoveryIdentity,
            .installation(appName: "accessibilitytestapp", id: "install-1")
        )
    }

    func testDiscoveryIdentityFallsBackToServiceIdWithoutInstallationId() {
        let firstDevice = DiscoveredDevice(
            id: "first",
            name: "AccessibilityTestApp#a18032ae",
            endpoint: endpoint,
            instanceId: "a18032ae"
        )
        let secondDevice = DiscoveredDevice(
            id: "second",
            name: "AccessibilityTestApp#841803ea",
            endpoint: endpoint,
            instanceId: "841803ea"
        )

        // Without installationId, each device gets a unique service-based identity
        XCTAssertNotEqual(firstDevice.discoveryIdentity, secondDevice.discoveryIdentity)
        XCTAssertEqual(firstDevice.discoveryIdentity, .device("first"))
    }

    func testDiscoveryRegistryUpdatesSameServiceWithoutMutation() {
        let firstDevice = DiscoveredDevice(
            id: "AccessibilityTestApp#a18032ae",
            name: "AccessibilityTestApp#a18032ae",
            endpoint: endpoint,
            displayDeviceName: "Before"
        )
        let updatedDevice = DiscoveredDevice(
            id: "AccessibilityTestApp#a18032ae",
            name: "AccessibilityTestApp#a18032ae",
            endpoint: endpoint,
            displayDeviceName: "After"
        )

        var registry = DiscoveryRegistry()

        XCTAssertEqual(registry.recordFound(firstDevice), [.found(firstDevice)])
        XCTAssertTrue(registry.recordFound(updatedDevice).isEmpty)
        XCTAssertEqual(registry.devices.first?.deviceName, "After")
    }

    func testDiscoveryRegistryIgnoresUnknownServiceLoss() {
        let device = DiscoveredDevice(
            id: "AccessibilityTestApp#a18032ae",
            name: "AccessibilityTestApp#a18032ae",
            endpoint: endpoint
        )

        var registry = DiscoveryRegistry()

        XCTAssertEqual(registry.recordFound(device), [.found(device)])
        XCTAssertTrue(registry.recordLost("missing-service").isEmpty)
        XCTAssertEqual(registry.devices, [device])
    }

    func testDiscoveryRegistryDedupesSimulatorRelaunches() {
        let oldDevice = DiscoveredDevice(
            id: "AccessibilityTestApp#a18032ae",
            name: "AccessibilityTestApp#a18032ae",
            endpoint: endpoint,

            installationId: "install-1",
            instanceId: "a18032ae"
        )
        let newDevice = DiscoveredDevice(
            id: "AccessibilityTestApp#841803ea",
            name: "AccessibilityTestApp#841803ea",
            endpoint: endpoint,

            installationId: "install-1",
            instanceId: "841803ea"
        )

        var registry = DiscoveryRegistry()

        XCTAssertEqual(registry.recordFound(oldDevice), [.found(oldDevice)])
        XCTAssertEqual(registry.devices, [oldDevice])
        XCTAssertEqual(
            registry.recordFound(newDevice),
            [.lost(oldDevice), .found(newDevice)]
        )
        XCTAssertEqual(registry.devices, [newDevice])
    }

    func testDiscoveryRegistryPromotesNewestSiblingWhenCurrentAdDisappears() {
        let oldDevice = DiscoveredDevice(
            id: "AccessibilityTestApp#a18032ae",
            name: "AccessibilityTestApp#a18032ae",
            endpoint: endpoint,

            installationId: "install-1",
            instanceId: "a18032ae"
        )
        let newDevice = DiscoveredDevice(
            id: "AccessibilityTestApp#841803ea",
            name: "AccessibilityTestApp#841803ea",
            endpoint: endpoint,

            installationId: "install-1",
            instanceId: "841803ea"
        )

        var registry = DiscoveryRegistry()
        _ = registry.recordFound(oldDevice)
        _ = registry.recordFound(newDevice)

        XCTAssertEqual(
            registry.recordLost(newDevice.id),
            [.lost(newDevice), .found(oldDevice)]
        )
        XCTAssertEqual(registry.devices, [oldDevice])
    }

    func testDiscoveryRegistryIgnoresHiddenSiblingRemoval() {
        let oldDevice = DiscoveredDevice(
            id: "AccessibilityTestApp#a18032ae",
            name: "AccessibilityTestApp#a18032ae",
            endpoint: endpoint,

            installationId: "install-1",
            instanceId: "a18032ae"
        )
        let newDevice = DiscoveredDevice(
            id: "AccessibilityTestApp#841803ea",
            name: "AccessibilityTestApp#841803ea",
            endpoint: endpoint,

            installationId: "install-1",
            instanceId: "841803ea"
        )

        var registry = DiscoveryRegistry()
        _ = registry.recordFound(oldDevice)
        _ = registry.recordFound(newDevice)

        XCTAssertTrue(registry.recordLost(oldDevice.id).isEmpty)
        XCTAssertEqual(registry.devices, [newDevice])
    }

    // MARK: - Host:Port Init

    func testHostPortInit() {
        let device = DiscoveredDevice(host: "127.0.0.1", port: 8080)

        XCTAssertEqual(device.id, "127.0.0.1:8080")
        XCTAssertEqual(device.name, "127.0.0.1:8080")
        XCTAssertNil(device.simulatorUDID)
    }

    func testDirectConnectTargetParsesLoopbackFilters() {
        let ipv4 = DiscoveredDevice.directConnectTarget(from: "127.0.0.1:8080")
        XCTAssertEqual(ipv4?.id, "127.0.0.1:8080")

        let ipv6 = DiscoveredDevice.directConnectTarget(from: "[::1]:9090")
        XCTAssertEqual(ipv6?.id, "::1:9090")
    }

    func testDirectConnectTargetRejectsNonLoopbackHostFilters() {
        XCTAssertNil(DiscoveredDevice.directConnectTarget(from: "example.com:8080"))
        XCTAssertNil(DiscoveredDevice.directConnectTarget(from: "QA:1"))
    }

    @ButtonHeistActor
    func testReachableCompletesOnTransportReadyWithoutStatusProbe() async {
        let device = DiscoveredDevice(
            id: "test",
            name: "ReachableApp#abc123",
            endpoint: DiscoveredDeviceEndpoint.hostPort(host: "::1", port: 1)
        )
        let mockConnection = MockConnection()
        mockConnection.emitTransportReadyOnConnect = true

        let previousProvider = makeReachabilityConnection
        makeReachabilityConnection = { _ in mockConnection }
        defer { makeReachabilityConnection = previousProvider }

        let reachable = await [device].reachable(timeout: 0.2)

        XCTAssertEqual(reachable, [device])
        XCTAssertTrue(mockConnection.sent.isEmpty, "Reachability must not enter the pre-auth message lifecycle")
    }

    @ButtonHeistActor
    func testReachableReleasesProbeConnectionAfterCompletion() async {
        let device = DiscoveredDevice(
            id: "test",
            name: "ReachableApp#abc123",
            endpoint: DiscoveredDeviceEndpoint.hostPort(host: "::1", port: 1)
        )

        let previousProvider = makeReachabilityConnection
        defer { makeReachabilityConnection = previousProvider }

        weak var weakProbe: ReachabilityProbeConnection?
        do {
            let probe = ReachabilityProbeConnection()
            weakProbe = probe
            makeReachabilityConnection = { _ in probe }

            let reachable = await [device].reachable(timeout: 0.2)
            XCTAssertEqual(reachable, [device])
        }

        makeReachabilityConnection = previousProvider
        for _ in 0..<10 {
            if weakProbe == nil { break }
            await Task.yield()
        }
        XCTAssertNil(weakProbe, "Reachability probe connection should deallocate after completion")
    }
}

@ButtonHeistActor
private final class ReachabilityProbeConnection: TransportReachabilityConnecting {
    var onEvent: (@ButtonHeistActor (ConnectionEvent) -> Void)?
    var onTransportReady: (@ButtonHeistActor () -> Void)?

    func connect() {
        onTransportReady?()
    }

    func disconnect() {}
}
