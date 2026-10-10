#if canImport(UIKit)
#if DEBUG
import Foundation

import ThePlans
import TheScore

enum InsideJobConfigurationSource: String, Sendable {
    case api
    case environment
    case infoPlist
    case defaultValue = "default"
    case generated

    var label: String {
        switch self {
        case .api:
            return "api"
        case .environment:
            return "environment"
        case .infoPlist:
            return "Info.plist"
        case .defaultValue:
            return "default"
        case .generated:
            return "generated"
        }
    }
}

struct ResolvedConfigurationValue<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
    let source: InsideJobConfigurationSource
}

enum InsideJobConfigurationWarning: Equatable, Sendable {
    case emptyValueIgnored(key: String, source: InsideJobConfigurationSource)
    case invalidValueIgnored(key: String, source: InsideJobConfigurationSource, value: String)

    var message: String {
        switch self {
        case .emptyValueIgnored(let key, let source):
            return "Ignoring empty \(key) from \(source.label)"
        case .invalidValueIgnored(let key, let source, let value):
            return "Ignoring invalid \(key) from \(source.label): \(value)"
        }
    }
}

enum StartupInfoPlistKey: String, CaseIterable, Sendable {
    case disableAutoStart = "InsideJobDisableAutoStart"
    case failureEvidence = "ButtonHeistFailureEvidence"
    case fingerprintsEnabled = "InsideJobFingerprintsEnabled"
    case token = "InsideJobToken"
    case instanceId = "InsideJobInstanceId"
    case port = "InsideJobPort"
    case scope = "InsideJobScope"
    case sessionTimeout = "InsideJobSessionTimeout"
}

struct StartupInfoPlist: Equatable, Sendable {
    static var main: StartupInfoPlist {
        StartupInfoPlist(bundle: .main)
    }

    private let values: [StartupInfoPlistKey: InfoPlistValue]

    init(bundle: Bundle) {
        self.init { key in
            guard let object = bundle.object(forInfoDictionaryKey: key) else { return nil }
            return decodeFoundationInfoPlistValue(object)
        }
    }

    init(contentsOf url: URL) {
        guard let dictionary = decodeInfoPlistValues(contentsOf: url) else {
            self.init(values: [:])
            return
        }

        self.init { key in
            dictionary[key]
        }
    }

    private init(valueForKey: (String) -> InfoPlistValue?) {
        var values: [StartupInfoPlistKey: InfoPlistValue] = [:]
        for key in StartupInfoPlistKey.allCases {
            if let value = valueForKey(key.rawValue) {
                values[key] = value
            }
        }
        self.init(values: values)
    }

    private init(values: [StartupInfoPlistKey: InfoPlistValue]) {
        self.values = values
    }

    subscript(key: StartupInfoPlistKey) -> InfoPlistValue? {
        values[key]
    }
}

enum InfoPlistValue: Equatable, Sendable, CustomStringConvertible {
    case bool(Bool)
    case string(String)
    case number(Double)
    case stringArray([String])
    case unsupported(String)

    var bool: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var string: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var number: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }

    var stringArray: [String]? {
        if case .stringArray(let value) = self {
            return value
        }
        return nil
    }

    var description: String {
        switch self {
        case .bool(let value):
            return String(value)
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .stringArray(let value):
            return Self.describe(value)
        case .unsupported(let value):
            return value
        }
    }

    private static func describe(_ strings: [String]) -> String {
        "[" + strings.map(\.debugDescription).joined(separator: ", ") + "]"
    }
}

/// Foundation's Bundle and property-list APIs vend raw plist objects. Keep
/// that `Any` decoding here and expose only typed `InfoPlistValue` to callers.
private func decodeInfoPlistValues(contentsOf url: URL) -> [String: InfoPlistValue]? {
    guard let data = try? Data(contentsOf: url),
          let propertyList = try? PropertyListSerialization.propertyList(
              from: data,
              options: [],
              format: nil
          ),
          let dictionary = propertyList as? NSDictionary else {
        return nil
    }

    var values: [String: InfoPlistValue] = [:]
    for (key, object) in dictionary {
        guard let key = key as? String else { continue }
        values[key] = decodeFoundationInfoPlistValue(object)
    }
    return values
}

private func decodeFoundationInfoPlistValue(_ object: Any) -> InfoPlistValue {
    if let string = object as? String {
        return .string(string)
    }
    if let strings = object as? [String] {
        return .stringArray(strings)
    }
    if let number = object as? NSNumber {
        if number.isBooleanPropertyListValue {
            return .bool(number.boolValue)
        }
        return .number(number.doubleValue)
    }
    return .unsupported(String(describing: object))
}

private extension NSNumber {
    var isBooleanPropertyListValue: Bool {
        CFGetTypeID(self as CFTypeRef) == CFBooleanGetTypeID()
    }
}

struct StartupEnvironmentKey: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    private init(_ key: EnvironmentKey) {
        self.rawValue = key.rawValue
    }

    static let disableAutoStart = StartupEnvironmentKey(.insideJobDisable)
    static let token = StartupEnvironmentKey(.insideJobToken)
    static let instanceId = StartupEnvironmentKey(.insideJobId)
    static let port = StartupEnvironmentKey(.insideJobPort)
    static let scope = StartupEnvironmentKey(.insideJobScope)
    static let sessionTimeout = StartupEnvironmentKey(.insideJobSessionTimeout)
    static let fingerprintsEnabled = StartupEnvironmentKey(.insideJobFingerprints)
    static let failureEvidence = StartupEnvironmentKey(.buttonheistFailureEvidence)

    fileprivate static let processProjectionKeys: [StartupEnvironmentKey] = [
        .disableAutoStart,
        .token,
        .instanceId,
        .port,
        .scope,
        .sessionTimeout,
        .fingerprintsEnabled,
        .failureEvidence,
    ]
}

struct StartupEnvironment: Equatable, Sendable {
    static let empty = StartupEnvironment()
    static var current: StartupEnvironment {
        StartupEnvironment(rawValues: ProcessInfo.processInfo.environment)
    }

    private let values: [StartupEnvironmentKey: String]

    init(values: [StartupEnvironmentKey: String] = [:]) {
        self.values = values
    }

    fileprivate init(rawValues: [String: String]) {
        self.values = Dictionary(uniqueKeysWithValues: StartupEnvironmentKey.processProjectionKeys.compactMap { key in
            rawValues[key.rawValue].map { (key, $0) }
        })
    }

    subscript(key: StartupEnvironmentKey) -> String? {
        values[key]
    }
}

struct InsideJobRuntimeConfiguration: Equatable, Sendable {
    private struct ResolutionInput {
        let token: SessionAuthToken?
        let instanceId: InsideJobInstanceID?
        let usesConfiguredInstanceId: Bool
        let allowedScopes: Set<ConnectionScope>?
        let preferredPort: UInt16?
        let addressFamily: ListenerAddressFamily
        let fingerprintsEnabled: Bool?
        let authenticationPolicy: InsideJobAuthenticationPolicy
    }

    static let defaultSessionTimeout: TimeInterval = 30.0
    static let minimumSessionTimeout: TimeInterval = 1.0
    static let maximumSessionTimeout: TimeInterval = 3600.0

    let disableAutoStart: ResolvedConfigurationValue<Bool>
    let token: ResolvedConfigurationValue<SessionAuthToken>
    let preferredPort: ResolvedConfigurationValue<UInt16>
    let allowedScopes: ResolvedConfigurationValue<Set<ConnectionScope>>
    let addressFamily: ListenerAddressFamily
    let sessionReleaseTimeout: ResolvedConfigurationValue<TimeInterval>
    let fingerprintsEnabled: ResolvedConfigurationValue<Bool>
    let failureEvidencePolicy: ResolvedConfigurationValue<FailureEvidencePolicy>
    let authenticationPolicy: InsideJobAuthenticationPolicy
    let sessionIdentity: InsideJobSessionIdentity
    let warnings: [InsideJobConfigurationWarning]

    static func resolve(
        env: StartupEnvironment = .current,
        infoPlist: StartupInfoPlist = .main
    ) -> InsideJobRuntimeConfiguration {
        resolve(
            env: env,
            infoPlist: infoPlist,
            input: ResolutionInput(
                token: nil,
                instanceId: nil,
                usesConfiguredInstanceId: true,
                allowedScopes: nil,
                preferredPort: nil,
                addressFamily: .dualStack,
                fingerprintsEnabled: nil,
                authenticationPolicy: .default
            )
        )
    }

    static func resolve(
        env: StartupEnvironment = .current,
        infoPlist: StartupInfoPlist = .main,
        token: String?,
        instanceId: String?,
        allowedScopes: Set<ConnectionScope>?,
        port: UInt16,
        addressFamily: ListenerAddressFamily = .dualStack,
        fingerprintsEnabled: Bool? = nil,
        authenticationPolicy: InsideJobAuthenticationPolicy = .default
    ) throws(InsideJobConfigurationError) -> InsideJobRuntimeConfiguration {
        try resolve(
            env: env,
            infoPlist: infoPlist,
            input: ResolutionInput(
                token: admitToken(token),
                instanceId: admitInstanceId(instanceId),
                usesConfiguredInstanceId: false,
                allowedScopes: allowedScopes,
                preferredPort: port,
                addressFamily: addressFamily,
                fingerprintsEnabled: fingerprintsEnabled,
                authenticationPolicy: authenticationPolicy
            )
        )
    }

    private static func resolve(
        env: StartupEnvironment,
        infoPlist: StartupInfoPlist,
        input: ResolutionInput
    ) -> InsideJobRuntimeConfiguration {
        var warnings: [InsideJobConfigurationWarning] = []
        let plist = infoPlist
        let disableAutoStart = resolveBool(
            envKey: .disableAutoStart,
            plistKey: .disableAutoStart,
            defaultValue: false,
            env: env,
            plist: plist,
            warnings: &warnings
        )
        let fingerprintsEnabled = resolveBool(
            envKey: .fingerprintsEnabled,
            plistKey: .fingerprintsEnabled,
            defaultValue: true,
            env: env,
            plist: plist,
            warnings: &warnings
        )
        let configuredToken = resolveString(
            envKey: .token,
            plistKey: .token,
            as: SessionAuthToken.self,
            env: env,
            plist: plist,
            absentSource: .generated,
            warnings: &warnings
        )
        let configuredInstanceId = resolveString(
            envKey: .instanceId,
            plistKey: .instanceId,
            as: InsideJobInstanceID.self,
            env: env,
            plist: plist,
            absentSource: .generated,
            warnings: &warnings
        )
        let configuredPort = resolvePort(env: env, plist: plist, warnings: &warnings)
        let configuredAllowedScopes = resolveAllowedScopes(env: env, plist: plist, warnings: &warnings)
        let sessionTimeout = resolveTimeInterval(
            envKey: .sessionTimeout,
            plistKey: .sessionTimeout,
            defaultValue: defaultSessionTimeout,
            clamp: { min(max(minimumSessionTimeout, $0), maximumSessionTimeout) },
            env: env,
            plist: plist,
            warnings: &warnings
        )
        let failureEvidencePolicy = resolveFailureEvidencePolicy(
            env: env,
            plist: plist,
            warnings: &warnings
        )

        let token = input.token.map {
            ResolvedConfigurationValue(value: $0, source: .api)
        } ?? configuredToken.value.map {
            ResolvedConfigurationValue(value: $0, source: configuredToken.source)
        } ?? ResolvedConfigurationValue(value: generatedSessionToken(), source: .generated)
        let instanceId = input.instanceId.map {
            ResolvedConfigurationValue<InsideJobInstanceID?>(value: $0, source: .api)
        } ?? (input.usesConfiguredInstanceId
            ? configuredInstanceId
            : ResolvedConfigurationValue(value: nil, source: .generated))

        return InsideJobRuntimeConfiguration(
            disableAutoStart: disableAutoStart,
            token: token,
            preferredPort: input.preferredPort.map {
                ResolvedConfigurationValue(value: $0, source: $0 == 0 ? .defaultValue : .api)
            } ?? configuredPort,
            allowedScopes: input.allowedScopes.map {
                ResolvedConfigurationValue(value: $0, source: .api)
            } ?? configuredAllowedScopes,
            addressFamily: input.addressFamily,
            sessionReleaseTimeout: sessionTimeout,
            fingerprintsEnabled: input.fingerprintsEnabled.map {
                ResolvedConfigurationValue(value: $0, source: .api)
            } ?? fingerprintsEnabled,
            failureEvidencePolicy: failureEvidencePolicy,
            authenticationPolicy: input.authenticationPolicy,
            sessionIdentity: InsideJobSessionIdentity.resolve(instanceId: instanceId),
            warnings: warnings
        )
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

    private static func resolveString<Value: NonBlankStringValue>(
        envKey: StartupEnvironmentKey,
        plistKey: StartupInfoPlistKey,
        as _: Value.Type,
        env: StartupEnvironment,
        plist: StartupInfoPlist,
        absentSource: InsideJobConfigurationSource,
        warnings: inout [InsideJobConfigurationWarning]
    ) -> ResolvedConfigurationValue<Value?> {
        if let envValue = env[envKey] {
            if let value = try? Value(validating: envValue) {
                return ResolvedConfigurationValue(value: value, source: .environment)
            }
            warnings.append(.emptyValueIgnored(key: envKey.rawValue, source: .environment))
        }

        if let plistValue = plist[plistKey]?.string {
            if let value = try? Value(validating: plistValue) {
                return ResolvedConfigurationValue(value: value, source: .infoPlist)
            }
            warnings.append(.emptyValueIgnored(key: plistKey.rawValue, source: .infoPlist))
        }

        return ResolvedConfigurationValue(value: nil, source: absentSource)
    }

    private static func resolvePort(
        env: StartupEnvironment,
        plist: StartupInfoPlist,
        warnings: inout [InsideJobConfigurationWarning]
    ) -> ResolvedConfigurationValue<UInt16> {
        if let envValue = env[.port] {
            if let parsed = parsePort(envValue) {
                return ResolvedConfigurationValue(value: parsed, source: .environment)
            }
            warnings.append(.invalidValueIgnored(
                key: StartupEnvironmentKey.port.rawValue,
                source: .environment,
                value: envValue
            ))
        }

        if let plistValue = plist[.port],
           let parsed = parsePort(plistValue) {
            return ResolvedConfigurationValue(value: parsed, source: .infoPlist)
        } else if let plistValue = plist[.port] {
            warnings.append(.invalidValueIgnored(
                key: StartupInfoPlistKey.port.rawValue,
                source: .infoPlist,
                value: String(describing: plistValue)
            ))
        }

        return ResolvedConfigurationValue(value: 0, source: .defaultValue)
    }

    private static func parsePort(_ value: String) -> UInt16? {
        UInt16(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parsePort(_ value: InfoPlistValue) -> UInt16? {
        if let number = value.number,
           number.rounded(.towardZero) == number,
           number >= 0,
           number <= Double(UInt16.max) {
            return UInt16(number)
        }
        return nil
    }

    private static func resolveTimeInterval(
        envKey: StartupEnvironmentKey,
        plistKey: StartupInfoPlistKey,
        defaultValue: TimeInterval,
        clamp: (TimeInterval) -> TimeInterval,
        env: StartupEnvironment,
        plist: StartupInfoPlist,
        warnings: inout [InsideJobConfigurationWarning]
    ) -> ResolvedConfigurationValue<TimeInterval> {
        if let envValue = env[envKey] {
            if let parsed = parseTimeInterval(envValue) {
                return ResolvedConfigurationValue(value: clamp(parsed), source: .environment)
            }
            warnings.append(.invalidValueIgnored(key: envKey.rawValue, source: .environment, value: envValue))
        }

        if let plistValue = plist[plistKey] {
            if let parsed = parseTimeInterval(plistValue) {
                return ResolvedConfigurationValue(value: clamp(parsed), source: .infoPlist)
            }
            warnings.append(.invalidValueIgnored(
                key: plistKey.rawValue,
                source: .infoPlist,
                value: String(describing: plistValue)
            ))
        }

        return ResolvedConfigurationValue(value: defaultValue, source: .defaultValue)
    }

    private static func parseTimeInterval(_ value: String) -> TimeInterval? {
        TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseTimeInterval(_ value: InfoPlistValue) -> TimeInterval? {
        value.number
    }

    private static func resolveAllowedScopes(
        env: StartupEnvironment,
        plist: StartupInfoPlist,
        warnings: inout [InsideJobConfigurationWarning]
    ) -> ResolvedConfigurationValue<Set<ConnectionScope>> {
        if let envValue = env[.scope] {
            if let parsed = ConnectionScope.parse(envValue) {
                return ResolvedConfigurationValue(value: parsed, source: .environment)
            }
            warnings.append(.invalidValueIgnored(
                key: StartupEnvironmentKey.scope.rawValue,
                source: .environment,
                value: envValue
            ))
        }

        if let plistValue = plist[.scope] {
            if let parsed = parseScopes(plistValue) {
                return ResolvedConfigurationValue(value: parsed, source: .infoPlist)
            }
            warnings.append(.invalidValueIgnored(
                key: StartupInfoPlistKey.scope.rawValue,
                source: .infoPlist,
                value: String(describing: plistValue)
            ))
        }

        return ResolvedConfigurationValue(value: ConnectionScope.default, source: .defaultValue)
    }

    private static func parseScopes(_ value: InfoPlistValue) -> Set<ConnectionScope>? {
        if let strings = value.stringArray {
            return ConnectionScope.parse(strings.joined(separator: ","))
        }
        return nil
    }

    private static func resolveBool(
        envKey: StartupEnvironmentKey,
        plistKey: StartupInfoPlistKey,
        defaultValue: Bool,
        env: StartupEnvironment,
        plist: StartupInfoPlist,
        warnings: inout [InsideJobConfigurationWarning]
    ) -> ResolvedConfigurationValue<Bool> {
        if let envValue = env[envKey] {
            if let parsed = parseBool(envValue) {
                return ResolvedConfigurationValue(value: parsed, source: .environment)
            }
            warnings.append(.invalidValueIgnored(key: envKey.rawValue, source: .environment, value: envValue))
        }

        if let plistValue = plist[plistKey] {
            if let parsed = parseBool(plistValue) {
                return ResolvedConfigurationValue(value: parsed, source: .infoPlist)
            }
            warnings.append(.invalidValueIgnored(
                key: plistKey.rawValue,
                source: .infoPlist,
                value: String(describing: plistValue)
            ))
        }

        return ResolvedConfigurationValue(value: defaultValue, source: .defaultValue)
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    private static func parseBool(_ value: InfoPlistValue) -> Bool? {
        value.bool
    }

    private static func resolveFailureEvidencePolicy(
        env: StartupEnvironment,
        plist: StartupInfoPlist,
        warnings: inout [InsideJobConfigurationWarning]
    ) -> ResolvedConfigurationValue<FailureEvidencePolicy> {
        if let envValue = env[.failureEvidence] {
            if let parsed = FailureEvidencePolicy(rawValue: envValue) {
                return ResolvedConfigurationValue(value: parsed, source: .environment)
            }
            warnings.append(.invalidValueIgnored(
                key: StartupEnvironmentKey.failureEvidence.rawValue,
                source: .environment,
                value: envValue
            ))
        }

        if let plistValue = plist[.failureEvidence] {
            if let string = plistValue.string,
               let parsed = FailureEvidencePolicy(rawValue: string) {
                return ResolvedConfigurationValue(value: parsed, source: .infoPlist)
            }
            warnings.append(.invalidValueIgnored(
                key: StartupInfoPlistKey.failureEvidence.rawValue,
                source: .infoPlist,
                value: String(describing: plistValue)
            ))
        }

        return ResolvedConfigurationValue(value: .screenshot, source: .defaultValue)
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
