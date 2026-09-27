#if canImport(UIKit)
#if DEBUG
import Foundation
import Testing
import UIKit

@testable import AccessibilitySnapshotParser
@_spi(ButtonHeistInternals) @testable import ThePlans
@testable import TheInsideJob
@_spi(ButtonHeistInternals) @testable import TheScore

@MainActor
@Suite struct DeterministicRuntimeScenarioDriverTests {
    @Test func `action settlement returns canonical result report and effect transcript`() async throws {
        let command = try HeistActionCommand.dismiss.resolve(in: .empty)
        let observation = InterfaceObservation.makeForTests(elements: [
            (AccessibilityElement.make(label: "Home"), HeistId(rawValue: "home")),
        ])
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try HeistPlan(body: [.action(ActionStep(command: .dismiss))]),
            timeout: try .seconds(5),
            inputs: [
                .pulse(after: .zero, observation: observation),
                .action(
                    expected: command,
                    disposition: .result(.success(payload: .empty(for: command.type)))
                ),
                .pulse(after: .zero, observation: observation),
            ]
        )

        let completed = try await scenario.run()

        let result = try #require(completed.result)
        let step = try #require(result.steps.first)
        let evidence = try #require(step.actionEvidence)
        guard case .completed(_, let expectation) = evidence else {
            Issue.record("Expected canonical completed action evidence")
            return
        }

        guard case .completed = completed.outcome else {
            Issue.record("Expected action settlement to complete")
            return
        }
        #expect(result.outcome == .passed)
        #expect(result.durationMs.milliseconds == 0)
        #expect(step.path.description == "$.body[0]")
        #expect(expectation.predicate == nil)
        #expect(expectation.terminalCause == .observed)
        #expect(expectation.observation.events == [.noChange])
        #expect(expectation.timing.elapsedMs.milliseconds == 0)
        #expect(completed.report?.summary.expectations?.allMet == true)
        #expect(completed.humanFailureDescription == nil)
        #expect(completed.effectTranscript == [.action(command)])
    }

    @Test func `authored action expectation requires its notification and terminal no change`() async throws {
        let command = try HeistActionCommand.dismiss.resolve(in: .empty)
        let home = observation(label: "Home")
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try HeistPlan(body: [
                .action(ActionStep(
                    command: .dismiss,
                    expectationPolicy: .expect(ActionExpectation(
                        predicate: .notification("Saved"),
                        timeout: try .seconds(1)
                    ))
                )),
            ]),
            timeout: try .seconds(5),
            inputs: [
                .pulse(after: .zero, observation: home),
                .action(
                    expected: command,
                    disposition: .result(.success(payload: .empty(for: command.type)))
                ),
                .notification(.init(text: "Saved", timestamp: fixtureTimestamp)),
                .pulse(after: .zero, observation: home),
            ]
        )

        let completed = try await scenario.run()
        let replay = try completed.result?.steps.first?.replayExpectation()

        #expect(completed.result?.outcome == .passed)
        #expect(completed.effectTranscript == [.action(command)])
        #expect(replay?.met == true)
    }

    @Test func `without expectation action still proves terminal no change`() async throws {
        let command = try HeistActionCommand.dismiss.resolve(in: .empty)
        let home = observation(label: "Home")
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try HeistPlan(body: [
                .action(ActionStep(
                    command: .dismiss,
                    expectationPolicy: .waived(try ActionExpectationWaiver(validating: "fixture"))
                )),
            ]),
            timeout: try .seconds(5),
            inputs: [
                .pulse(after: .zero, observation: home),
                .action(
                    expected: command,
                    disposition: .result(.success(payload: .empty(for: command.type)))
                ),
                .pulse(after: .zero, observation: home),
            ]
        )

        let completed = try await scenario.run()
        let replay = try completed.result?.steps.first?.replayExpectation()

        #expect(completed.result?.outcome == .passed)
        #expect(replay?.met == true)
        #expect(completed.effectTranscript == [.action(command)])
    }

    @Test func `expired terminal capture cannot complete a returned dispatch`() async throws {
        let command = try HeistActionCommand.dismiss.resolve(in: .empty)
        let home = observation(label: "Home")
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try HeistPlan(body: [.action(ActionStep(command: .dismiss))]),
            timeout: try .seconds(5),
            actionExpectationTimeoutPolicy: .init(standard: 1, screenTransition: 1),
            inputs: [
                .pulse(after: .zero, observation: home),
                .action(
                    expected: command,
                    disposition: .resultAfterAdvancingClock(
                        .success(payload: .empty(for: command.type)),
                        by: .seconds(1)
                    )
                ),
                .pulse(after: .zero, observation: home),
            ]
        )

        let completed = try await scenario.run()
        let action = try #require(completed.result?.steps.first)

        #expect(isFailed(completed.result))
        #expect(action.actionEvidence?.result?.outcome.failureKind == .timeout)
        #expect(completed.report?.nodes.first?.failure?.actionKind == .timeout)
        #expect(completed.effectTranscript == [.action(command)])
        #expect(completed.observationCaptureCount == 2)
    }

    @Test func `notification wait consumes the authored notification on its next pulse`() async throws {
        let home = observation(label: "Home")
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try notificationWaitPlan("Saved", timeout: 1),
            timeout: try .seconds(5),
            inputs: [
                .pulse(after: .zero, observation: home),
                .notification(.init(text: "Saved", timestamp: fixtureTimestamp)),
                .pulse(after: .zero, observation: home),
            ]
        )

        let completed = try await scenario.run()

        #expect(completed.result?.outcome == .passed)
        #expect(completed.result?.steps.first?.waitObservation?.notificationTexts == ["Saved"])
    }

    @Test func `event available before its deadline wins`() async throws {
        let command = try HeistActionCommand.dismiss.resolve(in: .empty)
        let home = observation(label: "Home")
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try HeistPlan(body: [
                .action(ActionStep(
                    command: .dismiss,
                    expectationPolicy: .expect(ActionExpectation(
                        predicate: .notification("Saved"),
                        timeout: try .seconds(1)
                    ))
                )),
            ]),
            timeout: try .seconds(5),
            inputs: [
                .pulse(after: .zero, observation: home),
                .action(
                    expected: command,
                    disposition: .resultAfterQueuingNotificationAndAdvancingClock(
                        .success(payload: .empty(for: command.type)),
                        notification: .init(text: "Saved", timestamp: fixtureTimestamp),
                        by: .milliseconds(999)
                    )
                ),
                .pulse(after: .zero, observation: home),
                .pulse(after: .zero, observation: home),
            ]
        )

        let completed = try await scenario.run()

        #expect(completed.result?.outcome == .passed)
        #expect(completed.effectTranscript == [.action(command)])
    }

    @Test func `deadline observed before a later event is recorded retains deadline-first ordering`() async throws {
        let command = try HeistActionCommand.dismiss.resolve(in: .empty)
        let home = observation(label: "Home")
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try HeistPlan(body: [
                .action(ActionStep(
                    command: .dismiss,
                    expectationPolicy: .expect(ActionExpectation(
                        predicate: .notification("Saved"),
                        timeout: try .seconds(1)
                    ))
                )),
            ]),
            timeout: try .seconds(5),
            inputs: [
                .pulse(after: .zero, observation: home),
                .action(
                    expected: command,
                    disposition: .resultAfterAdvancingClock(
                        .success(payload: .empty(for: command.type)),
                        by: .seconds(1)
                    )
                ),
                .notification(.init(text: "Saved", timestamp: fixtureTimestamp)),
                .pulse(after: .zero, observation: home),
            ]
        )

        let completed = try await scenario.run()
        let expectation = try actionExpectation(in: completed)
        let replay = try expectation.replay()

        #expect(isFailed(completed.result))
        #expect(expectation.terminalCause == .deadline)
        #expect(replay.met == true)
        #expect(completed.effectTranscript == [.action(command)])
    }

    @Test func `notification recorded at its deadline remains evidence after terminal deadline`() async throws {
        let command = try HeistActionCommand.dismiss.resolve(in: .empty)
        let home = observation(label: "Home")
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try HeistPlan(body: [
                .action(ActionStep(
                    command: .dismiss,
                    expectationPolicy: .expect(ActionExpectation(
                        predicate: .notification("Saved"),
                        timeout: try .seconds(1)
                    ))
                )),
            ]),
            timeout: try .seconds(5),
            inputs: [
                .pulse(after: .zero, observation: home),
                .action(
                    expected: command,
                    disposition: .resultAfterQueuingNotificationAndAdvancingClock(
                        .success(payload: .empty(for: command.type)),
                        notification: .init(text: "Saved", timestamp: fixtureTimestamp),
                        by: .seconds(1)
                    )
                ),
                .pulse(after: .zero, observation: home),
                .pulse(after: .zero, observation: home),
            ]
        )

        let completed = try await scenario.run()
        let expectation = try actionExpectation(in: completed)
        let replay = try expectation.replay()

        #expect(isFailed(completed.result))
        #expect(expectation.terminalCause == .deadline)
        #expect(expectation.observation.notificationTexts == ["Saved"])
        #expect(replay.met == true)
        #expect(completed.effectTranscript == [.action(command)])
    }

    @Test func `virtual time reaches the active leaf deadline without live waiting`() async throws {
        let home = observation(label: "Home")
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try notificationWaitPlan("Never", timeout: 1),
            timeout: try .seconds(5),
            inputs: [
                .pulse(after: .zero, observation: home),
                .pulse(after: .seconds(1), observation: home),
                .pulse(after: .zero, observation: home),
            ]
        )

        let completed = try await scenario.run()

        #expect(completed.result?.steps.first?.failure?.category == .timeout)
        #expect(isFailed(completed.result))
    }

    @Test func `virtual time reaches the whole heist deadline without live waiting`() async throws {
        let home = observation(label: "Home")
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try notificationWaitPlan("Never", timeout: 5),
            timeout: try .seconds(1),
            inputs: [
                .pulse(after: .zero, observation: home),
                .pulse(after: .seconds(1), observation: home),
                .pulse(after: .zero, observation: home),
            ]
        )

        let completed = try await scenario.run()

        #expect(completed.result?.steps.first?.failure?.category == .timeout)
        #expect(isFailed(completed.result))
    }

    @Test func `simultaneous leaf and whole expiry retains timeout outcome`() async throws {
        let home = observation(label: "Home")
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try notificationWaitPlan("Never", timeout: 1),
            timeout: try .seconds(1),
            inputs: [
                .pulse(after: .zero, observation: home),
                .pulse(after: .seconds(1), observation: home),
                .pulse(after: .zero, observation: home),
            ]
        )

        let completed = try await scenario.run()

        #expect(isFailed(completed.result))
        #expect(completed.result?.steps.first?.failure?.category == .timeout)
        #expect(completed.report?.nodes.first?.failure?.detail.category == .timeout)
    }

    @Test func `cancellation completes without a live clock or polling`() async throws {
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try notificationWaitPlan("Never", timeout: 30),
            timeout: try .seconds(60),
            inputs: [
                .pulse(after: .zero, observation: observation(label: "Home")),
                .cancel,
            ]
        )

        let completed = try await scenario.run()

        guard case .cancelled = completed.outcome else {
            Issue.record("Expected cancellation outcome")
            return
        }
        #expect(completed.result == nil)
        #expect(completed.effectTranscript.isEmpty)
    }

    @Test func `cancellation during observation start uses the shared cleanup path`() async throws {
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try notificationWaitPlan("Never", timeout: 30),
            timeout: try .seconds(60),
            inputs: [.cancelAfterObservationWaiter]
        )

        let completed = try await scenario.run()

        guard case .cancelled = completed.outcome else {
            Issue.record("Expected observation-start cancellation")
            return
        }
        #expect(completed.result == nil)
        #expect(completed.observationCaptureCount == 0)
    }

    @Test func `cancellation during dispatch uses the shared cleanup path`() async throws {
        let command = try HeistActionCommand.dismiss.resolve(in: .empty)
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try HeistPlan(body: [.action(ActionStep(command: .dismiss))]),
            timeout: try .seconds(5),
            inputs: [
                .pulse(after: .zero, observation: observation(label: "Home")),
                .cancelDuringAction(expected: command),
            ]
        )

        let completed = try await scenario.run()

        guard case .cancelled = completed.outcome else {
            Issue.record("Expected dispatch cancellation")
            return
        }
        #expect(completed.result == nil)
        #expect(completed.effectTranscript == [.action(command)])
    }

    @Test func `unavailable failure capture is preserved in the canonical result`() async throws {
        let capture = HeistFailureCapture.unavailable(
            kind: .actionFailed,
            message: "fixture capture unavailable"
        )
        let scenario = DeterministicRuntimeScenarioDriver(
            plan: try HeistPlan(body: [
                .fail(FailStep(message: try .init(validating: "expected failure"))),
            ]),
            timeout: try .seconds(5),
            failureEvidencePolicy: .screenshot,
            failureCaptures: [capture],
            inputs: []
        )

        let completed = try await scenario.run()

        #expect(isFailed(completed.result))
        #expect(completed.result?.failureCapture == capture)
        #expect(completed.effectTranscript.count == 1)
    }

    private let fixtureTimestamp = Date(timeIntervalSince1970: 1)

    private func notificationWaitPlan(
        _ text: String,
        timeout: WaitTimeout
    ) throws -> HeistPlan {
        try HeistPlan(body: [
            .wait(WaitStep(predicate: .notification(text), timeout: timeout)),
        ])
    }

    private func observation(label: String) -> InterfaceObservation {
        .makeForTests(elements: [
            (AccessibilityElement.make(label: label), HeistId(rawValue: label.lowercased())),
        ])
    }

    private func isFailed(_ result: HeistResult?) -> Bool {
        guard let result, case .failed = result.outcome else { return false }
        return true
    }

    private func actionExpectation(
        in completed: DeterministicRuntimeScenarioResult
    ) throws -> HeistExpectationEvidence {
        let evidence = try #require(completed.result?.steps.first?.actionEvidence)
        guard case .completed(_, let expectation) = evidence else {
            throw ExpectationEvidenceFailure.missing
        }
        return expectation
    }

    private enum ExpectationEvidenceFailure: Error {
        case missing
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
