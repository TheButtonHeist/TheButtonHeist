#if canImport(UIKit)
#if DEBUG
import Foundation

import TheScore

public enum InsideJobConfigurationError: Error, Equatable, Sendable {
    case blankToken
    case blankInstanceID
    case alreadyConfigured
    case alreadyLive
}

struct InsideJobSessionIdentity: Equatable, Sendable {
    let launchId: ServerLaunchID
    let installationId: InstallationID
    let effectiveInstanceId: ResolvedConfigurationValue<InsideJobInstanceID>

    static func resolve(
        instanceId: ResolvedConfigurationValue<InsideJobInstanceID?>
    ) -> InsideJobSessionIdentity {
        guard let launchId = try? ServerLaunchID(validating: UUID().uuidString),
              let generatedInstanceId = try? InsideJobInstanceID(
                validating: String(launchId.description.prefix(8)).lowercased()
              ) else {
            preconditionFailure("UUID generation produced a blank server identity")
        }
        return InsideJobSessionIdentity(
            launchId: launchId,
            installationId: loadOrCreateInstallationId(),
            effectiveInstanceId: instanceId.value.map {
                ResolvedConfigurationValue(value: $0, source: instanceId.source)
            } ?? ResolvedConfigurationValue(value: generatedInstanceId, source: .generated)
        )
    }

    private static func loadOrCreateInstallationId() -> InstallationID {
        let defaultsKey = "\(Bundle.main.insideJobIdentifier).installation-id"

        if let existing = UserDefaults.standard.string(forKey: defaultsKey),
           let installationId = try? InstallationID(validating: existing) {
            return installationId
        }

        guard let generated = try? InstallationID(validating: UUID().uuidString.lowercased()) else {
            preconditionFailure("UUID generation produced a blank installation ID")
        }
        UserDefaults.standard.set(generated.description, forKey: defaultsKey)
        return generated
    }
}

@MainActor
extension TheInsideJob {
    var effectiveInstanceId: InsideJobInstanceID {
        runtimeConfiguration.sessionIdentity.effectiveInstanceId.value
    }
}

extension Bundle {
    var insideJobIdentifier: BundleIdentifier {
        guard let bundleIdentifier,
              let identifier = try? BundleIdentifier(validating: bundleIdentifier) else {
            return "com.buttonheist.theinsidejob"
        }
        return identifier
    }
}

extension ProcessInfo {
    var simulatorUDID: SimulatorUDID? {
        environment[.udid].flatMap { try? SimulatorUDID(validating: $0) }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
