import Foundation

public enum HeistPlanSourceAdmission {
    public static func admit(
        commandName: String,
        path: String?,
        inlineDSL: String?
    ) throws(HeistPlanBuildError) -> HeistPlanLoadRequest {
        switch (path, inlineDSL) {
        case (.some, .some):
            throw HeistPlanBuildError.admission(
                code: .planningMultiplePlanSources,
                message: """
                \(commandName) accepts exactly one plan source: ButtonHeist DSL source in `plan` \
                or a generated `.heist` package artifact in `path`.
                """
            )
        case (.none, .none):
            throw HeistPlanBuildError.admission(
                code: .planningMissingPlanSource,
                message: """
                \(commandName) requires exactly one plan source: ButtonHeist DSL source in `plan` \
                or a generated `.heist` package artifact in `path`.
                """
            )
        case (.some(let path), .none):
            return HeistPlanLoadRequest(commandName: commandName, source: .artifactPath(path))
        case (.none, .some(let source)):
            return HeistPlanLoadRequest(commandName: commandName, source: .inlineDSL(source))
        }
    }
}

public enum HeistPlanLoading {
    public static func loadValidated(
        from request: HeistPlanLoadRequest
    ) throws(HeistPlanBuildError) -> HeistPlan {
        switch request.source {
        case .artifactPath(let path):
            return try loadValidatedArtifactPlan(path: path, commandName: request.commandName)
        case .inlineDSL(let source):
            return try compileInlineButtonHeistSource(source, commandName: request.commandName)
        }
    }
}

public enum HeistArgumentAdmission {
    public static func decodeJSON(
        _ data: Data,
        sourceURL: URL = URL(fileURLWithPath: "inline-heist-argument.json")
    ) throws(HeistPlanBuildError) -> HeistArgument {
        do {
            return try JSONDecoder().decode(HeistArgument.self, from: data)
        } catch {
            throw HeistPlanBuildError.admission(
                code: .planningInvalidArgument,
                path: sourceURL.path,
                message: "Invalid heist argument at \(sourceURL.path): \(String(describing: error))"
            )
        }
    }

    public static func validateRootArgument(
        _ argument: HeistArgument,
        for plan: HeistPlan
    ) throws(HeistPlanBuildError) {
        do {
            _ = try HeistExecutionEnvironment.empty.binding(argument: argument, to: plan.parameter)
        } catch {
            throw HeistPlanBuildError.admission(
                code: .planningInvalidRootArgument,
                message: "run_heist argument does not match root heist parameter: \(String(describing: error))"
            )
        }
    }
}

private extension HeistPlanBuildError {
    static func admission(
        code: HeistKnownBuildDiagnosticCode,
        path: String? = nil,
        message: String
    ) -> HeistPlanBuildError {
        HeistPlanBuildError(diagnostic: HeistBuildDiagnostic(
            code: code,
            phase: .planning,
            path: path,
            message: message
        ))
    }
}

private extension HeistPlanLoading {
    static func loadValidatedArtifactPlan(
        path: String,
        commandName: String
    ) throws(HeistPlanBuildError) -> HeistPlan {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HeistPlanBuildError.admission(
                code: .planningEmptyPath,
                message: "\(commandName) path must not be empty."
            )
        }

        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        guard url.pathExtension.lowercased() == "heist" else {
            throw HeistPlanBuildError.admission(
                code: .planningUnsupportedPath,
                path: path,
                message: """
                \(commandName) path must be a generated `.heist` package artifact for \(path). \
                Use ButtonHeist DSL source or `.heist`; raw `.json` HeistPlan IR and `plan.json` \
                are internal artifact content, not public run input.
                """
            )
        }

        do {
            return try HeistArtifactCodec.read(from: url).plan
        } catch let error as HeistArtifactCodecError {
            throw HeistPlanBuildError(diagnostics: [HeistBuildDiagnostic(
                code: .planningInvalidArtifact,
                phase: .planning,
                path: url.path,
                message: error.description
            )])
        } catch {
            throw HeistPlanBuildError(diagnostics: [HeistBuildDiagnostic(
                code: .planningInvalidArtifact,
                phase: .planning,
                path: url.path,
                message: String(describing: error)
            )])
        }
    }

    static func compileInlineButtonHeistSource(
        _ source: String,
        commandName: String
    ) throws(HeistPlanBuildError) -> HeistPlan {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HeistPlanBuildError.admission(
                code: .planningEmptyInlineSource,
                message: "\(commandName) ButtonHeist DSL source must not be empty."
            )
        }

        return try HeistSourceCompilation.compile(source, sourceName: "\(commandName)-inline.plan")
    }
}
