import Foundation

public enum HeistSourceCompilation {
    public static func compile(
        _ source: String,
        sourceName: String = "inline-heist-plan"
    ) throws(HeistPlanBuildError) -> HeistPlan {
        do {
            var lexer = HeistPlanSourceLexer(source: source, sourceName: sourceName)
            let tokens = try lexer.lex()
            var parser = HeistPlanSourceParser(tokens: tokens)
            return try parser.parseProgram()
        } catch let error as HeistPlanBuildError {
            throw error
        } catch let error as HeistPlanRuntimeSafetyError {
            throw HeistPlanBuildError(diagnostics: error.diagnostics)
        } catch {
            throw HeistPlanBuildError(diagnostics: [HeistBuildDiagnostic(
                code: .planRuntimeSafety,
                phase: .planValidation,
                message: "ButtonHeist source failed runtime safety: \(String(describing: error))"
            )])
        }
    }
}
