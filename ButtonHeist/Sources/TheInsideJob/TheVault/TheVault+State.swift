#if canImport(UIKit)
#if DEBUG
import Foundation
import ThePlans
import TheScore

extension TheVault {
    internal struct State {
        internal nonisolated static let defaultRetentionLimit = 256

        internal struct HistoryBoundary: Sendable, Equatable {
            internal let baseline: Observation.Snapshot?
            internal let historyIndex: Int
        }

        private struct PendingDepartureEvidence {
            let timestamp: Date
            let context: Observation.Context

            init(snapshot: Observation.Snapshot) {
                timestamp = snapshot.interface.timestamp
                context = snapshot.context
            }

            func snapshot() -> Observation.Snapshot {
                Observation.Snapshot(
                    interface: InterfaceTree.empty.semanticInterface(timestamp: timestamp),
                    context: context
                )
            }
        }

        private enum ReplacementRequirement {
            case newBaseline
            case pendingDeparture(PendingDepartureEvidence)

            var departureEvidence: PendingDepartureEvidence? {
                guard case .pendingDeparture(let evidence) = self else {
                    return nil
                }
                return evidence
            }
        }

        private struct CommittedObservation {
            let current: Current
            let observation: InterfaceObservation
            let tripwireSignal: TheTripwire.TripwireSignal
        }

        private enum CurrentPhase {
            case vacant(replacementRequirement: ReplacementRequirement?)
            case committed(CommittedObservation)
            case invalidated(CommittedObservation)

            var observation: CommittedObservation? {
                switch self {
                case .vacant:
                    nil
                case .committed(let observation), .invalidated(let observation):
                    observation
                }
            }

            var replacementRequirement: ReplacementRequirement? {
                guard case .vacant(let requirement) = self else { return nil }
                return requirement
            }
        }

        internal private(set) var history: Observation.History
        internal private(set) var scopedScreenChangedSequence: UInt64 = 0

        private var currentPhase = CurrentPhase.vacant(
            replacementRequirement: nil
        )
        private var notificationCursor = AccessibilityNotificationCursor.origin
        private var protectedHistoryIndex: Int?

        internal var current: Current? {
            currentPhase.observation?.current
        }

        internal var currentSnapshot: Observation.Snapshot? {
            current?.snapshot
        }

        internal var interfaceTree: InterfaceTree {
            interfaceObservation?.tree ?? .empty
        }

        internal var interfaceObservation: InterfaceObservation? {
            currentPhase.observation?.observation
        }

        internal var notificationIndex: AccessibilityNotificationCursor {
            notificationCursor
        }

        internal var notifications: [Observation.Notification] {
            history.compactMap { event in
                guard case .notification(let notification) = event else {
                    return nil
                }
                return notification
            }
        }

        internal init(retentionLimit: Int = defaultRetentionLimit) {
            history = Observation.History(retentionLimit: retentionLimit)
        }

        internal mutating func discardCurrentObservation() {
            discardCurrentObservation(
                requiring: currentPhase.replacementRequirement ?? .newBaseline
            )
        }

        internal mutating func invalidateCurrentObservationForScreenChange() {
            guard let currentSnapshot else { return }
            discardCurrentObservation(
                requiring: .pendingDeparture(
                    PendingDepartureEvidence(snapshot: currentSnapshot)
                )
            )
        }

        private mutating func discardCurrentObservation(
            requiring requirement: ReplacementRequirement
        ) {
            currentPhase = .vacant(replacementRequirement: requirement)
        }

        internal mutating func invalidateCurrentAdmission() {
            guard case .committed(let observation) = currentPhase else { return }
            currentPhase = .invalidated(observation)
        }

        internal mutating func invalidateAdmissionIfSignalChanged(
            to tripwireSignal: TheTripwire.TripwireSignal
        ) {
            guard case .committed(let observation) = currentPhase,
                  observation.tripwireSignal != tripwireSignal
            else { return }
            invalidateCurrentAdmission()
        }

        internal func admittedObservation(
            scope: SemanticObservationScope,
            after historyIndex: Int?
        ) -> Result<Current?, Observation.History.ReadError> {
            guard case .committed = currentPhase else { return .success(nil) }
            return current(after: historyIndex, scope: scope)
        }

        internal func current(
            after historyIndex: Int?,
            scope: SemanticObservationScope
        ) -> Result<Current?, Observation.History.ReadError> {
            guard let current,
                  current.scope >= scope
            else { return .success(nil) }
            guard let historyIndex else { return .success(current) }
            do {
                _ = try history.events(after: historyIndex)
                return .success(history.endIndex > historyIndex ? current : nil)
            } catch {
                return .failure(error)
            }
        }

        internal mutating func protectHistory(from index: Int) {
            do {
                _ = try history.events(after: index)
            } catch {
                preconditionFailure("Protected index is unavailable in observation history")
            }
            precondition(
                protectedHistoryIndex == nil,
                "Observation history already has an active reader"
            )
            protectedHistoryIndex = index
        }

        internal mutating func releaseHistory(from index: Int) {
            precondition(
                protectedHistoryIndex == index,
                "Observation history index does not belong to the active reader"
            )
            protectedHistoryIndex = nil
            history.prune(protectedBy: nil)
        }

        internal mutating func advanceHistoryProtection(
            from index: Int,
            to nextIndex: Int
        ) {
            precondition(
                protectedHistoryIndex == index,
                "Observation history index does not belong to the active reader"
            )
            do {
                _ = try history.events(after: nextIndex)
            } catch {
                preconditionFailure("Advanced protected index is unavailable in observation history")
            }
            protectedHistoryIndex = nextIndex
            history.prune(protectedBy: nextIndex)
        }

        internal func evidence(
            after boundary: HistoryBoundary
        ) -> Observation.Evidence {
            history.evidence(
                in: boundary.historyIndex..<history.endIndex,
                baseline: boundary.baseline,
                current: currentSnapshot
            )
        }

        internal func observationBoundary(
            scope: SemanticObservationScope
        ) -> HistoryBoundary {
            let baseline: Observation.Snapshot?
            switch admittedObservation(scope: scope, after: nil) {
            case .success(let current):
                baseline = current?.snapshot
            case .failure:
                baseline = nil
            }
            return HistoryBoundary(
                baseline: baseline,
                historyIndex: history.endIndex
            )
        }

        internal mutating func commitObservation(
            _ admission: Observation.Admission,
            beginningNewBaseline: Bool
        ) -> Result<Observation.Publication, Observation.CaptureFailure> {
            var next = self
            if beginningNewBaseline {
                next.discardCurrentObservation()
            }
            let admittedNotifications = admission.notifications.admittedNotifications.filter {
                $0.sequence > next.notificationCursor.sequence
            }
            let previousTree = next.interfaceTree
            let retainedTree = admittedNotifications.contains { notification in
                notification.kind == .layoutChanged
            } ? previousTree.invalidatingParentSpaceGeometry() : previousTree
            let comparedTree: InterfaceTree
            switch admission.scope {
            case .visible:
                comparedTree = retainedTree.updatingViewport(with: admission.tree)
            case .discovery:
                comparedTree = admission.discoveryCommitPolicy == .replaceInterface
                    ? admission.tree
                    : retainedTree.merging(admission.tree)
            }
            let candidateTree = switch admission.lineage {
            case .resting:
                comparedTree
            case .viewportMovement:
                retainedTree.merging(admission.tree)
            }

            let replacementRequirement = next.currentPhase.replacementRequirement
            let continuity: ScreenContinuity
            if replacementRequirement != nil {
                continuity = .replacement(.screenChangedNotification)
            } else {
                continuity = ScreenClassifier.classify(
                    from: previousTree == .empty ? nil : previousTree,
                    to: comparedTree,
                    notifications: admittedNotifications.map(\.kind),
                    lineage: admission.lineage
                )
            }
            let nextTree = continuity.isReplacement ? admission.tree : candidateTree
            let snapshot = Self.snapshot(
                tree: nextTree,
                admission: admission,
                semanticSignal: admission.tripwireSignal.semanticValue
            )
            let notificationEvents = admittedNotifications.compactMap {
                Observation.Notification(text: $0.text, element: $0.element)
                    .map(Observation.Event.notification)
            }
            let departureEvidence = replacementRequirement?.departureEvidence
                ?? next.currentSnapshot.map { PendingDepartureEvidence(snapshot: $0) }
            let events = Self.events(
                notificationEvents: notificationEvents,
                admittedNotifications: admittedNotifications,
                currentSnapshot: next.currentSnapshot,
                departureEvidence: departureEvidence,
                snapshot: snapshot,
                continuity: continuity,
                geometryTolerance: admission.geometryTolerance
            )

            let observation: InterfaceObservation
            do {
                observation = try admission.sourceObservation.replacingTreeWithCurrentCapture(nextTree)
            } catch {
                return .failure(.liveCaptureReattachmentFailed)
            }
            let historyRange = next.history.record(
                events,
                protectedBy: next.protectedHistoryIndex
            )
            let current = Current(
                snapshot: snapshot,
                scope: admission.scope,
                continuity: continuity
            )
            next.currentPhase = .committed(CommittedObservation(
                current: current,
                observation: observation,
                tripwireSignal: admission.tripwireSignal
            ))
            next.notificationCursor = AccessibilityNotificationCursor(
                sequence: max(
                    next.notificationCursor.sequence,
                    admission.notifications.through.sequence
                )
            )
            next.scopedScreenChangedSequence = max(
                next.scopedScreenChangedSequence,
                admission.notifications.scopedScreenChangedThrough
            )
            self = next
            return .success(Observation.Publication(
                current: current,
                events: events,
                historyRange: historyRange
            ))
        }

        private static func snapshot(
            tree: InterfaceTree,
            admission: Observation.Admission,
            semanticSignal: TheTripwire.SemanticSignal
        ) -> Observation.Snapshot {
            let windows = semanticSignal.windows.enumerated().map { index, window in
                Observation.WindowContext(
                    index: index,
                    level: window.level,
                    isKeyWindow: window.isKeyWindow
                )
            }
            let interface = tree.semanticInterface(timestamp: admission.timestamp)
            return Observation.Snapshot(
                interface: interface,
                context: Observation.Context(
                    firstResponder: tree.firstResponderTarget,
                    keyboardVisible: admission.keyboardVisible,
                    screenId: InterfaceSummary.screenId(for: interface),
                    windowStack: windows
                )
            )
        }

        private static func events(
            notificationEvents: [Observation.Event],
            admittedNotifications: [Observation.AdmittedNotification],
            currentSnapshot: Observation.Snapshot?,
            departureEvidence: PendingDepartureEvidence?,
            snapshot: Observation.Snapshot,
            continuity: ScreenContinuity,
            geometryTolerance: CGFloat
        ) -> [Observation.Event] {
            if continuity.isReplacement {
                let departure = departureEvidence?.snapshot()
                    ?? Observation.Snapshot(
                        interface: InterfaceTree.empty.semanticInterface(timestamp: snapshot.interface.timestamp),
                        context: .empty
                    )
                return notificationEvents + [
                    .elementsChanged(departure),
                    .screenChanged(ScreenFacts(
                        idAfter: InterfaceSummary.screenName(for: snapshot.interface)
                    )),
                    .elementsChanged(snapshot),
                ]
            }

            let changed = currentSnapshot.map {
                !$0.hasSameObservedState(
                    as: snapshot,
                    geometryTolerance: geometryTolerance
                )
            } ?? true
            let currentEvent: Observation.Event
            if forcesElementChange(admittedNotifications) || changed {
                currentEvent = .elementsChanged(snapshot)
            } else {
                currentEvent = .noChange
            }
            return notificationEvents + [currentEvent]
        }

        private static func forcesElementChange(
            _ notifications: [Observation.AdmittedNotification]
        ) -> Bool {
            notifications.contains {
                switch $0.kind {
                case .layoutChanged, .elementUpdate:
                    true
                case .screenChanged, .announcement, .unknown:
                    false
                }
            }
        }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
