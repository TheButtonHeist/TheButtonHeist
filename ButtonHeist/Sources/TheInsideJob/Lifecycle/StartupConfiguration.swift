#if canImport(UIKit)
#if DEBUG
import Foundation

import ThePlans
import TheScore

enum StartupConfigurationSource: String, Sendable {
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

struct ResolvedStartupValue<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
    let source: StartupConfigurationSource
}

enum StartupConfigurationWarning: Equatable, Sendable {
    case emptyValueIgnored(key: String, source: StartupConfigurationSource)
    case invalidValueIgnored(key: String, source: StartupConfigurationSource, value: String)

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

struct StartupConfiguration: Equatable, Sendable {
    static let defaultSessionTimeout: TimeInterval = 30.0
    static let minimumSessionTimeout: TimeInterval = 1.0
    static let maximumSessionTimeout: TimeInterval = 3600.0

    let disableAutoStart: ResolvedStartupValue<Bool>
    let fingerprintsEnabled: ResolvedStartupValue<Bool>
    let token: ResolvedStartupValue<SessionAuthToken?>
    let instanceId: ResolvedStartupValue<InsideJobInstanceID?>
    let preferredPort: ResolvedStartupValue<UInt16>
    let allowedScopes: ResolvedStartupValue<Set<ConnectionScope>>
    let sessionTimeout: ResolvedStartupValue<TimeInterval>
    let failureEvidencePolicy: ResolvedStartupValue<FailureEvidencePolicy>
    let warnings: [StartupConfigurationWarning]

    init(
        disableAutoStart: ResolvedStartupValue<Bool>,
        token: ResolvedStartupValue<SessionAuthToken?>,
        instanceId: ResolvedStartupValue<InsideJobInstanceID?>,
        preferredPort: ResolvedStartupValue<UInt16>,
        allowedScopes: ResolvedStartupValue<Set<ConnectionScope>>,
        sessionTimeout: ResolvedStartupValue<TimeInterval>,
        failureEvidencePolicy: ResolvedStartupValue<FailureEvidencePolicy> = ResolvedStartupValue(value: .screenshot, source: .defaultValue),
        fingerprintsEnabled: ResolvedStartupValue<Bool> = ResolvedStartupValue(value: true, source: .defaultValue),
        warnings: [StartupConfigurationWarning]
    ) {
        self.disableAutoStart = disableAutoStart
        self.fingerprintsEnabled = fingerprintsEnabled
        self.token = token
        self.instanceId = instanceId
        self.preferredPort = preferredPort
        self.allowedScopes = allowedScopes
        self.sessionTimeout = sessionTimeout
        self.failureEvidencePolicy = failureEvidencePolicy
        self.warnings = warnings
    }

    static func resolve(
        env: StartupEnvironment = .current,
        infoPlist: StartupInfoPlist = .main
    ) -> StartupConfiguration {
        var warnings: [StartupConfigurationWarning] = []
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
        let token = resolveString(
            envKey: .token,
            plistKey: .token,
            as: SessionAuthToken.self,
            env: env,
            plist: plist,
            absentSource: .generated,
            warnings: &warnings
        )
        let instanceId = resolveString(
            envKey: .instanceId,
            plistKey: .instanceId,
            as: InsideJobInstanceID.self,
            env: env,
            plist: plist,
            absentSource: .generated,
            warnings: &warnings
        )
        let preferredPort = resolvePort(env: env, plist: plist, warnings: &warnings)
        let allowedScopes = resolveAllowedScopes(env: env, plist: plist, warnings: &warnings)
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

        return StartupConfiguration(
            disableAutoStart: disableAutoStart,
            token: token,
            instanceId: instanceId,
            preferredPort: preferredPort,
            allowedScopes: allowedScopes,
            sessionTimeout: sessionTimeout,
            failureEvidencePolicy: failureEvidencePolicy,
            fingerprintsEnabled: fingerprintsEnabled,
            warnings: warnings
        )
    }

    private static func resolveString<Value: NonBlankStringValue>(
        envKey: StartupEnvironmentKey,
        plistKey: StartupInfoPlistKey,
        as _: Value.Type,
        env: StartupEnvironment,
        plist: StartupInfoPlist,
        absentSource: StartupConfigurationSource,
        warnings: inout [StartupConfigurationWarning]
    ) -> ResolvedStartupValue<Value?> {
        if let envValue = env[envKey] {
            if let value = try? Value(validating: envValue) {
                return ResolvedStartupValue(value: value, source: .environment)
            }
            warnings.append(.emptyValueIgnored(key: envKey.rawValue, source: .environment))
        }

        if let plistValue = plist[plistKey]?.string {
            if let value = try? Value(validating: plistValue) {
                return ResolvedStartupValue(value: value, source: .infoPlist)
            }
            warnings.append(.emptyValueIgnored(key: plistKey.rawValue, source: .infoPlist))
        }

        return ResolvedStartupValue(value: nil, source: absentSource)
    }

    private static func resolvePort(
        env: StartupEnvironment,
        plist: StartupInfoPlist,
        warnings: inout [StartupConfigurationWarning]
    ) -> ResolvedStartupValue<UInt16> {
        if let envValue = env[.port] {
            if let parsed = parsePort(envValue) {
                return ResolvedStartupValue(value: parsed, source: .environment)
            }
            warnings.append(.invalidValueIgnored(
                key: StartupEnvironmentKey.port.rawValue,
                source: .environment,
                value: envValue
            ))
        }

        if let plistValue = plist[.port],
           let parsed = parsePort(plistValue) {
            return ResolvedStartupValue(value: parsed, source: .infoPlist)
        } else if let plistValue = plist[.port] {
            warnings.append(.invalidValueIgnored(
                key: StartupInfoPlistKey.port.rawValue,
                source: .infoPlist,
                value: String(describing: plistValue)
            ))
        }

        return ResolvedStartupValue(value: 0, source: .defaultValue)
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
        warnings: inout [StartupConfigurationWarning]
    ) -> ResolvedStartupValue<TimeInterval> {
        if let envValue = env[envKey] {
            if let parsed = parseTimeInterval(envValue) {
                return ResolvedStartupValue(value: clamp(parsed), source: .environment)
            }
            warnings.append(.invalidValueIgnored(key: envKey.rawValue, source: .environment, value: envValue))
        }

        if let plistValue = plist[plistKey] {
            if let parsed = parseTimeInterval(plistValue) {
                return ResolvedStartupValue(value: clamp(parsed), source: .infoPlist)
            }
            warnings.append(.invalidValueIgnored(
                key: plistKey.rawValue,
                source: .infoPlist,
                value: String(describing: plistValue)
            ))
        }

        return ResolvedStartupValue(value: defaultValue, source: .defaultValue)
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
        warnings: inout [StartupConfigurationWarning]
    ) -> ResolvedStartupValue<Set<ConnectionScope>> {
        if let envValue = env[.scope] {
            if let parsed = ConnectionScope.parse(envValue) {
                return ResolvedStartupValue(value: parsed, source: .environment)
            }
            warnings.append(.invalidValueIgnored(
                key: StartupEnvironmentKey.scope.rawValue,
                source: .environment,
                value: envValue
            ))
        }

        if let plistValue = plist[.scope] {
            if let parsed = parseScopes(plistValue) {
                return ResolvedStartupValue(value: parsed, source: .infoPlist)
            }
            warnings.append(.invalidValueIgnored(
                key: StartupInfoPlistKey.scope.rawValue,
                source: .infoPlist,
                value: String(describing: plistValue)
            ))
        }

        return ResolvedStartupValue(value: ConnectionScope.default, source: .defaultValue)
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
        warnings: inout [StartupConfigurationWarning]
    ) -> ResolvedStartupValue<Bool> {
        if let envValue = env[envKey] {
            if let parsed = parseBool(envValue) {
                return ResolvedStartupValue(value: parsed, source: .environment)
            }
            warnings.append(.invalidValueIgnored(key: envKey.rawValue, source: .environment, value: envValue))
        }

        if let plistValue = plist[plistKey] {
            if let parsed = parseBool(plistValue) {
                return ResolvedStartupValue(value: parsed, source: .infoPlist)
            }
            warnings.append(.invalidValueIgnored(
                key: plistKey.rawValue,
                source: .infoPlist,
                value: String(describing: plistValue)
            ))
        }

        return ResolvedStartupValue(value: defaultValue, source: .defaultValue)
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
        warnings: inout [StartupConfigurationWarning]
    ) -> ResolvedStartupValue<FailureEvidencePolicy> {
        if let envValue = env[.failureEvidence] {
            if let parsed = FailureEvidencePolicy(rawValue: envValue) {
                return ResolvedStartupValue(value: parsed, source: .environment)
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
                return ResolvedStartupValue(value: parsed, source: .infoPlist)
            }
            warnings.append(.invalidValueIgnored(
                key: StartupInfoPlistKey.failureEvidence.rawValue,
                source: .infoPlist,
                value: String(describing: plistValue)
            ))
        }

        return ResolvedStartupValue(value: .screenshot, source: .defaultValue)
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
