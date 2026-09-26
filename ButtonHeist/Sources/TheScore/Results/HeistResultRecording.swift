import CryptoKit
import Foundation
import OSLog
import ThePlans

private let heistResultLogger = ButtonHeistLog.logger(.score(.results))

package enum HeistResultRecordingMode: String, Sendable, Equatable {
    case off
    case failures
    case all

    package init?(environmentValue: String?) {
        guard let environmentValue = environmentValue?.nilIfBlank else {
            self = .failures
            return
        }
        guard let mode = Self(rawValue: environmentValue) else { return nil }
        self = mode
    }

    func shouldRecord(_ result: HeistResult) -> Bool {
        switch (self, result.outcome) {
        case (.off, _):
            return false
        case (.failures, .failed):
            return true
        case (.failures, .passed):
            return false
        case (.all, _):
            return true
        }
    }
}

package struct HeistResultRecordingConfiguration: Sendable, Equatable {
    package static let processTemporaryDirectoryValue = "process-temporary-directory"

    package let rootDirectory: URL
    package let mode: HeistResultRecordingMode

    package init(
        rootDirectory: URL,
        mode: HeistResultRecordingMode = .failures
    ) {
        self.rootDirectory = rootDirectory
        self.mode = mode
    }

    package static var environment: HeistResultRecordingConfiguration? {
        guard let directory = EnvironmentKey.buttonheistResultsDir.value?.nilIfBlank else {
            return nil
        }
        guard let mode = HeistResultRecordingMode(environmentValue: EnvironmentKey.buttonheistResultsMode.value) else {
            return nil
        }
        return HeistResultRecordingConfiguration(rootDirectory: rootDirectory(for: directory), mode: mode)
    }

    private static func rootDirectory(for value: String) -> URL {
        switch value {
        case processTemporaryDirectoryValue:
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("buttonheist-results", isDirectory: true)
        default:
            let expandedDirectory = (value as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expandedDirectory, isDirectory: true)
        }
    }
}

package enum HeistResultRecordingError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case invalidPlanFingerprint(String)

    package var description: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported heist result recording schema version: \(version)"
        case .invalidPlanFingerprint(let fingerprint):
            "Invalid heist plan fingerprint: \(fingerprint)"
        }
    }
}

package struct HeistResultRecording: Codable, Sendable, Equatable {
    package static let currentSchemaVersion = 1

    package var schemaVersion: Int { Self.currentSchemaVersion }
    package let result: HeistResult
    package let planName: HeistPlanName?
    package let planFingerprint: String
    package let recordedAt: Date
    package let producerVersion: ButtonHeistVersion

    package init(
        result: HeistResult,
        plan: HeistPlan,
        recordedAt: Date = Date(),
        producerVersion: ButtonHeistVersion = buttonHeistVersion
    ) throws {
        self.result = result
        planName = plan.name
        planFingerprint = try Self.planFingerprint(for: plan)
        self.recordedAt = recordedAt
        self.producerVersion = producerVersion
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case result
        case planName
        case planFingerprint
        case recordedAt
        case producerVersion
    }

    package init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "heist result recording")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw HeistResultRecordingError.unsupportedSchemaVersion(schemaVersion)
        }
        let planFingerprint = try container.decode(String.self, forKey: .planFingerprint)
        guard Self.isPlanFingerprint(planFingerprint) else {
            throw HeistResultRecordingError.invalidPlanFingerprint(planFingerprint)
        }
        let recordedAtSeconds = try container.decode(TimeInterval.self, forKey: .recordedAt)
        guard recordedAtSeconds.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .recordedAt,
                in: container,
                debugDescription: "Heist result recording time must be finite"
            )
        }

        result = try container.decode(HeistResult.self, forKey: .result)
        planName = try container.decode(HeistPlanName?.self, forKey: .planName)
        self.planFingerprint = planFingerprint
        recordedAt = Date(timeIntervalSince1970: recordedAtSeconds)
        producerVersion = try container.decode(ButtonHeistVersion.self, forKey: .producerVersion)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(result, forKey: .result)
        try container.encode(planName, forKey: .planName)
        try container.encode(planFingerprint, forKey: .planFingerprint)
        try container.encode(recordedAt.timeIntervalSince1970, forKey: .recordedAt)
        try container.encode(producerVersion, forKey: .producerVersion)
    }
}

extension HeistResultRecording {
    @TaskLocal package static var environmentRecordingEnabled = true

    package static func withEnvironmentRecording<Value>(
        _ enabled: Bool,
        operation: nonisolated(nonsending) @Sendable () async throws -> Value
    ) async rethrows -> Value {
        try await $environmentRecordingEnabled.withValue(enabled, operation: operation)
    }

    @discardableResult
    package static func recordIfEnabled(
        _ result: HeistResult,
        plan: HeistPlan
    ) -> URL? {
        guard environmentRecordingEnabled,
              let configuration = HeistResultRecordingConfiguration.environment
        else {
            return nil
        }
        do {
            return try write(result, plan: plan, configuration: configuration)
        } catch {
            heistResultLogger.warning("Failed to record heist result: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    package static func write(
        _ result: HeistResult,
        plan: HeistPlan,
        configuration: HeistResultRecordingConfiguration
    ) throws -> URL? {
        guard configuration.mode.shouldRecord(result) else {
            return nil
        }

        let recording = try HeistResultRecording(result: result, plan: plan)
        try FileManager.default.createDirectory(
            at: configuration.rootDirectory,
            withIntermediateDirectories: true
        )
        let url = configuration.rootDirectory
            .appendingPathComponent("\(UUID().uuidString).json.gz", isDirectory: false)
        try HeistResultCodec.write(recording, to: url)
        return url
    }

    package static func planFingerprint(for plan: HeistPlan) throws -> String {
        let data = try plan.canonicalHeistJSONData()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func isPlanFingerprint(_ value: String) -> Bool {
        value.utf8.count == 24 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
