import Foundation

#if os(macOS) || os(Linux)
private enum HeistSwiftFileCompilationEnvironmentKey: String, Sendable, CustomStringConvertible {
    case thePlansBuildDirectory = "HEIST_THEPLANS_BUILD_DIR"
    case sourceCompilerTrace = "HEIST_SOURCE_COMPILER_TRACE"

    var description: String { rawValue }
}

private extension Dictionary where Key == String, Value == String {
    subscript(_ key: HeistSwiftFileCompilationEnvironmentKey) -> String? {
        self[key.rawValue]
    }
}

struct HeistSwiftFileCompilation: Sendable {
    let packageRoot: URL?
    let processLimits: HeistCompilerProcess.Limits
    let temporaryDirectory: URL

    private init(
        packageRoot: URL?,
        processLimits: HeistCompilerProcess.Limits,
        temporaryDirectory: URL
    ) {
        self.packageRoot = packageRoot
        self.processLimits = processLimits
        self.temporaryDirectory = temporaryDirectory
    }

    static func compile(
        _ source: URL,
        entry: HeistEntrySymbol,
        packageRoot: URL?,
        processLimits: HeistCompilerProcess.Limits,
        temporaryDirectory: URL
    ) async throws -> HeistPlan {
        try await Self(
            packageRoot: packageRoot,
            processLimits: processLimits,
            temporaryDirectory: temporaryDirectory
        ).compile(source, entry: entry)
    }

    /// Persistent, shared swiftc module cache for plan compilation. Reused
    /// across compiles so the Foundation/ThePlans module interfaces are built
    /// once per toolchain rather than on every plan.
    static let sharedModuleCacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("buttonheist-heist-plan-module-cache", isDirectory: true)

    func compile(
        _ source: URL,
        entry: HeistEntrySymbol
    ) async throws -> HeistPlan {
        try Task.checkCancellation()
        let source = source.standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw HeistSwiftFileCompilationError.sourceFileNotFound(source.path)
        }
        HeistSwiftFileCompilationTrace.write("preparing Swift heist compile")
        let thePlansSwiftcArguments = try Self.resolveThePlansSwiftcArguments(explicitPackageRoot: packageRoot)

        let tempURL = temporaryDirectory
            .appendingPathComponent("heist-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let buildDirectory = tempURL.appendingPathComponent("Build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)

        // Persist the module cache across compiles. A fresh per-compile cache
        // forced swiftc to rebuild the Foundation/ThePlans module interfaces on
        // every run — the dominant per-plan cost (~2.5s of ~3s). swiftc keys
        // cache entries by content hash, so sharing the path is safe and warm
        // compiles drop to sub-second.
        let moduleCache = Self.sharedModuleCacheDirectory
        try FileManager.default.createDirectory(at: moduleCache, withIntermediateDirectories: true)

        let compileDirectory = try writeCompileDirectory(
            at: tempURL,
            source: source,
            entry: entry
        )

        return try await compile(
            source: source,
            compileDirectory: compileDirectory,
            buildDirectory: buildDirectory,
            moduleCache: moduleCache,
            thePlansSwiftcArguments: thePlansSwiftcArguments
        )
    }

    private func compile(
        source: URL,
        compileDirectory: URL,
        buildDirectory: URL,
        moduleCache: URL,
        thePlansSwiftcArguments: [String]
    ) async throws -> HeistPlan {
        let executableURL = buildDirectory.appendingPathComponent("plan-compiler")
        HeistSwiftFileCompilationTrace.write("compiling Swift heist wrapper against built ThePlans artifacts")
        let compilerResult = try await HeistCompilerProcess.Runner.shared.execute(
            Self.planCompilerCommand(
                compileDirectory: compileDirectory,
                moduleCache: moduleCache,
                executableURL: executableURL,
                thePlansSwiftcArguments: thePlansSwiftcArguments
            ),
            purpose: .compilation,
            limits: processLimits
        )
        _ = try successfulOutput(
            from: compilerResult,
            phase: .compilation(source.path)
        )

        HeistSwiftFileCompilationTrace.write("running Swift heist wrapper")
        let executionResult = try await HeistCompilerProcess.Runner.shared.execute(
            HeistCompilerProcess.Command(executable: executableURL, arguments: []),
            purpose: .execution,
            limits: processLimits
        )
        let output = try successfulOutput(
            from: executionResult,
            phase: .execution(source.path)
        )

        do {
            return try HeistPlanJSONCodec.decodeValidatedPlan(output.stdout, sourceURL: source)
        } catch let error as HeistPlanJSONCodecError {
            throw HeistSwiftFileCompilationError.invalidCompilerOutput(error.description)
        } catch let error as HeistPlanRuntimeSafetyError {
            throw HeistSwiftFileCompilationError.runtimeSafetyFailed(error.description)
        } catch {
            throw HeistSwiftFileCompilationError.invalidCompilerOutput(String(describing: error))
        }
    }

    private func successfulOutput(
        from outcome: HeistCompilerProcess.Outcome,
        phase: HeistSwiftFileCompilationProcessPhase
    ) throws -> HeistCompilerProcess.Output {
        switch outcome {
        case .succeeded(let output):
            return output
        case .nonzeroExit(let code, let output):
            throw phase.nonzeroExit(code: code, diagnostics: output.diagnostics)
        case .signaled(let signal, let output):
            throw phase.signaled(signal: signal, diagnostics: output.diagnostics)
        case .timedOut(let output):
            throw phase.timedOut(diagnostics: output.diagnostics)
        case .cancelled:
            throw CancellationError()
        case .outputLimitExceeded(let stream, let output):
            throw phase.outputLimitExceeded(stream: stream, diagnostics: output.diagnostics)
        }
    }

    private func writeCompileDirectory(
        at tempURL: URL,
        source: URL,
        entry: HeistEntrySymbol
    ) throws -> URL {
        let sourcesURL = tempURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("PlanCompiler", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)

        let wrapper = """
        \(sourceLocationDirective(for: source))
        \(try String(contentsOf: source, encoding: .utf8))

        #sourceLocation()
        import Foundation
        import ThePlans

        let plan: HeistPlan = try \(entry)()
        FileHandle.standardOutput.write(try plan.canonicalHeistJSONData())
        """
        try wrapper.write(
            to: sourcesURL.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
        return sourcesURL
    }

    package static func planCompilerCommand(
        compileDirectory: URL,
        moduleCache: URL,
        executableURL: URL,
        thePlansSwiftcArguments: [String]
    ) -> HeistCompilerProcess.Command {
        var arguments = [
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
            executableURL.path,
            compileDirectory.appendingPathComponent("main.swift").path,
        ]
        arguments.append(contentsOf: thePlansSwiftcArguments)
        return HeistCompilerProcess.Command(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: arguments
        )
    }

    private func sourceLocationDirective(for source: URL) -> String {
        "#sourceLocation(file: \(swiftStringLiteral(source.path)), line: 1)"
    }

    private func swiftStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
        return #""\#(escaped)""#
    }
}

extension HeistSwiftFileCompilation {
    private static let environmentOverrideKey = HeistSwiftFileCompilationEnvironmentKey.thePlansBuildDirectory

    static func resolveThePlansSwiftcArguments(explicitPackageRoot: URL?) throws -> [String] {
        try resolveThePlansSwiftcArguments(
            explicitPackageRoot: explicitPackageRoot,
            environment: ProcessInfo.processInfo.environment,
            executableURL: currentExecutableURL()
        )
    }

    static func resolveThePlansSwiftcArguments(
        explicitPackageRoot: URL?,
        environment: [String: String],
        executableURL: URL?
    ) throws -> [String] {
        try resolveThePlansSwiftcArguments(
            explicitPackageRoot: explicitPackageRoot,
            environment: environment,
            executableURL: executableURL,
            swiftPMBuildDirectory: swiftPMBuildDirectory(for:)
        )
    }

    static func resolveThePlansSwiftcArguments(
        explicitPackageRoot: URL?,
        environment: [String: String],
        executableURL: URL?,
        swiftPMBuildDirectory: (URL) throws -> URL
    ) throws -> [String] {
        // The override is an explicit boundary contract for Xcode and release
        // automation. It deliberately wins over every other context.
        if let override = environmentOverridePath(in: environment) {
            HeistSwiftFileCompilationTrace.write("resolving \(environmentOverrideKey) override at \(override)")
            guard (override as NSString).isAbsolutePath else {
                throw HeistSwiftFileCompilationError.buildArtifactsNotFound(
                    searched: [override],
                    hint: "\(environmentOverrideKey) must name one absolute build directory."
                )
            }
            let buildDirectory = URL(fileURLWithPath: override, isDirectory: true)
            if let arguments = try resolveSwiftPMBuildDirectory(buildDirectory) {
                HeistSwiftFileCompilationTrace.write("using built ThePlans artifacts at \(buildDirectory.path)")
                return arguments
            }
            if let arguments = resolveXcodeProductsDirectory(buildDirectory) {
                HeistSwiftFileCompilationTrace.write("using built ThePlans artifacts at \(buildDirectory.path)")
                return arguments
            }
            throw HeistSwiftFileCompilationError.buildArtifactsNotFound(
                searched: [buildDirectory.path],
                hint: """
                \(environmentOverrideKey)=\(override) does not contain built ThePlans artifacts \
                (expected Modules/ThePlans.swiftmodule or Modules/ThePlans.swiftinterface and ThePlans.build/*.swift.o, or \
                ThePlans.framework in an Xcode products directory). \
                Build them with `swift build --product heist-plan` \
                and point \(environmentOverrideKey) at the absolute path of `.build/debug`.
                """
            )
        }

        if let explicitPackageRoot {
            let packageRoot = try admittedPackageRoot(explicitPackageRoot)
            HeistSwiftFileCompilationTrace.write("checking ButtonHeist package root: \(packageRoot.path)")
            let buildDirectory = try swiftPMBuildDirectory(packageRoot)
            if let arguments = try resolveSwiftPMBuildDirectory(buildDirectory) {
                HeistSwiftFileCompilationTrace.write("using built ThePlans artifacts at \(buildDirectory.path)")
                return arguments
            }

            throw HeistSwiftFileCompilationError.buildArtifactsNotFound(
                searched: [buildDirectory.path],
                hint: """
                SwiftPM reports no built ThePlans artifacts for \(packageRoot.path). \
                Build that package with `swift build --product heist-plan`, or set \
                \(environmentOverrideKey) to the absolute path of one exact SwiftPM build directory \
                or Xcode products directory.
                """
            )
        }

        guard let installedBuildDirectory = installedBuildDirectory(for: executableURL) else {
            throw HeistSwiftFileCompilationError.packageRootNotFound
        }
        HeistSwiftFileCompilationTrace.write("checking installed ThePlans artifacts: \(installedBuildDirectory.path)")
        if let arguments = try resolveSwiftPMBuildDirectory(installedBuildDirectory) {
            HeistSwiftFileCompilationTrace.write("using built ThePlans artifacts at \(installedBuildDirectory.path)")
            return arguments
        }

        throw HeistSwiftFileCompilationError.buildArtifactsNotFound(
            searched: [installedBuildDirectory.path],
            hint: """
            The installed executable's prefix does not contain its required ThePlans artifacts. \
            Reinstall Button Heist, supply Configuration(packageRoot:), or set \
            \(environmentOverrideKey) to one exact SwiftPM build directory or Xcode products directory.
            """
        )
    }
}

private extension HeistSwiftFileCompilation {

    private static func environmentOverridePath(in environment: [String: String]) -> String? {
        guard let override = environment[environmentOverrideKey],
              !override.isEmpty else {
            return nil
        }
        return override
    }

    private static func admittedPackageRoot(_ url: URL) throws -> URL {
        let packageRoot = url.standardizedFileURL
        let manifest = packageRoot.appendingPathComponent("Package.swift")
        let directSources = packageRoot.appendingPathComponent("Sources/ThePlans", isDirectory: true)
        let repositorySources = packageRoot.appendingPathComponent("ButtonHeist/Sources/ThePlans", isDirectory: true)
        let containsThePlans = FileManager.default.fileExists(atPath: directSources.path)
            || FileManager.default.fileExists(atPath: repositorySources.path)
        guard FileManager.default.fileExists(atPath: manifest.path),
              containsThePlans else {
            throw HeistSwiftFileCompilationError.packageRootNotFound
        }
        return packageRoot
    }

    private static func currentExecutableURL() -> URL? {
        if let executableURL = Bundle.main.executableURL {
            return executableURL
        }
        guard let rawExecutable = CommandLine.arguments.first,
              rawExecutable.contains("/") else {
            return nil
        }
        return URL(fileURLWithPath: rawExecutable)
    }

    private static func installedBuildDirectory(for executableURL: URL?) -> URL? {
        guard let executableURL else { return nil }
        let executable = executableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let binDirectory = executable.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else { return nil }
        let prefix = binDirectory.deletingLastPathComponent()
        guard let architecture = currentArchitectureBuildDirectoryName() else {
            return nil
        }
        return prefix
            .appendingPathComponent("lib/ThePlans", isDirectory: true)
            .appendingPathComponent(architecture, isDirectory: true)
            .appendingPathComponent("release", isDirectory: true)
    }

    private static func currentArchitectureBuildDirectoryName() -> String? {
        #if arch(arm64)
        return "arm64-apple-macosx"
        #elseif arch(x86_64)
        return "x86_64-apple-macosx"
        #else
        return nil
        #endif
    }

    private static func resolveSwiftPMBuildDirectory(_ buildDirectory: URL) throws -> [String]? {
        let modulesDirectory = buildDirectory.appendingPathComponent("Modules", isDirectory: true)
        let binaryModule = modulesDirectory.appendingPathComponent("ThePlans.swiftmodule")
        let textualModuleInterface = modulesDirectory.appendingPathComponent("ThePlans.swiftinterface")
        let objectsDirectory = buildDirectory.appendingPathComponent("ThePlans.build", isDirectory: true)
        guard FileManager.default.fileExists(atPath: binaryModule.path)
                || FileManager.default.fileExists(atPath: textualModuleInterface.path) else {
            return nil
        }
        let objectFiles = try SwiftPMBuildDescription.activeSwiftObjectFiles(
            in: buildDirectory,
            moduleName: "ThePlans"
        ) ?? swiftObjectFiles(in: objectsDirectory)
        guard !objectFiles.isEmpty else {
            return nil
        }
        return [
            "-I",
            modulesDirectory.path,
        ] + objectFiles.map(\.path)
    }

    private static func resolveXcodeProductsDirectory(_ productsDirectory: URL) -> [String]? {
        let frameworkDirectory = productsDirectory.appendingPathComponent("ThePlans.framework", isDirectory: true)
        let binary = frameworkDirectory.appendingPathComponent("ThePlans")
        let swiftModuleDirectory = frameworkDirectory
            .appendingPathComponent("Modules", isDirectory: true)
            .appendingPathComponent("ThePlans.swiftmodule", isDirectory: true)
        guard FileManager.default.fileExists(atPath: binary.path),
              FileManager.default.fileExists(atPath: swiftModuleDirectory.path) else {
            return nil
        }
        return [
            "-F",
            productsDirectory.path,
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            productsDirectory.path,
            "-framework",
            "ThePlans",
        ]
    }

    private static func swiftPMBuildDirectory(for packageRoot: URL) throws -> URL {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            "build",
            "--show-bin-path",
            "--package-path",
            packageRoot.path,
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let output = String(
            bytes: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0,
              !output.isEmpty,
              (output as NSString).isAbsolutePath else {
            let diagnostics = String(
                bytes: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw HeistSwiftFileCompilationError.buildArtifactsNotFound(
                searched: [packageRoot.path],
                hint: "SwiftPM could not resolve this package's build directory: \(diagnostics)"
            )
        }
        return URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
    }

    private static func swiftObjectFiles(in directory: URL) throws -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try entries
            .filter { $0.lastPathComponent.hasSuffix(".swift.o") }
            .filter {
                let values = try $0.resourceValues(forKeys: [.isRegularFileKey])
                return values.isRegularFile == true
            }
            .map { directory.appendingPathComponent($0.lastPathComponent) }
            .sorted { $0.path < $1.path }
    }

}

struct SwiftPMBuildDescription: Decodable {
    let swiftCommands: [String: SwiftPMBuildCommand]

    private enum CodingKeys: String, CodingKey {
        case swiftCommands
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            swiftCommands = [:]
            return
        }
        swiftCommands = (try? container.decode([String: SwiftPMBuildCommand].self, forKey: .swiftCommands)) ?? [:]
    }

    static func activeSwiftObjectFiles(
        in buildDirectory: URL,
        moduleName: String
    ) throws -> [URL]? {
        let descriptionURL = buildDirectory.appendingPathComponent("description.json")
        guard let data = try? Data(contentsOf: descriptionURL) else {
            return nil
        }

        let description = try JSONDecoder().decode(SwiftPMBuildDescription.self, from: data)
        for command in description.swiftCommands.values {
            guard command.moduleName == moduleName,
                  let objectPaths = command.objects else {
                continue
            }

            let objectFiles = try objectPaths.compactMap { path -> URL? in
                let originalURL = URL(fileURLWithPath: path)
                guard originalURL.lastPathComponent.hasSuffix(".swift.o") else { return nil }
                // description.json may retain the path from the build that was
                // staged. The admitted build directory, not that stale path,
                // owns the object identity used for this compilation.
                let admittedURL = buildDirectory
                    .appendingPathComponent("ThePlans.build", isDirectory: true)
                    .appendingPathComponent(originalURL.lastPathComponent)
                let values = try admittedURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { return nil }
                return admittedURL
            }
            return objectFiles.sorted { $0.path < $1.path }
        }

        return nil
    }
}

struct SwiftPMBuildCommand: Decodable {
    let moduleName: String?
    let objects: [String]?

    private enum CodingKeys: String, CodingKey {
        case moduleName
        case objects
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            moduleName = nil
            objects = nil
            return
        }
        moduleName = try? container.decode(String.self, forKey: .moduleName)
        objects = try? container.decode([String].self, forKey: .objects)
    }
}

private enum HeistSwiftFileCompilationTrace {
    static func write(_ message: String) {
        guard ProcessInfo.processInfo.environment[.sourceCompilerTrace] == "1" else {
            return
        }

        let line = "heist-source-compiler: \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

#endif
