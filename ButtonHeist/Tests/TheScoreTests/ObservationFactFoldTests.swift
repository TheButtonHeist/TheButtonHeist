import ButtonHeistTestSupport
import Testing
import ThePlans
@testable import TheScore

@Suite struct ObservationFactFoldTests {
    @Test func `screen replacement is authored as departure boundary then arrival`() {
        let events = screenReplacementEvents(
            departing: snapshot(["Cart"]),
            arriving: snapshot(["Checkout"])
        )

        guard case .elementsChanged(let departure) = events[0],
              case .screenChanged(let screen) = events[1],
              case .elementsChanged(let arrival) = events[2]
        else {
            Issue.record("Expected departure, screen boundary, and arrival")
            return
        }
        #expect(departure.interface.tree.isEmpty)
        #expect(screen == ScreenFacts(idAfter: "Checkout"))
        #expect(arrival == snapshot(["Checkout"]))
    }

    @Test func `replacement reintroduces matching new-generation targets`() throws {
        let predicate = try resolved(.elementsChanged([
            .appeared(.label("Checkout")),
        ]))
        let events = screenReplacementEvents(
            departing: snapshot(["Checkout"]),
            arriving: snapshot(["Checkout"])
        )
        let expectation = Expectation(
            [predicate],
            baseline: snapshot(["Checkout"])
        )
        let afterDeparture = expectation.evaluating(events[0])
        let afterBoundary = afterDeparture.evaluating(events[1])

        #expect(afterDeparture.result != .satisfied)
        #expect(afterBoundary.result != .satisfied)
        #expect(afterBoundary.evaluating(events[2]).result == .satisfied)
        #expect(Expectation(
            [predicate],
            baseline: snapshot(["Checkout"]),
            events: events
        ).result == .satisfied)
    }

    @Test func `replacement removes matching old-generation targets`() throws {
        let predicate = try resolved(.elementsChanged([
            .disappeared(.label("Library")),
        ]))
        let events = screenReplacementEvents(
            departing: snapshot(["Library"]),
            arriving: snapshot(["Checkout"])
        )
        let expectation = Expectation(
            [predicate],
            baseline: snapshot(["Library"])
        )

        #expect(expectation.result != .satisfied)
        #expect(expectation.evaluating(events[0]).result == .satisfied)
        #expect(Expectation(
            [predicate],
            baseline: snapshot(["Library"]),
            events: events
        ).result == .satisfied)
    }

    @Test func `replacement presence replays from departure and arrival snapshots`() throws {
        let events = screenReplacementEvents(
            departing: snapshot(["Library"]),
            arriving: snapshot(["Checkout"])
        )
        let exists = try resolved(.exists(.label("Checkout")))
        let missing = try resolved(.missing(.label("Library")))

        #expect(Expectation([exists], events: Array(events.prefix(2))).result != .satisfied)
        #expect(Expectation([exists], events: events).result == .satisfied)
        #expect(Expectation([missing], events: [events[1]]).result != .satisfied)
        #expect(Expectation([missing], events: events).result == .satisfied)
    }

    @Test func `replacement rejects property updates across the screen boundary`() throws {
        let predicate = try resolved(.elementsChanged([
            .updated(
                .label("Counter"),
                .value(before: "1", after: "2")
            ),
        ]))
        let events = screenReplacementEvents(
            departing: valueSnapshot(label: "Counter", value: "1"),
            arriving: valueSnapshot(label: "Counter", value: "2")
        )

        #expect(Expectation(
            [predicate],
            baseline: valueSnapshot(label: "Counter", value: "1"),
            events: events
        ).result != .satisfied)
    }

    @Test func `no-change event is retained in authored order without answering other lanes`() throws {
        let predicates: [ObservationPredicate] = [
            .noChange,
            try resolved(.notification("Saved")),
        ]
        let notification = Observation.Event.notification(try #require(
            Observation.Notification(text: "Saved", element: nil)
        ))
        let beforeNoChange = Expectation(predicates).evaluating(notification)
        let complete = beforeNoChange.evaluating(.noChange)

        #expect(beforeNoChange.result != .satisfied)
        #expect(complete.result == .satisfied)
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

    private func valueSnapshot(
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

    private func screenReplacementEvents(
        departing: Observation.Snapshot,
        arriving: Observation.Snapshot
    ) -> [Observation.Event] {
        [
            .elementsChanged(Observation.Snapshot(
                interface: makeTestInterface(
                    elements: [],
                    timestamp: departing.interface.timestamp
                ),
                context: departing.context
            )),
            .screenChanged(ScreenFacts(idAfter: "Checkout")),
            .elementsChanged(arriving),
        ]
    }
}
