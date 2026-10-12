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

/// Compiles trusted local Swift authoring files into canonical heist plans.
///
/// This operation invokes the external Swift toolchain and executes a generated
/// wrapper; it does not implement a Swift compiler.
/// Do not use it for remote or inline source; those inputs belong to
/// `HeistSourceParser`, whose restricted grammar cannot execute arbitrary code.
public enum HeistPlanCompiler {
    public struct Configuration: Sendable, Equatable {
        public static let `default` = Configuration()

        public let packageRoot: URL?
        let processLimits: HeistCompilerProcess.Limits
        let temporaryDirectory: URL

        public init(packageRoot: URL? = nil) {
            self.packageRoot = packageRoot
            self.processLimits = .default
            self.temporaryDirectory = FileManager.default.temporaryDirectory
        }

        init(
            packageRoot: URL? = nil,
            processLimits: HeistCompilerProcess.Limits,
            temporaryDirectory: URL = FileManager.default.temporaryDirectory
        ) {
            self.packageRoot = packageRoot
            self.processLimits = processLimits
            self.temporaryDirectory = temporaryDirectory
        }
    }

    public static func compile(
        file url: URL,
        entry: HeistEntrySymbol = "heist",
        configuration: Configuration = .default
    ) async throws(HeistPlanBuildError) -> HeistPlan {
        let source = url.standardizedFileURL
        do {
            try Task.checkCancellation()
#if os(macOS) || os(Linux)
            let plan = try await HeistSwiftCompilation.compile(
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
}

private extension HeistPlanCompiler {
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
