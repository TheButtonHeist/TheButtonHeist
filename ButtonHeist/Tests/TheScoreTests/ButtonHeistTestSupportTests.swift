import AccessibilitySnapshotModel
import ButtonHeistTestSupport
import Foundation
import Testing
import ThePlans
@testable import TheScore

@Suite struct ButtonHeistTestSupportTests {

    @Test func `shared JSONProbe reads nested typed values`() throws {
        let probe = try JSONProbe(data: Data("""
        {
          "items": [{"label": "Save"}],
          "metadata": {
            "enabled": true,
            "count": 2,
            "ratio": 1,
            "traits": ["button", "selected"]
          }
        }
        """.utf8))

        let firstItem = try #require(try probe.array("items").first)
        let metadata = try probe.object("metadata")

        #expect(try firstItem.string("label") == "Save")
        #expect(try metadata.bool("enabled"))
        #expect(try metadata.int("count") == 2)
        #expect(try metadata.double("ratio") == 1)
        #expect(try metadata.strings("traits") == ["button", "selected"])
    }

    @Test func `shared JSONProbe reports typed path failures`() throws {
        let probe = try JSONProbe(data: Data(#"{"root":{"bad-key":true}}"#.utf8))

        do {
            _ = try probe.object("root").string("bad-key")
            Issue.record("Expected JSONProbeFailure")
        } catch let error as JSONProbeFailure {
            #expect(error.path == #"$.root["bad-key"]"#)
            #expect(error.reason == "Expected string, got bool")
        }
    }

    @Test func `shared temporary directory fixture removes directory after body returns`() throws {
        let directory = try withTemporaryDirectory(prefix: "temp-directory-fixture") { directory in
            #expect(FileManager.default.fileExists(atPath: directory.path))
            try Data([0x00]).write(to: directory.appendingPathComponent("scratch.bin"))
            return directory
        }

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func `shared temporary directory fixture throws creation failures before body runs`() throws {
        try withTemporaryDirectory(prefix: "temp-directory-fixture-parent") { directory in
            let fileURL = directory.appendingPathComponent("not-a-directory")
            try Data([0x00]).write(to: fileURL)

            #expect(throws: (any Error).self) {
                try withTemporaryDirectory(prefix: "child", rootDirectory: fileURL) { _ in
                    Issue.record("Expected directory creation to fail before body runs")
                }
            }
        }
    }

    @Test func `shared result directory fixture finds one gzip artifact recursively`() throws {
        let resultName = try withResultDirectory(prefix: "result-directory-fixture") { directory in
            let nestedDirectory = directory.appendingPathComponent("checkout-flow", isDirectory: true)
            try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
            try Data([0x00]).write(to: nestedDirectory.appendingPathComponent("result-passed.json.gz"))
            try Data([0x00]).write(to: nestedDirectory.appendingPathComponent("notes.txt"))

            return try assertSingleResultArtifactURL(in: directory).lastPathComponent
        }

        #expect(resultName == "result-passed.json.gz")
    }

    @Test func `interface fixture owns paths traversal annotations and activation defaults`() throws {
        let button = makeTestHeistElement(
            label: "Save",
            traits: [.button],
            frameX: 10,
            frameY: 20,
            frameWidth: 80,
            frameHeight: 40
        )
        let interface = makeTestInterface(nodes: [
            .container(
                makeTestSemanticContainer(label: "Actions", identifier: "actions"),
                containerName: "actions_group",
                children: [.element(button)]
            ),
        ])

        #expect(interface.annotations.elements == [
            InterfaceElementAnnotation(
                path: TreePath([0, 0]),
                actions: [.activate],
                geometry: button.geometry
            ),
        ])
        #expect(interface.annotations.containers == [
            InterfaceContainerAnnotation(path: TreePath([0]), containerName: "actions_group"),
        ])
        guard case .container(_, let children) = try #require(interface.tree.first),
              case .element(let element, let traversalIndex) = try #require(children.first) else {
            Issue.record("Expected nested test element")
            return
        }
        #expect(traversalIndex == 0)
        #expect(element.usesDefaultActivationPoint)
        #expect(element.activationPoint == AccessibilityPoint(x: 50, y: 40))
        #expect(interface.projectedElements.first?.semantics.assertable.orderedActions == [.activate])
    }

    @Test func `interface fixture preserves explicit activation and normalizes unavailable evidence`() {
        let explicit = makeTestAccessibilityElement(makeTestHeistElement(
            activationPointEvidence: .explicit(ScreenPoint(x: 7, y: 9))
        ))
        let unavailable = makeTestAccessibilityElement(makeTestHeistElement(
            activationPointEvidence: .unavailable
        ))

        #expect(!explicit.usesDefaultActivationPoint)
        #expect(explicit.activationPoint == AccessibilityPoint(x: 7, y: 9))
        #expect(unavailable.usesDefaultActivationPoint)
        #expect(unavailable.activationPoint == AccessibilityPoint(x: 50, y: 22))
    }

    @Test func `result fixture constructs terminal and child aborted nodes`() throws {
        let passed = HeistResultFixture.action(
            command: .dismiss,
            result: .success(payload: .dismiss)
        )
        let failed = HeistResultFixture.action(
            command: .dismiss,
            result: .failure(
                payload: .dismiss,
                failureKind: .actionFailed,
                message: "blocked",
            )
        )
        let warning = HeistResultFixture.warning(message: "Heads up")
        let wait = HeistResultFixture.wait()
        let selection = HeistCaseSelectionResult.selectingFirstMatch(
            cases: [
                HeistCaseMatchResult(
                    predicate: AccessibilityPredicate.exists(.label("Ready")),
                    met: true
                ),
            ],
            ifNone: .noMatch,
            elapsedMs: 1
        )
        let conditional = HeistResultFixture.conditional(
            selection: selection,
            children: [failed]
        )
        let iteration = HeistResultFixture.forEachStringIteration(
            ordinal: 0,
            value: "Milk",
            status: .failed,
            failureReason: "child failed",
            children: [failed]
        )

        #expect(passed.status == .passed)
        #expect(failed.status == .failed)
        #expect(warning.warningEvidence?.message == "Heads up")
        #expect(try wait.replayExpectation()?.met == true)
        #expect(conditional.abortedAtChildPath == failed.path)
        #expect(iteration.abortedAtChildPath == failed.path)
        #expect(HeistResultFixture.result(steps: [failed]).outcome == .failed(abortedAtPath: failed.path))
    }

    @Test func `eventually uses a bounded ContinuousClock poll`() async {
        let probe = EventuallyProbe()

        #expect(await eventually(within: .seconds(1)) {
            await probe.reachesTwo()
        })
        #expect(await eventually(within: .zero) { false } == false)
    }
}

private actor EventuallyProbe {
    private var count = 0

    func reachesTwo() -> Bool {
        count += 1
        return count == 2
    }
}
