import Foundation

package enum CanonicalValueDescription {
    package enum QuotedStringStyle: Equatable, Sendable {
        case json
        case singleLineJSON
        case plain
    }

    package static func quoted(_ value: String) -> String {
        quoted(value, style: .json)
    }

    package static func quoted(_ value: String, style: QuotedStringStyle) -> String {
        switch style {
        case .json:
            return jsonQuoted(value)
        case .singleLineJSON:
            return jsonQuoted(value.replacingOccurrences(of: "\n", with: " "))
        case .plain:
            return "\"\(value)\""
        }
    }

    private static func jsonQuoted(_ value: String) -> String {
        // Boundary try?: display-only JSON string escaping, with a local
        // deterministic escape path when Foundation encoding cannot help.
        if let data = try? JSONEncoder().encode(value),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    package static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    package static func stringField(_ name: String, _ value: String?) -> String? {
        nonEmpty(value).map { "\(name)=\(quoted($0))" }
    }

    package static func stringMatchFields(_ name: String, _ values: [ResolvedStringMatch]) -> String? {
        let fields = values.compactMap { value -> String? in
            guard value.hasPredicateLiteral else { return nil }
            return "\(name)=\(stringMatch(value))"
        }
        guard !fields.isEmpty else { return nil }
        return fields.joined(separator: " ")
    }

    package static func stringMatch(_ value: ResolvedStringMatch) -> String {
        guard let string = value.value else { return "isEmpty" }
        switch value.mode {
        case .exact: return quoted(string)
        case .contains: return "contains(\(quoted(string)))"
        case .prefix: return "prefix(\(quoted(string)))"
        case .suffix: return "suffix(\(quoted(string)))"
        case .isEmpty: return "isEmpty"
        }
    }

    package static func predicateCheckField(_ check: ResolvedElementPredicateCheck) -> String? {
        switch check {
        case .label(let match):
            guard match.hasPredicateLiteral else { return nil }
            return "label=\(stringMatch(match))"
        case .identifier(let match):
            guard match.hasPredicateLiteral else { return nil }
            return "identifier=\(stringMatch(match))"
        case .value(let match):
            guard match.hasPredicateLiteral else { return nil }
            return "value=\(stringMatch(match))"
        case .hint(let match):
            guard match.hasPredicateLiteral else { return nil }
            return "hint=\(stringMatch(match))"
        case .traits(let traits):
            return listField("traits", traits.isEmpty ? nil : traits.canonicalHeistTraitArray)
        case .actions(let actions):
            return listField("actions", actions.isEmpty ? nil : actions.canonicalElementActionArray)
        case .customContent(let match):
            guard match.hasPredicateLiteral else { return nil }
            return "customContent=\(match)"
        case .rotors(let matches):
            return stringMatchFields("rotors", matches)
        case .exclude(let check):
            guard let field = predicateCheckField(check) else { return nil }
            return "exclude(\(field))"
        }
    }

    package static func valueField<T>(_ name: String, _ value: T?) -> String? {
        value.map { "\(name)=\($0)" }
    }

    package static func listField<T>(_ name: String, _ values: [T]?) -> String? {
        guard let values, !values.isEmpty else { return nil }
        return "\(name)=\(list(values))"
    }

    package static func list<T>(_ values: [T]) -> String {
        "[\(values.map { String(describing: $0) }.joined(separator: ", "))]"
    }

    package static func call(_ name: String, _ fields: [String]) -> String {
        fields.isEmpty ? "\(name)(*)" : "\(name)(\(fields.joined(separator: " ")))"
    }

    package static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        let rounded = value.rounded()
        if abs(value - rounded) < 0.000_001 {
            return "\(Int(rounded))"
        }
        var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }
}
