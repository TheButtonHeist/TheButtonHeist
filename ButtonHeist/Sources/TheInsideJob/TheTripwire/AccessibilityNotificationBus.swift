#if canImport(UIKit)
#if DEBUG
import Foundation
import UIKit

import TheScore

/// Vault-owned notification sequence, attribution, and retained ingress log.
@MainActor
final class AccessibilityNotificationBus {
    private struct IngressLog {
        let retentionLimit: Int
        private(set) var retainedEvents: [PendingAccessibilityNotificationEvent] = []
        private(set) var latestSequence: UInt64 = 0
        private(set) var latestScopedScreenChangedSequence: UInt64 = 0
        private var evictedThroughSequence: UInt64 = 0
        private var ambientEventCount = 0

        init(retentionLimit: Int) {
            precondition(retentionLimit > 0, "Notification retention must be positive")
            self.retentionLimit = retentionLimit
        }

        mutating func append(_ event: PendingAccessibilityNotificationEvent) {
            precondition(
                event.sequence > latestSequence,
                "Accessibility notification sequence must advance"
            )
            latestSequence = event.sequence
            if case .screenChanged = event.kind, event.owner.provenance == .scoped {
                latestScopedScreenChangedSequence = event.sequence
            }
            retainedEvents.append(event)
            guard event.owner == .ambient else { return }
            ambientEventCount += 1
            pruneAmbientEventsAfterAppend()
        }

        func checkpoint(
            after cursor: AccessibilityNotificationCursor,
            selection: AccessibilityNotificationCheckpointSelection
        ) -> AccessibilityNotificationBatch {
            let selectedEvents = retainedEvents.filter {
                $0.sequence > cursor.sequence && selection.includes($0)
            }
            return AccessibilityNotificationBatch(
                events: selectedEvents,
                through: AccessibilityNotificationCursor(sequence: latestSequence),
                scopedScreenChangedThrough: latestScopedScreenChangedSequence,
                gap: selection.includesAmbient && cursor.sequence < evictedThroughSequence
                    ? AccessibilityNotificationGap(
                        droppedThroughSequence: evictedThroughSequence
                    )
                    : nil
            )
        }

        mutating func freezeCycleClaim(
            id: AccessibilityNotificationCycleClaim.ID,
            after cursor: AccessibilityNotificationCursor
        ) -> AccessibilityNotificationBatch {
            let cutoff = AccessibilityNotificationCursor(sequence: latestSequence)
            var claimedEvents: [PendingAccessibilityNotificationEvent] = []
            for index in retainedEvents.indices {
                let event = retainedEvents[index]
                guard event.sequence <= cutoff.sequence,
                      event.owner.isEligibleForCycleClaim(
                        sequence: event.sequence,
                        after: cursor
                      )
                else {
                    continue
                }
                commitOwner(
                    .cycle(
                        id,
                        provenance: event.owner.provenance
                    ),
                    at: index
                )
                claimedEvents.append(retainedEvents[index])
            }
            let scopedScreenChangedThrough = claimedEvents.last(where: {
                $0.kind == .screenChanged && $0.owner.provenance == .scoped
            })?.sequence ?? 0
            return AccessibilityNotificationBatch(
                events: claimedEvents,
                through: cutoff,
                scopedScreenChangedThrough: scopedScreenChangedThrough,
                gap: cursor.sequence < evictedThroughSequence
                    ? AccessibilityNotificationGap(
                        droppedThroughSequence: evictedThroughSequence
                    )
                    : nil
            )
        }

        mutating func acknowledgeCycleClaim(_ id: AccessibilityNotificationCycleClaim.ID) {
            retainedEvents.removeAll { event in
                guard case .cycle(let ownerID, _) = event.owner else { return false }
                return ownerID == id
            }
        }

        private mutating func commitOwner(
            _ owner: PendingAccessibilityNotificationEvent.Owner,
            at index: Int
        ) {
            let wasAmbient = retainedEvents[index].owner == .ambient
            let isAmbient = owner == .ambient
            switch (wasAmbient, isAmbient) {
            case (true, false):
                ambientEventCount -= 1
            case (false, true):
                ambientEventCount += 1
            case (true, true), (false, false):
                break
            }
            retainedEvents[index].owner = owner
        }

        private mutating func pruneAmbientEventsAfterAppend() {
            let overflow = ambientEventCount - retentionLimit
            guard overflow > 0 else { return }

            var remaining = overflow
            var newestEvictedSequence: UInt64 = 0
            retainedEvents.removeAll { event in
                guard remaining > 0, event.owner == .ambient else { return false }
                remaining -= 1
                newestEvictedSequence = max(newestEvictedSequence, event.sequence)
                return true
            }
            precondition(remaining == 0, "Ambient notification ownership count drifted")
            ambientEventCount -= overflow
            evictedThroughSequence = max(evictedThroughSequence, newestEvictedSequence)
        }
    }

    private var ingressLog = IngressLog(retentionLimit: 64)
    private var activeHeistCursor: AccessibilityNotificationCursor?
    private var nextActionWindowID: UInt64 = 0
    private var activeActionWindowID: AccessibilityNotificationActionWindowID?
    private var nextCycleClaimID: UInt64 = 0
    private var frozenCycleClaim: AccessibilityNotificationCycleClaim?
    private var admittedAmbientThrough = AccessibilityNotificationCursor.origin

    var latestSequence: UInt64 {
        ingressLog.latestSequence
    }

    /// Sequence of the most recent `screenChanged` notification recorded
    /// inside a heist or action notification scope, or 0.
    var latestScopedScreenChangedSequence: UInt64 {
        ingressLog.latestScopedScreenChangedSequence
    }

    func cursor() -> AccessibilityNotificationCursor {
        AccessibilityNotificationCursor(sequence: ingressLog.latestSequence)
    }

    /// Opens the outer correlation window for a running heist.
    ///
    /// While this scope is active, action windows may claim attribution. Unclaimed
    /// ingress remains owned by this scope until its admitted cutoff is released.
    func beginHeistScope() -> AccessibilityNotificationScopeLease {
        beginScopeLease(ownership: .heist)
    }

    /// Opens the inner attribution window for one dispatched action.
    ///
    /// Events with sequence numbers greater than this cursor can be attached to
    /// the action evidence without stealing earlier heist-level context.
    func beginActionWindow() -> AccessibilityNotificationScopeLease {
        precondition(
            activeActionWindowID == nil,
            "Only one action notification window may be active"
        )
        nextActionWindowID += 1
        let actionWindowID = AccessibilityNotificationActionWindowID(
            rawValue: nextActionWindowID
        )
        let cursor = AccessibilityNotificationCursor(
            sequence: ingressLog.latestSequence
        )
        activeActionWindowID = actionWindowID
        return beginScopeLease(
            ownership: .action(actionWindowID),
            cursor: cursor
        )
    }

    private func beginScopeLease(
        ownership: AccessibilityNotificationScopeOwnership,
        cursor: AccessibilityNotificationCursor? = nil
    ) -> AccessibilityNotificationScopeLease {
        let cursor = cursor ?? AccessibilityNotificationCursor(sequence: ingressLog.latestSequence)
        if ownership == .heist {
            precondition(activeHeistCursor == nil, "Only one heist notification scope may be active")
            activeHeistCursor = cursor
        }
        return AccessibilityNotificationScopeLease(
            bus: self,
            cursor: cursor,
            ownership: ownership
        )
    }

    func record(
        rawCode: UInt32,
        timestamp: Date,
        notificationData: PendingAccessibilityNotificationPayload,
        associatedElement: PendingAccessibilityNotificationPayload
    ) {
        precondition(
            ingressLog.latestSequence < UInt64.max,
            "Accessibility notification sequence overflowed"
        )
        ingressLog.append(PendingAccessibilityNotificationEvent(
            sequence: ingressLog.latestSequence + 1,
            rawCode: rawCode,
            timestamp: timestamp,
            notificationData: notificationData,
            associatedElement: associatedElement,
            owner: currentOwner
        ))
    }

    nonisolated fileprivate static func stringPayload(_ value: AnyObject?) -> String? {
        switch value {
        case let string as NSString:
            return normalized(string as String)
        case let attributed as NSAttributedString:
            return normalized(attributed.string)
        default:
            return nil
        }
    }

    nonisolated fileprivate static func notificationPayloadObject(from object: AnyObject?) -> AnyObject? {
        guard let dictionary = object as? NSDictionary,
              let data = dictionary["data"]
        else {
            return object
        }
        if data is NSNull {
            return nil
        }
        return data as AnyObject
    }

    nonisolated private static func normalized(_ string: String) -> String? {
        let normalized = string
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    nonisolated fileprivate static func className(for value: AnyObject?) -> String {
        guard let object = value else { return "nil" }
        return NSStringFromClass(type(of: object))
    }

    nonisolated fileprivate static func summary(for value: AnyObject?) -> String? {
        switch value {
        case let dictionary as NSDictionary:
            return dictionarySummary(dictionary)
        case let array as NSArray:
            return arraySummary(array)
        case let string as NSString:
            return "string(\(truncated(string as String)))"
        case let attributed as NSAttributedString:
            return "attributedString(\(truncated(attributed.string)))"
        case let object as NSObject:
            return "object(class=\(NSStringFromClass(type(of: object))) description=\(truncated(String(describing: object))))"
        default:
            return nil
        }
    }

    nonisolated private static func dictionarySummary(_ dictionary: NSDictionary) -> String {
        var entries: [String] = []
        for (key, value) in dictionary {
            let valueObject = value as AnyObject
            entries.append(
                "\(truncated(String(describing: key))):\(className(for: valueObject))=\(truncated(String(describing: value)))"
            )
            if entries.count == 8 { break }
        }
        let suffix = dictionary.count > entries.count ? ",..." : ""
        return "dictionary(count=\(dictionary.count) \(entries.joined(separator: ","))\(suffix))"
    }

    nonisolated private static func arraySummary(_ array: NSArray) -> String {
        var entries: [String] = []
        for value in array {
            let valueObject = value as AnyObject
            entries.append("\(className(for: valueObject))=\(truncated(String(describing: value)))")
            if entries.count == 8 { break }
        }
        let suffix = array.count > entries.count ? ",..." : ""
        return "array(count=\(array.count) \(entries.joined(separator: ","))\(suffix))"
    }

    nonisolated private static func truncated(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if singleLine.count <= 160 {
            return singleLine
        }
        return "\(singleLine.prefix(157))..."
    }

    func checkpoint(
        after cursor: AccessibilityNotificationCursor,
        selection: AccessibilityNotificationCheckpointSelection = .scoped
    ) -> AccessibilityNotificationBatch {
        ingressLog.checkpoint(after: cursor, selection: selection)
    }

    func freezeObservationCycleClaim() -> AccessibilityNotificationCycleClaim {
        if let frozenCycleClaim {
            return AccessibilityNotificationCycleClaim(
                bus: self,
                id: frozenCycleClaim.id,
                batch: frozenCycleClaim.batch
            )
        }
        nextCycleClaimID += 1
        let id = AccessibilityNotificationCycleClaim.ID(
            rawValue: nextCycleClaimID
        )
        let claimedBatch = ingressLog.freezeCycleClaim(
            id: id,
            after: admittedAmbientThrough
        )
        let claim = AccessibilityNotificationCycleClaim(
            bus: self,
            id: id,
            batch: claimedBatch
        )
        frozenCycleClaim = claim
        return claim
    }

    fileprivate func acknowledgeCycleClaim(
        _ id: AccessibilityNotificationCycleClaim.ID
    ) -> Bool {
        guard frozenCycleClaim?.id == id else { return false }
        ingressLog.acknowledgeCycleClaim(id)
        admittedAmbientThrough = frozenCycleClaim?.batch.through
            ?? admittedAmbientThrough
        frozenCycleClaim = nil
        return true
    }

    fileprivate func sealScope(
        _ ownership: AccessibilityNotificationScopeOwnership,
        after cursor: AccessibilityNotificationCursor
    ) -> AccessibilityNotificationCoverage {
        let screenChangedThrough = ingressLog.latestScopedScreenChangedSequence
        let coverage = AccessibilityNotificationCoverage(
            after: cursor,
            through: AccessibilityNotificationCursor(
                sequence: ingressLog.latestSequence
            ),
            scopedScreenChangedThrough: screenChangedThrough > cursor.sequence
                ? screenChangedThrough
                : 0
        )
        switch ownership {
        case .heist:
            precondition(
                activeHeistCursor == cursor,
                "Cannot end an inactive heist notification scope"
            )
            activeHeistCursor = nil
        case .action(let actionWindowID):
            guard let activeActionWindowID else {
                preconditionFailure(
                    "Cannot end an action notification window that is not active"
                )
            }
            precondition(
                activeActionWindowID == actionWindowID,
                "Cannot end an action notification window that is not active"
            )
            self.activeActionWindowID = nil
        }
        return coverage
    }

    private var currentOwner: PendingAccessibilityNotificationEvent.Owner {
        if let actionWindowID = activeActionWindowID {
            return .action(actionWindowID)
        }
        if let activeHeistCursor {
            return .heist(activeHeistCursor)
        }
        return .ambient
    }
}

struct AccessibilityNotificationCursor: Sendable, Equatable {
    static let origin = AccessibilityNotificationCursor(sequence: 0)

    let sequence: UInt64
}

struct AccessibilityNotificationCoverage: Sendable, Equatable {
    let after: AccessibilityNotificationCursor
    let through: AccessibilityNotificationCursor
    let scopedScreenChangedThrough: UInt64

    var requiresObservation: Bool {
        through.sequence > after.sequence
    }
}

enum AccessibilityNotificationCheckpointSelection: Sendable {
    case all
    case scoped

    fileprivate func includes(_ event: PendingAccessibilityNotificationEvent) -> Bool {
        switch self {
        case .all:
            true
        case .scoped:
            event.owner.provenance == .scoped
        }
    }

    fileprivate var includesAmbient: Bool {
        switch self {
        case .all:
            true
        case .scoped:
            false
        }
    }
}

struct AccessibilityNotificationActionWindowID: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

enum AccessibilityNotificationScopeOwnership: Sendable, Equatable {
    case heist
    case action(AccessibilityNotificationActionWindowID)
}

struct AccessibilityNotificationBatch {
    let events: [PendingAccessibilityNotificationEvent]
    let through: AccessibilityNotificationCursor
    let scopedScreenChangedThrough: UInt64
    let gap: AccessibilityNotificationGap?

    /// Starts a complete observation history after ambient ingress was evicted.
    ///
    /// Scoped events are timeout-bounded and never evicted, so they remain
    /// admissible on the new baseline. Missing ambient history cannot be
    /// represented as `.noChange`; discarding the prior snapshot makes the
    /// capture publish a replacement instead.
    var beginningNewBaseline: Self {
        precondition(gap != nil, "A complete notification batch needs no new baseline")
        return Self(
            events: events.filter { $0.provenance == .scoped },
            through: through,
            scopedScreenChangedThrough: scopedScreenChangedThrough,
            gap: nil
        )
    }
}

@MainActor
final class AccessibilityNotificationCycleClaim {
    struct ID: RawRepresentable, Sendable, Equatable {
        let rawValue: UInt64
    }

    let id: ID
    let batch: AccessibilityNotificationBatch

    private weak var bus: AccessibilityNotificationBus?

    fileprivate init(
        bus: AccessibilityNotificationBus,
        id: ID,
        batch: AccessibilityNotificationBatch
    ) {
        self.bus = bus
        self.id = id
        self.batch = batch
    }

    @discardableResult
    func acknowledgeObservationCycle() -> Bool {
        bus?.acknowledgeCycleClaim(id) ?? false
    }
}

enum AccessibilityNotificationProvenance: Sendable, Equatable {
    case scoped
    case ambient
}

/// Main-actor lifetime token for scoped notification attribution.
@MainActor
final class AccessibilityNotificationScopeLease {
    private enum State {
        case active(AccessibilityNotificationBus)
        case sealed(AccessibilityNotificationCoverage)
        case admitting(
            AccessibilityNotificationCoverage,
            cancellationRequested: Bool
        )
        case finished
    }

    let cursor: AccessibilityNotificationCursor

    private let ownership: AccessibilityNotificationScopeOwnership
    private var state: State

    fileprivate init(
        bus: AccessibilityNotificationBus,
        cursor: AccessibilityNotificationCursor,
        ownership: AccessibilityNotificationScopeOwnership
    ) {
        self.cursor = cursor
        self.ownership = ownership
        self.state = .active(bus)
    }

    isolated deinit {
        cancel()
    }

    func admitCausallyCovered<Result>(
        _ admit: (AccessibilityNotificationCoverage) async -> Result?
    ) async -> Result? {
        let coverage: AccessibilityNotificationCoverage
        switch state {
        case .active(let bus):
            coverage = bus.sealScope(ownership, after: cursor)
        case .sealed(let sealedCoverage):
            coverage = sealedCoverage
        case .admitting, .finished:
            return nil
        }
        state = .admitting(coverage, cancellationRequested: false)

        let result = await admit(coverage)
        guard case .admitting(
            let admittedCoverage,
            let cancellationRequested
        ) = state,
              admittedCoverage == coverage
        else { return nil }

        if result != nil {
            state = .finished
        } else {
            state = cancellationRequested ? .finished : .sealed(coverage)
        }
        return result
    }

    func cancel() {
        switch state {
        case .active(let bus):
            _ = bus.sealScope(ownership, after: cursor)
            state = .finished
        case .sealed:
            state = .finished
        case .admitting(let coverage, cancellationRequested: false):
            state = .admitting(
                coverage,
                cancellationRequested: true
            )
        case .admitting(_, cancellationRequested: true), .finished:
            break
        }
    }
}

struct PendingAccessibilityNotificationEvent {
    enum Owner: Sendable, Equatable {
        case ambient
        case heist(AccessibilityNotificationCursor)
        case action(AccessibilityNotificationActionWindowID)
        case cycle(
            AccessibilityNotificationCycleClaim.ID,
            provenance: AccessibilityNotificationProvenance
        )

        var provenance: AccessibilityNotificationProvenance {
            switch self {
            case .ambient:
                .ambient
            case .heist, .action:
                .scoped
            case .cycle(_, let provenance):
                provenance
            }
        }

        func isEligibleForCycleClaim(
            sequence: UInt64,
            after ambientCursor: AccessibilityNotificationCursor
        ) -> Bool {
            switch self {
            case .ambient:
                sequence > ambientCursor.sequence
            case .heist, .action:
                true
            case .cycle:
                false
            }
        }
    }

    let sequence: UInt64
    let kind: AccessibilityNotificationKind
    let timestamp: Date
    /// The argument posted with the accessibility notification.
    let notificationData: PendingAccessibilityNotificationPayload
    /// UIKit's correlation subject. It is notification content only for
    /// element-change notifications.
    let associatedElement: PendingAccessibilityNotificationPayload
    var owner: Owner

    var provenance: AccessibilityNotificationProvenance {
        owner.provenance
    }

    init(
        sequence: UInt64,
        kind: AccessibilityNotificationKind,
        timestamp: Date,
        notificationData: PendingAccessibilityNotificationPayload,
        associatedElement: PendingAccessibilityNotificationPayload,
        provenance: AccessibilityNotificationProvenance
    ) {
        let owner: Owner = switch provenance {
        case .scoped:
            .heist(.origin)
        case .ambient:
            .ambient
        }
        self.init(
            sequence: sequence,
            kind: kind,
            timestamp: timestamp,
            notificationData: notificationData,
            associatedElement: associatedElement,
            owner: owner
        )
    }

    fileprivate init(
        sequence: UInt64,
        kind: AccessibilityNotificationKind,
        timestamp: Date,
        notificationData: PendingAccessibilityNotificationPayload,
        associatedElement: PendingAccessibilityNotificationPayload,
        owner: Owner
    ) {
        self.sequence = sequence
        self.kind = kind
        self.timestamp = timestamp
        self.notificationData = notificationData
        self.associatedElement = associatedElement
        self.owner = owner
    }

    init(
        sequence: UInt64,
        rawCode: UInt32,
        timestamp: Date,
        notificationData: PendingAccessibilityNotificationPayload,
        associatedElement: PendingAccessibilityNotificationPayload,
        provenance: AccessibilityNotificationProvenance
    ) {
        self.init(
            sequence: sequence,
            kind: AccessibilityNotificationKind(rawCode: rawCode),
            timestamp: timestamp,
            notificationData: notificationData,
            associatedElement: associatedElement,
            provenance: provenance
        )
    }

    fileprivate init(
        sequence: UInt64,
        rawCode: UInt32,
        timestamp: Date,
        notificationData: PendingAccessibilityNotificationPayload,
        associatedElement: PendingAccessibilityNotificationPayload,
        owner: Owner
    ) {
        self.init(
            sequence: sequence,
            kind: AccessibilityNotificationKind(rawCode: rawCode),
            timestamp: timestamp,
            notificationData: notificationData,
            associatedElement: associatedElement,
            owner: owner
        )
    }
}

enum PendingAccessibilityNotificationPayload {
    case none
    case string(String)
    case object(AccessibilityNotificationObjectIdentity)
}

struct CapturedAccessibilityNotificationPayload {
    static var none: CapturedAccessibilityNotificationPayload {
        CapturedAccessibilityNotificationPayload(
            pendingPayload: .none,
            className: "nil",
            summary: nil,
            objectIdentifier: nil
        )
    }

    let pendingPayload: PendingAccessibilityNotificationPayload
    let className: String
    let summary: String?
    let objectIdentifier: ObjectIdentifier?

    init(_ object: AnyObject?) {
        guard let object else {
            self = .none
            return
        }
        let className = AccessibilityNotificationBus.className(for: object)
        let summary = AccessibilityNotificationBus.summary(for: object)
        guard let payloadObject = AccessibilityNotificationBus.notificationPayloadObject(from: object) else {
            self.init(
                pendingPayload: .none,
                className: className,
                summary: summary,
                objectIdentifier: nil
            )
            return
        }
        if let value = AccessibilityNotificationBus.stringPayload(payloadObject) {
            self.init(
                pendingPayload: .string(value),
                className: className,
                summary: summary,
                objectIdentifier: nil
            )
        } else {
            let identity = AccessibilityNotificationObjectIdentity(
                object: payloadObject,
                className: className,
                summary: summary
            )
            self.init(
                pendingPayload: .object(identity),
                className: className,
                summary: summary,
                objectIdentifier: identity.objectIdentifier
            )
        }
    }

    private init(
        pendingPayload: PendingAccessibilityNotificationPayload,
        className: String,
        summary: String?,
        objectIdentifier: ObjectIdentifier?
    ) {
        self.pendingPayload = pendingPayload
        self.className = className
        self.summary = summary
        self.objectIdentifier = objectIdentifier
    }
}

final class AccessibilityNotificationObjectIdentity {
    let objectIdentifier: ObjectIdentifier
    let className: String
    let summary: String?
    weak var object: AnyObject?

    init(_ object: AnyObject) {
        self.objectIdentifier = ObjectIdentifier(object)
        self.className = AccessibilityNotificationBus.className(for: object)
        self.summary = AccessibilityNotificationBus.summary(for: object)
        self.object = object
    }

    init(object: AnyObject, className: String, summary: String?) {
        self.objectIdentifier = ObjectIdentifier(object)
        self.className = className
        self.summary = summary
        self.object = object
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
