import ButtonHeist
import ThePlans
import TheScore

@main
struct ButtonHeistPublicProductsImportContract {
    static func main() async throws {
        let plan = try HeistPlan("PublicProductsImportContract") {
            Warn("public products imported")
        }
        let planName = plan.name ?? "PublicProductsImportContract"
        let value: HeistValue = .string(planName.description)
        let commandName = ButtonHeist.TheFence.Command.runHeist.rawValue
        _ = (plan, value, commandName)
        guard CommandLine.arguments.count == 3 else { return }
        try await verifyClient(
            configuration: EnvironmentConfig.resolve(
                deviceFilter: CommandLine.arguments[1],
                token: CommandLine.arguments[2],
                autoReconnect: false,
                environment: ButtonHeistEnvironment(driverID: CommandLine.arguments[2])
            )
        )
    }

    @MainActor
    static func verifyClient(configuration: EnvironmentConfig) async throws {
        let plan = try HeistPlan(parameter: "label") { label in
            WaitFor(.exists(.label(label)))
        }
        try await ButtonHeist.withSession(configuration) { heist in
            let before: Interface = try await heist.captureInterface()
            guard before.projectedElements.contains(where: { $0.semantics.assertable.label == "InsideJob integration consumer" }) else {
                throw ConsumerFailure.missingInterface
            }
            let selection = try await heist.captureInterface(InterfaceQuery(capture: .current, subtree: .label("Record")))
            guard selection.projectedElements.count == 1,
                  selection.projectedElements.first?.semantics.assertable.label == "Record" else {
                throw ConsumerFailure.missingInterface
            }
            let result: HeistResult = try await heist.run {
                oneFingerTap(.label("Record"))
                WaitFor(.exists(.label("Recorded")))
            }
            guard !result.isFailure, result.steps.count == 2 else {
                throw ConsumerFailure.executionFailed
            }
            let after = try await heist.captureInterface()
            guard let recorded = after.projectedElements.first(where: { $0.semantics.assertable.label == "Recorded" }),
                  case .onscreen(let frame, _) = recorded.geometry.screen,
                  frame.rect != nil else {
                throw ConsumerFailure.missingInterface
            }
            let failed = try await heist.run { Fail("Expected client conformance failure") }
            guard failed.isFailure, failed.steps.first?.status == .failed,
                  failed.steps.first?.kind == .fail,
                  failed.steps.first?.failure?.category == .explicitFailure,
                  failed.steps.first?.failure?.observed == "Expected client conformance failure" else {
                throw ConsumerFailure.executionFailed
            }
            let recovered = try await heist.run(plan, argument: .string("Recorded"))
            guard !recovered.isFailure else { throw ConsumerFailure.executionFailed }
        }
        let result = try await ButtonHeist.run(configuration: configuration) {
            WaitFor(.exists(.label("Recorded")))
        }
        guard !result.isFailure else { throw ConsumerFailure.executionFailed }
        let prebuilt = try await ButtonHeist.run(plan, configuration: configuration, argument: .string("Recorded"))
        guard !prebuilt.isFailure else { throw ConsumerFailure.executionFailed }
        print("PASS: public Swift client captured, selected, tapped, waited, preserved failure evidence, and reconnected")
    }
}

private enum ConsumerFailure: Error {
    case missingInterface
    case executionFailed
}
