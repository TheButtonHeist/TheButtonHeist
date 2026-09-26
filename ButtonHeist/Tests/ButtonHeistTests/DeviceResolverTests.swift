import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist
import Network
import TheScore

final class DeviceResolverTests: XCTestCase {

    // MARK: - directConnectTarget fast path

    @ButtonHeistActor
    func testResolveDirectConnectSkipsDiscovery() async throws {
        var discoveryCallCount = 0
        let resolver = DeviceResolver(
            filter: "127.0.0.1:5555",
            discoveryTimeout: 1_000_000_000,
            getDiscoveredDevices: {
                discoveryCallCount += 1
                return []
            }
        )

        let device = try await resolver.resolve()
        XCTAssertEqual(discoveryCallCount, 0)
        XCTAssertEqual(device.id, "127.0.0.1:5555")
    }

    @ButtonHeistActor
    func testResolveNonLoopbackFilterDoesNotShortCircuit() async {
        var discoveryCallCount = 0
        let resolver = DeviceResolver(
            filter: "192.168.1.100:5555",
            discoveryTimeout: 0,
            getDiscoveredDevices: {
                discoveryCallCount += 1
                return []
            }
        )
        guard case .query(let query) = resolver.target.kind else {
            return XCTFail("Expected non-loopback endpoint to remain a discovery query")
        }
        XCTAssertEqual(query.rawValue, "192.168.1.100:5555")

        do {
            _ = try await resolver.resolve()
            XCTFail("Expected error for no devices found")
        } catch let error as HandoffConnectionError {
            XCTAssertEqual(error, .noDeviceFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertGreaterThan(discoveryCallCount, 0)
    }

    @ButtonHeistActor
    func testResolveFilterWaitsForMatchingDeviceAfterNonMatch() async throws {
        let otherDevice = makeDevice(id: "other", name: "OtherApp#aaa")
        let targetDevice = makeDevice(id: "target", name: "DemoApp#bbb")
        var discoveryCallCount = 0
        let resolver = DeviceResolver(
            filter: "DemoApp",
            discoveryTimeout: 2_000_000_000,
            getDiscoveredDevices: {
                discoveryCallCount += 1
                return discoveryCallCount < 8 ? [otherDevice] : [otherDevice, targetDevice]
            }
        )

        let device = try await resolver.resolve()

        XCTAssertEqual(device, targetDevice)
    }

    @ButtonHeistActor
    func testResolveNoDevicesThrowsNoDeviceFound() async {
        let resolver = DeviceResolver(
            filter: nil,
            discoveryTimeout: 0,
            getDiscoveredDevices: { [] }
        )

        do {
            _ = try await resolver.resolve()
            XCTFail("Expected noDeviceFound")
        } catch let error as HandoffConnectionError {
            XCTAssertEqual(error, .noDeviceFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @ButtonHeistActor
    func testResolveDefaultSelectsSingleDevice() async throws {
        let device = makeDevice(id: "only", name: "DemoApp#one")
        let resolver = DeviceResolver(
            filter: nil,
            discoveryTimeout: 0,
            getDiscoveredDevices: { [device] }
        )

        let resolved = try await resolver.resolve()

        XCTAssertEqual(resolved, device)
    }

    @ButtonHeistActor
    func testResolveExplicitTargetSelectsSingleMatch() async throws {
        let otherDevice = makeDevice(id: "other", name: "OtherApp#aaa")
        let targetDevice = makeDevice(id: "target", name: "DemoApp#bbb")
        let resolver = DeviceResolver(
            filter: "DemoApp",
            discoveryTimeout: 0,
            getDiscoveredDevices: { [otherDevice, targetDevice] }
        )

        let resolved = try await resolver.resolve()

        XCTAssertEqual(resolved, targetDevice)
    }

    @ButtonHeistActor
    func testResolveDefaultRejectsAmbiguousDevices() async {
        let devices = [
            makeDevice(id: "first", name: "DemoApp#one"),
            makeDevice(id: "second", name: "OtherApp#two"),
        ]
        let resolver = DeviceResolver(
            filter: nil,
            discoveryTimeout: 0,
            getDiscoveredDevices: { devices }
        )

        do {
            _ = try await resolver.resolve()
            XCTFail("Expected ambiguousDeviceTarget")
        } catch let error as HandoffConnectionError {
            XCTAssertEqual(
                error,
                .ambiguousDeviceTarget(filter: "(none)", matches: devices.map(\.name))
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @ButtonHeistActor
    func testResolveExplicitTargetRejectsAmbiguousMatches() async {
        let devices = [
            makeDevice(id: "first", name: "DemoApp#one"),
            makeDevice(id: "second", name: "DemoApp#two"),
        ]
        let resolver = DeviceResolver(
            filter: "DemoApp",
            discoveryTimeout: 0,
            getDiscoveredDevices: { devices }
        )

        do {
            _ = try await resolver.resolve()
            XCTFail("Expected ambiguousDeviceTarget")
        } catch let error as HandoffConnectionError {
            XCTAssertEqual(
                error,
                .ambiguousDeviceTarget(filter: "DemoApp", matches: devices.map(\.name))
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @ButtonHeistActor
    func testResolveUnknownTargetThrowsNoMatchingDevice() async {
        let devices = [
            makeDevice(id: "first", name: "DemoApp#one"),
        ]
        let resolver = DeviceResolver(
            filter: "Missing",
            discoveryTimeout: 0,
            getDiscoveredDevices: { devices }
        )

        do {
            _ = try await resolver.resolve()
            XCTFail("Expected noMatchingDevice")
        } catch let error as HandoffConnectionError {
            XCTAssertEqual(
                error,
                .noMatchingDevice(filter: "Missing", available: devices.map(\.name))
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @ButtonHeistActor
    func testConnectionResolutionTimeoutCapsLongHandshakeTimeout() async {
        XCTAssertEqual(TheHandoff.connectionResolutionTimeout(for: 30), 2)
        XCTAssertEqual(TheHandoff.connectionResolutionTimeout(for: 1.25), 1.25)
        XCTAssertEqual(TheHandoff.connectionResolutionTimeout(for: 0.01), 0.05)
    }

    // MARK: - Helpers

    private func makeDevice(id: DiscoveryDeviceID, name: String) -> DiscoveredDevice {
        DiscoveredDevice(
            id: id, name: name,
            endpoint: .hostPort(host: "127.0.0.1", port: 9999)
        )
    }
}

private extension DeviceResolver {
    init(
        filter: String?,
        discoveryTimeout: UInt64,
        getDiscoveredDevices: @escaping () -> [DiscoveredDevice]
    ) {
        self.init(
            target: DeviceResolutionTarget(filter: filter),
            discoveryTimeout: discoveryTimeout,
            getDiscoveredDevices: getDiscoveredDevices
        )
    }
}
