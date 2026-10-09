import Foundation

#if os(macOS) || os(Linux)
extension HeistPlanBuildError {
    static func swiftCompilation(
        code: HeistKnownBuildDiagnosticCode,
        _ message: String,
        phase: HeistBuildPhase = .swiftCompilation,
        source: URL?
    ) -> HeistPlanBuildError {
        HeistPlanBuildError(diagnostic: HeistBuildDiagnostic(
            code: code,
            phase: phase,
            sourceSpan: source.map {
                HeistBuildSourceSpan(
                    sourceName: $0.path,
                    offset: 0,
                    line: 1,
                    column: 1
                )
            },
            message: message
        ))
    }

    static func swiftSourceNotFound(_ source: URL) -> HeistPlanBuildError {
        swiftCompilation(
            code: .swiftCompilationSourceNotFound,
            "Swift heist source file not found: \(source.path).",
            source: source
        )
    }

    static func swiftPackageRootNotFound(source: URL? = nil) -> HeistPlanBuildError {
        swiftCompilation(
            code: .swiftCompilationPackageRootNotFound,
            boundedCompilerDiagnostics("""
            Swift plan compilation has no admitted ThePlans artifact context. \
            Supply HeistSwiftCompiler.Configuration(packageRoot:) with one ButtonHeist package root, \
            run an installed Button Heist executable with its lib/ThePlans artifacts, or set \
            HEIST_THEPLANS_BUILD_DIR to one exact build directory holding ThePlans artifacts \
            (Modules/ThePlans.swiftmodule or Modules/ThePlans.swiftinterface, plus ThePlans.build/*.swift.o).
            """),
            source: source
        )
    }

    static func swiftBuildArtifactsNotFound(
        searched: [String],
        hint: String,
        source: URL? = nil
    ) -> HeistPlanBuildError {
        let searchedList = searched.map { "  - \($0)" }.joined(separator: "\n")
        return swiftCompilation(
            code: .swiftCompilationBuildArtifactsNotFound,
            boundedCompilerDiagnostics("""
            could not find built ThePlans artifacts for Swift compilation.
            searched:
            \(searchedList)
            \(hint)
            """),
            source: source
        )
    }

    static func invalidSwiftCompilerOutput(
        _ diagnostics: String,
        source: URL,
        entry: HeistEntrySymbol
    ) -> HeistPlanBuildError {
        swiftCompilation(
            code: .swiftCompilationInvalidOutput,
            "Compiled Swift heist source\(entrySuffix(entry)) did not emit valid HeistPlan JSON: \(boundedCompilerDiagnostics(diagnostics))",
            source: source
        )
    }

    static func swiftRuntimeSafetyFailure(
        _ diagnostics: String,
        source: URL,
        entry: HeistEntrySymbol
    ) -> HeistPlanBuildError {
        swiftCompilation(
            code: .planRuntimeSafety,
            "Compiled Swift heist source\(entrySuffix(entry)) failed runtime safety: \(boundedCompilerDiagnostics(diagnostics))",
            phase: .planValidation,
            source: source
        )
    }

    fileprivate static func entrySuffix(_ entry: HeistEntrySymbol) -> String {
        " entry \(CanonicalValueDescription.quoted(entry.description))"
    }

    fileprivate static func boundedCompilerDiagnostics(
        _ message: String,
        maxLines: Int = 12,
        maxCharacters: Int = 2_000
    ) -> String {
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

enum HeistSwiftFileCompilationProcessPhase {
    case compilation(source: URL, entry: HeistEntrySymbol)
    case execution(source: URL, entry: HeistEntrySymbol)

    func nonzeroExit(code: Int32, diagnostics: String) -> HeistPlanBuildError {
        let details = processDetails(prefix: "exit code \(code)", diagnostics: diagnostics)
        return failure(
            compilation: (
                .swiftCompilationCompileFailed,
                "Failed to compile Swift heist source\(entrySuffix): \(Self.bounded(details))"
            ),
            execution: (
                .swiftCompilationExecutionFailed,
                "Compiled Swift heist source\(entrySuffix) failed while evaluating the entry: \(Self.bounded(details))"
            )
        )
    }

    func signaled(signal: Int32, diagnostics: String) -> HeistPlanBuildError {
        failure(
            compilation: (
                .swiftCompilationCompilerTerminated,
                "Swift compiler\(entrySuffix) terminated by signal \(signal): \(Self.bounded(diagnostics))"
            ),
            execution: (
                .swiftCompilationExecutionTerminated,
                "Compiled Swift heist source\(entrySuffix) terminated by signal \(signal): \(Self.bounded(diagnostics))"
            )
        )
    }

    func timedOut(diagnostics: String) -> HeistPlanBuildError {
        failure(
            compilation: (
                .swiftCompilationCompileTimedOut,
                "Swift heist source compilation\(entrySuffix) exceeded its deadline: \(Self.bounded(diagnostics))"
            ),
            execution: (
                .swiftCompilationExecutionTimedOut,
                "Compiled Swift heist source\(entrySuffix) exceeded its evaluation deadline: \(Self.bounded(diagnostics))"
            )
        )
    }

    func outputLimitExceeded(
        stream: HeistCompilerProcess.OutputStream,
        diagnostics: String
    ) -> HeistPlanBuildError {
        failure(
            compilation: (
                .swiftCompilationCompileOutputLimitExceeded,
                "Swift compiler\(entrySuffix) exceeded its \(stream.rawValue) output limit: \(Self.bounded(diagnostics))"
            ),
            execution: (
                .swiftCompilationExecutionOutputLimitExceeded,
                "Compiled Swift heist source\(entrySuffix) exceeded its \(stream.rawValue) output limit: \(Self.bounded(diagnostics))"
            )
        )
    }

    private typealias Failure = (code: HeistKnownBuildDiagnosticCode, message: String)

    private var source: URL {
        switch self {
        case .compilation(let source, _), .execution(let source, _):
            source
        }
    }

    private var entrySuffix: String {
        switch self {
        case .compilation(_, let entry), .execution(_, let entry):
            HeistPlanBuildError.entrySuffix(entry)
        }
    }

    private func failure(
        compilation: Failure,
        execution: Failure
    ) -> HeistPlanBuildError {
        let selected = switch self {
        case .compilation: compilation
        case .execution: execution
        }
        return .swiftCompilation(
            code: selected.code,
            selected.message,
            source: source
        )
    }

    private static func bounded(_ diagnostics: String) -> String {
        HeistPlanBuildError.boundedCompilerDiagnostics(diagnostics)
    }

    private func processDetails(prefix: String, diagnostics: String) -> String {
        guard !diagnostics.isEmpty else { return prefix }
        return "\(prefix): \(diagnostics)"
    }
}
#endif
