import Foundation
import ThePlans
import XCTest

@testable import ButtonHeistCLIExe

final class PlanCommandTests: XCTestCase {
    func testValidateRejectsStandaloneJSON() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("plan.json")
        try plan().canonicalHeistJSONData().write(to: input)

        let command = try PlanCommand.Validate.parse([input.path])

        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertTrue(String(describing: error).contains("Unsupported heist input extension"))
        }
    }

    func testCanonicalizeWritesEquivalentHeistArtifact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.heist")
        let output = directory.appendingPathComponent("output.heist")
        let expected = try plan()
        try HeistArtifactCodec.writePlan(expected, to: input)

        let command = try PlanCommand.Canonicalize.parse([
            input.path,
            "--output", output.path,
        ])
        try command.run()

        XCTAssertEqual(try HeistArtifactCodec.readPlan(from: output), expected)
    }

    private func plan() throws -> HeistPlan {
        try HeistPlan("planCommandTest") {
            Warn("done")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buttonheist-plan-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
