import Foundation
import ButtonHeistTestSupport
import Testing
@_spi(ButtonHeistInternals) import ThePlans

func representativeArtifactPlan() throws -> HeistPlan {
    try HeistPlan("searchFlow") {
        Warn("check state")
    }
}

func validArtifactManifest() -> HeistArtifactManifest {
    validArtifactManifest(entry: "searchFlow")
}

func validArtifactManifest(entry: HeistPlanName) -> HeistArtifactManifest {
    HeistArtifactManifest(
        format: .buttonHeist,
        entry: entry,
        formatVersion: currentHeistArtifactFormatVersion,
        planVersion: currentHeistPlanVersion,
        producer: .buttonHeist,
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

func writePackage(
    named name: String,
    in directory: URL,
    manifest: HeistArtifactManifest,
    planJSON: Data,
    validate: (URL) throws -> Void
) throws {
    try writePackage(
        named: name,
        in: directory,
        manifestJSON: HeistArtifactCodec.canonicalManifestJSONData(manifest),
        planJSON: planJSON,
        validate: validate
    )
}

func writePackage(
    named name: String,
    in directory: URL,
    manifestJSON: Data,
    planJSON: Data,
    validate: (URL) throws -> Void
) throws {
    let packageURL = directory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try manifestJSON.write(to: packageURL.appendingPathComponent("manifest.json"))
    try planJSON.write(to: packageURL.appendingPathComponent("plan.json"))
    try validate(packageURL)
}

func rawArtifactManifestJSON(
    entry: String?,
    includeFormatVersion: Bool = true,
    producerFields: [String] = [#" "name" : "buttonheist""#],
    additionalFields: [String] = []
) -> Data {
    var fields = [
        #"  "createdAt" : "2026-06-05T00:00:00Z""#,
        #"  "format" : "com.royalpineapple.buttonheist.heist""#,
        #"  "planVersion" : 3"#,
        #"  "producer" : { \#(producerFields.joined(separator: ", ")) }"#,
    ]
    if let entry {
        fields.insert(#"  "entry" : "\#(entry)""#, at: 1)
    }
    if includeFormatVersion {
        fields.insert(#"  "formatVersion" : 1"#, at: 2)
    }
    fields.append(contentsOf: additionalFields)
    return Data(("{\n" + fields.joined(separator: ",\n") + "\n}\n").utf8)
}

func expectArtifactReadError(
    from url: URL,
    containing substrings: [String],
    excluding excludedSubstrings: [String] = []
) throws {
    do {
        _ = try HeistArtifactCodec.read(from: url)
        Issue.record("Expected artifact read to fail")
    } catch {
        let description = String(describing: error)
        for substring in substrings {
            #expect(description.contains(substring), "\(description) did not contain \(substring)")
        }
        for substring in excludedSubstrings {
            #expect(!description.contains(substring), "\(description) unexpectedly contained \(substring)")
        }
    }
}

typealias PlansTemporaryDirectory = TemporaryDirectoryFixture
