import Foundation
import CryptoKit
@_spi(ButtonHeistTooling) import ButtonHeist
import TheScore

enum PublicCommandContractFixture {
    enum Mode: Equatable {
        case comparison
        case update
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missing(URL)
        case empty(URL)

        var description: String {
            switch self {
            case .missing(let url):
                """
                Missing generated contract fixture at \(url.path). Run: \
                \(PublicCommandContractFixture.updateCommand)
                """
            case .empty(let url):
                """
                Generated contract fixture at \(url.path) is empty. Run: \
                \(PublicCommandContractFixture.updateCommand)
                """
            }
        }
    }

    static let updateEnvironmentKey = "BUTTONHEIST_UPDATE_PUBLIC_COMMAND_CONTRACT"
    static let maximumCommittedByteCount = 100_000
    static let updateCommand = """
        BUTTONHEIST_UPDATE_PUBLIC_COMMAND_CONTRACT=1 scripts/swift-test-gate.sh \
        ButtonHeistMCP --filter ToolSyncTests.publicCommandContractMatchesCommittedDescriptorSnapshot
        """

    static var fileURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "tests/fixtures/public-cli-mcp-command-contract.json")
    }

    static func renderedData() throws -> Data {
        let commands = try TheFence.Command.descriptors
            .lazy
            .filter(\.isPublicRequestContract)
            .sorted { $0.command.rawValue < $1.command.rawValue }
            .map { try Command($0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        var data = try encoder.encode(Contract(commands: commands))
        data.append(0x0A)
        return data
    }

    static func inputSchemaSHA256(_ inputSchema: HeistValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(inputSchema))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func mode(environment: [String: String]) -> Mode {
        guard environment["CI"] == nil,
              environment[updateEnvironmentKey] == "1" else {
            return .comparison
        }
        return .update
    }

    static func committedData(
        for renderedData: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fixtureURL: URL = PublicCommandContractFixture.fileURL
    ) throws -> Data {
        switch mode(environment: environment) {
        case .comparison:
            guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
                throw FixtureError.missing(fixtureURL)
            }
            let data = try Data(contentsOf: fixtureURL)
            guard !data.isEmpty else {
                throw FixtureError.empty(fixtureURL)
            }
            return data

        case .update:
            try renderedData.write(to: fixtureURL, options: .atomic)
            return renderedData
        }
    }
}

private extension PublicCommandContractFixture {
    struct Contract: Encodable {
        let commands: [Command]
    }

    struct Command: Encodable {
        let name: String
        let family: String
        let requiresConnectionBeforeDispatch: Bool
        let cliExposure: String
        let mcpExposure: String
        let description: String
        let timeout: Timeout
        let inputSchemaSHA256: String
        let mcpAnnotations: MCPAnnotations?

        init(_ descriptor: FenceCommandDescriptor) throws {
            name = descriptor.command.rawValue
            family = descriptor.family.rawValue
            requiresConnectionBeforeDispatch = descriptor.requiresConnectionBeforeDispatch
            cliExposure = descriptor.cliExposure.contractValue
            mcpExposure = descriptor.mcpExposure.contractValue
            description = descriptor.description
            timeout = Timeout(descriptor.timeout)
            inputSchemaSHA256 = try PublicCommandContractFixture.inputSchemaSHA256(
                descriptor.inputJSONSchema
            )
            mcpAnnotations = descriptor.mcpAnnotations.map(MCPAnnotations.init)
        }
    }

    enum Timeout: Encodable {
        enum Kind: String, Encodable {
            case none
            case fixed
            case action
            case performStep
            case heist
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case base
            case seconds
        }

        case none
        case fixed(FenceCommandFixedTimeout)
        case action
        case performStep
        case heist

        init(_ timeout: FenceCommandTimeoutSemantics) {
            switch timeout {
            case .none:
                self = .none
            case .fixed(let base):
                self = .fixed(base)
            case .action:
                self = .action
            case .performStep:
                self = .performStep
            case .heist:
                self = .heist
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .none:
                try container.encode(Kind.none, forKey: .kind)
            case .fixed(let base):
                try container.encode(Kind.fixed, forKey: .kind)
                try container.encode(base.rawValue, forKey: .base)
                try container.encode(base.seconds, forKey: .seconds)
            case .action:
                try container.encode(Kind.action, forKey: .kind)
            case .performStep:
                try container.encode(Kind.performStep, forKey: .kind)
            case .heist:
                try container.encode(Kind.heist, forKey: .kind)
            }
        }
    }

    struct MCPAnnotations: Encodable {
        let readOnlyHint: Bool?
        let idempotentHint: Bool?

        init(_ annotations: MCPToolAnnotationSpec) {
            readOnlyHint = annotations.readOnlyHint
            idempotentHint = annotations.idempotentHint
        }
    }
}

private extension CLIExposure {
    var contractValue: String {
        switch self {
        case .directCommand:
            return "directCommand"
        case .notExposed:
            return "notExposed"
        }
    }
}

private extension MCPExposure {
    var contractValue: String {
        switch self {
        case .directTool:
            return "directTool"
        case .notExposed:
            return "notExposed"
        }
    }
}
