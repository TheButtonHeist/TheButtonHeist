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

struct InsideJobRuntimeConfiguration: Equatable, Sendable {
    let token: ResolvedStartupValue<SessionAuthToken>
    let preferredPort: ResolvedStartupValue<UInt16>
    let allowedScopes: ResolvedStartupValue<Set<ConnectionScope>>
    let addressFamily: ListenerAddressFamily
    let sessionReleaseTimeout: ResolvedStartupValue<TimeInterval>
    let fingerprintsEnabled: ResolvedStartupValue<Bool>
    let failureEvidencePolicy: ResolvedStartupValue<FailureEvidencePolicy>
    let authenticationPolicy: InsideJobAuthenticationPolicy
    let sessionIdentity: InsideJobSessionIdentity

    static func resolve(
        startupConfiguration: StartupConfiguration,
        token: String?,
        instanceId: String?,
        allowedScopes: Set<ConnectionScope>?,
        port: UInt16,
        addressFamily: ListenerAddressFamily = .dualStack,
        fingerprintsEnabled: Bool? = nil,
        authenticationPolicy: InsideJobAuthenticationPolicy = .default
    ) throws(InsideJobConfigurationError) -> InsideJobRuntimeConfiguration {
        let explicitToken = try admitToken(token)
        let explicitInstanceId = try admitInstanceId(instanceId)
        let resolvedToken = resolveRuntimeToken(
            explicitToken: explicitToken,
            startupToken: startupConfiguration.token
        )
        let resolvedInstanceId = ResolvedStartupValue(
            value: explicitInstanceId,
            source: explicitInstanceId == nil ? .generated : .api
        )
        return InsideJobRuntimeConfiguration(
            token: resolvedToken,
            preferredPort: ResolvedStartupValue(
                value: port,
                source: port == 0 ? .defaultValue : .api
            ),
            allowedScopes: allowedScopes.map {
                ResolvedStartupValue(value: $0, source: .api)
            } ?? startupConfiguration.allowedScopes,
            addressFamily: addressFamily,
            sessionReleaseTimeout: startupConfiguration.sessionTimeout,
            fingerprintsEnabled: fingerprintsEnabled.map {
                ResolvedStartupValue(value: $0, source: .api)
            } ?? startupConfiguration.fingerprintsEnabled,
            failureEvidencePolicy: startupConfiguration.failureEvidencePolicy,
            authenticationPolicy: authenticationPolicy,
            sessionIdentity: InsideJobSessionIdentity.resolve(instanceId: resolvedInstanceId)
        )
    }

    static func resolve(startupConfiguration: StartupConfiguration) -> InsideJobRuntimeConfiguration {
        let resolvedToken = resolveRuntimeToken(
            explicitToken: nil,
            startupToken: startupConfiguration.token
        )
        return InsideJobRuntimeConfiguration(
            token: resolvedToken,
            preferredPort: startupConfiguration.preferredPort,
            allowedScopes: startupConfiguration.allowedScopes,
            addressFamily: .dualStack,
            sessionReleaseTimeout: startupConfiguration.sessionTimeout,
            fingerprintsEnabled: startupConfiguration.fingerprintsEnabled,
            failureEvidencePolicy: startupConfiguration.failureEvidencePolicy,
            authenticationPolicy: .default,
            sessionIdentity: InsideJobSessionIdentity.resolve(instanceId: startupConfiguration.instanceId)
        )
    }

    private static func resolveRuntimeToken(
        explicitToken: SessionAuthToken?,
        startupToken: ResolvedStartupValue<SessionAuthToken?>
    ) -> ResolvedStartupValue<SessionAuthToken> {
        if let explicitToken {
            return ResolvedStartupValue(value: explicitToken, source: .api)
        }
        if let startupTokenValue = startupToken.value {
            return ResolvedStartupValue(value: startupTokenValue, source: startupToken.source)
        }
        return ResolvedStartupValue(value: generatedSessionToken(), source: .generated)
    }

    private static func generatedSessionToken() -> SessionAuthToken {
        // Console access is already the authority boundary for this debug tool.
        // UUID v4 remains easy to recognize, copy, and pass between processes.
        guard let token = try? SessionAuthToken(validating: UUID().uuidString.lowercased()) else {
            preconditionFailure("UUID generation produced a blank session token")
        }
        return token
    }

    private static func admitToken(_ value: String?) throws(InsideJobConfigurationError) -> SessionAuthToken? {
        guard let value else { return nil }
        do {
            return try SessionAuthToken(validating: value)
        } catch {
            throw .blankToken
        }
    }

    private static func admitInstanceId(_ value: String?) throws(InsideJobConfigurationError) -> InsideJobInstanceID? {
        guard let value else { return nil }
        do {
            return try InsideJobInstanceID(validating: value)
        } catch {
            throw .blankInstanceID
        }
    }
}

struct InsideJobSessionIdentity: Equatable, Sendable {
    let launchId: ServerLaunchID
    let installationId: InstallationID
    let effectiveInstanceId: ResolvedStartupValue<InsideJobInstanceID>

    static func resolve(
        instanceId: ResolvedStartupValue<InsideJobInstanceID?>
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
                ResolvedStartupValue(value: $0, source: instanceId.source)
            } ?? ResolvedStartupValue(value: generatedInstanceId, source: .generated)
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
