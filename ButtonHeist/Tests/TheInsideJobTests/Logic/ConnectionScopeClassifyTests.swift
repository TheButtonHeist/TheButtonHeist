import Foundation
import Network
import Testing
@testable import TheInsideJob
import TheScore

@Suite("ConnectionScope.classify")
struct ConnectionScopeClassifyTests {

    // MARK: - classify (typed NWEndpoint.Host, no interfaces)

    @Test func classifiesIPv4Loopback() {
        #expect(ConnectionScope.classify(host: .ipv4(.loopback)) == .simulator)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("127.0.0.1")) == .simulator)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("127.0.0.2")) == .simulator)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("127.255.255.255")) == .simulator)
    }

    @Test func classifiesIPv6Loopback() {
        #expect(ConnectionScope.classify(host: .ipv6(.loopback)) == .simulator)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("::1")) == .simulator)
    }

    @Test func classifiesPrivateIPv4AsNetwork() {
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("192.168.1.100")) == .network)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("10.0.0.5")) == .network)
    }

    @Test func classifiesPublicIPv4AsNetwork() {
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("8.8.8.8")) == .network)
    }

    @Test func classifiesLinkLocalAsNetwork() {
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("fe80::1")) == .network)
    }

    @Test func classifiesGlobalIPv6AsNetwork() {
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("2001:db8::1")) == .network)
    }

    @Test func classifiesHostnameAsNetwork() {
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("example.local")) == .network)
    }

    // MARK: - classify with interface platform heuristics

    @Test func platformHeuristicClassifiesLoopbackInterfaceEvidenceAsSimulator() {
        let evidence = ConnectionPathEvidence(
            host: NWEndpoint.Host("169.254.239.217"),
            interfaceNames: ["lo0"]
        )

        #expect(evidence.interfaceFacts == [
            ConnectionPathEvidence.InterfaceFact(name: "lo0")
        ])
        #expect(evidence.path == .simulator(.loopbackInterface(name: "lo0")))
        #expect(ConnectionScope.classify(evidence) == .simulator)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("169.254.239.217"), interfaceNames: ["lo0"]) == .simulator)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("fe80::1"), interfaceNames: ["lo0"]) == .simulator)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("192.168.1.100"), interfaceNames: ["lo0"]) == .simulator)
    }

    @Test func platformHeuristicClassifiesAppleNetworkPrivateInterfaceEvidenceAsUSB() {
        let evidence = ConnectionPathEvidence(
            host: NWEndpoint.Host("fd9a:6190:eed7::1"),
            interfaceNames: ["anpi0"]
        )

        #expect(evidence.interfaceFacts == [
            ConnectionPathEvidence.InterfaceFact(name: "anpi0")
        ])
        #expect(evidence.path == .usb(.appleNetworkPrivateInterface(name: "anpi0")))
        #expect(ConnectionScope.classify(evidence) == .usb)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("fd9a:6190:eed7::1"), interfaceNames: ["anpi0"]) == .usb)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("192.168.1.100"), interfaceNames: ["anpi0"]) == .usb)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("2001:db8::1"), interfaceNames: ["anpi0"]) == .usb)
    }

    @Test func platformHeuristicClassifiesAppleNetworkPrivateInterfaceVariantsAsUSB() {
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("fe80::1"), interfaceNames: ["anpi1"]) == .usb)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("fe80::1"), interfaceNames: ["anpi2"]) == .usb)
    }

    @Test func platformHeuristicLeavesNonMatchingInterfaceEvidenceAsNetwork() {
        let evidence = ConnectionPathEvidence(
            host: NWEndpoint.Host("fd9a:6190:eed7::1"),
            interfaceNames: ["en0"]
        )

        #expect(evidence.interfaceFacts == [
            ConnectionPathEvidence.InterfaceFact(name: "en0")
        ])
        #expect(evidence.path == .network(.noLocalPathEvidence))
        #expect(ConnectionScope.classify(evidence) == .network)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("fd9a:6190:eed7::1"), interfaceNames: ["en0"]) == .network)
        #expect(ConnectionScope.classify(host: NWEndpoint.Host("192.168.1.100"), interfaceNames: ["en0"]) == .network)
    }

    @Test func loopbackAddressStillClassifiesAsSimulatorWithUSBInterfaceEvidence() {
        let evidence = ConnectionPathEvidence(host: .ipv4(.loopback), interfaceNames: ["anpi0"])

        #expect(evidence.path == .simulator(.ipv4LoopbackAddress))
        #expect(ConnectionScope.classify(evidence) == .simulator)
        #expect(ConnectionScope.classify(host: .ipv4(.loopback), interfaceNames: ["anpi0"]) == .simulator)
        #expect(ConnectionScope.classify(host: .ipv6(.loopback), interfaceNames: ["anpi0"]) == .simulator)
    }

    @Test func `the CoreDevice endpoint pair on the observed iPhone tunnel is USB`() {
        let evidence = ConnectionPathEvidence(
            host: NWEndpoint.Host("fd9a:6190:eed7::2"),
            localHost: NWEndpoint.Host("fd9a:6190:eed7::1"),
            interfaceNames: ["utun4"]
        )

        #expect(evidence.path == .usb(.coreDeviceTunnel(name: "utun4")))
        #expect(ConnectionScope.classify(evidence) == .usb)
    }

    @Test func `the CoreDevice pair without a tunnel interface remains network scoped`() {
        #expect(ConnectionScope.classify(
            host: NWEndpoint.Host("fd9a:6190:eed7::2"),
            localHost: NWEndpoint.Host("fd9a:6190:eed7::1"),
            interfaceNames: ["en0"]
        ) == .network)
    }

    @Test func `tunnel interface alone does not prove a CoreDevice connection`() {
        #expect(ConnectionScope.classify(
            host: NWEndpoint.Host("fd9a:6190:eed7::2"),
            interfaceNames: ["utun4"]
        ) == .network)
    }

    @Test func `other tunnel endpoint pairs remain network scoped`() {
        for (remote, local) in [
            ("fd9a:6190:eed7::3", "fd9a:6190:eed7::1"),
            ("fd9a:6190:eed7::2", "fd9a:6190:eed7::3"),
            ("fd9a:6190:eed8::2", "fd9a:6190:eed7::1"),
            ("2001:db8::2", "2001:db8::1"),
            ("192.168.1.2", "192.168.1.1"),
        ] {
            #expect(ConnectionScope.classify(
                host: NWEndpoint.Host(remote),
                localHost: NWEndpoint.Host(local),
                interfaceNames: ["utun4"]
            ) == .network)
        }
    }
}
