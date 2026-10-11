#if canImport(UIKit)
#if DEBUG
import Foundation
import TheScore

extension TheVault.State {
    /// Read projection of the Vault's current snapshot and navigation admission.
    ///
    /// The State owns the committed observation. This projection carries
    /// neither a second observation nor capture identity.
    internal struct Current: Sendable, Equatable {
        internal let snapshot: Observation.Snapshot
        internal let scope: SemanticObservationScope
        internal let continuity: ScreenContinuity

    }
}

extension Observation {
    internal enum CaptureFailure: Error, Sendable, Equatable {
        case cancelled
        case sourceTreeUnavailable
        case hierarchyChangedDuringCapture
        case liveCaptureReattachmentFailed

        internal var diagnostic: String {
            switch self {
            case .cancelled:
                "the accessibility capture was cancelled"
            case .sourceTreeUnavailable:
                "the accessibility tree could not be read"
            case .hierarchyChangedDuringCapture:
                "the view hierarchy moved while the reading was taken"
            case .liveCaptureReattachmentFailed:
                "live accessibility evidence no longer matches the committed interface"
            }
        }
    }

    /// One admitted observation's current state and authored events.
    internal struct Publication: Sendable {
        /// One retained semantic event paired with its absolute history
        /// position. Event values remain position-free; a publication carries
        /// the position from retained truth into live delivery.
        internal struct Entry: Sendable, Equatable {
            internal let historyIndex: Int
            internal let event: Observation.Event
        }

        internal let current: TheVault.State.Current
        internal let entries: [Entry]

        internal var events: [Event] {
            entries.map(\.event)
        }

        internal init(
            current: TheVault.State.Current,
            events: [Event],
            historyRange: Range<Int>
        ) {
            precondition(
                events.count == historyRange.count,
                "Every published observation event must have one history position"
            )
            self.current = current
            entries = zip(historyRange, events).map { historyIndex, event in
                Entry(historyIndex: historyIndex, event: event)
            }
        }
    }

    internal struct Admission {
        internal let sourceObservation: InterfaceObservation
        internal let tripwireSignal: TheTripwire.TripwireSignal
        internal let discoveryCommitPolicy: Navigation.DiscoveryCommitPolicy
        internal let lineage: ScreenLineage
        internal let scope: SemanticObservationScope
        internal let notifications: NotificationSnapshot
        internal let keyboardVisible: Bool?
        internal let timestamp: Date
        /// Where the read tree's visible elements sat. Only the viewport has
        /// live geometry, so only the viewport is asked.
        internal let viewportFrames: [HeistId: CGRect]
        /// The device's touch-target size, captured eagerly because the
        /// comparison that uses it runs off the main actor.
        internal let geometryTolerance: CGFloat

        internal var tree: InterfaceTree {
            sourceObservation.tree
        }
    }

    internal struct NotificationSnapshot: Sendable {
        internal let admittedNotifications: [AdmittedNotification]
        internal let through: AccessibilityNotificationCursor
        internal let scopedScreenChangedThrough: UInt64

        internal init?(
            admittedNotifications: [AdmittedNotification],
            through: AccessibilityNotificationCursor,
            scopedScreenChangedThrough: UInt64,
            gap: AccessibilityNotificationGap? = nil
        ) {
            guard gap == nil else { return nil }
            self.admittedNotifications = admittedNotifications
            self.through = through
            self.scopedScreenChangedThrough = scopedScreenChangedThrough
        }

    }

    internal struct AdmittedNotification: Sendable, Equatable {
        internal let sequence: UInt64
        internal let kind: AccessibilityNotificationKind
        internal let text: String?
        internal let element: HeistElement.Semantics?
    }
}

@MainActor
internal enum VisibleObservationOutcome: Equatable {
    case committed(TheVault.State.Current)
    case unavailable(Observation.CaptureFailure)

    internal var isCommitted: Bool {
        if case .committed = self { true } else { false }
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
