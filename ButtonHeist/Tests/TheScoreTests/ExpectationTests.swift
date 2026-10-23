import ButtonHeistTestSupport
import Testing
import ThePlans
@testable import TheScore

@Suite struct ExpectationTests {
    @Test func `events advance expectations one at a time deterministically`() throws {
        let predicates = [
            try resolved(.elementsChanged([
                .appeared(.label("Checkout")),
            ])),
        ]
        let events: [Observation.Event] = [
            .elementsChanged(snapshot([])),
            .elementsChanged(snapshot(["Checkout"])),
        ]
        let first = Expectation(predicates)
        let second = Expectation(predicates)

        let firstPrefix = first.evaluating(events[0])
        let secondPrefix = second.evaluating(events[0])
        #expect(firstPrefix.result != .satisfied)
        #expect(secondPrefix == firstPrefix)

        let firstComplete = firstPrefix.evaluating(events[1])
        let secondComplete = secondPrefix.evaluating(events[1])
        #expect(firstComplete.result == .satisfied)
        #expect(secondComplete == firstComplete)
    }

    @Test func `ordered progress sequence requires the final Ready arrival`() throws {
        let predicates = [
            try resolved(.elementsChanged([
                .disappeared(.label("Ready")),
                .appeared(.label("Loading")),
                .updated(
                    .label("Loading"),
                    .value(before: "0%", after: "100%")
                ),
                .disappeared(.label("Loading")),
                .appeared(.label("Ready")),
            ])),
        ]
        let events: [Observation.Event] = [
            .elementsChanged(snapshot(["Ready"])),
            .elementsChanged(snapshot(label: "Loading", value: "0%")),
            .elementsChanged(snapshot(label: "Loading", value: "100%")),
            .elementsChanged(snapshot(["Ready"])),
        ]

        #expect(Expectation(predicates, events: Array(events.dropLast())).result != .satisfied)
        #expect(Expectation(predicates, events: events).result == .satisfied)
    }

    @Test func `events can answer later predicates in independent lanes`() throws {
        let predicates = [
            try resolved(.notification("Saved")),
            try resolved(.exists(.label("Present"))),
        ]
        let events: [Observation.Event] = [
            .elementsChanged(snapshot(["Present"])),
            .notification(try notification(text: "Saved")),
        ]

        #expect(Expectation(predicates, events: [events[0]]).result != .satisfied)
        #expect(Expectation(predicates, events: events).result == .satisfied)
    }

    @Test func `baseline initializes current presence without publishing an event`() throws {
        let expectation = Expectation([
            try resolved(.exists(.label("Ready"))),
            try resolved(.missing(.label("Loading"))),
        ], baseline: snapshot(["Ready"]))

        #expect(expectation.result == .satisfied)
    }

    @Test func `baseline initializes the before leg of an appearance`() throws {
        let expectation = Expectation([
            try resolved(.elementsChanged([
                .appeared(.label("Checkout")),
            ])),
        ], baseline: snapshot([])).evaluating(
            .elementsChanged(snapshot(["Checkout"]))
        )

        #expect(expectation.result == .satisfied)
    }

    @Test func `a later sighting invalidates current absence before settlement`() throws {
        let predicate = try resolved(.missing(.label("Moved")))
        let missed = Expectation([predicate], requiringNoChange: true)
            .evaluating(.elementsChanged(snapshot([])))
        let found = missed.evaluating(.elementsChanged(snapshot(["Moved"])))

        #expect(missed.isWaitingOnlyForNoChange)
        #expect(!found.isWaitingOnlyForNoChange)
        #expect(found.evaluating(.noChange).result != .satisfied)
        #expect(found.evaluating(.elementsChanged(snapshot([])))
            .evaluating(.noChange).result == .satisfied)
    }

    @Test func `renewed absence needs settlement after an earlier settled miss`() throws {
        let predicate = try resolved(.missing(.label("Moved")))
        let events: [Observation.Event] = [
            .elementsChanged(snapshot([])),
            .noChange,
            .elementsChanged(snapshot(["Moved"])),
            .elementsChanged(snapshot([])),
        ]
        let expectation = Expectation([predicate], events: events, requiringNoChange: true)

        #expect(expectation.result != .satisfied)
        #expect(expectation.evaluating(.noChange).result == .satisfied)
    }

    @Test func `one event cannot satisfy both legs of an update`() throws {
        let predicate = try resolved(.elementsChanged([
            .updated(.label("Total"), .value()),
        ]))
        let before = Expectation([predicate]).evaluating(
            .elementsChanged(snapshot(label: "Total", value: "$1"))
        )
        let after = before.evaluating(
            .elementsChanged(snapshot(label: "Total", value: "$2"))
        )

        #expect(before.result != .satisfied)
        #expect(after.result == .satisfied)
    }

    @Test func `no change matches only a no-change event`() {
        let predicate = ObservationPredicate.noChange
        let afterElements = Expectation([predicate]).evaluating(
            .elementsChanged(snapshot(["Ready"]))
        )
        let afterScreen = afterElements.evaluating(
            .screenChanged(ScreenFacts(idAfter: "Checkout"))
        )
        let afterNoChange = afterScreen.evaluating(.noChange)

        #expect(afterElements.result == .waiting(predicate.description))
        #expect(afterScreen.result == .waiting(predicate.description))
        #expect(afterNoChange.result == .satisfied)
    }

    @Test func `terminal no-change settles only after authored predicates match`() throws {
        let predicate = try resolved(.notification("Saved"))
        let authoredEvents: [Observation.Event] = [
            .noChange,
            .notification(try notification(text: "Saved")),
        ]
        let earlyNoChange = Expectation([predicate], requiringNoChange: true)
            .evaluating(authoredEvents[0])
        let authoredMatch = earlyNoChange.evaluating(authoredEvents[1])
        let settled = authoredMatch.evaluating(.noChange)

        #expect(earlyNoChange.result != .satisfied)
        #expect(authoredMatch.result != .satisfied)
        #expect(settled.result == .satisfied)
        #expect(Expectation(
            [predicate],
            events: authoredEvents,
            requiringNoChange: true
        ) == authoredMatch)
        #expect(Expectation(
            [predicate],
            events: authoredEvents + [.noChange],
            requiringNoChange: true
        ) == settled)
    }

    @Test func `terminal no-change without authored predicates requires one no-change`() {
        let expectation = Expectation(requiringNoChange: true)

        #expect(expectation.result != .satisfied)
        #expect(expectation.evaluating(.noChange).result == .satisfied)
    }

    @Test func `empty expectation is complete before and after events`() {
        let expectation = Expectation()

        #expect(expectation.result == .satisfied)
        #expect(expectation.evaluating(
            .elementsChanged(snapshot(["Anything"]))
        ).result == .satisfied)
        #expect(expectation.evaluating(.noChange).result == .satisfied)
    }

    private func resolved(
        _ predicate: AccessibilityPredicate
    ) throws -> ObservationPredicate {
        try predicate.resolve(in: .empty)
    }

    private func snapshot(_ labels: [String]) -> Observation.Snapshot {
        Observation.Snapshot(
            interface: makeTestInterface(elements: labels.map {
                makeTestHeistElement(description: $0, label: $0)
            }),
            context: .empty
        )
    }

    private func snapshot(
        label: String,
        value: String
    ) -> Observation.Snapshot {
        Observation.Snapshot(
            interface: makeTestInterface(elements: [
                makeTestHeistElement(label: label, value: value),
            ]),
            context: .empty
        )
    }

    private func notification(
        text: String
    ) throws -> Observation.Notification {
        try #require(Observation.Notification(text: text, element: nil))
    }
}
