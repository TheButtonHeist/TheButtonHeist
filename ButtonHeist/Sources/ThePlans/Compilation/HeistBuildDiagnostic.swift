import Foundation

public enum HeistBuildDiagnosticKind: String, Sendable, Equatable {
    case error
    case warning
}

public enum HeistBuildPhase: String, Sendable, Equatable {
    case dslBuild = "dsl_build"
    case sourceCompilation = "source_compilation"
    case swiftCompilation = "swift_compilation"
    case planValidation = "plan_validation"
    case planning
}

public enum HeistKnownBuildDiagnosticCode: String, Sendable, Hashable, CaseIterable {
    case dslInvalidActionExpectation = "heist.dsl.invalid_action_expectation"
    case dslInvalidActionUntil = "heist.dsl.invalid_action_until"
    case dslInvalidDefinition = "heist.dsl.invalid_definition"
    case dslInvalidForEachElement = "heist.dsl.invalid_for_each_element"
    case dslInvalidForEachString = "heist.dsl.invalid_for_each_string"
    case dslInvalidInvocationExpectation = "heist.dsl.invalid_invocation_expectation"
    case dslInvalidInvocationPath = "heist.dsl.invalid_invocation_path"
    case dslInvalidRepeatUntil = "heist.dsl.invalid_repeat_until"

    case sourceInvalidSyntax = "heist.source.invalid_syntax"
    case sourceWaitForGate = "heist.source.wait_for_gate"
    case nonDurableAction = "heist.plan.non_durable_action"
    case planRuntimeSafety = "heist.plan.runtime_safety"

    case planningMissingPlanSource = "heist.planning.missing_plan_source"
    case planningMultiplePlanSources = "heist.planning.multiple_plan_sources"
    case planningEmptyPath = "heist.planning.empty_path"
    case planningUnsupportedPath = "heist.planning.unsupported_path"
    case planningEmptyInlineSource = "heist.planning.empty_inline_source"
    case planningInvalidPlanSource = "heist.planning.invalid_plan_source"
    case planningInvalidArtifact = "heist.planning.invalid_artifact"
    case planningInvalidArgument = "heist.planning.invalid_argument"
    case planningInvalidRootArgument = "heist.planning.invalid_root_argument"

    case performWrongStepCount = "heist.perform.wrong_step_count"
    case performUnsupportedStep = "heist.perform.unsupported_step"

    case swiftCompilationFailed = "heist.swift_compilation.failed"
    case swiftCompilationUnsupportedPlatform = "heist.swift_compilation.unsupported_platform"
    case swiftCompilationCancelled = "heist.swift_compilation.cancelled"
    case swiftCompilationSourceNotFound = "heist.swift_compilation.source_not_found"
    case swiftCompilationPackageRootNotFound = "heist.swift_compilation.package_root_not_found"
    case swiftCompilationBuildArtifactsNotFound = "heist.swift_compilation.build_artifacts_not_found"
    case swiftCompilationCompileFailed = "heist.swift_compilation.compile_failed"
    case swiftCompilationExecutionFailed = "heist.swift_compilation.execution_failed"
    case swiftCompilationCompileTimedOut = "heist.swift_compilation.compile_timed_out"
    case swiftCompilationExecutionTimedOut = "heist.swift_compilation.execution_timed_out"
    case swiftCompilationCompileOutputLimitExceeded = "heist.swift_compilation.compile_output_limit_exceeded"
    case swiftCompilationExecutionOutputLimitExceeded = "heist.swift_compilation.execution_output_limit_exceeded"
    case swiftCompilationCompilerTerminated = "heist.swift_compilation.compiler_terminated"
    case swiftCompilationExecutionTerminated = "heist.swift_compilation.execution_terminated"
    case swiftCompilationInvalidOutput = "heist.swift_compilation.invalid_output"

    case directoryNoSources = "heist.directory.no_sources"
    case directoryCancelled = "heist.directory.cancelled"
    case directoryNotDirectory = "heist.directory.not_directory"
    case directoryUnsupportedSourceFile = "heist.directory.unsupported_source_file"

    case catalogAnonymousCapability = "heist.catalog.anonymous_capability"
    case catalogDuplicateCapability = "heist.catalog.duplicate_capability"
    case catalogInvalidEntry = "heist.catalog.invalid_entry"
}

public struct HeistBuildDiagnosticCode: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    private init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ knownCode: HeistKnownBuildDiagnosticCode) {
        self.init(knownCode.rawValue)
    }

    public static func externalBoundaryRawCode(_ rawValue: String) -> Self {
        Self(rawValue)
    }

    public var knownCode: HeistKnownBuildDiagnosticCode? {
        HeistKnownBuildDiagnosticCode(rawValue: rawValue)
    }

    public var description: String {
        rawValue
    }
}

public extension HeistBuildDiagnosticCode {
    static let dslInvalidActionExpectation = Self(HeistKnownBuildDiagnosticCode.dslInvalidActionExpectation)
    static let dslInvalidActionUntil = Self(HeistKnownBuildDiagnosticCode.dslInvalidActionUntil)
    static let dslInvalidDefinition = Self(HeistKnownBuildDiagnosticCode.dslInvalidDefinition)
    static let dslInvalidForEachElement = Self(HeistKnownBuildDiagnosticCode.dslInvalidForEachElement)
    static let dslInvalidForEachString = Self(HeistKnownBuildDiagnosticCode.dslInvalidForEachString)
    static let dslInvalidInvocationExpectation = Self(HeistKnownBuildDiagnosticCode.dslInvalidInvocationExpectation)
    static let dslInvalidInvocationPath = Self(HeistKnownBuildDiagnosticCode.dslInvalidInvocationPath)
    static let dslInvalidRepeatUntil = Self(HeistKnownBuildDiagnosticCode.dslInvalidRepeatUntil)

    static let sourceInvalidSyntax = Self(HeistKnownBuildDiagnosticCode.sourceInvalidSyntax)
    static let sourceWaitForGate = Self(HeistKnownBuildDiagnosticCode.sourceWaitForGate)
    static let nonDurableAction = Self(HeistKnownBuildDiagnosticCode.nonDurableAction)
    static let planRuntimeSafety = Self(HeistKnownBuildDiagnosticCode.planRuntimeSafety)

    static let planningMissingPlanSource = Self(HeistKnownBuildDiagnosticCode.planningMissingPlanSource)
    static let planningMultiplePlanSources = Self(HeistKnownBuildDiagnosticCode.planningMultiplePlanSources)
    static let planningEmptyPath = Self(HeistKnownBuildDiagnosticCode.planningEmptyPath)
    static let planningUnsupportedPath = Self(HeistKnownBuildDiagnosticCode.planningUnsupportedPath)
    static let planningEmptyInlineSource = Self(HeistKnownBuildDiagnosticCode.planningEmptyInlineSource)
    static let planningInvalidPlanSource = Self(HeistKnownBuildDiagnosticCode.planningInvalidPlanSource)
    static let planningInvalidArtifact = Self(HeistKnownBuildDiagnosticCode.planningInvalidArtifact)
    static let planningInvalidArgument = Self(HeistKnownBuildDiagnosticCode.planningInvalidArgument)
    static let planningInvalidRootArgument = Self(HeistKnownBuildDiagnosticCode.planningInvalidRootArgument)

    static let performWrongStepCount = Self(HeistKnownBuildDiagnosticCode.performWrongStepCount)
    static let performUnsupportedStep = Self(HeistKnownBuildDiagnosticCode.performUnsupportedStep)
}

public struct HeistBuildSourceSpan: Sendable, Equatable, CustomStringConvertible {
    public let sourceName: String
    public let offset: Int
    public let line: Int
    public let column: Int
    public let length: Int?

    public init(
        sourceName: String,
        offset: Int,
        line: Int,
        column: Int,
        length: Int? = nil
    ) {
        self.sourceName = sourceName
        self.offset = offset
        self.line = line
        self.column = column
        self.length = length
    }

    public var description: String {
        "\(sourceName):\(line):\(column)"
    }
}

public struct HeistBuildDiagnostic: Sendable, Equatable, CustomStringConvertible {
    public let code: HeistBuildDiagnosticCode
    public let kind: HeistBuildDiagnosticKind
    public let phase: HeistBuildPhase
    public let sourceSpan: HeistBuildSourceSpan?
    public let path: String?
    public let message: String
    public let hint: String?

    public init(
        code: HeistKnownBuildDiagnosticCode,
        kind: HeistBuildDiagnosticKind = .error,
        phase: HeistBuildPhase,
        sourceSpan: HeistBuildSourceSpan? = nil,
        path: String? = nil,
        message: String,
        hint: String? = nil
    ) {
        self.code = HeistBuildDiagnosticCode(code)
        self.kind = kind
        self.phase = phase
        self.sourceSpan = sourceSpan
        self.path = path
        self.message = message
        self.hint = hint
    }

    public init(
        externalBoundaryRawCode rawCode: String,
        kind: HeistBuildDiagnosticKind = .error,
        phase: HeistBuildPhase,
        sourceSpan: HeistBuildSourceSpan? = nil,
        path: String? = nil,
        message: String,
        hint: String? = nil
    ) {
        self.code = .externalBoundaryRawCode(rawCode)
        self.kind = kind
        self.phase = phase
        self.sourceSpan = sourceSpan
        self.path = path
        self.message = message
        self.hint = hint
    }

    fileprivate init(
        preservingCode code: HeistBuildDiagnosticCode,
        kind: HeistBuildDiagnosticKind,
        phase: HeistBuildPhase,
        sourceSpan: HeistBuildSourceSpan?,
        path: String?,
        message: String,
        hint: String?
    ) {
        self.code = code
        self.kind = kind
        self.phase = phase
        self.sourceSpan = sourceSpan
        self.path = path
        self.message = message
        self.hint = hint
    }

    public var severity: Severity {
        switch kind {
        case .error:
            return .error
        case .warning:
            return .warning
        }
    }

    public var source: HeistBuildSourceLocation? {
        guard let sourceSpan else { return nil }
        return HeistBuildSourceLocation(
            url: URL(fileURLWithPath: sourceSpan.sourceName),
            line: sourceSpan.line,
            column: sourceSpan.column
        )
    }

    public var description: String {
        renderedMessage
    }

    public var title: String {
        code.title
    }

    public var renderedMessage: String {
        let location: String
        if let sourceSpan {
            location = "\(sourceSpan): "
        } else if let path {
            location = "\(path): "
        } else {
            location = ""
        }
        let suffix = hint.map { " Hint: \($0)" } ?? ""
        return "\(kind.rawValue): \(location)\(message)\(suffix)"
    }
}

public struct HeistPlanBuildError: Error, Sendable, Equatable, CustomStringConvertible {
    public let diagnostics: [HeistBuildDiagnostic]

    package init(diagnostics: [HeistBuildDiagnostic]) {
        self.diagnostics = diagnostics
    }

    package init(diagnostic: HeistBuildDiagnostic) {
        self.init(diagnostics: [diagnostic])
    }

    public var description: String {
        "ButtonHeist plan build failed: \(diagnostics.map(\.renderedMessage).joined(separator: "; "))"
    }
}

extension HeistPlanBuildError {
    static func sourceCompilation(
        message: String,
        sourceSpan: HeistBuildSourceSpan
    ) -> HeistPlanBuildError {
        HeistPlanBuildError(diagnostic: HeistBuildDiagnostic(
            code: .sourceInvalidSyntax,
            phase: .sourceCompilation,
            sourceSpan: sourceSpan,
            message: message
        ))
    }

    static func planStructure(
        path: String,
        message: String,
        hint: String? = nil
    ) -> HeistPlanBuildError {
        HeistPlanBuildError(diagnostics: [
            HeistBuildDiagnostic(
                code: .planRuntimeSafety,
                phase: .planValidation,
                path: path,
                message: message,
                hint: hint
            ),
        ])
    }
}

public extension HeistBuildDiagnosticCode {
    var title: String {
        switch knownCode {
        case .dslInvalidActionExpectation:
            return "Invalid action expectation"
        case .dslInvalidActionUntil:
            return "Invalid action until clause"
        case .dslInvalidDefinition:
            return "Invalid heist definition"
        case .dslInvalidForEachElement:
            return "Invalid element loop"
        case .dslInvalidForEachString:
            return "Invalid string loop"
        case .dslInvalidInvocationExpectation:
            return "Invalid RunHeist expectation"
        case .dslInvalidInvocationPath:
            return "Invalid RunHeist path"
        case .dslInvalidRepeatUntil:
            return "Invalid repeat-until"
        case .sourceInvalidSyntax:
            return "Invalid ButtonHeist source"
        case .sourceWaitForGate:
            return "Invalid WaitFor source"
        case .nonDurableAction:
            return "Non-durable action"
        case .planRuntimeSafety:
            return "Plan semantic validation failed"
        case .performWrongStepCount:
            return "Invalid perform step count"
        case .performUnsupportedStep:
            return "Unsupported perform step"
        case .planningMissingPlanSource,
             .planningMultiplePlanSources,
             .planningEmptyPath,
             .planningUnsupportedPath,
             .planningEmptyInlineSource,
             .planningInvalidPlanSource,
             .planningInvalidArtifact,
             .planningInvalidArgument,
             .planningInvalidRootArgument,
             .swiftCompilationFailed,
             .swiftCompilationUnsupportedPlatform,
             .swiftCompilationCancelled,
             .swiftCompilationSourceNotFound,
             .swiftCompilationPackageRootNotFound,
             .swiftCompilationBuildArtifactsNotFound,
             .swiftCompilationCompileFailed,
             .swiftCompilationExecutionFailed,
             .swiftCompilationCompileTimedOut,
             .swiftCompilationExecutionTimedOut,
             .swiftCompilationCompileOutputLimitExceeded,
             .swiftCompilationExecutionOutputLimitExceeded,
             .swiftCompilationCompilerTerminated,
             .swiftCompilationExecutionTerminated,
             .swiftCompilationInvalidOutput,
             .directoryNoSources,
             .directoryCancelled,
             .directoryNotDirectory,
             .directoryUnsupportedSourceFile,
             .catalogAnonymousCapability,
             .catalogDuplicateCapability,
             .catalogInvalidEntry,
             .none:
            break
        }
        return rawValue
            .split(separator: ".")
            .last
            .map { String($0).replacingOccurrences(of: "_", with: " ") }
            ?? rawValue
    }
}

extension HeistBuildDiagnostic {
    static let heistPathComponentHint =
        "Use a non-empty dot-separated heist capability name with Swift-style identifier components."

    static func dslBuild(
        code: HeistKnownBuildDiagnosticCode,
        path: String? = nil,
        message: String,
        hint: String? = nil
    ) -> HeistBuildDiagnostic {
        HeistBuildDiagnostic(
            code: code,
            phase: .dslBuild,
            path: path,
            message: message,
            hint: hint
        )
    }

    static func invalidDefinitionPath(
        _ path: String,
        error: Error,
        phase: HeistBuildPhase,
        sourceSpan: HeistBuildSourceSpan? = nil
    ) -> HeistBuildDiagnostic {
        HeistBuildDiagnostic(
            code: .dslInvalidDefinition,
            phase: phase,
            sourceSpan: sourceSpan,
            path: pathForDiagnostic(path),
            message: "HeistDef path is invalid: \(String(describing: error))",
            hint: heistPathComponentHint
        )
    }

    static func invalidInvocationPath(
        _ path: String,
        error: Error,
        phase: HeistBuildPhase,
        sourceSpan: HeistBuildSourceSpan? = nil
    ) -> HeistBuildDiagnostic {
        HeistBuildDiagnostic(
            code: .dslInvalidInvocationPath,
            phase: phase,
            sourceSpan: sourceSpan,
            path: pathForDiagnostic(path),
            message: "RunHeist name is invalid: \(String(describing: error))",
            hint: heistPathComponentHint
        )
    }

    func withPath(_ path: String) -> HeistBuildDiagnostic {
        HeistBuildDiagnostic(
            preservingCode: code,
            kind: kind,
            phase: phase,
            sourceSpan: sourceSpan,
            path: path,
            message: message,
            hint: hint
        )
    }

    private static func pathForDiagnostic(_ path: String) -> String? {
        path.isEmpty ? nil : path
    }
}

extension HeistPlanRuntimeSafetyError {
    var diagnostics: [HeistBuildDiagnostic] {
        failures.map(\.diagnostic)
    }
}

private extension HeistPlanRuntimeSafetyFailure {
    private static let durableHeistActionContract = "durable heist action"

    var diagnostic: HeistBuildDiagnostic {
        HeistBuildDiagnostic(
            code: diagnosticCode,
            phase: .planValidation,
            path: path.description,
            message: "\(contract); observed \(observed)",
            hint: correction
        )
    }

    var diagnosticCode: HeistKnownBuildDiagnosticCode {
        contract == Self.durableHeistActionContract ? .nonDurableAction : .planRuntimeSafety
    }
}
