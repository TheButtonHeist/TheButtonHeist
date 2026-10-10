import Testing
import MCP
import Foundation
@_spi(ButtonHeistTooling) import ButtonHeist
import TheScore
@testable import ButtonHeistMCP

struct ToolSyncTests {
    @Test("Public CLI/MCP command contract matches the committed descriptor snapshot")
    func publicCommandContractMatchesCommittedDescriptorSnapshot() throws {
        let actual = try PublicCommandContractFixture.renderedData()
        let fixtureURL = PublicCommandContractFixture.fileURL
        let expected = try PublicCommandContractFixture.committedData(for: actual)

        #expect(
            actual == expected,
            """
            Public CLI/MCP command contract drifted from \(fixtureURL.path).
            Review the typed descriptor change, then run: \(PublicCommandContractFixture.updateCommand)
            """
        )
    }

    @Test("Committed public command contract stays digest-based and below 100 KB")
    func committedPublicCommandContractStaysDigestBasedAndBounded() throws {
        let data = try Data(contentsOf: PublicCommandContractFixture.fileURL)
        let contract = try JSONDecoder().decode(Value.self, from: data)
        let commands = try #require(contract.objectValue?["commands"]?.arrayValue)
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")

        #expect(data.count < PublicCommandContractFixture.maximumCommittedByteCount)
        #expect(!commands.isEmpty)
        for command in commands {
            let fields = try #require(command.objectValue)
            let digest = try #require(fields["inputSchemaSHA256"]?.stringValue)
            let timeout = try #require(fields["timeout"]?.objectValue)

            #expect(fields["inputSchema"] == nil)
            #expect(fields["exposedByCLI"] == nil)
            #expect(fields["exposedByMCP"] == nil)
            #expect(fields["family"]?.stringValue != nil)
            #expect(fields["requiresConnectionBeforeDispatch"] != nil)
            #expect(fields["cliExposure"]?.stringValue != nil)
            #expect(fields["mcpExposure"]?.stringValue != nil)
            let timeoutKind = try #require(timeout["kind"]?.stringValue)
            let hasFixedBase = timeoutKind == "fixed"
            #expect((timeout["base"] != nil) == hasFixedBase)
            #expect((timeout["seconds"] != nil) == hasFixedBase)
            #expect(digest.utf8.count == 64)
            #expect(digest.unicodeScalars.allSatisfy(lowercaseHex.contains))
        }
    }

    @Test("Public command input schema digest is canonical across dictionary order")
    func publicCommandInputSchemaDigestIsCanonicalAcrossDictionaryOrder() throws {
        let first = HeistValue.object([
            "type": .string("object"),
            "properties": .object([
                "alpha": .object(["type": .string("string")]),
                "beta": .object(["type": .string("integer")]),
            ]),
        ])
        let reordered = HeistValue.object([
            "properties": .object([
                "beta": .object(["type": .string("integer")]),
                "alpha": .object(["type": .string("string")]),
            ]),
            "type": .string("object"),
        ])

        #expect(
            try PublicCommandContractFixture.inputSchemaSHA256(first)
                == PublicCommandContractFixture.inputSchemaSHA256(reordered)
        )
    }

    @Test("Public command contract update requires exact local opt-in")
    func publicCommandContractUpdateRequiresExactLocalOptIn() {
        let key = PublicCommandContractFixture.updateEnvironmentKey

        #expect(PublicCommandContractFixture.mode(environment: [:]) == .comparison)
        #expect(PublicCommandContractFixture.mode(environment: [key: "true"]) == .comparison)
        #expect(PublicCommandContractFixture.mode(environment: [key: "1"]) == .update)
        #expect(PublicCommandContractFixture.mode(environment: [key: "1", "CI": "1"]) == .comparison)
    }

    @Test("Public command contract comparison never rewrites the fixture")
    func publicCommandContractComparisonNeverRewritesFixture() throws {
        let fixtureURL = temporaryContractFixtureURL()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let committed = Data("committed\n".utf8)
        let rendered = Data("rendered\n".utf8)
        try committed.write(to: fixtureURL)

        let expected = try PublicCommandContractFixture.committedData(
            for: rendered,
            environment: [:],
            fixtureURL: fixtureURL
        )

        #expect(expected == committed)
        #expect(try Data(contentsOf: fixtureURL) == committed)
    }

    @Test("Public command contract comparison rejects missing and empty fixtures")
    func publicCommandContractComparisonRejectsMissingAndEmptyFixtures() throws {
        let fixtureURL = temporaryContractFixtureURL()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let rendered = Data("rendered\n".utf8)

        #expect(throws: PublicCommandContractFixture.FixtureError.self) {
            try PublicCommandContractFixture.committedData(
                for: rendered,
                environment: [:],
                fixtureURL: fixtureURL
            )
        }

        try Data().write(to: fixtureURL)
        #expect(throws: PublicCommandContractFixture.FixtureError.self) {
            try PublicCommandContractFixture.committedData(
                for: rendered,
                environment: [:],
                fixtureURL: fixtureURL
            )
        }
    }

    @Test("Tool input schemas satisfy canonical schema lint in memory")
    func toolInputSchemasSatisfyCanonicalSchemaLintInMemory() {
        let violations = ToolSchemaLint.violations(in: ToolDefinitions.all)
        #expect(
            violations.isEmpty,
            "Tool input schema lint violations:\n\(violations.joined(separator: "\n"))"
        )
    }

    @Test("Serialized ListTools JSON satisfies canonical schema lint")
    func serializedListToolsJSONSatisfiesCanonicalSchemaLint() throws {
        let data = try JSONEncoder().encode(ListTools.Result(tools: ToolDefinitions.all))
        let violations = try ToolSchemaLint.violationsInSerializedListToolsJSON(data)
        #expect(
            violations.isEmpty,
            "Serialized ListTools schema lint violations:\n\(violations.joined(separator: "\n"))"
        )
    }

    @Test("MCP tool surface stays source-oriented")
    func mcpToolSurfaceStaysSourceOriented() {
        let expected = directToolDescriptors().map(\.command.rawValue).sorted()

        #expect(ToolDefinitions.all.map(\.name).sorted() == expected)
    }

    @Test("MCP tool definitions are descriptor projections")
    func toolDefinitionsAreDescriptorProjections() throws {
        let toolsByName = Dictionary(grouping: ToolDefinitions.all, by: \.name)

        for descriptor in directToolDescriptors() {
            let tool = try #require(
                toolsByName[descriptor.command.rawValue]?.first,
                "Missing MCP tool for descriptor \(descriptor.command.rawValue)"
            )
            let expectedInputSchema = try inputSchemaValue(for: descriptor.command)

            #expect(tool.name == descriptor.command.rawValue)
            #expect(tool.description == descriptor.description)
            #expect(tool.inputSchema == expectedInputSchema)
        }
    }

    @Test("Action schema delegates canonical action decoding to the domain type")
    func actionSchemaUsesOneOpaqueDomainPayload() throws {
        let action = try inputSchemaValue(for: .action)

        #expect(schemaValue(at: ["properties", "action", "type"], in: action) == .string("object"))
        #expect(schemaValue(at: ["properties", "action", "properties"], in: action) == nil)
        #expect(schemaValue(at: ["required"], in: action) == .array([.string("action")]))
    }

    @Test("Expectation and target schemas expose only canonical fields")
    func expectationAndTargetSchemasExposeOnlyCanonicalFields() throws {
        let action = try inputSchemaValue(for: .action)
        let expectationProperties = try #require(
            schemaValue(at: ["properties", "expect", "properties"], in: action)?.objectValue
        )
        #expect(Set(expectationProperties.keys) == [
            "type",
            "target",
            "match",
            "scope",
            "assertions",
            "text",
            "element",
        ])
        #expect(
            schemaValue(at: ["properties", "expect", "properties", "type", "enum"], in: action)
                == .array(AccessibilityPredicate.wireTypeValues.map(Value.string))
        )

        let getInterface = try inputSchemaValue(for: .getInterface)
        let targetProperties = try #require(
            schemaValue(at: ["properties", "subtree", "properties"], in: getInterface)?.objectValue
        )
        #expect(Set(targetProperties.keys) == ["checks", "ref", "ordinal", "container", "target"])
        for removedAlias in ["label", "identifier", "value"] {
            #expect(targetProperties[removedAlias] == nil)
        }
        let matchSchema = try #require(
            schemaValue(
                at: ["properties", "subtree", "properties", "checks", "items", "properties", "match"],
                in: getInterface
            )
        )
        assertStringMatchSchema(matchSchema, path: "get_interface.inputSchema.properties.subtree.checks.match")
    }

    @Test("AccessibilityTarget schema recursion uses one local definition")
    func accessibilityTargetSchemaRecursionUsesOneLocalDefinition() throws {
        let getInterface = try inputSchemaValue(for: .getInterface)
        let reference = Value.object(["$ref": .string("#/$defs/AccessibilityTarget")])

        #expect(
            schemaValue(
                at: ["properties", "subtree"],
                in: getInterface,
                resolvingFinalReference: false
            ) == reference
        )
        #expect(
            schemaValue(
                at: ["$defs", "AccessibilityTarget", "properties", "target"],
                in: getInterface,
                resolvingFinalReference: false
            ) == reference
        )
        #expect(schemaValue(at: ["$defs", "AccessibilityTarget", "properties", "checks"], in: getInterface) != nil)
    }

    @Test("get_interface subtree container is an object-only predicate")
    func getInterfaceSubtreeContainerSchemaIsObjectOnly() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == "get_interface" })
        let rootProperties = try #require(schemaValue(at: ["properties"], in: tool.inputSchema)?.objectValue)
        #expect(rootProperties["checks"] == nil)

        let containerPath = ["properties", "subtree", "properties", "container"]
        let container = try #require(schemaValue(at: containerPath, in: tool.inputSchema))

        #expect(container.objectValue?["type"] == .string("object"))

        let properties = try #require(schemaValue(at: containerPath + ["properties"], in: tool.inputSchema)?.objectValue)
        #expect(properties["containerName"] == nil)
        #expect(properties["checks"] != nil)
        #expect(
            schemaValue(at: containerPath + ["properties", "checks", "minItems"], in: tool.inputSchema)
                == .int(1)
        )
        #expect(
            schemaValue(at: containerPath + ["properties", "checks", "items", "properties", "kind", "enum"], in: tool.inputSchema) == .array([
                .string("type"),
                .string("identifier"),
                .string("semantic"),
                .string("rowCount"),
                .string("columnCount"),
                .string("modalBoundary"),
                .string("scrollable"),
                .string("actions"),
            ])
        )
        let checkPropertiesPath = containerPath + ["properties", "checks", "items", "properties"]
        let checkProperties = try #require(
            schemaValue(at: checkPropertiesPath, in: tool.inputSchema)?.objectValue
        )
        #expect(Set(checkProperties.keys) == ["kind", "type", "match", "semantic", "values", "value"])
        #expect(
            schemaValue(at: checkPropertiesPath + ["type", "enum"], in: tool.inputSchema) == .array([
                .string("none"),
                .string("semanticGroup"),
                .string("list"),
                .string("landmark"),
                .string("dataTable"),
                .string("tabBar"),
                .string("series"),
            ])
        )
        #expect(
            schemaValue(at: checkPropertiesPath + ["semantic", "properties", "kind", "enum"], in: tool.inputSchema)
                == .array([.string("label"), .string("value")])
        )
        #expect(
            schemaValue(at: checkPropertiesPath + ["values", "minItems"], in: tool.inputSchema)
                == .int(1)
        )
    }

    @Test("get_interface schema exposes bounded discovery limits")
    func getInterfaceSchemaExposesBoundedDiscoveryLimits() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == "get_interface" })
        for field in ["maxScrollsPerContainer", "maxScrollsPerDiscovery"] {
            let schema = try #require(
                schemaValue(at: ["properties", field], in: tool.inputSchema)?.objectValue,
                "get_interface missing \(field)"
            )
            #expect(schema["type"] == .string("integer"))
            #expect(schema["minimum"] == .int(1))
            #expect(schema["maximum"] == .int(2_000))
        }
    }

    @Test("run_heist schema exposes plan sources and root argument")
    func runHeistSchemaExposesOnlyPlan() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == "run_heist" })

        // The MCP run_heist tool exposes only public authoring sources:
        // canonical ButtonHeist source, .heist artifact path, and root
        // argument. Raw JSON IR fields remain internal and are not advertised.
        for field in ["path", "plan", "argument"] {
            #expect(
                schemaValue(at: ["properties", field], in: tool.inputSchema) != nil,
                "run_heist schema must expose \(field)"
            )
        }
        for field in ["version", "name", "parameter", "definitions", "body"] {
            #expect(
                schemaValue(at: ["properties", field], in: tool.inputSchema) == nil,
                "run_heist schema must not expose raw JSON IR field \(field)"
            )
        }
        #expect(schemaValue(at: ["properties", "argument", "properties", "type", "enum"], in: tool.inputSchema) == .array([
            .string("none"),
            .string("string"),
            .string("accessibility_target"),
        ]))
        #expect(
            schemaValue(at: ["properties", "argument", "properties", "target", "additionalProperties"], in: tool.inputSchema)
                == .bool(false)
        )
        #expect(schemaValue(at: ["properties", "argument", "properties", "target", "properties", "checks"], in: tool.inputSchema) != nil)
        #expect(schemaValue(at: ["properties", "argument", "properties", "target", "properties", "label"], in: tool.inputSchema) == nil)
        #expect(schemaValue(at: ["properties", "argument", "properties", "target", "properties", "unexpected"], in: tool.inputSchema) == nil)
    }

    @Test("validate_heist is offline and exposes canonical sources, argument, and lint")
    func validateHeistSchema() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == "validate_heist" })

        for field in ["path", "plan", "argument", "lint"] {
            #expect(schemaValue(at: ["properties", field], in: tool.inputSchema) != nil)
        }
        for field in ["version", "name", "parameter", "definitions", "body"] {
            #expect(schemaValue(at: ["properties", field], in: tool.inputSchema) == nil)
        }
        #expect(schemaValue(at: ["properties", "lint", "default"], in: tool.inputSchema) == .string("composition_quality"))
    }

    @Test("perform schema exposes one step source without plan IR")
    func performSchemaExposesOneStepSourceWithoutPlanIR() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == "perform" })

        #expect(schemaValue(at: ["properties", "step"], in: tool.inputSchema) != nil)
        #expect(schemaValue(at: ["required"], in: tool.inputSchema) == .array([.string("step")]))
        for field in ["source", "path", "plan", "version", "name", "parameter", "definitions", "body"] {
            #expect(
                schemaValue(at: ["properties", field], in: tool.inputSchema) == nil,
                "perform schema must not expose \(field)"
            )
        }
    }

    @Test("heist discovery schemas expose validated plan source")
    func heistDiscoverySchemasExposePlanSource() throws {
        let listHeists = try #require(ToolDefinitions.all.first { $0.name == "list_heists" })
        let describeHeist = try #require(ToolDefinitions.all.first { $0.name == "describe_heist" })

        for tool in [listHeists, describeHeist] {
            for field in ["path", "plan"] {
                #expect(
                    schemaValue(at: ["properties", field], in: tool.inputSchema) != nil,
                    "\(tool.name) schema must expose \(field)"
                )
            }
            for field in ["version", "name", "parameter", "definitions", "body"] {
                #expect(
                    schemaValue(at: ["properties", field], in: tool.inputSchema) == nil,
                    "\(tool.name) schema must not expose raw JSON IR field \(field)"
                )
            }
        }

        #expect(schemaValue(at: ["properties", "heist"], in: describeHeist.inputSchema) != nil)
        #expect(schemaValue(at: ["required"], in: describeHeist.inputSchema) == .array([.string("heist")]))
        #expect(schemaValue(at: ["properties", "heist"], in: listHeists.inputSchema) == nil)
        #expect(schemaValue(at: ["properties", "detail", "enum"], in: listHeists.inputSchema) == .array([
            .string("summary"),
            .string("detailed"),
        ]))
        #expect(schemaValue(at: ["properties", "detail", "default"], in: listHeists.inputSchema) == .string("summary"))
    }
}

private func temporaryContractFixtureURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "public-command-contract-\(UUID().uuidString).json")
}

private func schemaValue(
    at path: [String],
    in root: Value,
    resolvingFinalReference: Bool = true
) -> Value? {
    let value = path.reduce(Optional(root)) { value, key in
        resolvedLocalReference(value, in: root)?.objectValue?[key]
    }
    return resolvingFinalReference ? resolvedLocalReference(value, in: root) : value
}

private func resolvedLocalReference(_ value: Value?, in root: Value) -> Value? {
    guard let value,
          let reference = value.objectValue?["$ref"]?.stringValue,
          reference.hasPrefix("#/") else {
        return value
    }
    return reference.dropFirst(2).split(separator: "/").reduce(Optional(root)) { resolved, component in
        resolved?.objectValue?[String(component)]
    }
}

private func inputSchemaValue(for command: TheFence.Command) throws -> Value {
    let data = try JSONEncoder().encode(command.descriptor.inputJSONSchema)
    return try JSONDecoder().decode(Value.self, from: data)
}

private func directToolDescriptors() -> [FenceCommandDescriptor] {
    TheFence.Command.descriptors.filter { $0.mcpExposure == .directTool }
}

private func assertStringMatchSchema(_ schema: Value, path: String) {
    let object = schema.objectValue
    #expect(object?["type"] == .string("object"), "\(path) must advertise object-form StringMatch")
    #expect(object?["additionalProperties"] == .bool(false), "\(path) must close object-form StringMatch fields")
    #expect(object?["required"] == .array([.string("mode")]), "\(path) must require mode in object form")
    #expect(object?["description"]?.stringValue?.contains("mode exact") == true, "\(path) should describe exact matching through object-form StringMatch")
    #expect(
        object?["properties"]?.objectValue?["mode"] == .object([
            "type": .string("string"),
            "enum": .array([
                .string("exact"),
                .string("contains"),
                .string("prefix"),
                .string("suffix"),
                .string("isEmpty"),
            ]),
        ]),
        "\(path).properties.mode must enumerate StringMatch modes"
    )
    #expect(
        object?["properties"]?.objectValue?["value"] == .object(["type": .string("string")]),
        "\(path).properties.value must be a string"
    )
}

private extension Value {
    var arrayValue: [Value]? {
        guard case .array(let array) = self else { return nil }
        return array
    }

    var objectValue: [String: Value]? {
        guard case .object(let object) = self else { return nil }
        return object
    }
}

private enum ToolSchemaLint {
    private static let bannedCombinatorKeywords = ["oneOf", "anyOf", "allOf"]
    private static let maximumNestingDepth = 64

    static func violations(in tools: [Tool]) -> [String] {
        tools.flatMap { tool in
            lintRootSchema(tool.inputSchema, path: "\(tool.name).inputSchema")
        }
    }

    static func violationsInSerializedListToolsJSON(_ data: Data) throws -> [String] {
        let listToolsJSON = try JSONDecoder().decode(Value.self, from: data)
        guard case .object(let root) = listToolsJSON,
              let toolsValue = root["tools"],
              case .array(let tools) = toolsValue else {
            return ["$.tools missing from serialized ListTools JSON"]
        }

        return tools.enumerated().flatMap { index, toolValue in
            guard case .object(let toolObject) = toolValue else {
                return ["$.tools[\(index)] is not an object"]
            }
            let name = toolObject["name"]?.stringValue ?? "$.tools[\(index)]"
            guard let inputSchema = toolObject["inputSchema"] else {
                return ["\(name).inputSchema missing from serialized ListTools JSON"]
            }
            return lintRootSchema(inputSchema, path: "\(name).inputSchema")
        }
    }

    private static func lintRootSchema(_ schema: Value, path: String) -> [String] {
        guard case .object(let object) = schema else {
            return ["\(path) root schema is not an object"]
        }

        var violations: [String] = []
        let depth = nestingDepth(schema)
        if depth > maximumNestingDepth {
            violations.append("\(path) nesting depth \(depth) exceeds \(maximumNestingDepth)")
        }
        if object["additionalProperties"] != .bool(false) {
            violations.append("\(path) root schema must set additionalProperties: false")
        }
        violations += lint(schema, path: path)
        return violations
    }

    private static func lint(_ value: Value, path: String) -> [String] {
        switch value {
        case .object(let object):
            var violations: [String] = []

            // Schema combinators are banned entirely on the MCP surface — OpenAI
            // tool input schemas reject oneOf/anyOf/allOf at any depth.
            for combinator in bannedCombinatorKeywords where object[combinator] != nil {
                violations.append("\(path).\(combinator) is a forbidden JSON Schema combinator")
            }

            if let typeValue = object["type"] {
                if case .array = typeValue {
                    violations.append("\(path).type is an array-valued JSON Schema type")
                }
                if typeValue == .string("array"), object["items"] == nil {
                    violations.append("\(path) is an array schema without items")
                }
            }

            if let requiredValue = object["required"] {
                guard case .array(let requiredItems) = requiredValue else {
                    violations.append("\(path).required is not an array")
                    return violations + lintNestedValues(in: object, path: path)
                }

                var requiredKeys: [String] = []
                for (index, item) in requiredItems.enumerated() {
                    guard case .string(let key) = item else {
                        violations.append("\(path).required[\(index)] is not a string")
                        continue
                    }
                    requiredKeys.append(key)
                }

                let uniqueRequiredKeys = Set(requiredKeys)
                if uniqueRequiredKeys.count != requiredKeys.count {
                    violations.append("\(path).required contains duplicate keys")
                }

                guard let propertiesValue = object["properties"],
                      case .object(let properties) = propertiesValue else {
                    violations.append("\(path).required is present without object properties")
                    return violations + lintNestedValues(in: object, path: path)
                }

                for key in uniqueRequiredKeys where properties[key] == nil {
                    violations.append("\(path).required contains key '\(key)' not present in properties")
                }
            }

            return violations + lintNestedValues(in: object, path: path)

        case .array(let values):
            return values.enumerated().flatMap { index, nestedValue in
                lint(nestedValue, path: "\(path)[\(index)]")
            }

        default:
            return []
        }
    }

    private static func lintNestedValues(in object: [String: Value], path: String) -> [String] {
        object.flatMap { key, nestedValue in
            lint(nestedValue, path: "\(path).\(key)")
        }
    }

    private static func nestingDepth(_ value: Value, depth: Int = 0) -> Int {
        switch value {
        case .object(let object):
            return object.values.map { nestingDepth($0, depth: depth + 1) }.max() ?? depth
        case .array(let values):
            return values.map { nestingDepth($0, depth: depth + 1) }.max() ?? depth
        default:
            return depth
        }
    }
}
