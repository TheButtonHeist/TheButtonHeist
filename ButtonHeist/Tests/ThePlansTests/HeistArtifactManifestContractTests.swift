import Foundation
import Testing
@_spi(ButtonHeistInternals) import ThePlans

@Test
func `heist artifact manifest rejects unknown root fields`() throws {
    let temp = try PlansTemporaryDirectory()
    let plan = try representativeArtifactPlan()
    let manifestJSON = rawArtifactManifestJSON(additionalFields: [
        #"  "legacyKind" : "raw-json""#,
    ])

    try writePackage(
        named: "UnknownManifestField.heist",
        in: temp.url,
        manifestJSON: manifestJSON,
        planJSON: plan.canonicalHeistJSONData()
    ) { url in
        try expectArtifactReadError(
            from: url,
            containing: [
                "invalid manifest.json",
                "Unknown manifest field",
                "legacyKind",
            ]
        )
    }
}

@Test
func `heist artifact manifest rejects unknown producer fields`() throws {
    let temp = try PlansTemporaryDirectory()
    let manifestJSON = rawArtifactManifestJSON(
        producerFields: [
            #" "name" : "buttonheist""#,
            #" "legacySource" : "json""#,
        ]
    )

    try writePackage(
        named: "UnknownProducerField.heist",
        in: temp.url,
        manifestJSON: manifestJSON,
        planJSON: representativeArtifactPlan().canonicalHeistJSONData()
    ) { url in
        try expectArtifactReadError(
            from: url,
            containing: [
                "invalid manifest.json",
                "Unknown manifest producer field",
                "legacySource",
            ]
        )
    }
}

@Test
func `heist artifact manifest rejects stale version key`() throws {
    let temp = try PlansTemporaryDirectory()
    let manifestJSON = rawArtifactManifestJSON(additionalFields: [
        #"  "version" : 1"#,
    ])

    try writePackage(
        named: "StaleManifestVersionKey.heist",
        in: temp.url,
        manifestJSON: manifestJSON,
        planJSON: representativeArtifactPlan().canonicalHeistJSONData()
    ) { url in
        try expectArtifactReadError(
            from: url,
            containing: [
                "invalid manifest.json",
                "Unknown manifest field",
                "version",
            ]
        )
    }
}

@Test
func `heist artifact validates manifest and plan versions`() throws {
    let temp = try PlansTemporaryDirectory()

    try writePackage(
        named: "MissingFormatVersion.heist",
        in: temp.url,
        manifestJSON: rawArtifactManifestJSON(includeFormatVersion: false),
        planJSON: representativeArtifactPlan().canonicalHeistJSONData()
    ) { url in
        try expectArtifactReadError(
            from: url,
            containing: [
                "invalid manifest.json",
                "Missing manifest field",
                "formatVersion",
            ]
        )
    }

    try writePackage(
        named: "UnsupportedArtifact.heist",
        in: temp.url,
        manifest: HeistArtifactManifest(
            format: .buttonHeist,
            formatVersion: currentHeistArtifactFormatVersion + 1,
            producer: .buttonHeist,
            createdAt: Date(timeIntervalSince1970: 0)
        ),
        planJSON: representativeArtifactPlan().canonicalHeistJSONData()
    ) { url in
        #expect(throws: HeistArtifactCodecError.self) {
            try HeistArtifactCodec.read(from: url)
        }
    }

    try writePackage(
        named: "MissingPlanVersion.heist",
        in: temp.url,
        manifest: validArtifactManifest(),
        planJSON: Data(#"{"body":[{"type":"warn","warn":{"message":"missing version"}}]}"#.utf8)
    ) { url in
        #expect(throws: HeistArtifactCodecError.self) {
            try HeistArtifactCodec.read(from: url)
        }
    }

    try writePackage(
        named: "UnsupportedPlanVersion.heist",
        in: temp.url,
        manifest: HeistArtifactManifest(
            format: .buttonHeist,
            formatVersion: currentHeistArtifactFormatVersion,
            producer: .buttonHeist,
            createdAt: Date(timeIntervalSince1970: 0)
        ),
        planJSON: Data(#"{"version":4,"body":[{"type":"warn","warn":{"message":"new version"}}]}"#.utf8)
    ) { url in
        #expect(throws: HeistArtifactCodecError.self) {
            try HeistArtifactCodec.read(from: url)
        }
    }

}

@Test
func `heist artifact manifest rejects duplicated plan identity fields`() throws {
    let temp = try PlansTemporaryDirectory()
    let plan = try representativeArtifactPlan()

    try writePackage(
        named: "DuplicatedPlanIdentity.heist",
        in: temp.url,
        manifestJSON: rawArtifactManifestJSON(additionalFields: [
            #"  "entry" : "searchFlow""#,
            #"  "planVersion" : 3"#,
        ]),
        planJSON: plan.canonicalHeistJSONData()
    ) { url in
        try expectArtifactReadError(
            from: url,
            containing: [
                "invalid manifest.json",
                "Unknown manifest field",
            ]
        )
    }
}

@Test
func `heist artifact requires a named root plan`() throws {
    let temp = try PlansTemporaryDirectory()
    try writePackage(
        named: "Anonymous.heist",
        in: temp.url,
        manifest: validArtifactManifest(),
        planJSON: Data(#"{"version":3,"body":[{"type":"warn","warn":{"message":"anonymous"}}]}"#.utf8)
    ) { url in
        try expectArtifactReadError(
            from: url,
            containing: ["artifact root plan must have a non-empty name"]
        )
    }
}

@Test
func `heist artifact accepts parameterized root entry through validation contract`() throws {
    let temp = try PlansTemporaryDirectory()
    let plan = try HeistPlan(
        name: "search",
        parameter: .string(name: "query"),
        body: [.action(ActionStep(command: .typeText(
            reference: "query",
            target: .label("Search")
        )))]
    )

    try writePackage(
        named: "ParameterizedRoot.heist",
        in: temp.url,
        manifest: validArtifactManifest(),
        planJSON: try JSONEncoder().encode(plan)
    ) { url in
        let plan = try HeistArtifactCodec.readPlan(from: url)
        #expect(plan.name == "search")
        #expect(plan.parameter.kind == .string)
    }
}

@Test
func `heist artifact loading rejects standard definition cap`() throws {
    let temp = try PlansTemporaryDirectory()
    let definitions = try (0...250).map { index in
        try HeistPlan(name: HeistPlanName(validating: "definition\(index)"), body: [
            .warn(WarnStep(message: try HeistWarningMessage(validating: "definition \(index)"))),
        ])
    }
    let encodedDefinitions = try definitions.map {
        try #require(String(bytes: JSONEncoder().encode($0), encoding: .utf8))
    }.joined(separator: ",")
    let planJSON = Data("""
    {
      "version": 3,
      "name": "tooManyDefinitions",
      "definitions": [\(encodedDefinitions)],
      "body": [{ "type": "warn", "warn": { "message": "body" } }]
    }
    """.utf8)

    try writePackage(
        named: "TooManyDefinitions.heist",
        in: temp.url,
        manifest: validArtifactManifest(),
        planJSON: planJSON
    ) { url in
        do {
            _ = try HeistArtifactCodec.readPlan(from: url)
            Issue.record("Expected artifact loading to reject too many definitions")
        } catch {
            let diagnostic = String(describing: error)
            #expect(diagnostic.contains("max total heist definitions"))
            #expect(diagnostic.contains("251 definitions"))
        }
    }
}
