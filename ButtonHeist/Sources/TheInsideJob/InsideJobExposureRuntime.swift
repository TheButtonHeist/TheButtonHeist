#if canImport(UIKit)
#if DEBUG
import UIKit

@MainActor
extension TheInsideJob {
    @discardableResult
    func advertiseService(on transport: ServerTransport, port: UInt16) -> String? {
        let exposure = ServerExposure(
            allowedScopes: runtimeConfiguration.allowedScopes.value,
            addressFamily: runtimeConfiguration.addressFamily
        )
        guard exposure.publishesBonjour else { return nil }

        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"
        let serviceName = "\(appName)#\(effectiveInstanceId)"

        transport.advertise(
            serviceName: serviceName,
            simulatorUDID: ProcessInfo.processInfo.simulatorUDID?.description,
            installationId: runtimeConfiguration.sessionIdentity.installationId.description,
            instanceId: effectiveInstanceId.description,
            additionalTXT: [
                "devicename": UIDevice.current.name
            ]
        )

        return serviceName
    }

    func logStartupSummary(
        actualPort: UInt16,
        bonjourServiceName: String?
    ) {
        let scopeNames = runtimeConfiguration.allowedScopes.value.map(\.rawValue).sorted().joined(separator: ",")
        let bonjourDescription = if let bonjourServiceName {
            "bonjour=advertising service=\(bonjourServiceName)"
        } else {
            "bonjour=disabled reason=network-scope-not-enabled"
        }
        let fields = [
            "actualPort=\(actualPort)",
            "preferredPort=\(runtimeConfiguration.preferredPort.value)(\(runtimeConfiguration.preferredPort.source.label))",
            "tokenSource=\(runtimeConfiguration.token.source.label)",
            "sessionId=\(runtimeConfiguration.sessionIdentity.launchId)",
            "instanceIdentifier=\(effectiveInstanceId)(\(runtimeConfiguration.sessionIdentity.effectiveInstanceId.source.label))",
            "allowedScopes=\(scopeNames)(\(runtimeConfiguration.allowedScopes.source.label))",
            "addressFamily=\(runtimeConfiguration.addressFamily.rawValue)",
            "sessionTimeout=\(runtimeConfiguration.sessionReleaseTimeout.value)s(\(runtimeConfiguration.sessionReleaseTimeout.source.label))",
            "fingerprints=\(runtimeConfiguration.fingerprintsEnabled.value)(\(runtimeConfiguration.fingerprintsEnabled.source.label))",
            "failureEvidence=\(runtimeConfiguration.failureEvidencePolicy.value.rawValue)(\(runtimeConfiguration.failureEvidencePolicy.source.label))",
            "tls=psk",
            bonjourDescription
        ].joined(separator: " ")
        insideJobLogger.info("Startup summary: \(fields, privacy: .public) token=<redacted>")
        if runtimeConfiguration.token.source == .generated {
            let token = runtimeConfiguration.token.value
            insideJobLogger.info("Generated ButtonHeist token: BUTTONHEIST_TOKEN=\(token.description, privacy: .public)")
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
