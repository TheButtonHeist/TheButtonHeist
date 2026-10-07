import Testing
@testable import TheInsideJob
import TheScore

@Suite("ServerExposure")
struct ServerExposureTests {

    @Test func defaultScopeDoesNotPublishBonjour() {
        let exposure = ServerExposure(allowedScopes: ConnectionScope.default)

        #expect(!exposure.publishesBonjour)
    }

    @Test func networkScopePublishesBonjour() {
        let exposure = ServerExposure(allowedScopes: [.simulator, .usb, .network])

        #expect(exposure.publishesBonjour)
    }

    @Test func simulatorOnlyScopeBindsToLoopback() {
        #expect(ServerExposure(allowedScopes: [.simulator]).bindsToLoopbackOnly)
        #expect(!ServerExposure(allowedScopes: ConnectionScope.default).bindsToLoopbackOnly)
    }

    @Test func addressFamilyDefaultsToDualStack() {
        #expect(ServerExposure(allowedScopes: [.simulator]).addressFamily == .dualStack)
        #expect(ServerExposure(allowedScopes: [.simulator], addressFamily: .ipv6).addressFamily == .ipv6)
    }
}
