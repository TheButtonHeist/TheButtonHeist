#if canImport(UIKit)
#if DEBUG
import UIKit

import TheScore
import ThePlans

import AccessibilitySnapshotParser

/// Main-actor owner of Button Heist's current accessibility interface.
///
/// The interface tree is the only target-resolution authority. Its committed
/// observation carries disposable UIKit evidence for actionability.
@MainActor
final class TheVault {

    typealias VisibleObservationSource = @MainActor (TheVault) -> InterfaceObservation?
    typealias KeyboardVisibilitySource = @MainActor () -> Bool?

    init(
        tripwire: TheTripwire,
        visibleObservationSource: @escaping VisibleObservationSource = TheVault.captureVisibleObservation,
        keyboardVisibilitySource: @escaping KeyboardVisibilitySource = { nil },
        notificationIngress: AccessibilityNotificationIngress = .process,
        pulseIngress: Observation.Stream.PulseIngress = .displayLink,
        observationSchedulingBoundary: Observation.Stream.SchedulingBoundary = .immediate
    ) {
        self.tripwire = tripwire
        self.visibleObservationSource = visibleObservationSource
        self.keyboardVisibilitySource = keyboardVisibilitySource
        self.notificationIngress = notificationIngress
        self.pulseIngress = pulseIngress
        self.observationSchedulingBoundary = observationSchedulingBoundary
    }

    /// TheTripwire owns window access and live observation pacing.
    let tripwire: TheTripwire

    /// Parser used only while capturing a live accessibility hierarchy.
    let hierarchyParser = AccessibilityHierarchyParser()

    /// Pending accessibility notifications captured while semantic observation is active.
    let accessibilityNotifications = AccessibilityNotificationBus()

    /// The only source used for explicit viewport refreshes. Production parses
    /// UIKit; tests may replace the source only while constructing the vault.
    private let visibleObservationSource: VisibleObservationSource
    private let keyboardVisibilitySource: KeyboardVisibilitySource
    private let notificationIngress: AccessibilityNotificationIngress
    private let pulseIngress: Observation.Stream.PulseIngress
    private let observationSchedulingBoundary: Observation.Stream.SchedulingBoundary

    var keyboardVisible: Bool? {
        keyboardVisibilitySource()
    }

    // MARK: - Interface State

    /// The Vault's sole durable observation state.
    var state = State()

    var currentInterfaceObservation: InterfaceObservation {
        state.interfaceObservation ?? .empty
    }

    var interfaceTree: InterfaceTree {
        currentInterfaceObservation.tree
    }

    var currentLiveCapture: LiveCapture {
        currentInterfaceObservation.liveCapture
    }

    // MARK: - Observation Scheduling

    lazy var semanticObservationStream = Observation.Stream(
        vault: self,
        tripwire: tripwire,
        notificationIngress: notificationIngress,
        pulseIngress: pulseIngress,
        schedulingBoundary: observationSchedulingBoundary
    )

    // MARK: - Interaction Cursor State

    /// Held rotor cursor — the single semantic selection while in rotor mode.
    /// Entering rotor mode on a host starts at index 0; subsequent steps
    /// reacquire live evidence for this value cursor. Any non-rotor action
    /// clears it (rotor mode exit).
    var rotorCursor: RotorCursor?

    struct RotorCursor {
        let hostHeistId: HeistId
        let rotorName: RotorName
        let selectionHistoryIndex: Int
        let selectionHeistId: HeistId
        let textRange: TextRangeReference?
    }

    struct RotorHistoryAdmission {
        let historyIndex: Int
        let invalidatedCursor: RotorCursor?
    }

    /// Drop rotor mode. Called when any non-rotor interaction runs.
    func clearRotorCursor() {
        rotorCursor = nil
    }

    // MARK: - Computed Accessors

    /// Scrollable container paths paired with their backing UIScrollView from the
    /// visible live view. Unwraps the weak ref wrapper for call sites that need
    /// a live scroll view.
    var scrollableContainerViewsByPath: [TreePath: UIScrollView] {
        Dictionary(
            uniqueKeysWithValues: currentLiveCapture.dispatchReferences.scrollableContainerViewsByPath.compactMap { path, reference in
                reference.view.map { (path, $0) }
            }
        )
    }

    /// Elements retained in the interface tree, including explored off-viewport elements.
    var interfaceElementIDs: Set<HeistId> {
        ids(in: .interface)
    }

    /// Elements backed by the latest viewport observation.
    var viewportElementIDs: Set<HeistId> {
        ids(in: .viewport)
    }

    func interfaceElement(heistId: HeistId) -> InterfaceTree.Element? {
        interfaceTree.findElement(heistId: heistId)
    }

    /// HeistId captured for the current viewport's first responder.
    var firstResponderHeistId: HeistId? {
        interfaceTree.firstResponderHeistId
    }

    static func captureVisibleObservation(from vault: TheVault) -> InterfaceObservation? {
        vault.capture().flatMap { try? admitObservation(from: $0) }
    }

    func captureVisibleObservation() -> InterfaceObservation? {
        visibleObservationSource(self)
    }

}

#endif // DEBUG
#endif // canImport(UIKit)
