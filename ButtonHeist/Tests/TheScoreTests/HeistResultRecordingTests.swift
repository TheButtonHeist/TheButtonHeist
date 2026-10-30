import ButtonHeistTestSupport
import Foundation
import ThePlans
import Testing
@testable import TheScore

@Suite(.serialized) struct HeistResultRecordingTests {

    @MainActor
    @Test func `recording remains self contained after move and rename`() async throws {
        try await withTemporaryDirectory(prefix: "heist-result-recorder") { directory in
            let plan = try samplePlan()
            let result = failedResult()
            let originalURL = try #require(try await HeistResultRecording.write(
                result,
                plan: plan,
                configuration: HeistResultRecordingConfiguration(rootDirectory: directory, mode: .failures)
            ))
            let movedDirectory = directory.appendingPathComponent("moved", isDirectory: true)
            try FileManager.default.createDirectory(at: movedDirectory, withIntermediateDirectories: true)
            let renamedURL = movedDirectory.appendingPathComponent("renamed-recording")
            try FileManager.default.moveItem(at: originalURL, to: renamedURL)

            let recording = try HeistResultCodec.decode(contentsOf: renamedURL)
            #expect(recording.schemaVersion == HeistResultRecording.currentSchemaVersion)
            #expect(recording.result == result)
            #expect(recording.planName == "Checkout_Flow")
            #expect(recording.planFingerprint == (try HeistResultRecording.planFingerprint(for: plan)))
            #expect(recording.recordedAt <= Date())
            #expect(recording.producerVersion == buttonHeistVersion)
        }
    }

    @Test func `skip passing result unless mode records passing`() async throws {
        try await withTemporaryDirectory(prefix: "heist-result-recorder") { directory in
            let plan = try samplePlan()
            let result = passedResult()

            let skipped = try await HeistResultRecording.write(
                result,
                plan: plan,
                configuration: HeistResultRecordingConfiguration(rootDirectory: directory, mode: .failures)
            )
            let recording = try #require(try await HeistResultRecording.write(
                result,
                plan: plan,
                configuration: HeistResultRecordingConfiguration(rootDirectory: directory, mode: .all)
            ))

            #expect(skipped == nil)
            #expect(try HeistResultCodec.decode(contentsOf: recording).result == result)
        }
    }

    @Test func `recording round trips complete provenance`() throws {
        let recordedAt = Date(timeIntervalSince1970: 1_753_800_123.456)
        let producerVersion: ButtonHeistVersion = "1.2.3"
        let plan = try samplePlan()
        let recording = try HeistResultRecording(
            result: failedResult(),
            plan: plan,
            recordedAt: recordedAt,
            producerVersion: producerVersion
        )

        let decoded = try HeistResultCodec.decode(HeistResultCodec.encode(recording))

        #expect(decoded == recording)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.result == failedResult())
        #expect(decoded.planName == plan.name)
        #expect(decoded.planFingerprint == (try HeistResultRecording.planFingerprint(for: plan)))
        #expect(decoded.recordedAt == recordedAt)
        #expect(decoded.producerVersion == producerVersion)
    }

    @Test func `recording root has one exact shape`() throws {
        let recording = try HeistResultRecording(result: passedResult(), plan: samplePlan())
        let data = try HeistResultCodec.encode(recording)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == [
            "schemaVersion",
            "result",
            "planName",
            "planFingerprint",
            "recordedAt",
            "producerVersion",
        ])
        #expect(object["outcome"] == nil)
    }

    @Test func `recording rejects unknown root key`() throws {
        let recording = try HeistResultRecording(result: passedResult(), plan: samplePlan())
        var object = try recordingJSONObject(recording)
        object["legacyResult"] = object["result"]

        #expect(throws: DecodingError.self) {
            _ = try HeistResultCodec.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func `recording rejects unsupported schema version`() throws {
        let recording = try HeistResultRecording(result: passedResult(), plan: samplePlan())
        var object = try recordingJSONObject(recording)
        object["schemaVersion"] = 2

        #expect(throws: HeistResultRecordingError.unsupportedSchemaVersion(2)) {
            _ = try HeistResultCodec.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func `recording preserves bounded result admission`() throws {
        let result = HeistResultFixture.result(steps: [
            HeistResultFixture.warning(path: "$.body[0]", message: "first"),
            HeistResultFixture.warning(path: "$.body[1]", message: "second"),
        ])
        let recording = try HeistResultRecording(result: result, plan: samplePlan())
        let data = try HeistResultCodec.encode(recording)
        let limits = HeistResultCodecLimits(
            maxGzipCompressedBytes: 1_024,
            maxGzipDecompressedBytes: 1_024,
            maxNodeCount: 1
        )

        #expect(throws: DecodingError.self) {
            _ = try HeistResultCodec.decode(data, limits: limits)
        }
    }

    @Test func `recording modes decide from canonical result outcome`() {
        let failed = failedResult()
        let passed = passedResult()

        let expectations: [(HeistResultRecordingMode, failure: Bool, passing: Bool)] = [
            (.off, false, false),
            (.failures, true, false),
            (.all, true, true),
        ]
        for (mode, failure, passing) in expectations {
            #expect(mode.shouldRecord(failed) == failure)
            #expect(mode.shouldRecord(passed) == passing)
        }
    }

    @Test func `scoped recorder disables and restores ambient failure collection`() async throws {
        try await withResultDirectory(prefix: "heist-result-recorder-scope") { directory in
            let previousDirectory = EnvironmentKey.buttonheistResultsDir.value
            let previousMode = EnvironmentKey.buttonheistResultsMode.value
            setEnvironment(EnvironmentKey.buttonheistResultsDir.rawValue, directory.path)
            setEnvironment(EnvironmentKey.buttonheistResultsMode.rawValue, HeistResultRecordingMode.failures.rawValue)
            defer {
                setEnvironment(EnvironmentKey.buttonheistResultsDir.rawValue, previousDirectory)
                setEnvironment(EnvironmentKey.buttonheistResultsMode.rawValue, previousMode)
            }

            let before = await HeistResultRecording.recordIfEnabled(
                failedResult(),
                plan: try samplePlan()
            )
            let skipped = try await HeistResultRecording.withEnvironmentRecording(false) {
                await HeistResultRecording.recordIfEnabled(failedResult(), plan: try samplePlan())
            }
            let after = await HeistResultRecording.recordIfEnabled(
                failedResult(),
                plan: try samplePlan()
            )

            #expect(before != nil)
            #expect(skipped == nil)
            #expect(after != nil)
            #expect(try resultArtifactURLs(in: directory).count == 2)
        }
    }

    @Test func `environment resolves process temp and rejects unknown mode`() throws {
        let previousDirectory = EnvironmentKey.buttonheistResultsDir.value
        let previousMode = EnvironmentKey.buttonheistResultsMode.value
        setEnvironment(
            EnvironmentKey.buttonheistResultsDir.rawValue,
            HeistResultRecordingConfiguration.processTemporaryDirectoryValue
        )
        setEnvironment(EnvironmentKey.buttonheistResultsMode.rawValue, nil)
        defer {
            setEnvironment(EnvironmentKey.buttonheistResultsDir.rawValue, previousDirectory)
            setEnvironment(EnvironmentKey.buttonheistResultsMode.rawValue, previousMode)
        }

        let configuration = try #require(try HeistResultRecordingConfiguration.environment)
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let rootDirectory = configuration.rootDirectory.standardizedFileURL.path

        #expect(rootDirectory.hasPrefix(temporaryDirectory))
        #expect(configuration.rootDirectory.lastPathComponent == "buttonheist-results")

        setEnvironment(EnvironmentKey.buttonheistResultsMode.rawValue, "failed")
        #expect(throws: HeistResultRecordingError.invalidMode("failed")) {
            _ = try HeistResultRecordingConfiguration.environment
        }

        setEnvironment(EnvironmentKey.buttonheistResultsMode.rawValue, "off")
        #expect(try HeistResultRecordingConfiguration.environment?.mode == .off)
    }

    @Test func `result mode parser accepts only canonical spellings`() throws {
        #expect(try HeistResultRecordingMode(environmentValue: nil) == .failures)
        #expect(try HeistResultRecordingMode(environmentValue: "off") == .off)
        #expect(try HeistResultRecordingMode(environmentValue: "failures") == .failures)
        #expect(try HeistResultRecordingMode(environmentValue: "all") == .all)

        for value in ["passing-and-failing", "failed", "always", "ALL"] {
            #expect(throws: HeistResultRecordingError.invalidMode(value)) {
                _ = try HeistResultRecordingMode(environmentValue: value)
            }
        }
    }

    private func samplePlan() throws -> HeistPlan {
        try HeistPlan(
            name: "Checkout_Flow",
            body: [.warn(WarnStep(message: "record result"))]
        )
    }

    private func failedResult() -> HeistResult {
        HeistResultFixture.result(
            steps: [HeistResultFixture.explicitFailure(path: "$.body[0]", message: "boom")],
            durationMs: 3
        )
    }

    private func passedResult() -> HeistResult {
        HeistResultFixture.result(
            steps: [HeistResultFixture.warning(path: "$.body[0]", message: "record result")],
            durationMs: 2
        )
    }

    private func recordingJSONObject(_ recording: HeistResultRecording) throws -> [String: Any] {
        let data = try HeistResultCodec.encode(recording)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func setEnvironment(_ key: String, _ value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}
