import Foundation

import ThePlans
import TheScore

extension TheFence {

    struct RunHeistRequest {
        let plan: HeistPlan
        let argument: HeistArgument
        let timeout: HeistTimeout?
    }

    struct PerformRequest {
        let plan: HeistPlan
    }

    struct ListHeistsRequest {
        let descriptions: [HeistDescription]
        let detail: HeistCatalogDetail
    }

    struct DescribeHeistRequest {
        let description: HeistDescription
    }

    struct ValidateHeistRequest {
        let source: HeistPlanLoadRequest
        let argument: HeistArgument
        let argumentProvided: Bool
        let lintMode: HeistValidationLintMode
    }

    enum PerformableHeistStep: Sendable, Equatable {
        case action(ActionStep)
        case wait(WaitStep)

    }

    enum PerformStepValidationError: Error, Sendable, Equatable, CustomStringConvertible {
        case wrongStepCount(Int)
        case unsupportedStep

        var diagnostic: HeistBuildDiagnostic {
            switch self {
            case .wrongStepCount:
                return Self.diagnostic(code: .performWrongStepCount)
            case .unsupportedStep:
                return Self.diagnostic(code: .performUnsupportedStep)
            }
        }

        var description: String {
            switch self {
            case .wrongStepCount:
                return Self.guidance
            case .unsupportedStep:
                return Self.guidance
            }
        }

        private static let guidance = """
        perform accepts one action statement or one simple WaitFor statement. \
        Use run_heist for branching, loops, reusable heists, warnings, failures, or multiple steps.
        """

        private static func diagnostic(code: HeistKnownBuildDiagnosticCode) -> HeistBuildDiagnostic {
            HeistBuildDiagnostic(
                code: code,
                phase: .planning,
                message: guidance,
                hint: "Use run_heist for full ButtonHeist programs."
            )
        }
    }

    func decodePerformRequest(_ arguments: CommandArgumentEnvelope) throws -> PerformRequest {
        try CommandArgumentEnvelopeLimits.validateHeistPlanSource(arguments, field: Command.perform.rawValue)
        let source = try arguments.requiredValue(FenceParameters.performStep)
        let plan = try loadInlinePerformStepSource(source)
        _ = try performableStep(in: plan)
        return PerformRequest(plan: plan)
    }

    func decodeRunHeistRequest(_ arguments: CommandArgumentEnvelope) throws -> RunHeistRequest {
        let plan = try admitRuntimeSafeHeistPlanSource(
            from: arguments,
            commandName: Command.runHeist.rawValue
        )
        let argument = try decodeRootHeistArgument(from: arguments)
        try validateRootHeistArgument(argument, for: plan)
        return RunHeistRequest(
            plan: plan,
            argument: argument,
            timeout: try arguments.value(FenceParameters.heistTimeout)
        )
    }

    func decodeValidateHeistRequest(_ arguments: CommandArgumentEnvelope) throws -> ValidateHeistRequest {
        try CommandArgumentEnvelopeLimits.validateHeistPlanSource(arguments, field: Command.validateHeist.rawValue)
        let path = try arguments.value(FenceParameters.planPath)
        let inlineDSL = try arguments.value(FenceParameters.inlinePlan)
        let source: HeistPlanLoadRequest
        do {
            source = try HeistPlanSourceAdmission.admit(
                commandName: Command.validateHeist.rawValue,
                path: path,
                inlineDSL: inlineDSL
            )
        } catch let error {
            throw buildDiagnosticFenceError(error.diagnostics)
        }
        return ValidateHeistRequest(
            source: source,
            argument: try decodeRootHeistArgument(from: arguments),
            argumentProvided: arguments.value(for: "argument") != nil,
            lintMode: try arguments.value(
                FenceParameters.heistValidationLint,
                defaultFrom: Command.validateHeist.descriptor
            )
        )
    }

    func loadInlinePerformStepSource(_ source: String) throws -> HeistPlan {
        do {
            return try HeistPlanLoading.loadValidated(from: HeistPlanLoadRequest(
                commandName: Command.perform.rawValue,
                source: .inlineDSL(
                    """
                    HeistPlan {
                    \(source)
                    }
                    """
                )
            ))
        } catch let error {
            throw performStepSourceLoadError(for: error.diagnostics)
        }
    }

    func performStepSourceLoadError(for diagnostics: [HeistBuildDiagnostic]) -> FenceError {
        guard Self.containsPerformUnsupportedStepDiagnostic(diagnostics) else {
            return buildDiagnosticFenceError(diagnostics)
        }
        return buildDiagnosticFenceError([PerformStepValidationError.unsupportedStep.diagnostic])
    }

    func performableStep(in plan: HeistPlan) throws -> PerformableHeistStep {
        guard plan.definitions.isEmpty else {
            throw buildDiagnosticFenceError([PerformStepValidationError.unsupportedStep.diagnostic])
        }
        guard plan.body.count == 1, let step = plan.body.first else {
            throw buildDiagnosticFenceError([PerformStepValidationError.wrongStepCount(plan.body.count).diagnostic])
        }
        switch step {
        case .action(let action):
            guard action.command.isPerformPrimitive else {
                throw buildDiagnosticFenceError([PerformStepValidationError.unsupportedStep.diagnostic])
            }
            return .action(action)
        case .wait(let wait):
            guard wait.elseBody == nil else {
                throw buildDiagnosticFenceError([PerformStepValidationError.unsupportedStep.diagnostic])
            }
            return .wait(wait)
        case .conditional, .forEachElement, .forEachString, .repeatUntil, .warn, .fail, .heist, .invoke:
            throw buildDiagnosticFenceError([PerformStepValidationError.unsupportedStep.diagnostic])
        }
    }

    func decodeListHeistsRequest(_ arguments: CommandArgumentEnvelope) throws -> ListHeistsRequest {
        let detail = try arguments.value(
            FenceParameters.heistCatalogDetail,
            defaultFrom: Command.listHeists.descriptor
        )
        do {
            let plan = try admitRuntimeSafeHeistPlanSource(
                from: arguments,
                commandName: Command.listHeists.rawValue
            )
            return ListHeistsRequest(descriptions: try plan.heistDescriptions(), detail: detail)
        } catch let error as HeistCatalogError {
            throw FenceError.invalidRequest(error.description)
        }
    }

    func decodeDescribeHeistRequest(_ arguments: CommandArgumentEnvelope) throws -> DescribeHeistRequest {
        let requestedName = try arguments.requiredValue(FenceParameters.heistName)
        do {
            let requestedPath = try HeistDefinitionPath(validating: requestedName)
            let plan = try admitRuntimeSafeHeistPlanSource(
                from: arguments,
                commandName: Command.describeHeist.rawValue
            )
            return DescribeHeistRequest(description: try plan.describeHeist(at: requestedPath))
        } catch let error as HeistPathValidationError {
            throw FenceError.invalidRequest(error.description)
        } catch let error as HeistCatalogError {
            throw FenceError.invalidRequest(error.description)
        } catch let error as HeistDescriptionLookupError {
            throw FenceError.invalidRequest(error.description)
        }
    }

}

private extension HeistActionCommand {
    var isPerformPrimitive: Bool {
        switch self {
        case .activate, .increment, .decrement, .customAction, .rotor,
             .typeText, .oneFingerTap, .longPress, .swipe,
             .drag, .dismiss, .magicTap, .editAction, .setPasteboard, .takeScreenshot, .dismissKeyboard:
            return true
        case .scroll, .scrollToVisible, .scrollToEdge:
            return false
        }
    }
}

private extension TheFence {

    func admitRuntimeSafeHeistPlanSource(
        from arguments: CommandArgumentEnvelope,
        commandName: String
    ) throws -> HeistPlan {
        // Admission: accept exactly one public source shape for a plan. ThePlans
        // then returns a RuntimeSafety-validated executable `HeistPlan`.
        try CommandArgumentEnvelopeLimits.validateHeistPlanSource(arguments, field: commandName)
        let path = try arguments.value(FenceParameters.planPath)
        let inlineDSL = try arguments.value(FenceParameters.inlinePlan)
        do {
            let request = try HeistPlanSourceAdmission.admit(
                commandName: commandName,
                path: path,
                inlineDSL: inlineDSL
            )
            return try HeistPlanLoading.loadValidated(from: request)
        } catch let error {
            throw buildDiagnosticFenceError(error.diagnostics)
        }
    }

    func decodeRootHeistArgument(from arguments: CommandArgumentEnvelope) throws -> HeistArgument {
        guard let value = arguments.value(for: "argument") else { return .none }
        let data = try JSONEncoder().encode(value)
        do {
            return try HeistArgumentAdmission.decodeJSON(
                data,
                sourceURL: URL(fileURLWithPath: "run_heist-argument.json")
            )
        } catch let error {
            throw buildDiagnosticFenceError(error.diagnostics)
        }
    }

    func validateRootHeistArgument(_ argument: HeistArgument, for plan: HeistPlan) throws {
        do {
            try HeistArgumentAdmission.validateRootArgument(argument, for: plan)
        } catch let error {
            throw buildDiagnosticFenceError(error.diagnostics)
        }
    }

    func buildDiagnosticFenceError(_ diagnostics: [HeistBuildDiagnostic]) -> FenceError {
        FenceError.heistBuildDiagnostics(diagnostics)
    }

    static func containsPerformUnsupportedStepDiagnostic(_ diagnostics: [HeistBuildDiagnostic]) -> Bool {
        diagnostics.contains { diagnostic in
            diagnostic.code == .sourceWaitForGate
        }
    }

}
