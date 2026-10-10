import ThePlans
import Foundation
import AccessibilitySnapshotModel

/// Integer-projected accessibility frame used for stable element diffing.
public struct ElementPropertyFrame: Codable, Sendable, Equatable, Hashable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    package init(x: Int, y: Int, width: Int, height: Int) {
        precondition(Self.admits(width: width, height: height))
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static func admit(x: Int, y: Int, width: Int, height: Int) -> Self? {
        guard admits(width: width, height: height) else { return nil }
        return Self(x: x, y: y, width: width, height: height)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case x
        case y
        case width
        case height
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "element property frame")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let admitted = Self.admit(
            x: try container.decode(Int.self, forKey: .x),
            y: try container.decode(Int.self, forKey: .y),
            width: try container.decode(Int.self, forKey: .width),
            height: try container.decode(Int.self, forKey: .height)
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "element property frame dimensions must be non-negative"
            ))
        }
        self = admitted
    }

    private static func admits(width: Int, height: Int) -> Bool {
        width >= 0 && height >= 0
    }

    public var displayText: String {
        "\(x),\(y),\(width),\(height)"
    }
}

/// Integer-projected accessibility activation point used for stable element diffing.
public struct ElementPropertyPoint: Codable, Sendable, Equatable, Hashable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public var displayText: String {
        "\(x),\(y)"
    }
}

/// Typed element property value used by diffs. Human-readable strings are
/// derived at projection/rendering edges through `displayText`.
public enum ElementPropertyValue: Codable, Sendable, Equatable {
    case text(String)
    case traits(Set<HeistTrait>)
    case actions(ElementActionSet)
    case frame(ElementPropertyFrame)
    case activationPoint(ElementPropertyPoint)
    case customContent([HeistCustomContent])
    case rotors([HeistRotor])

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case value
        case traits
        case actions
        case frame
        case activationPoint
        case customContent
        case rotors
    }

    private enum Kind: String, Codable {
        case text
        case traits
        case actions
        case frame
        case activationPoint
        case customContent
        case rotors
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "element property value")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let allowedKeys: Set<CodingKeys>
        switch kind {
        case .text:
            allowedKeys = [.kind, .value]
            self = .text(try container.decode(String.self, forKey: .value))
        case .traits:
            allowedKeys = [.kind, .traits]
            self = .traits(try container.decode([HeistTrait].self, forKey: .traits).heistTraitSet)
        case .actions:
            allowedKeys = [.kind, .actions]
            self = .actions(try container.decode(ElementActionSet.self, forKey: .actions))
        case .frame:
            allowedKeys = [.kind, .frame]
            self = .frame(try container.decode(ElementPropertyFrame.self, forKey: .frame))
        case .activationPoint:
            allowedKeys = [.kind, .activationPoint]
            self = .activationPoint(try container.decode(ElementPropertyPoint.self, forKey: .activationPoint))
        case .customContent:
            allowedKeys = [.kind, .customContent]
            self = .customContent(try container.decode([HeistCustomContent].self, forKey: .customContent))
        case .rotors:
            allowedKeys = [.kind, .rotors]
            self = .rotors(try container.decode([HeistRotor].self, forKey: .rotors))
        }
        try container.rejectIncompatibleFields(
            allowing: allowedKeys,
            typeName: "\(kind.rawValue) property value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .traits(let traits):
            try container.encode(Kind.traits, forKey: .kind)
            try container.encode(traits.canonicalHeistTraitArray, forKey: .traits)
        case .actions(let actions):
            try container.encode(Kind.actions, forKey: .kind)
            try container.encode(actions, forKey: .actions)
        case .frame(let frame):
            try container.encode(Kind.frame, forKey: .kind)
            try container.encode(frame, forKey: .frame)
        case .activationPoint(let point):
            try container.encode(Kind.activationPoint, forKey: .kind)
            try container.encode(point, forKey: .activationPoint)
        case .customContent(let content):
            try container.encode(Kind.customContent, forKey: .kind)
            try container.encode(content, forKey: .customContent)
        case .rotors(let rotors):
            try container.encode(Kind.rotors, forKey: .kind)
            try container.encode(rotors, forKey: .rotors)
        }
    }

    public var displayText: String {
        switch self {
        case .text(let value):
            return value
        case .traits(let traits):
            return traits.canonicalHeistTraitArray.map(\.rawValue).joined(separator: ", ")
        case .actions(let actions):
            return actions.displayText
        case .frame(let frame):
            return frame.displayText
        case .activationPoint(let point):
            return point.displayText
        case .customContent(let content):
            return content.compactMap { item -> String? in
                switch (item.label.isEmpty, item.value.isEmpty) {
                case (false, false): return "\(item.label): \(item.value)"
                case (false, true): return item.label
                case (true, false): return item.value
                case (true, true): return nil
                }
            }.joined(separator: "; ")
        case .rotors(let rotors):
            return rotors.map(\.name).joined(separator: ", ")
        }
    }
}

public struct ElementPropertyValueChange<Value: Sendable & Equatable>: Sendable, Equatable {
    public let old: Value?
    public let new: Value?

    private init(old: Value?, new: Value?) {
        self.old = old
        self.new = new
    }

    public static func difference(old: Value?, new: Value?) -> Self? {
        guard old != new else { return nil }
        return Self(old: old, new: new)
    }

    fileprivate func satisfies<Checker>(
        _ expected: PropertyChangeCore<Checker>,
        matches: (Checker, Value?) -> Bool
    ) -> Bool {
        if let before = expected.before, !matches(before, old) { return false }
        if let after = expected.after, !matches(after, new) { return false }
        return true
    }
}

/// A single typed property change. Each case pins the property to the only
/// value type it can carry.
public enum PropertyChange: Sendable, Equatable {
    case label(ElementPropertyValueChange<String>)
    case identifier(ElementPropertyValueChange<String>)
    case value(ElementPropertyValueChange<String>)
    case traits(ElementPropertyValueChange<Set<HeistTrait>>)
    case hint(ElementPropertyValueChange<String>)
    case actions(ElementPropertyValueChange<ElementActionSet>)
    case frame(ElementPropertyValueChange<ElementPropertyFrame>)
    case activationPoint(ElementPropertyValueChange<ElementPropertyPoint>)
    case customContent(ElementPropertyValueChange<[HeistCustomContent]>)
    case rotors(ElementPropertyValueChange<[HeistRotor]>)

    public static func label(old: String?, new: String?) -> Self? {
        ElementPropertyValueChange.difference(old: old, new: new).map(Self.label)
    }

    public static func identifier(old: String?, new: String?) -> Self? {
        ElementPropertyValueChange.difference(old: old, new: new).map(Self.identifier)
    }

    public static func value(old: String?, new: String?) -> Self? {
        ElementPropertyValueChange.difference(old: old, new: new).map(Self.value)
    }

    public static func traits(old: [HeistTrait]?, new: [HeistTrait]?) -> Self? {
        let old = old.map(\.heistTraitSet)
        let new = new.map(\.heistTraitSet)
        return ElementPropertyValueChange.difference(old: old, new: new).map(Self.traits)
    }

    public static func hint(old: String?, new: String?) -> Self? {
        ElementPropertyValueChange.difference(old: old, new: new).map(Self.hint)
    }

    public static func actions(old: ElementActionSet?, new: ElementActionSet?) -> Self? {
        ElementPropertyValueChange.difference(old: old, new: new).map(Self.actions)
    }

    public static func actions(old: [ElementAction]?, new: [ElementAction]?) -> Self? {
        actions(
            old: old.map { ElementActionSet($0) },
            new: new.map { ElementActionSet($0) }
        )
    }

    public static func frame(old: ElementPropertyFrame?, new: ElementPropertyFrame?) -> Self? {
        ElementPropertyValueChange.difference(old: old, new: new).map(Self.frame)
    }

    public static func activationPoint(old: ElementPropertyPoint?, new: ElementPropertyPoint?) -> Self? {
        ElementPropertyValueChange.difference(old: old, new: new).map(Self.activationPoint)
    }

    public static func customContent(old: [HeistCustomContent]?, new: [HeistCustomContent]?) -> Self? {
        ElementPropertyValueChange.difference(old: old, new: new).map(Self.customContent)
    }

    public static func rotors(old: [HeistRotor]?, new: [HeistRotor]?) -> Self? {
        ElementPropertyValueChange.difference(old: old, new: new).map(Self.rotors)
    }

    public var property: ElementProperty {
        switch self {
        case .label: return .label
        case .identifier: return .identifier
        case .value: return .value
        case .traits: return .traits
        case .hint: return .hint
        case .actions: return .actions
        case .frame: return .frame
        case .activationPoint: return .activationPoint
        case .customContent: return .customContent
        case .rotors: return .rotors
        }
    }

    public var oldValue: ElementPropertyValue? {
        switch self {
        case .label(let change), .identifier(let change), .value(let change), .hint(let change):
            return change.old.map(ElementPropertyValue.text)
        case .traits(let change): return change.old.map(ElementPropertyValue.traits)
        case .actions(let change): return change.old.map(ElementPropertyValue.actions)
        case .frame(let change): return change.old.map(ElementPropertyValue.frame)
        case .activationPoint(let change): return change.old.map(ElementPropertyValue.activationPoint)
        case .customContent(let change): return change.old.map(ElementPropertyValue.customContent)
        case .rotors(let change): return change.old.map(ElementPropertyValue.rotors)
        }
    }

    public var newValue: ElementPropertyValue? {
        switch self {
        case .label(let change), .identifier(let change), .value(let change), .hint(let change):
            return change.new.map(ElementPropertyValue.text)
        case .traits(let change): return change.new.map(ElementPropertyValue.traits)
        case .actions(let change): return change.new.map(ElementPropertyValue.actions)
        case .frame(let change): return change.new.map(ElementPropertyValue.frame)
        case .activationPoint(let change): return change.new.map(ElementPropertyValue.activationPoint)
        case .customContent(let change): return change.new.map(ElementPropertyValue.customContent)
        case .rotors(let change): return change.new.map(ElementPropertyValue.rotors)
        }
    }

    public var oldDisplayText: String? {
        oldValue?.displayText
    }

    public var newDisplayText: String? {
        newValue?.displayText
    }

}

extension PropertyChange: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case property
        case old
        case new
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "property change")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let property = try container.decode(ElementProperty.self, forKey: .property)
        switch property {
        case .label:
            self = .label(try Self.decodeChange(String.self, from: container))
        case .identifier:
            self = .identifier(try Self.decodeChange(String.self, from: container))
        case .value:
            self = .value(try Self.decodeChange(String.self, from: container))
        case .traits:
            self = .traits(try Self.decodeChange(
                [HeistTrait].self,
                from: container,
                normalizing: \.heistTraitSet
            ))
        case .hint:
            self = .hint(try Self.decodeChange(String.self, from: container))
        case .actions:
            self = .actions(try Self.decodeChange(ElementActionSet.self, from: container))
        case .frame:
            self = .frame(try Self.decodeChange(ElementPropertyFrame.self, from: container))
        case .activationPoint:
            self = .activationPoint(try Self.decodeChange(ElementPropertyPoint.self, from: container))
        case .customContent:
            self = .customContent(try Self.decodeChange([HeistCustomContent].self, from: container))
        case .rotors:
            self = .rotors(try Self.decodeChange([HeistRotor].self, from: container))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(property, forKey: .property)
        switch self {
        case .label(let change):
            try Self.encodeChange(change, to: &container)
        case .identifier(let change):
            try Self.encodeChange(change, to: &container)
        case .value(let change):
            try Self.encodeChange(change, to: &container)
        case .traits(let change):
            try container.encodeIfPresent(change.old?.canonicalHeistTraitArray, forKey: .old)
            try container.encodeIfPresent(change.new?.canonicalHeistTraitArray, forKey: .new)
        case .hint(let change):
            try Self.encodeChange(change, to: &container)
        case .actions(let change):
            try Self.encodeChange(change, to: &container)
        case .frame(let change):
            try Self.encodeChange(change, to: &container)
        case .activationPoint(let change):
            try Self.encodeChange(change, to: &container)
        case .customContent(let change):
            try Self.encodeChange(change, to: &container)
        case .rotors(let change):
            try Self.encodeChange(change, to: &container)
        }
    }

    private static func encodeChange<Value>(
        _ change: ElementPropertyValueChange<Value>,
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws where Value: Encodable & Sendable & Equatable {
        try container.encodeIfPresent(change.old, forKey: .old)
        try container.encodeIfPresent(change.new, forKey: .new)
    }

    private static func decodeChange<Value>(
        _ value: Value.Type,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ElementPropertyValueChange<Value> where Value: Codable & Sendable & Equatable {
        try decodeChange(value, from: container, normalizing: { $0 })
    }

    private static func decodeChange<WireValue, Value>(
        _ value: WireValue.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        normalizing: (WireValue) -> Value
    ) throws -> ElementPropertyValueChange<Value>
    where WireValue: Decodable, Value: Sendable & Equatable {
        let old = try container.decodeIfPresent(WireValue.self, forKey: .old).map(normalizing)
        let new = try container.decodeIfPresent(WireValue.self, forKey: .new).map(normalizing)
        guard let change = ElementPropertyValueChange.difference(old: old, new: new) else {
            throw DecodingError.dataCorruptedError(
                forKey: .property,
                in: container,
                debugDescription: "property change must carry different old and new values"
            )
        }
        return change
    }
}

extension PropertyChange {
    package func satisfies(_ expected: ResolvedElementPropertyChange) -> Bool {
        switch (self, expected.value) {
        case (.value(let observed), .value(let change)), (.hint(let observed), .hint(let change)):
            return observed.satisfies(change) { $0.matches(optional: $1) }
        case (.traits(let observed), .traits(let change)):
            return observed.satisfies(change, matches: Self.matchesTraits)
        case (.actions(let observed), .actions(let change)):
            return observed.satisfies(change, matches: Self.matchesActions)
        case (.customContent(let observed), .customContent(let change)):
            return observed.satisfies(change, matches: Self.matchesCustomContent)
        case (.rotors(let observed), .rotors(let change)):
            return observed.satisfies(change, matches: Self.matchesRotors)
        default:
            return false
        }
    }

    private static func matchesTraits(_ checker: TraitSetMatch, _ value: Set<HeistTrait>?) -> Bool {
        guard let value else { return false }
        return checker.include.isSubset(of: value)
            && checker.exclude.isDisjoint(with: value)
    }

    private static func matchesActions(_ checker: ActionSetMatch, _ value: ElementActionSet?) -> Bool {
        guard let value else { return false }
        return checker.include.isSubset(of: value.actions)
            && checker.exclude.isDisjoint(with: value.actions)
    }

    private static func matchesCustomContent(
        _ checker: ResolvedCustomContentMatch,
        _ value: [HeistCustomContent]?
    ) -> Bool {
        guard let value else { return false }
        return value.contains { checker.matches($0) }
    }

    private static func matchesRotors(_ checker: ResolvedRotorSetMatch, _ value: [HeistRotor]?) -> Bool {
        guard let value else { return false }
        let rotorNames = value.map(\.name)
        return checker.include.allSatisfy { rotorNames.contains(matching: $0) }
            && checker.exclude.allSatisfy { !rotorNames.contains(matching: $0) }
    }
}

private extension ResolvedCustomContentMatch {
    func matches(_ content: HeistCustomContent) -> Bool {
        label.matches(content.label)
            && value.matches(content.value)
            && (isImportant.map { $0 == content.isImportant } ?? true)
    }
}

private extension Optional where Wrapped == ResolvedStringMatch {
    func matches(_ text: String) -> Bool {
        map { $0.matches(text) } ?? true
    }
}

private extension Collection where Element == String {
    func contains(matching match: ResolvedStringMatch) -> Bool {
        contains { match.matches($0) }
    }
}

/// An element whose state changed — carries both sides of the transition and
/// which properties differ.
public struct ElementUpdate: Codable, Sendable, Equatable {
    public let before: HeistElement
    public let after: HeistElement
    public let changes: [PropertyChange]

    public init(before: HeistElement, after: HeistElement, changes: [PropertyChange]) {
        self.before = before
        self.after = after
        self.changes = changes
    }
}
