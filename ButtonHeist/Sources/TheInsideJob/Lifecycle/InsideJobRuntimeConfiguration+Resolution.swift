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

private struct StartupConfigurationResolver {
    let environment: StartupEnvironment
    let infoPlist: StartupInfoPlist
    private(set) var warnings: [InsideJobConfigurationWarning] = []

    mutating func resolve<Value: Equatable & Sendable>(
        environmentKey: StartupEnvironmentKey,
        infoPlistKey: StartupInfoPlistKey,
        defaultValue: Value,
        parseEnvironment: (String) -> Value?,
        parseInfoPlist: (InfoPlistValue) -> Value?
    ) -> ResolvedConfigurationValue<Value> {
        if let rawValue = environment[environmentKey] {
            if let value = parseEnvironment(rawValue) {
                return ResolvedConfigurationValue(value: value, source: .environment)
            }
            warnings.append(.invalidValueIgnored(
                key: environmentKey.rawValue,
                source: .environment,
                value: rawValue
            ))
        }

        if let rawValue = infoPlist[infoPlistKey] {
            if let value = parseInfoPlist(rawValue) {
                return ResolvedConfigurationValue(value: value, source: .infoPlist)
            }
            warnings.append(.invalidValueIgnored(
                key: infoPlistKey.rawValue,
                source: .infoPlist,
                value: String(describing: rawValue)
            ))
        }

        return ResolvedConfigurationValue(value: defaultValue, source: .defaultValue)
    }

    mutating func resolveString<Value: NonBlankStringValue>(
        environmentKey: StartupEnvironmentKey,
        infoPlistKey: StartupInfoPlistKey,
        as _: Value.Type,
        absentSource: InsideJobConfigurationSource
    ) -> ResolvedConfigurationValue<Value?> {
        if let rawValue = environment[environmentKey] {
            if let value = try? Value(validating: rawValue) {
                return ResolvedConfigurationValue(value: value, source: .environment)
            }
            warnings.append(.emptyValueIgnored(key: environmentKey.rawValue, source: .environment))
        }

        if let rawValue = infoPlist[infoPlistKey]?.string {
            if let value = try? Value(validating: rawValue) {
                return ResolvedConfigurationValue(value: value, source: .infoPlist)
            }
            warnings.append(.emptyValueIgnored(key: infoPlistKey.rawValue, source: .infoPlist))
        }

        return ResolvedConfigurationValue(value: nil, source: absentSource)
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
        var resolver = StartupConfigurationResolver(environment: env, infoPlist: infoPlist)
        let disableAutoStart = resolver.resolve(
            environmentKey: .disableAutoStart,
            infoPlistKey: .disableAutoStart,
            defaultValue: false,
            parseEnvironment: parseBool,
            parseInfoPlist: parseBool
        )
        let fingerprintsEnabled = resolver.resolve(
            environmentKey: .fingerprintsEnabled,
            infoPlistKey: .fingerprintsEnabled,
            defaultValue: true,
            parseEnvironment: parseBool,
            parseInfoPlist: parseBool
        )
        let configuredToken = resolver.resolveString(
            environmentKey: .token,
            infoPlistKey: .token,
            as: SessionAuthToken.self,
            absentSource: .generated
        )
        let configuredInstanceId = resolver.resolveString(
            environmentKey: .instanceId,
            infoPlistKey: .instanceId,
            as: InsideJobInstanceID.self,
            absentSource: .generated
        )
        let configuredPort = resolver.resolve(
            environmentKey: .port,
            infoPlistKey: .port,
            defaultValue: 0,
            parseEnvironment: parsePort,
            parseInfoPlist: parsePort
        )
        let configuredAllowedScopes = resolver.resolve(
            environmentKey: .scope,
            infoPlistKey: .scope,
            defaultValue: ConnectionScope.default,
            parseEnvironment: ConnectionScope.parse,
            parseInfoPlist: parseScopes
        )
        let sessionTimeout = resolver.resolve(
            environmentKey: .sessionTimeout,
            infoPlistKey: .sessionTimeout,
            defaultValue: defaultSessionTimeout,
            parseEnvironment: {
                parseTimeInterval($0).map {
                    min(max(minimumSessionTimeout, $0), maximumSessionTimeout)
                }
            },
            parseInfoPlist: {
                parseTimeInterval($0).map {
                    min(max(minimumSessionTimeout, $0), maximumSessionTimeout)
                }
            }
        )
        let failureEvidencePolicy = resolver.resolve(
            environmentKey: .failureEvidence,
            infoPlistKey: .failureEvidence,
            defaultValue: FailureEvidencePolicy.screenshot,
            parseEnvironment: FailureEvidencePolicy.init(rawValue:),
            parseInfoPlist: { $0.string.flatMap(FailureEvidencePolicy.init(rawValue:)) }
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
            warnings: resolver.warnings
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

    private static func parseTimeInterval(_ value: String) -> TimeInterval? {
        TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseTimeInterval(_ value: InfoPlistValue) -> TimeInterval? {
        value.number
    }

    private static func parseScopes(_ value: InfoPlistValue) -> Set<ConnectionScope>? {
        if let strings = value.stringArray {
            return ConnectionScope.parse(strings.joined(separator: ","))
        }
        return nil
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
}

#endif // DEBUG
#endif // canImport(UIKit)
