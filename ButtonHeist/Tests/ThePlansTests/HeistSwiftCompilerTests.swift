import Foundation
import ButtonHeistTestSupport
import Testing
@testable import ThePlans

@Suite(.serialized)
struct HeistSwiftCompilerTests {
    @Test
    func `entry symbol validates one canonical dotted identifier currency`() throws {
        #expect(try HeistEntrySymbol(validating: "Checkout.compile").description == "Checkout.compile")
        #expect(throws: HeistPathValidationError.self) {
            _ = try HeistEntrySymbol(validating: "Checkout-compile")
        }
    }

    @Test
    func `known build diagnostic codes preserve raw output`() {
        let representativeCodes: [(HeistKnownBuildDiagnosticCode, String)] = [
            (.dslInvalidActionExpectation, "heist.dsl.invalid_action_expectation"),
            (.sourceInvalidSyntax, "heist.source.invalid_syntax"),
            (.planRuntimeSafety, "heist.plan.runtime_safety"),
            (.swiftCompilationCompileFailed, "heist.swift_compilation.compile_failed"),
            (.directoryNoSources, "heist.directory.no_sources"),
            (.catalogDuplicateCapability, "heist.catalog.duplicate_capability"),
        ]

        for (code, rawValue) in representativeCodes {
            #expect(HeistBuildDiagnosticCode(code).rawValue == rawValue)
            #expect(HeistBuildDiagnostic(code: code, phase: .planning, message: "test").code.rawValue == rawValue)
        }
    }

    @Test
    func `compileFile compiles a simple named HeistPlan Swift source`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            named: "Named.swift",
            """
            import ThePlans

            func heist() throws -> HeistPlan {
                try HeistPlan("NamedPlan") {
                    Warn("ok")
                }
            }
            """
        )

        let plan = try await HeistSwiftCompiler().compileFile(source)

        #expect(plan.name == "NamedPlan")
        #expect(plan.body == [.warn(WarnStep(message: "ok"))])
    }

    @Test
    func `compileFile rejects default heist value source`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            named: "Value.swift",
            """
            import ThePlans

            let heist = try HeistPlan("ValuePlan") {
                Warn("ok")
            }
            """
        )

        let diagnostics = try await buildDiagnostics {
            try await HeistSwiftCompiler().compileFile(source)
        }
        let text = diagnostics.map(\.description).joined(separator: "\n")

        #expect(text.contains("cannot call value of non-function type"))
    }

    @Test
    func `compileFile rejects invalid Swift source with bounded diagnostics`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            named: "Broken.swift",
            """
            import ThePlans

            let heist =
            """
        )

        let diagnostics = try await buildDiagnostics {
            try await HeistSwiftCompiler().compileFile(source)
        }
        let diagnostic = try #require(diagnostics.first)

        #expect(diagnostic.code.rawValue == "heist.swift_compilation.compile_failed")
        #expect(diagnostic.kind == .error)
        #expect(diagnostic.phase == .swiftCompilation)
        #expect(diagnostic.sourceSpan?.sourceName.hasSuffix("Broken.swift") == true)
        #expect(diagnostic.renderedMessage.count < 2_500)
    }

    @Test
    func `compileFile rejects compiler output that is not valid heist JSON`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            named: "BadOutput.swift",
            """
            import Foundation
            import ThePlans

            FileHandle.standardOutput.write(Data("not-json".utf8))

            func heist() throws -> HeistPlan {
                try HeistPlan("BadOutput") {
                    Warn("ok")
                }
            }
            """
        )

        let diagnostics = try await buildDiagnostics {
            try await HeistSwiftCompiler().compileFile(source)
        }
        let diagnostic = try #require(diagnostics.first)

        #expect(diagnostic.code.rawValue == "heist.swift_compilation.invalid_output")
        #expect(diagnostic.phase == .swiftCompilation)
        #expect(diagnostic.message.contains("valid HeistPlan JSON"))
        #expect(diagnostic.renderedMessage.count < 2_500)
    }

    @Test
    func `compileFile cancellation throws canonical build diagnostic`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(named: "Cancelled.swift", namedPlan: "Cancelled")
        let task = Task {
            try await HeistSwiftCompiler().compileFile(source)
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected compilation cancellation to throw")
        } catch {
            let buildError = try #require(error as? HeistPlanBuildError)
            #expect(buildError.diagnostics.map(\.code.knownCode) == [.swiftCompilationCancelled])
        }
    }

#if !(os(macOS) || os(Linux))
    @Test
    func `compileFile unsupported platform throws canonical build diagnostic`() async throws {
        let source = URL(fileURLWithPath: "/tmp/Unsupported.swift")

        do {
            _ = try await HeistSwiftCompiler().compileFile(source)
            Issue.record("Expected unsupported platform compilation to throw")
        } catch {
            let buildError = try #require(error as? HeistPlanBuildError)
            #expect(buildError.diagnostics.map(\.code.knownCode) == [.swiftCompilationUnsupportedPlatform])
        }
    }
#endif

    @Test
    func `compiler plan JSON maps typed version admission failure`() {
        let data = Data(#"{"version":4,"body":[{"type":"warn","warn":{"message":"future"}}]}"#.utf8)
        let sourceURL = URL(fileURLWithPath: "/tmp/future-plan.swift")

        #expect(throws: HeistPlanJSONCodecError.unsupportedVersion(
            source: sourceURL.path,
            observed: 4
        )) {
            _ = try HeistPlanJSONCodec.decodeValidatedPlan(data, sourceURL: sourceURL)
        }
    }

    @Test
    func `compileFile returns a runtime validated HeistPlan`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            named: "Validated.swift",
            """
            import ThePlans

            func heist() throws -> HeistPlan {
                try HeistPlan("Validated") {
                    Warn("ok")
                }
            }
            """
        )

        let plan = try await HeistSwiftCompiler().compileFile(source)

        #expect(plan.lint(.strictTest).isEmpty)
        #expect(try JSONDecoder().decode(HeistPlan.self, from: plan.canonicalHeistJSONData()) == plan)
    }

    @Test
    func `compileFile allows Swift wrapper outside selected heist`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            named: "Wrapped.swift",
            """
            import ThePlans

            enum StoreFlows {
                static func checkout() throws -> HeistPlan {
                    try HeistPlan("Checkout") {
                        Warn("ok")
                    }
                }
            }

            func heist() throws -> HeistPlan {
                try StoreFlows.checkout()
            }
            """
        )

        let plan = try await HeistSwiftCompiler().compileFile(source)

        #expect(plan.name == "Checkout")
        #expect(plan.body == [.warn(WarnStep(message: "ok"))])
    }

    @Test
    func `compileFile ignores Swift wrapper strings that mention HeistPlan`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            named: "WrapperStrings.swift",
            #"""
            import ThePlans

            let template = """
            HeistPlan {
                let x = 1
            }
            """

            let rawTemplate = #"HeistPlan { if true { Warn("not real DSL") } }"#

            func heist() throws -> HeistPlan {
                try HeistPlan("WrapperStrings") {
                    Warn("ok")
                }
            }
            """#
        )

        let plan = try await HeistSwiftCompiler().compileFile(source)

        #expect(plan.name == "WrapperStrings")
        #expect(plan.body == [.warn(WarnStep(message: "ok"))])
    }

    @Test
    func `compileFile ignores Swift wrapper comments and return types that mention HeistPlan`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            named: "WrapperComments.swift",
            """
            import ThePlans

            /*
                /*
                    inner block
                */
                HeistPlan {
                    let x = 1
                }
            */

            func makeHeist() throws -> /* wrapped return type */ HeistPlan {
                try HeistPlan("WrapperComments") {
                    Warn("ok")
                }
            }

            func heist() throws -> HeistPlan {
                try makeHeist()
            }
            """
        )

        let plan = try await HeistSwiftCompiler().compileFile(source)

        #expect(plan.name == "WrapperComments")
        #expect(plan.body == [.warn(WarnStep(message: "ok"))])
    }

    @Test
    func `compileFile allows trusted Swift frontend helpers to emit a validated plan`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            named: "TrustedFrontend.swift",
            """
            import ThePlans

            func payLabel() -> String { "Pay" }

            func heist() throws -> HeistPlan {
                try HeistPlan("TrustedFrontend") {
                    Activate(.label(payLabel()))
                        .expect(.screenChanged)
                }
            }
            """
        )

        let plan = try await HeistSwiftCompiler().compileFile(source)

        #expect(plan.name == "TrustedFrontend")
        #expect(plan.body == [
            .action(ActionStep(
                command: .activate(.predicate(.label("Pay"))),
                expectationPolicy: .expect(ActionExpectation(
                    predicate: .screenChanged
                )))),
        ])
    }

    @Test
    func `compileFile allows trusted Swift frontend to emit raw validated HeistPlan AST`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            named: "RawBody.swift",
            """
            import ThePlans

            func heist() throws -> HeistPlan {
                try HeistPlan(name: "RawBody", body: [
                    .warn(WarnStep(message: "raw")),
                ])
            }
            """
        )

        let plan = try await HeistSwiftCompiler().compileFile(source)

        #expect(plan.name == "RawBody")
        #expect(plan.body == [.warn(WarnStep(message: "raw"))])
    }

    @Test
    func `swift DSL builder failures surface typed build diagnostics`() throws {
        do {
            _ = try HeistPlan("InvalidExpectation") {
                Activate(.label("Pay"))
                    .expect(.exists(.label("Done")), timeout: 1)
                    .expect(.missing(.label("Error")), timeout: 2)
            }
            Issue.record("Expected invalid expectation composition to fail")
        } catch let error as HeistPlanBuildError {
            #expect(error.diagnostics.count == 2)
            #expect(error.diagnostics.allSatisfy { $0.code == .dslInvalidActionExpectation })
            #expect(error.diagnostics.allSatisfy { $0.phase == .dslBuild })
            #expect(error.diagnostics.allSatisfy { $0.path == "activate" })
            #expect(error.diagnostics.contains {
                $0.message.contains("unsupported expectation composition")
                    && $0.hint == "Use one predicate per expectation, or follow the action with a WaitFor."
            })
            #expect(error.diagnostics.contains {
                $0.message.contains("multiple explicit expectation timeouts")
                    && $0.hint == "Use one explicit timeout for the composed expectation."
            })
        } catch {
            Issue.record("Expected HeistPlanBuildError, got \(error)")
        }
    }

    @Test
    func `result builders do not accept native Swift control flow in heist body`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            named: "NativeIf.swift",
            """
            import ThePlans

            let shouldPay = true
            func heist() throws -> HeistPlan {
                try HeistPlan("NativeIf") {
                    if shouldPay {
                        Activate(.label("Pay"))
                    }
                }
            }
            """
        )

        let diagnostics = try await buildDiagnostics {
            try await HeistSwiftCompiler().compileFile(source)
        }
        let text = diagnostics.map(\.description).joined(separator: "\n")

        #expect(text.contains("Failed to compile Swift heist source"))
    }

    @Test
    func `result builders do not accept native Swift control flow in heist definitions`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let source = try temp.writeSwiftSource(
            named: "NativeIfInDefinition.swift",
            """
            import ThePlans

            func heist() throws -> HeistPlan {
                try HeistPlan("NativeIfInDefinition") {
                    HeistDef<Void>("Helper") {
                        if Bool.random() {
                            Warn("raw")
                        }
                    }

                    RunHeist("Helper")
                }
            }
            """
        )

        let diagnostics = try await buildDiagnostics {
            try await HeistSwiftCompiler().compileFile(source)
        }
        let text = diagnostics.map(\.description).joined(separator: "\n")

        #expect(text.contains("Failed to compile Swift heist source"))
    }

    @Test
    func `conditionals compile with concrete screen assertions`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let validSource = try temp.writeSwiftSource(
            named: "SnapshotConditional.swift",
            """
            import ThePlans

            func heist() throws -> HeistPlan {
                try HeistPlan("SnapshotConditional") {
                    If(.exists(.label("Ready"))) {
                        Warn("ready")
                    }

                    If {
                        Case(.missing(.label("Loading"))) {
                            Warn("loaded")
                        }

                        Else {
                            Warn("loading")
                        }
                    }
                }
            }
            """
        )
        let plan = try await HeistSwiftCompiler().compileFile(validSource)
        #expect(plan.body.count == 2)
    }

    @Test
    func `canonical predicate composition compiles`() async throws {
        let temp = try CompilerTemporaryDirectory()
        let validSource = try temp.writeSwiftSource(
            named: "PredicateComposition.swift",
            """
            import ThePlans

            func heist() throws -> HeistPlan {
                try HeistPlan("PredicateComposition") {
                    WaitFor(.exists(.label("Receipt")))
                    WaitFor(.missing(.label("Loading")))
                    WaitFor(.screenChanged("Receipt"))
                    WaitFor(.elementsChanged([
                        .updated(.identifier("count"), .value("3")),
                    ]))
                }
            }
            """
        )
        let plan = try await HeistSwiftCompiler().compileFile(validSource)
        #expect(plan.body.count == 4)
    }

    @Test
    func `compileDirectory compiles multiple Swift files into one catalog`() async throws {
        let temp = try CompilerTemporaryDirectory()
        _ = try temp.writeSwiftSource(named: "Alpha.swift", namedPlan: "Alpha")
        _ = try temp.writeSwiftSource(named: "Beta.swift", namedPlan: "Beta")

        let result = try await HeistSwiftCompiler().compileDirectory(temp.url)

        #expect(result.diagnostics.isEmpty)
        #expect(result.source == temp.url.standardizedFileURL)
        #expect(result.capabilities.map(\.name) == ["Alpha", "Beta"])
    }

    @Test
    func `compileDirectory returns catalog with non-error diagnostics`() async throws {
        let temp = try CompilerTemporaryDirectory()
        _ = try temp.writeSwiftSource(
            named: "Anonymous.swift",
            """
            import ThePlans

            func heist() throws -> HeistPlan {
                try HeistPlan {
                    Warn("anonymous")
                }
            }
            """
        )

        let result = try await HeistSwiftCompiler().compileDirectory(temp.url)

        #expect(result.capabilities.count == 1)
        #expect(result.diagnostics.map(\.code.knownCode) == [.catalogAnonymousCapability])
        #expect(result.diagnostics.map(\.kind) == [.warning])
        #expect(result.diagnostics.map { $0.sourceSpan?.sourceName } == [
            temp.url.appendingPathComponent("Anonymous.swift").path,
        ])
    }

    @Test
    func `compileDirectory fails duplicate capability names`() async throws {
        let temp = try CompilerTemporaryDirectory()
        _ = try temp.writeSwiftSource(named: "First.swift", namedPlan: "Duplicate")
        _ = try temp.writeSwiftSource(named: "Second.swift", namedPlan: "Duplicate")

        let diagnostics = try await buildDiagnostics {
            try await HeistSwiftCompiler().compileDirectory(temp.url)
        }
        let diagnostic = try #require(diagnostics.first)

        #expect(diagnostic.code.rawValue == "heist.catalog.duplicate_capability")
        #expect(diagnostic.phase == .planValidation)
        #expect(diagnostic.sourceSpan?.sourceName.hasSuffix("Second.swift") == true)
    }

    @Test
    func `compileDirectory does not derive names from filenames`() async throws {
        let temp = try CompilerTemporaryDirectory()
        _ = try temp.writeSwiftSource(named: "Filename.swift", namedPlan: "PlanName")

        let result = try await HeistSwiftCompiler().compileDirectory(temp.url)

        #expect(result.capabilities.map(\.name) == ["PlanName"])
        #expect(!result.capabilities.map { $0.name ?? "" }.contains("Filename"))
    }

    @Test
    func `compileDirectory ignores hidden files`() async throws {
        let temp = try CompilerTemporaryDirectory()
        _ = try temp.writeSwiftSource(named: ".Hidden.swift", "this is not Swift")
        _ = try temp.writeSwiftSource(named: "Visible.swift", namedPlan: "Visible")

        let result = try await HeistSwiftCompiler().compileDirectory(temp.url)

        #expect(result.capabilities.map(\.name) == ["Visible"])
    }

    @Test
    func `compileDirectory rejects anonymous capabilities in multi file catalog`() async throws {
        let temp = try CompilerTemporaryDirectory()
        _ = try temp.writeSwiftSource(
            named: "Anonymous.swift",
            """
            import ThePlans

            func heist() throws -> HeistPlan {
                try HeistPlan {
                    Warn("anonymous")
                }
            }
            """
        )
        _ = try temp.writeSwiftSource(named: "Named.swift", namedPlan: "Named")

        let diagnostics = try await buildDiagnostics {
            try await HeistSwiftCompiler().compileDirectory(temp.url)
        }

        #expect(diagnostics.map(\.description).joined(separator: "\n").contains("anonymous capability"))
    }

    @Test
    func testCompilerThrowsOrderedBuildDiagnostics() async throws {
        let temp = try CompilerTemporaryDirectory()
        _ = try temp.writeSwiftSource(named: "A.swift", namedPlan: "Valid")
        _ = try temp.writeSwiftSource(named: "B.swift", "not valid Swift")
        _ = try temp.writeSwiftSource(named: "C.swift", "also not valid Swift")

        do {
            _ = try await HeistSwiftCompiler().compileDirectory(temp.url)
            Issue.record("Expected directory compilation to throw")
        } catch let error {
            #expect(error.diagnostics.map { $0.sourceSpan?.sourceName }.compactMap { $0 } == [
                temp.url.appendingPathComponent("B.swift").path,
                temp.url.appendingPathComponent("C.swift").path,
            ])
            #expect(error.diagnostics.allSatisfy { $0.kind == .error })
        }
    }

#if os(macOS) || os(Linux)
    @Test
    func `explicit package root ignores sibling and nested checkouts`() throws {
        let temp = try CompilerTemporaryDirectory()
        let admittedRoot = try temp.makeButtonHeistPackage(named: "admitted")
        let admittedBuild = try temp.writeThePlansArtifacts(in: admittedRoot.appendingPathComponent(".build/debug"))
        let siblingRoot = try temp.makeButtonHeistPackage(named: "ButtonHeist")
        _ = try temp.writeThePlansArtifacts(in: siblingRoot.appendingPathComponent(".build/debug"))
        let nestedRoot = try temp.makeButtonHeistPackage(named: "admitted/ButtonHeist")
        _ = try temp.writeThePlansArtifacts(in: nestedRoot.appendingPathComponent(".build/debug"))

        let arguments = try HeistSwiftFileCompilation.resolveThePlansSwiftcArguments(
            explicitPackageRoot: admittedRoot,
            environment: [:],
            executableURL: nil,
            swiftPMBuildDirectory: { _ in admittedBuild }
        )

        #expect(arguments == temp.swiftPMArguments(for: admittedBuild))
    }

    @Test
    func `explicit package root wins over installed artifacts`() throws {
        let temp = try CompilerTemporaryDirectory()
        let localRoot = try temp.makeButtonHeistPackage(named: "local")
        let localBuild = try temp.writeThePlansArtifacts(in: localRoot.appendingPathComponent(".build/debug"))
        let installedExecutable = temp.url.appendingPathComponent("installed/bin/heist-plan")
        let installedBuild = try temp.writeInstalledThePlansArtifacts(for: installedExecutable)

        let arguments = try HeistSwiftFileCompilation.resolveThePlansSwiftcArguments(
            explicitPackageRoot: localRoot,
            environment: [:],
            executableURL: installedExecutable,
            swiftPMBuildDirectory: { _ in localBuild }
        )

        #expect(arguments == temp.swiftPMArguments(for: localBuild))
        #expect(arguments != temp.swiftPMArguments(for: installedBuild))
    }

    @Test
    func `explicit package root never selects artifacts outside that root`() throws {
        let temp = try CompilerTemporaryDirectory()
        let admittedRoot = try temp.makeButtonHeistPackage(named: "admitted")
        let outsideRoot = try temp.makeButtonHeistPackage(named: "neighbor")
        let outsideBuild = try temp.writeThePlansArtifacts(in: outsideRoot.appendingPathComponent(".build/debug"))

        do {
            _ = try HeistSwiftFileCompilation.resolveThePlansSwiftcArguments(
                explicitPackageRoot: admittedRoot,
                environment: [:],
                executableURL: nil,
                swiftPMBuildDirectory: { root in
                    root.appendingPathComponent(".build/native/debug", isDirectory: true)
                }
            )
            Issue.record("Expected explicit package root without artifacts to fail")
        } catch let error as HeistSwiftFileCompilationError {
            guard case .buildArtifactsNotFound(let searched, _) = error else {
                Issue.record("Expected build artifact diagnostic, got \(error)")
                return
            }
            #expect(searched.allSatisfy { $0.hasPrefix(admittedRoot.path + "/.build/") })
            #expect(!searched.contains(outsideBuild.path))
        }
    }

    @Test
    func `missing artifact context fails with typed diagnostic`() throws {
        #expect(throws: HeistSwiftFileCompilationError.packageRootNotFound) {
            _ = try HeistSwiftFileCompilation.resolveThePlansSwiftcArguments(
                explicitPackageRoot: nil,
                environment: [:],
                executableURL: nil
            )
        }
    }

    @Test
    func `installed executable prefix resolves its deterministic release artifact`() throws {
        let temp = try CompilerTemporaryDirectory()
        let executable = temp.url.appendingPathComponent("prefix/bin/heist-plan")
        let installedBuild = try temp.writeInstalledThePlansArtifacts(for: executable)

        let arguments = try HeistSwiftFileCompilation.resolveThePlansSwiftcArguments(
            explicitPackageRoot: nil,
            environment: [:],
            executableURL: executable
        )

        #expect(arguments == temp.swiftPMArguments(for: installedBuild))
    }

    @Test
    func `explicit environment artifact override has first precedence`() throws {
        let temp = try CompilerTemporaryDirectory()
        let localRoot = try temp.makeButtonHeistPackage(named: "local")
        _ = try temp.writeThePlansArtifacts(in: localRoot.appendingPathComponent(".build/debug"))
        let overrideBuild = try temp.writeThePlansArtifacts(in: temp.url.appendingPathComponent("override"))
        let executable = temp.url.appendingPathComponent("prefix/bin/heist-plan")
        _ = try temp.writeInstalledThePlansArtifacts(for: executable)

        let arguments = try HeistSwiftFileCompilation.resolveThePlansSwiftcArguments(
            explicitPackageRoot: localRoot,
            environment: ["HEIST_THEPLANS_BUILD_DIR": overrideBuild.path],
            executableURL: executable
        )

        #expect(arguments == temp.swiftPMArguments(for: overrideBuild))
    }

    @Test
    func `relative environment artifact override is rejected`() throws {
        #expect(throws: HeistSwiftFileCompilationError.self) {
            _ = try HeistSwiftFileCompilation.resolveThePlansSwiftcArguments(
                explicitPackageRoot: nil,
                environment: ["HEIST_THEPLANS_BUILD_DIR": ".build/debug"],
                executableURL: nil
            )
        }
    }

    @Test
    func `compiler command preserves exact argument contract`() {
        let compileDirectory = URL(fileURLWithPath: "/tmp/heist/Sources/PlanCompiler", isDirectory: true)
        let moduleCache = URL(fileURLWithPath: "/tmp/heist/module-cache", isDirectory: true)
        let executable = URL(fileURLWithPath: "/tmp/heist/Build/plan-compiler")
        let thePlansArguments = ["-I", "/tmp/heist/Modules", "/tmp/heist/ThePlans.o"]

        let command = HeistSwiftFileCompilation.planCompilerCommand(
            compileDirectory: compileDirectory,
            moduleCache: moduleCache,
            executableURL: executable,
            thePlansSwiftcArguments: thePlansArguments
        )

        #expect(command == HeistCompilerProcess.Command(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "swiftc",
                "-j",
                "1",
                "-num-threads",
                "1",
                "-swift-version",
                "6",
                "-module-cache-path",
                moduleCache.path,
                "-o",
                executable.path,
                compileDirectory.appendingPathComponent("main.swift").path,
                "-I",
                "/tmp/heist/Modules",
                "/tmp/heist/ThePlans.o",
            ]
        ))
    }
#endif

    @Test
    func `swiftPM metadata extraction selects active object files`() throws {
        let temp = try CompilerTemporaryDirectory()
        let objectDirectory = temp.url.appendingPathComponent("ThePlans.build", isDirectory: true)
        try FileManager.default.createDirectory(at: objectDirectory, withIntermediateDirectories: true)

        let activeObject = objectDirectory.appendingPathComponent("Active.swift.o")
        let staleObject = objectDirectory.appendingPathComponent("Stale.swift.o")
        let outsideObject = temp.url.appendingPathComponent("outside/Active.swift.o")
        try Data().write(to: activeObject)
        try Data().write(to: staleObject)
        try FileManager.default.createDirectory(
            at: outsideObject.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: outsideObject)

        let descriptionJSON = """
        {
          "swiftCommands": {
            "broken": [ "ignored" ],
            "other": {
              "moduleName": "Other",
              "objects": [ \(try jsonStringLiteral(staleObject.path)) ]
            },
            "theplans": {
              "moduleName": "ThePlans",
              "objects": [
                \(try jsonStringLiteral(outsideObject.path)),
                \(try jsonStringLiteral("/missing/build/Generated.swift"))
              ]
            }
          }
        }
        """
        try descriptionJSON.write(to: temp.url.appendingPathComponent("description.json"), atomically: true, encoding: .utf8)

        let objectFiles = try #require(try SwiftPMBuildDescription.activeSwiftObjectFiles(
            in: temp.url,
            moduleName: "ThePlans"
        ))
        #expect(objectFiles == [activeObject])
    }

}

private func buildDiagnostics<Value>(
    _ operation: () async throws -> Value
) async throws -> [HeistBuildDiagnostic] {
    do {
        _ = try await operation()
        throw CompilerTestFailure("Expected compilation to fail")
    } catch let error as HeistPlanBuildError {
        return error.diagnostics
    }
}

private final class CompilerTemporaryDirectory {
    private let fixture: TemporaryDirectoryFixture
    var url: URL { fixture.url }

    init() throws {
        fixture = try TemporaryDirectoryFixture(prefix: "heist-compiler-tests")
    }

    func writeSwiftSource(named fileName: String, _ source: String) throws -> URL {
        let url = url.appendingPathComponent(fileName)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeSwiftSource(named fileName: String, namedPlan name: String) throws -> URL {
        try writeSwiftSource(
            named: fileName,
            """
            import ThePlans

            func heist() throws -> HeistPlan {
                try HeistPlan("\(name)") {
                    Warn("ok")
                }
            }
            """
        )
    }

    func makeButtonHeistPackage(named name: String) throws -> URL {
        let packageRoot = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageRoot.appendingPathComponent("ButtonHeist/Sources/ThePlans", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "// swift-tools-version: 6.0\n".write(
            to: packageRoot.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        return packageRoot
    }

    func writeThePlansArtifacts(in buildDirectory: URL) throws -> URL {
        let modulesDirectory = buildDirectory.appendingPathComponent("Modules", isDirectory: true)
        let objectsDirectory = buildDirectory.appendingPathComponent("ThePlans.build", isDirectory: true)
        try FileManager.default.createDirectory(at: modulesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: objectsDirectory, withIntermediateDirectories: true)
        try Data().write(to: modulesDirectory.appendingPathComponent("ThePlans.swiftinterface"))
        try Data().write(to: objectsDirectory.appendingPathComponent("Identity.swift.o"))
        return buildDirectory
    }

    func writeInstalledThePlansArtifacts(for executable: URL) throws -> URL {
        let prefix = executable.deletingLastPathComponent().deletingLastPathComponent()
        let buildDirectory = prefix
            .appendingPathComponent("lib/ThePlans", isDirectory: true)
            .appendingPathComponent(currentTestArchitectureBuildDirectoryName(), isDirectory: true)
            .appendingPathComponent("release", isDirectory: true)
        return try writeThePlansArtifacts(in: buildDirectory)
    }

    func swiftPMArguments(for buildDirectory: URL) -> [String] {
        [
            "-I",
            buildDirectory.appendingPathComponent("Modules", isDirectory: true).path,
            buildDirectory.appendingPathComponent("ThePlans.build/Identity.swift.o").path,
        ]
    }
}

private func currentTestArchitectureBuildDirectoryName() -> String {
    #if arch(arm64)
    return "arm64-apple-macosx"
    #elseif arch(x86_64)
    return "x86_64-apple-macosx"
    #else
    return "unsupported-architecture"
    #endif
}

private func jsonStringLiteral(_ value: String) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let literal = String(data: data, encoding: .utf8) else {
        throw CompilerTestFailure("could not encode JSON string literal")
    }
    return literal
}

private struct CompilerTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
