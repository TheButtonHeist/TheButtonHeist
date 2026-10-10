#if canImport(UIKit)
#if DEBUG
import UIKit

import TheScore

extension TheGetaway {

    func sendServerInfo(
        respond: @escaping SocketResponseHandler,
        delivery: ClientDelivery
    ) async {
        let screenBounds = ScreenMetrics.current.bounds
        guard let listeningPort = transport?.listeningPort else {
            await sendMessage(
                .error(ServerError(kind: .general, message: "Server info contract failed: transport is not listening")),
                respond: respond,
                delivery: delivery
            )
            return
        }
        guard let info = ServerInfo(
            admitting: Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App",
            bundleIdentifier: Bundle.main.insideJobIdentifier,
            deviceName: UIDevice.current.name,
            systemVersion: UIDevice.current.systemVersion,
            screenWidth: screenBounds.width,
            screenHeight: screenBounds.height,
            instanceId: identity.launchId,
            instanceIdentifier: identity.effectiveInstanceId,
            listeningPort: listeningPort,
            simulatorUDID: ProcessInfo.processInfo.simulatorUDID,
            vendorIdentifier: UIDevice.current.identifierForVendor.flatMap {
                try? VendorIdentifier(validating: $0.uuidString)
            },
            tlsActive: identity.tlsActive
        ) else {
            await sendMessage(
                .error(ServerError(kind: .general, message: "Server info contract failed: screen metrics are invalid")),
                respond: respond,
                delivery: delivery
            )
            return
        }
        await sendMessage(.info(info), respond: respond, delivery: delivery)
    }

    func captureStatus() async -> StatusPayload {
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""

        let identity = StatusIdentity(
            appName: appName,
            bundleIdentifier: Bundle.main.insideJobIdentifier,
            appBuild: appBuild,
            deviceName: UIDevice.current.name,
            systemVersion: UIDevice.current.systemVersion,
            buttonHeistVersion: buttonHeistVersion
        )

        let isActive = await muscle.isSessionActive
        let connectionCount = await muscle.activeSessionConnectionCount
        let activeDriverId = await muscle.exposedDriverId
        let session = StatusSession(
            active: isActive,
            watchersAllowed: false,
            activeConnections: connectionCount,
            activeDriverId: activeDriverId
        )

        return StatusPayload(identity: identity, session: session)
    }

    static func capturePongPayload(identity: ServerIdentity) -> PongPayload {
        let info = Bundle.main.infoDictionary ?? [:]
        let appName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? ProcessInfo.processInfo.processName
        return PongPayload(
            buttonHeistVersion: buttonHeistVersion,
            appName: appName,
            bundleIdentifier: Bundle.main.insideJobIdentifier,
            appVersion: info["CFBundleShortVersionString"] as? String,
            appBuild: info["CFBundleVersion"] as? String,
            serverInstanceIdentifier: identity.effectiveInstanceId
        )
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
