import ArgumentParser
import Foundation
import ThePlans

struct PlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Compile, validate, and render Button Heist plans.",
        subcommands: [Compile.self, Validate.self, Canonicalize.self, RenderSwift.self]
    )

    struct Compile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "compile",
            abstract: "Compile Swift DSL source into a generated .heist package."
        )

        @Argument(help: "Path to a Swift source file that imports ThePlans.")
        var source: String

        @Option(name: .long, help: "Zero-argument throwing function returning a HeistPlan.")
        var entry: String = "heist"

        @Option(name: .long, help: "Path to write a generated .heist package.")
        var output: String

        func run() async throws {
            let entrySymbol: HeistEntrySymbol
            do {
                entrySymbol = try HeistEntrySymbol(validating: entry)
            } catch {
                throw ValidationError(String(describing: error))
            }
            do {
                let plan = try await HeistSwiftCompiler().compileFile(
                    URL(fileURLWithPath: source),
                    entry: entrySymbol
                )
                try PlanIO.write(plan, to: output)
            } catch let error as HeistPlanBuildError {
                throw ValidationError(error.diagnostics.map(\.description).joined(separator: "\n"))
            }
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "validate",
            abstract: "Validate a generated .heist package artifact."
        )

        @Argument(help: "Path to a generated .heist package artifact.")
        var plan: String

        func run() throws {
            _ = try PlanIO.read(plan)
        }
    }

    struct Canonicalize: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "canonicalize",
            abstract: "Re-encode a .heist package artifact."
        )

        @Argument(help: "Path to a generated .heist package artifact.")
        var plan: String

        @Option(name: .long, help: "Path to write a generated .heist package.")
        var output: String

        func run() throws {
            try PlanIO.write(try PlanIO.read(plan), to: output)
        }
    }

    struct RenderSwift: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "render-swift",
            abstract: "Render a heist plan as canonical Swift DSL."
        )

        @Argument(help: "Path to a generated .heist package artifact.")
        var plan: String

        func run() throws {
            let output = try PlanIO.read(plan).canonicalSwiftDSL() + "\n"
            FileHandle.standardOutput.write(Data(output.utf8))
        }
    }
}

private enum PlanIO {
    static func read(_ path: String) throws -> HeistPlan {
        do {
            return try HeistArtifactCodec.readPlan(from: URL(fileURLWithPath: path))
        } catch let error as HeistArtifactCodecError {
            throw ValidationError(error.description)
        } catch {
            throw ValidationError("failed to read \(path): \(error)")
        }
    }

    static func write(_ plan: HeistPlan, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "heist" else {
            throw ValidationError(
                "plan output must be a generated .heist package; raw .json HeistPlan IR is internal artifact content."
            )
        }
        do {
            try HeistArtifactCodec.writePlan(plan, to: url)
        } catch let error as HeistArtifactCodecError {
            throw ValidationError(error.description)
        }
    }
}
