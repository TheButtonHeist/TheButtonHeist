import Foundation
import Testing
@testable import ThePlans

@Suite("Canonical Accessibility Predicate")
struct CanonicalAccessibilityPredicateTests {
    /// A screen predicate carries a match and never an assertion list, so its
    /// wire shape has no `assertions` key to be empty. The unnamed form asks
    /// only that a boundary happened, so it carries no `match` either.
    @Test("screen JSON carries the arrived-at match and no assertion list")
    func screenJSON() throws {
        #expect(try json(AccessibilityPredicate.screenChanged) == #"{"scope":"screen","type":"changed"}"#)
        #expect(
            try json(AccessibilityPredicate.screenChanged("Settings")) ==
            #"{"match":{"mode":"exact","value":"Settings"},"scope":"screen","type":"changed"}"#
        )
    }

    /// A scope decides which key carries the authored meaning, so the other one
    /// is not a spare field to ignore. Admitting both and reading one accepts a
    /// document and silently drops what it asked for.
    @Test("a changed predicate rejects the key belonging to the other scope")
    func changedScopeRejectsForeignKeys() throws {
        let screenWithAssertions = Data(#"""
        {"type":"changed","scope":"screen","assertions":[{"type":"exists","target":{"checks":[]}}]}
        """#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AccessibilityPredicate.self, from: screenWithAssertions)
        }

        let elementsWithMatch = Data(#"""
        {"type":"changed","scope":"elements","assertions":[],"match":{"mode":"exact","value":"Settings"}}
        """#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AccessibilityPredicate.self, from: elementsWithMatch)
        }
    }

    @Test("elements JSON uses one canonical target and assertion language")
    func elementsJSON() throws {
        let predicate = AccessibilityPredicate.elementsChanged([
            .exists(.label("Current")),
            .missing(.label("Gone")),
            .appeared(.label("New")),
            .disappeared(.label("Old")),
            .updated(.identifier("count"), .value(before: "1", after: "2")),
        ])

        let decoded = try JSONDecoder().decode(
            AccessibilityPredicate.self,
            from: JSONEncoder().encode(predicate)
        )
        #expect(decoded == predicate)
    }

    @Test("concrete assertion types share the canonical wire codec")
    func assertionJSON() throws {
        let root = AccessibilityPredicate.missing(.label("Loading"))
        let condition = PresenceCondition.missing(.label("Loading"))
        let elementPresence = ElementAssertion.missing(.label("Loading"))
        let elementUpdate = ElementAssertion.updated(
            .identifier("count"),
            .value(before: "1", after: "2")
        )

        let presenceJSON = #"{"target":{"checks":[{"kind":"label","match":{"mode":"exact","value":"Loading"}}]},"type":"missing"}"#
        #expect(try json(root) == presenceJSON)
        #expect(try json(condition) == presenceJSON)
        #expect(try json(elementPresence) == presenceJSON)
        #expect(try JSONDecoder().decode(
            AccessibilityPredicate.self,
            from: JSONEncoder().encode(root)
        ) == root)
        #expect(try JSONDecoder().decode(
            PresenceCondition.self,
            from: JSONEncoder().encode(condition)
        ) == condition)
        #expect(try JSONDecoder().decode(
            ElementAssertion.self,
            from: JSONEncoder().encode(elementPresence)
        ) == elementPresence)
        #expect(try JSONDecoder().decode(
            ElementAssertion.self,
            from: JSONEncoder().encode(elementUpdate)
        ) == elementUpdate)
    }

    @Test("updated admits only element-terminal targets through the canonical target wire")
    func updatedTargetAdmission() throws {
        let target = AccessibilityElementTarget.within(
            container: .identifier("Checkout"),
            .target(.identifier("count"), ordinal: 2)
        )
        let assertion = ElementAssertion.updated(
            target,
            .value(before: "1", after: "2")
        )

        let encoded = try JSONEncoder().encode(assertion)
        #expect(try JSONDecoder().decode(ElementAssertion.self, from: encoded) == assertion)

        let containerTarget = Data(#"""
        {
          "type": "updated",
          "target": { "container": { "checks": [{ "kind": "identifier", "match": { "mode": "exact", "value": "Checkout" } }] } },
          "property": "value",
          "after": { "mode": "exact", "value": "2" }
        }
        """#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ElementAssertion.self, from: containerTarget)
        }

        let scopedContainerTarget = Data(#"""
        {
          "type": "updated",
          "target": {
            "container": { "checks": [{ "kind": "identifier", "match": { "mode": "exact", "value": "Checkout" } }] },
            "target": { "container": { "checks": [{ "kind": "identifier", "match": { "mode": "exact", "value": "List" } }] } }
          },
          "property": "value",
          "after": { "mode": "exact", "value": "2" }
        }
        """#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ElementAssertion.self, from: scopedContainerTarget)
        }
    }

    @Test("notification JSON carries text and one standalone element predicate")
    func notificationJSON() throws {
        let any = AccessibilityPredicate.notification
        let matchingText = AccessibilityPredicate.notification(.contains("processed"))
        let matchingElement = AccessibilityPredicate.notification(element: .label("Saved"))
        let matchingBoth = AccessibilityPredicate.notification(
            text: .contains("processed"),
            element: .element(.label("Saved"), .traits([.staticText]))
        )

        #expect(try json(any) == #"{"type":"notification"}"#)
        #expect(
            try json(matchingText) ==
            #"{"text":{"mode":"contains","value":"processed"},"type":"notification"}"#
        )
        #expect(
            try json(matchingElement) ==
            #"{"element":{"checks":[{"kind":"label","match":{"mode":"exact","value":"Saved"}}]},"type":"notification"}"#
        )
        #expect(
            try JSONDecoder().decode(AccessibilityPredicate.self, from: JSONEncoder().encode(matchingBoth))
                == matchingBoth
        )
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                PresenceCondition.self,
                from: Data(#"{"type":"notification"}"#.utf8)
            )
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                ElementAssertion.self,
                from: Data(#"{"type":"notification"}"#.utf8)
            )
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                AccessibilityPredicate.self,
                from: Data(#"{"type":"notification","target":{"ref":"row"}}"#.utf8)
            )
        }
    }

    @Test("branch presence projects into the execution predicate currency")
    func presenceConditionRootPredicate() throws {
        let condition = PresenceCondition.exists(.label("Receipt"))
        let root = AccessibilityPredicate.exists(.label("Receipt"))
        let resolvedCondition: ResolvedPresenceCondition = try condition.resolve(in: .empty)
        let executionRoot: ObservationPredicate = try root.resolve(in: .empty)

        #expect(condition.rootPredicate == root)
        #expect(resolvedCondition.rootPredicate == executionRoot)
    }

    @Test("container-only targets use the canonical target slot")
    func containerTargetJSON() throws {
        let predicate = AccessibilityPredicate.exists(
            .container(.identifier("Checkout"), ordinal: 1)
        )
        let data = try JSONEncoder().encode(predicate)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try #require(object["target"] as? [String: Any])

        let expectedJSON = #"{"target":{"container":{"checks":["# +
            #"{"kind":"identifier","match":{"mode":"exact","value":"Checkout"}}]},"# +
            #""ordinal":1},"type":"exists"}"#
        #expect(try json(predicate) == expectedJSON)
        #expect(object["type"] as? String == "exists")
        #expect(target["container"] != nil)
        #expect(target["ordinal"] as? Int == 1)
        #expect(predicate.description.contains("ordinal: 1"))
        #expect(try JSONDecoder().decode(AccessibilityPredicate.self, from: data) == predicate)
    }

    @Test(
        "malformed changed JSON is rejected",
        arguments: malformedJSONSources
    )
    func rejectsMalformedJSON(source: String) {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                AccessibilityPredicate.self,
                from: Data(source.utf8)
            )
        }
    }

    private static let malformedJSONSources: [String] = [
        #"{"type":"changed","scope":"screen","unexpected":true}"#,
        #"{"type":"changed","scope":"invalid","assertions":[]}"#,
        #"{"type":"changed","scope":"elements","assertions":[{"type":"updated","# +
            #""target":{"checks":[{"identifier":{"mode":"exact","value":"count"}}]},"# +
            #""property":"value","after":{"mode":"exact","value":"2"}}]}"#,
        #"{"type":"changed","scope":"elements","assertions":["# +
            #"{"type":"changed","scope":"screen"}]}"#,
        #"{"type":"exists","target":{"container":{"checks":["# +
            #"{"kind":"semantic","semantic":{"kind":"identifier","# +
            #""match":{"mode":"exact","value":"Checkout"}}}]},"ordinal":-1}}"#,
        #"{"type":"exists","target":{"container":{"checks":["# +
            #"{"kind":"semantic","semantic":{"kind":"identifier","# +
            #""match":{"mode":"exact","value":"Checkout"}}}]},"# +
            #""target":{"checks":["# +
            #"{"kind":"label","match":{"mode":"exact","value":"Pay"}}]},"ordinal":1}}"#,
    ]

    /// Both screen spellings round-trip: bare `.screen()` for any boundary, and
    /// `.screen("Name")` for the arrived-at screen. The element question that
    /// used to ride inside `.screen([...])` is a sibling predicate now, so it
    /// round-trips through its own `WaitFor`.
    @Test("source parser and renderer use only changed screen spelling")
    func sourceRoundTrip() throws {
        let source = """
        HeistPlan {
            WaitFor(.screenChanged)
            WaitFor(.screenChanged("Receipt"))
            WaitFor(.exists(.container(.identifier("Checkout"), ordinal: 1)))
        }
        """
        let plan = try HeistSourceCompilation.compile(source)
        let expected = try HeistPlan(body: [
            .wait(WaitStep(predicate: .screenChanged, timeout: defaultWaitTimeout)),
            .wait(WaitStep(predicate: .screenChanged("Receipt"), timeout: defaultWaitTimeout)),
            .wait(WaitStep(
                predicate: .exists(.container(.identifier("Checkout"), ordinal: 1)),
                timeout: defaultWaitTimeout
            )),
        ])

        #expect(plan == expected)
        #expect(try plan.canonicalSwiftDSL().contains(".screenChanged"))
        #expect(try plan.canonicalSwiftDSL().contains(".screenChanged(\"Receipt\")"))
        #expect(try plan.canonicalSwiftDSL().contains(".container(.identifier(\"Checkout\"), ordinal: 1)"))
    }

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try #require(String(data: encoder.encode(value), encoding: .utf8))
    }
}
