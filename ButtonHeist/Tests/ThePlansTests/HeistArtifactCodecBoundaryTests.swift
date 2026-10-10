import Foundation
import Testing
@_spi(ButtonHeistInternals) import ThePlans

private struct EncodedHeistPlanHeaderContract: Decodable {
    let version: Int
    let name: String
}

@Test
func `heist artifact package writes manifest and canonical plan`() throws {
    let temp = try PlansTemporaryDirectory()
    let artifactURL = temp.url.appendingPathComponent("SearchFlow.heist")
    let plan = try representativeArtifactPlan()

    try HeistArtifactCodec.writePlan(plan, to: artifactURL)

    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: artifactURL.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)

    let manifestURL = artifactURL.appendingPathComponent("manifest.json")
    let planURL = artifactURL.appendingPathComponent("plan.json")
    #expect(FileManager.default.fileExists(atPath: manifestURL.path))
    #expect(FileManager.default.fileExists(atPath: planURL.path))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(HeistArtifactManifest.self, from: Data(contentsOf: manifestURL))
    #expect(manifest.format == .buttonHeist)
    #expect(manifest.formatVersion == currentHeistArtifactFormatVersion)

    let planObject = try JSONDecoder().decode(EncodedHeistPlanHeaderContract.self, from: Data(contentsOf: planURL))
    #expect(planObject.version == HeistPlan.currentVersion)
    #expect(planObject.name == "searchFlow")
    #expect(try HeistArtifactCodec.readPlan(from: artifactURL) == plan)
    #expect(try HeistArtifactCodec.read(from: artifactURL).plan.name == "searchFlow")
}

@Test
func `heist artifact plan identity is independent of output path`() throws {
    let temp = try PlansTemporaryDirectory()
    let artifactURL = temp.url.appendingPathComponent("CompletelyDifferent.heist")
    let plan = try representativeArtifactPlan()

    try HeistArtifactCodec.writePlan(plan, to: artifactURL)

    let artifact = try HeistArtifactCodec.read(from: artifactURL)
    #expect(artifact.plan.name == "searchFlow")
}

@Test
func `public artifact plan helpers reject standalone raw plan json`() throws {
    let temp = try PlansTemporaryDirectory()
    let jsonURL = temp.url.appendingPathComponent("SearchFlow.json")
    let plan = try HeistPlan(body: [.warn(WarnStep(message: "raw unnamed IR"))])

    try plan.canonicalHeistJSONData().write(to: jsonURL)

    #expect(throws: HeistArtifactCodecError.self) {
        try HeistArtifactCodec.readPlan(from: jsonURL)
    }
    #expect(throws: HeistArtifactCodecError.self) {
        try HeistArtifactCodec.writePlan(plan, to: jsonURL)
    }
}

@Test
func `public artifact package helpers require heist extension`() throws {
    let temp = try PlansTemporaryDirectory()
    let packageURL = temp.url.appendingPathComponent("SearchFlow.package")
    let plan = try representativeArtifactPlan()

    #expect(throws: HeistArtifactCodecError.self) {
        try HeistArtifactCodec.write(HeistArtifact(plan: plan), to: packageURL)
    }
    #expect(throws: HeistArtifactCodecError.self) {
        _ = try HeistArtifactCodec.read(from: packageURL)
    }
}
