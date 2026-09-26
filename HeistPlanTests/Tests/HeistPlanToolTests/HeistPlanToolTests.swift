import Foundation
import Testing
import ThePlans

@Suite(.serialized)
struct HeistPlanToolTests {
    @Test
    func `validate succeeds for a valid fixture`() throws {
        let temp = try TemporaryDirectory()
        let planURL = temp.url.appendingPathComponent("valid.heist")
        try HeistArtifactCodec.writePlan(representativePlan(), to: planURL)

        let result = try runHeistPlan(["validate", planURL.path])

        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout.isEmpty)
    }

    @Test
    func `validate rejects standalone JSON plan input`() throws {
        let temp = try TemporaryDirectory()
        let planURL = temp.url.appendingPathComponent("standalone.json")
        try writeCanonicalJSON(representativePlan(), to: planURL)

        let result = try runHeistPlan(["validate", planURL.path])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Unsupported heist input extension"))
        #expect(result.stderr.contains("Use a generated .heist package artifact"))
    }

    @Test
    func `validate fails for raw JSON with heist extension`() throws {
        let temp = try TemporaryDirectory()
        let planURL = temp.url.appendingPathComponent("raw.heist")
        try writeCanonicalJSON(representativePlan(), to: planURL)

        let result = try runHeistPlan(["validate", planURL.path])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("raw JSON is not a .heist package"))
    }

    @Test
    func `validate fails for runtime-invalid plan with path and contract`() throws {
        let temp = try TemporaryDirectory()
        let planURL = temp.url.appendingPathComponent("runtime-invalid.heist")
        try writeRuntimeInvalidHeistArtifact(to: planURL)

        let result = try runHeistPlan(["validate", planURL.path])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("$.body[500]"))
        #expect(result.stderr.contains("max total heist steps"))
    }

    @Test
    func `render-swift prints canonical Swift`() throws {
        let temp = try TemporaryDirectory()
        let planURL = temp.url.appendingPathComponent("valid.heist")
        try HeistArtifactCodec.writePlan(representativePlan(), to: planURL)

        let result = try runHeistPlan(["render-swift", planURL.path])

        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout == """
        HeistPlan("loginFlow") {
            TypeText("alex@example.com", into: .identifier("email"))
                .expect(.elementsChanged([.updated(.identifier("email"), .value("alex@example.com"))]), timeout: 1)

            Warn("done")
        }

        """)
    }

    @Test
    func `canonicalize writes package JSON from plan`() throws {
        let temp = try TemporaryDirectory()
        let inputURL = temp.url.appendingPathComponent("input.heist")
        let outputURL = temp.url.appendingPathComponent("output.heist")
        let plan = try representativePlan()
        try HeistArtifactCodec.writePlan(plan, to: inputURL)

        let result = try runHeistPlan([
            "canonicalize",
            inputURL.path,
            "--output",
            outputURL.path,
        ])

        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout.isEmpty)
        let output = try String(contentsOf: outputURL.appendingPathComponent("plan.json"), encoding: .utf8)
        let expected = try String(data: plan.canonicalHeistJSONData() + Data([0x0A]), encoding: .utf8)
        #expect(output + "\n" == expected)
        #expect(FileManager.default.fileExists(atPath: outputURL.appendingPathComponent("manifest.json").path))
    }

    @Test
    func `canonicalize requires output and does not print plan JSON`() throws {
        let temp = try TemporaryDirectory()
        let inputURL = temp.url.appendingPathComponent("input.heist")
        try HeistArtifactCodec.writePlan(representativePlan(), to: inputURL)

        let result = try runHeistPlan(["canonicalize", inputURL.path])

        #expect(result.exitCode != 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("Missing expected argument '--output"))
    }

}

private func representativePlan() throws -> HeistPlan {
    try HeistPlan("loginFlow") {
        TypeText("alex@example.com", into: .identifier("email"))
            .expect(.elementsChanged([
                .updated(.identifier("email"), .value("alex@example.com")),
            ]), timeout: 1)

        Warn("done")
    }
}

private func writeCanonicalJSON(_ plan: HeistPlan, to url: URL) throws {
    try plan.canonicalHeistJSONData().write(to: url)
}

private func writeRuntimeInvalidHeistArtifact(to url: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    let manifest = HeistArtifactManifest(
        format: .buttonHeist,
        entry: "tooManySteps",
        formatVersion: currentHeistArtifactFormatVersion,
        planVersion: currentHeistPlanVersion,
        producer: .buttonHeist,
        createdAt: Date(timeIntervalSince1970: 0)
    )
    try HeistArtifactCodec.canonicalManifestJSONData(manifest)
        .write(to: url.appendingPathComponent(HeistArtifactCodec.manifestFileName))
    try runtimeInvalidPlanJSONData()
        .write(to: url.appendingPathComponent(HeistArtifactCodec.planFileName))
}

private func runtimeInvalidPlanJSONData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(RuntimeInvalidPlanFixture(
        version: currentHeistPlanVersion,
        name: "tooManySteps",
        body: Array(repeating: RuntimeInvalidWarnStepFixture(message: "too many steps"), count: 501)
    ))
}

private struct RuntimeInvalidPlanFixture: Encodable {
    let version: Int
    let name: String
    let body: [RuntimeInvalidWarnStepFixture]
}

private struct RuntimeInvalidWarnStepFixture: Encodable {
    let type = "warn"
    let warn: RuntimeInvalidWarnPayloadFixture

    init(message: String) {
        self.warn = RuntimeInvalidWarnPayloadFixture(message: message)
    }
}

private struct RuntimeInvalidWarnPayloadFixture: Encodable {
    let message: String
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heist-plan-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct ToolResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private func runHeistPlan(_ arguments: [String]) throws -> ToolResult {
    let tool = try heistPlanToolURL()
    return try runProcess(executable: tool, arguments: arguments)
}

private func heistPlanToolURL() throws -> URL {
    if let path = ProcessInfo.processInfo.environment["HEIST_PLAN_TOOL"], !path.isEmpty {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
    }

    let testExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let debugDirectory = testExecutable
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let root = try repositoryRoot()
    let candidates = [
        debugDirectory.appendingPathComponent("heist-plan"),
        testExecutable.deletingLastPathComponent().appendingPathComponent("heist-plan"),
        root.appendingPathComponent(".build/debug/heist-plan"),
    ]
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    throw TestFailure("heist-plan executable was not built")
}

private func runProcess(executable: URL, arguments: [String]) throws -> ToolResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments

    let capture = try ToolOutputCapture()
    process.standardOutput = capture.stdoutHandle
    process.standardError = capture.stderrHandle

    try process.run()
    process.waitUntilExit()

    try capture.close()
    return ToolResult(
        exitCode: process.terminationStatus,
        stdout: try capture.stdoutString(),
        stderr: try capture.stderrString()
    )
}

private final class ToolOutputCapture {
    let stdoutURL: URL
    let stderrURL: URL
    let stdoutHandle: FileHandle
    let stderrHandle: FileHandle

    init() throws {
        let temp = FileManager.default.temporaryDirectory
        stdoutURL = temp.appendingPathComponent("heist-plan-tests-stdout-\(UUID().uuidString)")
        stderrURL = temp.appendingPathComponent("heist-plan-tests-stderr-\(UUID().uuidString)")
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        stderrHandle = try FileHandle(forWritingTo: stderrURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
    }

    func close() throws {
        try stdoutHandle.close()
        try stderrHandle.close()
    }

    func stdoutString() throws -> String {
        String(data: try Data(contentsOf: stdoutURL), encoding: .utf8) ?? ""
    }

    func stderrString() throws -> String {
        String(data: try Data(contentsOf: stderrURL), encoding: .utf8) ?? ""
    }
}

private func repositoryRoot() throws -> URL {
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    if isRepositoryRoot(currentDirectory) {
        return currentDirectory
    }

    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != candidate.deletingLastPathComponent().path {
        if isRepositoryRoot(candidate) {
            return candidate
        }
        candidate = candidate.deletingLastPathComponent()
    }

    throw TestFailure("could not find repository root")
}

private func isRepositoryRoot(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
        && FileManager.default.fileExists(atPath: url.appendingPathComponent("ButtonHeist/Sources/HeistPlanTool").path)
        && FileManager.default.fileExists(atPath: url.appendingPathComponent("HeistPlanTests/Package.swift").path)
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
