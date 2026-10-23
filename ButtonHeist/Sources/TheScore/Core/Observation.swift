import Foundation
import ThePlans

/// Canonical values produced while observing an accessibility interface.
public enum Observation {}

public extension Observation {
    /// Immutable semantic accessibility state admitted from one parse.
    struct Snapshot: Codable, Sendable, Equatable {
        public let interface: Interface
        public let context: Context

        public init(
            interface: Interface,
            context: Context
        ) {
            self.interface = interface
            self.context = context
        }
    }

    /// Semantic context that affects the meaning of a parsed interface.
    struct Context: Codable, Sendable, Equatable {
        public static let empty = Context()

        public let firstResponder: AccessibilityTarget?
        public let keyboardVisible: Bool?
        public let screenId: String?
        public let windowStack: [WindowContext]

        public init(
            firstResponder: AccessibilityTarget? = nil,
            keyboardVisible: Bool? = nil,
            screenId: String? = nil,
            windowStack: [WindowContext] = []
        ) {
            self.firstResponder = firstResponder
            self.keyboardVisible = keyboardVisible
            self.screenId = screenId
            self.windowStack = windowStack
        }
    }

    struct WindowContext: Codable, Sendable, Equatable {
        public let index: Int
        public let level: Double
        public let isKeyWindow: Bool

        public init(index: Int, level: Double, isKeyWindow: Bool) {
            self.index = index
            self.level = level
            self.isKeyWindow = isKeyWindow
        }
    }

    /// Normalized content carried by one accessibility notification.
    ///
    /// Notification kind is consumed before this value is published. An
    /// attached element is parsed independently and carries current semantics
    /// only; it has no graph identity or geometry.
    struct Notification: Codable, Sendable, Equatable {
        public let text: String?
        public let element: HeistElement.Semantics?

        public init?(text: String?, element: HeistElement.Semantics?) {
            guard text != nil || element != nil else { return nil }
            self.text = text
            self.element = element
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case text
            case element
        }

        public init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(
                allowed: CodingKeys.self,
                typeName: "accessibility notification"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let text = try container.decodeIfPresent(String.self, forKey: .text)
            let element = try container.decodeIfPresent(
                HeistElement.Semantics.self,
                forKey: .element
            )
            guard let notification = Self(text: text, element: element) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Accessibility notification must contain text or element semantics"
                ))
            }
            self = notification
        }
    }

    /// One semantic event admitted by the Vault.
    enum Event: Codable, Sendable, Equatable {
        case elementsChanged(Snapshot)
        case screenChanged(ScreenFacts)
        case notification(Notification)
        case noChange

        public var snapshot: Snapshot? {
            switch self {
            case .elementsChanged(let snapshot):
                snapshot
            case .screenChanged, .notification, .noChange:
                nil
            }
        }

        package var changesInterface: Bool {
            switch self {
            case .elementsChanged, .screenChanged:
                true
            case .notification, .noChange:
                false
            }
        }
    }

    /// Exact notification ingress lost before semantic observation admission.
    struct NotificationSequenceGap: Codable, Sendable, Equatable {
        /// The last sequence known to the observation consumer before the gap.
        public let afterSequence: UInt64
        /// The last sequence dropped by ingress, inclusive.
        public let throughSequence: UInt64

        package init(afterSequence: UInt64, throughSequence: UInt64) {
            precondition(afterSequence < throughSequence, "Notification gap must contain a sequence")
            self.afterSequence = afterSequence
            self.throughSequence = throughSequence
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case afterSequence
            case throughSequence
        }

        public init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(
                allowed: CodingKeys.self,
                typeName: "notification sequence gap"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let afterSequence = try container.decode(UInt64.self, forKey: .afterSequence)
            let throughSequence = try container.decode(UInt64.self, forKey: .throughSequence)
            guard afterSequence < throughSequence else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Notification gap must contain a sequence"
                ))
            }
            self.afterSequence = afterSequence
            self.throughSequence = throughSequence
        }
    }

    /// Facts known to be absent from an observation interval.
    enum Gap: Codable, Sendable, Equatable, Error {
        case notificationIngress(
            NotificationSequenceGap,
            additional: [NotificationSequenceGap]
        )
        case captureUnavailable
        case historyUnavailable
        case explorationIncomplete
    }

    /// Whether every selected fact in an observation interval is represented.
    enum Coverage: Codable, Sendable, Equatable {
        case complete
        case incomplete(Gap)
    }

    /// Immutable observation facts supporting one action or wait result.
    struct Evidence: Codable, Sendable, Equatable {
        public let baseline: Snapshot?
        public let events: [Event]
        public let current: Snapshot?
        public let coverage: Coverage

        public init(
            baseline: Snapshot?,
            events: [Event],
            current: Snapshot?,
            coverage: Coverage
        ) {
            self.baseline = baseline
            self.events = events
            self.current = current
            self.coverage = coverage
        }

        public var notificationTexts: [String] {
            events.compactMap { event in
                guard case .notification(let notification) = event else {
                    return nil
                }
                return notification.text
            }
        }

        package static func editTransition(
            from previous: Snapshot?,
            to current: Snapshot
        ) -> ElementEdits {
            previous.map {
                ElementEdits.between($0.interface, current.interface)
            } ?? ElementEdits(
                added: current.interface.projectedElements,
                removed: [],
                updated: []
            )
        }
    }
}

package extension Observation.Snapshot {
    var summary: String {
        let interfaceSummary = "interface: \(interface.projectedElements.count) elements"
        let screen = context.screenId ?? InterfaceSummary.screenName(for: interface)
        guard let screen else { return interfaceSummary }
        return "screen: \(screen); \(interfaceSummary)"
    }
}
