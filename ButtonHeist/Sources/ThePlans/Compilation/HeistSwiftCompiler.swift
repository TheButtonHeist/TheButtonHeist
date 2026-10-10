import Foundation

public enum Severity: String, Sendable, Equatable {
    case error
    case warning
}

public struct HeistBuildSourceLocation: Sendable, Equatable, CustomStringConvertible {
    public let url: URL
    public let line: Int?
    public let column: Int?

    public init(url: URL, line: Int? = nil, column: Int? = nil) {
        self.url = url
        self.line = line
        self.column = column
    }

    public var description: String {
        var result = url.path
        if let line {
            result += ":\(line)"
        }
        if let column {
            result += ":\(column)"
        }
        return result
    }
}

public struct HeistCatalogCompilationResult: Sendable, Equatable {
    public let source: URL
    public let capabilities: [HeistPlan]
    public let diagnostics: [HeistBuildDiagnostic]
}

public actor HeistSwiftCompiler {
    public struct Configuration: Sendable, Equatable {
        public static let `default` = Configuration()

        public let packageRoot: URL?
        public let directoryEntry: HeistEntrySymbol
        let processLimits: HeistCompilerProcess.Limits
        let temporaryDirectory: URL

        public init(
            packageRoot: URL? = nil,
            directoryEntry: HeistEntrySymbol = "heist"
        ) {
            self.packageRoot = packageRoot
            self.directoryEntry = directoryEntry
            self.processLimits = .default
            self.temporaryDirectory = FileManager.default.temporaryDirectory
        }

        init(
            packageRoot: URL? = nil,
            directoryEntry: HeistEntrySymbol = "heist",
            processLimits: HeistCompilerProcess.Limits,
            temporaryDirectory: URL = FileManager.default.temporaryDirectory
        ) {
            self.packageRoot = packageRoot
            self.directoryEntry = directoryEntry
            self.processLimits = processLimits
            self.temporaryDirectory = temporaryDirectory
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    public func compileFile(
        _ url: URL,
        entry: HeistEntrySymbol = "heist"
    ) async throws(HeistPlanBuildError) -> HeistPlan {
        let source = url.standardizedFileURL
        do {
            try Task.checkCancellation()
#if os(macOS) || os(Linux)
            let plan = try await HeistSwiftFileCompilation.compile(
                source,
                entry: entry,
                packageRoot: configuration.packageRoot,
                processLimits: configuration.processLimits,
                temporaryDirectory: configuration.temporaryDirectory
            )
            try Task.checkCancellation()
            return plan
#else
            throw HeistPlanBuildError(diagnostics: [
                Self.diagnostic(
                    code: .swiftCompilationUnsupportedPlatform,
                    "Swift heist source compilation is only supported on macOS and Linux.",
                    source: source
                ),
            ])
#endif
        } catch is CancellationError {
            throw HeistPlanBuildError(diagnostics: [Self.diagnostic(
                code: .swiftCompilationCancelled,
                "Swift heist compilation was cancelled.",
                source: source
            )])
        } catch let error as HeistPlanBuildError {
            throw error
        } catch {
            throw HeistPlanBuildError(diagnostics: Self.diagnostics(for: error, source: source))
        }
    }

    public func compileDirectory(
        _ url: URL
    ) async throws(HeistPlanBuildError) -> HeistCatalogCompilationResult {
        let directory = url.standardizedFileURL
        do {
            try Task.checkCancellation()
            let sources = try Self.sourceFiles(in: directory)
            guard !sources.isEmpty else {
                throw HeistPlanBuildError(diagnostics: [
                    Self.diagnostic(
                        code: .directoryNoSources,
                        "Directory contains no Swift heist source files.",
                        phase: .planning,
                        source: directory
                    ),
                ])
            }

            var plans: [HeistPlan] = []
            var diagnostics: [HeistBuildDiagnostic] = []
            for source in sources {
                try Task.checkCancellation()
                do {
                    plans.append(try await compileFile(source, entry: configuration.directoryEntry))
                } catch let error {
                    diagnostics.append(contentsOf: error.diagnostics)
                }
            }

            guard diagnostics.allSatisfy({ $0.severity != .error }) else {
                throw HeistPlanBuildError(diagnostics: diagnostics)
            }
            diagnostics.append(contentsOf: Self.catalogDiagnostics(for: plans, sources: sources))
            guard diagnostics.allSatisfy({ $0.severity != .error }) else {
                throw HeistPlanBuildError(diagnostics: diagnostics)
            }

            return HeistCatalogCompilationResult(
                source: directory,
                capabilities: plans,
                diagnostics: diagnostics
            )
        } catch is CancellationError {
            throw HeistPlanBuildError(diagnostics: [Self.diagnostic(
                code: .directoryCancelled,
                "Swift heist directory compilation was cancelled.",
                phase: .planning,
                source: directory
            )])
        } catch let error as HeistPlanBuildError {
            throw error
        } catch {
            throw HeistPlanBuildError(
                diagnostics: Self.diagnostics(for: error, source: directory)
            )
        }
    }
}

private extension HeistSwiftCompiler {
    static func sourceFiles(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw HeistPlanBuildError(diagnostic: diagnostic(
                code: .directoryNotDirectory,
                "Heist catalog source is not a directory.",
                phase: .planning,
                source: directory
            ))
        }

        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var swiftSources: [URL] = []
        var unsupportedHeistSources: [URL] = []
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if entry.pathExtension.lowercased() == "swift" {
                swiftSources.append(entry.standardizedFileURL)
            } else if looksLikeHeistSource(entry) {
                unsupportedHeistSources.append(entry.standardizedFileURL)
            }
        }

        guard unsupportedHeistSources.isEmpty else {
            throw HeistPlanBuildError(diagnostics: unsupportedHeistSources.map {
                diagnostic(
                    code: .directoryUnsupportedSourceFile,
                    "Unsupported heist source file. Directory compilation only accepts .swift files.",
                    phase: .planning,
                    source: $0
                )
            })
        }
        return swiftSources.sorted { $0.path < $1.path }
    }

    static func looksLikeHeistSource(_ url: URL) -> Bool {
        let lowercasedName = url.lastPathComponent.lowercased()
        if lowercasedName == "readme" || lowercasedName.hasPrefix("readme.") {
            return false
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let source = String(data: Data(data.prefix(64 * 1024)), encoding: .utf8) else {
            return false
        }
        return source.contains("import ThePlans")
            || source.contains("HeistPlan(")
            || source.contains("Warn(")
            || source.contains("Activate(")
    }

    static func catalogDiagnostics(
        for plans: [HeistPlan],
        sources: [URL]
    ) -> [HeistBuildDiagnostic] {
        var diagnostics: [HeistBuildDiagnostic] = []
        var seen: [HeistDefinitionPath: URL] = [:]

        for (index, plan) in plans.enumerated() {
            let source = sources[index]
            if plan.name == nil {
                diagnostics.append(diagnostic(
                    code: .catalogAnonymousCapability,
                    "Directory heist source compiled an anonymous capability. Name directory capabilities in the authored HeistPlan.",
                    severity: plans.count > 1 ? .error : .warning,
                    phase: .planValidation,
                    source: source
                ))
            }

            do {
                let descriptions = try plan.heistDescriptions()
                for description in descriptions {
                    guard let lookupPath = description.identity.lookupPath else { continue }
                    if let previous = seen[lookupPath] {
                        diagnostics.append(diagnostic(
                            code: .catalogDuplicateCapability,
                            "Duplicate capability name \"\(description.identity.displayName)\" also compiled from \(previous.lastPathComponent).",
                            phase: .planValidation,
                            source: source
                        ))
                    } else {
                        seen[lookupPath] = source
                    }
                }
            } catch let error as HeistCatalogError {
                diagnostics.append(diagnostic(
                    code: .catalogInvalidEntry,
                    error.description,
                    phase: .planValidation,
                    source: source
                ))
            } catch {
                diagnostics.append(diagnostic(
                    code: .catalogInvalidEntry,
                    "Invalid compiled catalog entry: \(bounded(errorDescription: error))",
                    phase: .planValidation,
                    source: source
                ))
            }
        }

        return diagnostics
    }

    static func diagnostics(
        for error: Error,
        source: URL?
    ) -> [HeistBuildDiagnostic] {
        return [diagnostic(bounded(errorDescription: error), source: source)]
    }

    static func diagnostic(
        code: HeistKnownBuildDiagnosticCode = .swiftCompilationFailed,
        _ message: String,
        severity: Severity = .error,
        phase: HeistBuildPhase = .swiftCompilation,
        source: URL?
    ) -> HeistBuildDiagnostic {
        HeistBuildDiagnostic(
            code: code,
            kind: severity.diagnosticKind,
            phase: phase,
            sourceSpan: source.map {
                HeistBuildSourceSpan(
                    sourceName: $0.path,
                    offset: 0,
                    line: 1,
                    column: 1
                )
            },
            message: message,
            hint: nil
        )
    }

    static func bounded(errorDescription error: Error) -> String {
        bounded(String(describing: error))
    }

    static func bounded(_ message: String, maxLines: Int = 12, maxCharacters: Int = 2_000) -> String {
        var lines = message
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines)) + ["..."]
        }
        var compact = lines.joined(separator: "\n")
        if compact.count > maxCharacters {
            compact = String(compact.prefix(maxCharacters)) + "..."
        }
        return compact.isEmpty ? "no compiler diagnostics" : compact
    }
}

private extension Severity {
    var diagnosticKind: HeistBuildDiagnosticKind {
        switch self {
        case .error:
            return .error
        case .warning:
            return .warning
        }
    }
}
