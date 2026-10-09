#if canImport(UIKit)
#if DEBUG
import Foundation
import ThePlans
import TheScore

struct ActionTiming {
    enum Phase {
        case targetResolution
        case actionDispatch
        case interaction
    }

    private let actionStart: RuntimeElapsed.Instant
    private var targetResolution: ElapsedMilliseconds?
    private var actionDispatch: ElapsedMilliseconds?
    private var interaction: ElapsedMilliseconds?

    init(startedAt: RuntimeElapsed.Instant = RuntimeElapsed.now) {
        actionStart = startedAt
    }

    mutating func record(
        _ phase: Phase,
        since start: RuntimeElapsed.Instant,
        endedAt: RuntimeElapsed.Instant = RuntimeElapsed.now
    ) {
        let duration = RuntimeElapsed.milliseconds(since: start, endedAt: endedAt)
        switch phase {
        case .targetResolution: Self.record(duration, in: &targetResolution)
        case .actionDispatch: Self.record(duration, in: &actionDispatch)
        case .interaction: Self.record(duration, in: &interaction)
        }
    }

    func freeze(endedAt: RuntimeElapsed.Instant = RuntimeElapsed.now) -> ActionPerformanceTiming {
        ActionPerformanceTiming(
            targetResolutionMs: targetResolution,
            actionDispatchMs: actionDispatch,
            interactionMs: interaction,
            totalMs: RuntimeElapsed.milliseconds(since: actionStart, endedAt: endedAt)
        )
    }

    private static func record(_ duration: ElapsedMilliseconds, in slot: inout ElapsedMilliseconds?) {
        precondition(slot == nil, "action timing phase may only be recorded once")
        slot = duration
    }
}

extension TheBrains {
    func executeRuntimeAction(_ command: HeistActionCommand) async -> ActionResult {
        guard semanticObservationIsActive else {
            return runtimeInactiveResult(payload: command.actionResultPayload)
        }
        let completion: HeistExecution.Completion
        do {
            completion = try await HeistExecution.Host(brains: self).execute(
                command,
                timeout: .default
            )
        } catch {
            let failure = HeistExecution.Failure.classify(error)
            return .failure(
                payload: command.actionResultPayload,
                failureKind: failure.actionFailureKind,
                message: failure.description
            )
        }
        return completion.steps.first?.reportActionResult ?? .failure(
            payload: command.actionResultPayload,
            failureKind: .actionFailed,
            message: "single-action execution produced no action result"
        )
    }

    func dispatchRuntimeAction(
        _ command: ResolvedHeistActionCommand,
        deadline: SemanticObservationDeadline
    ) async -> TheSafecracker.ActionDispatchResult {
        let startedAt = RuntimeElapsed.now
        var timing = ActionTiming(startedAt: startedAt)
        if let rejection = actionEffectAdmissionRejection(
            command,
            deadline: deadline
        ) {
            timing.record(.interaction, since: startedAt)
            return rejection.withTiming(timing.freeze())
        }
        clearRotorCursorBeforeNonRotorAction(command)
        let result = await dispatchRawRuntimeAction(
            command,
            deadline: deadline,
            timing: &timing
        )
        timing.record(.interaction, since: startedAt)
        return result.withTiming(timing.freeze())
    }

    private func actionEffectAdmissionRejection(
        _ command: ResolvedHeistActionCommand,
        deadline: SemanticObservationDeadline
    ) -> TheSafecracker.ActionDispatchResult? {
        if Task.isCancelled {
            return .failure(
                .empty(for: command.type),
                message: "action dispatch was cancelled before effect dispatch"
            )
        }
        guard deadline.hasTimeRemaining(at: RuntimeElapsed.now) else {
            return .failure(
                .empty(for: command.type),
                message: "action deadline expired before effect dispatch",
                failureKind: .timeout
            )
        }
        return nil
    }

    private func dispatchRawRuntimeAction(
        _ command: ResolvedHeistActionCommand,
        deadline: SemanticObservationDeadline,
        timing: inout ActionTiming
    ) async -> TheSafecracker.ActionDispatchResult {
        switch command.payload {
        case .activate(let target):
            return await actions.executeActivate(
                target,
                deadline: deadline,
                timing: &timing
            )
        case .increment(let target):
            return await actions.executeIncrement(
                target,
                deadline: deadline,
                timing: &timing
            )
        case .decrement(let target):
            return await actions.executeDecrement(
                target,
                deadline: deadline,
                timing: &timing
            )
        case .customAction(let name, let target):
            return await actions.executeCustomAction(
                name: name,
                target: target,
                deadline: deadline,
                timing: &timing
            )
        case .dismiss:
            return await actions.executeDismiss()
        case .magicTap:
            return await actions.executeMagicTap()
        case .rotor(let selection, let target, let direction):
            return await actions.executeRotor(
                selection: selection,
                target: target,
                direction: direction,
                deadline: deadline,
                timing: &timing
            )
        case .editAction(let target):
            return await actions.executeEditAction(target, deadline: deadline)
        case .setPasteboard(let target):
            return await actions.executeSetPasteboard(target)
        case .takeScreenshot:
            return await dispatchTakeScreenshot(
                observationBoundary: .cancellation
            )
        case .dismissKeyboard:
            return await actions.executeResignFirstResponder(deadline: deadline)
        case .oneFingerTap(let target):
            return await actions.executeTap(target, deadline: deadline)
        case .longPress(let target):
            return await actions.executeLongPress(target, deadline: deadline)
        case .swipe(let target):
            return await actions.executeSwipe(target, deadline: deadline)
        case .drag(let target):
            return await actions.executeDrag(target, deadline: deadline)
        case .typeText(let payload):
            return await actions.executeTypeText(
                text: payload.text,
                target: payload.target,
                deadline: deadline
            )
        case .scroll(let target):
            return await navigation.executeScroll(target, deadline: deadline)
        case .scrollToVisible(let target):
            return await navigation.executeScrollToVisible(
                target: target,
                deadline: deadline
            )
        case .scrollToEdge(let target):
            return await navigation.executeScrollToEdge(
                target,
                deadline: deadline
            )
        }
    }

    private func clearRotorCursorBeforeNonRotorAction(_ command: ResolvedHeistActionCommand) {
        if case .rotor = command.payload {} else {
            vault.clearRotorCursor()
        }
    }

    func executePasteboardRead() -> ActionResult {
        let result = actions.executeGetPasteboard()
        switch result.outcome {
        case .success:
            return .success(payload: result.payload, message: result.message)
        case .failure(let failureKind):
            return .failure(
                payload: result.payload,
                failureKind: failureKind,
                message: result.message
            )
        }
    }

}

#endif // DEBUG
#endif // canImport(UIKit)
