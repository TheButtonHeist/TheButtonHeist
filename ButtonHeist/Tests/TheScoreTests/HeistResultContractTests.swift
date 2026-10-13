import ButtonHeistTestSupport
import Foundation
import Testing
import ThePlans
import TheScore

@Suite struct HeistResultContractTests {
    @Test func `semantic nodes round trip through their single codec owner`() throws {
        let steps = try [
            HeistResultFixture.action(),
            HeistResultFixture.warning(path: "$.body[1]", message: "notice"),
            HeistResultFixture.explicitFailure(path: "$.body[2]", message: "stop"),
        ] + relationshipSteps()

        #expect(steps[1].kind == .warn)
        #expect(steps[2].kind == .fail)
        for step in steps {
            let data = try JSONEncoder().encode(step)
            #expect(try JSONDecoder().decode(HeistExecutionStepResult.self, from: data) == step)
        }
    }

    @Test func `step encoding owns semantics and completion in one node`() throws {
        let object = try jsonObject(HeistResultFixture.warning(message: "notice"))

        #expect(Set(object.keys) == ["path", "node"])
        let node = try #require(object["node"] as? [String: Any])
        #expect(node["type"] as? String == "warning")
        #expect(node["outcome"] as? String == "passed")
        #expect(node["message"] as? String == "notice")
        #expect(node["children"] is [Any])
    }

    @Test func `decode rejects unknown missing and incompatible node fields`() {
        let malformed = [
            #"{"path":"$.body[0]","node":{"type":"warning","outcome":"passed","message":"notice","children":[],"extra":true}}"#,
            #"{"path":"$.body[0]","node":{"type":"warning","outcome":"passed","children":[]}}"#,
            #"{"path":"$.body[0]","node":{"type":"warning","outcome":"failed","message":"notice","failure":{"category":"explicitFailure","#
                + #"contract":"x","observed":"y"},"children":[]}}"#,
            #"{"path":"$.body[0]","node":{"type":"unknown","outcome":"passed","children":[]}}"#,
        ]

        for result in malformed {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(HeistExecutionStepResult.self, from: Data(result.utf8))
            }
        }
    }

    @Test func `decode rejects negative result duration`() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                HeistResult.self,
                from: Data(#"{"steps":[],"durationMs":-1}"#.utf8)
            )
        }
    }

    @Test func `decode rejects malformed external result relationships`() throws {
        let steps = try relationshipSteps()
        let malformed = try [
            replacingNode(in: steps[0]) { node in
                node["command"] = try jsonValue(HeistActionCommand.magicTap)
            },
            replacingNode(in: steps[1]) { node in
                node["count"] = 1
            },
            replacingNode(in: steps[2]) { node in
                node["type"] = "for_each_string"
            },
            replacingNode(in: steps[4]) { node in
                node["type"] = "for_each_element"
            },
            replacingNode(in: steps[6]) { node in
                node["type"] = "repeat_until"
            },
        ]

        for object in malformed {
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(HeistExecutionStepResult.self, from: data)
            }
        }
    }

    @Test func `for each evidence admits only source matching iterations`() {
        #expect(HeistForEachEvidence(
            source: .strings,
            iterationCount: 1,
            iteration: .element(ordinal: 0, targetOrdinal: 0, targetSummary: "Row")
        ) == nil)
        #expect(HeistForEachEvidence(
            source: .elements(matchedCount: 1),
            iterationCount: 1,
            iteration: .string(ordinal: 0, value: "Row")
        ) == nil)
    }

    @Test func `execution result derives terminal outcome without duplicating steps`() throws {
        let result = HeistResultFixture.result(
            steps: [HeistResultFixture.explicitFailure(message: "stop")],
            durationMs: 3
        )
        let passed = HeistResultFixture.result(steps: [])
        let object = try jsonObject(result)

        #expect(result.isFailure)
        #expect(result.outcome == .failed(abortedAtPath: "$.body[0]"))
        #expect(passed.outcome == .passed)
        #expect(Set(object.keys) == ["steps", "durationMs"])
        #expect(try JSONDecoder().decode(
            HeistResult.self,
            from: JSONSerialization.data(withJSONObject: object)
        ) == result)
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func relationshipSteps() throws -> [HeistExecutionStepResult] {
        let stringDeclaration = try #require(HeistForEachStringDeclaration(parameter: "item", count: 2))
        let stringSummary = try #require(HeistForEachEvidence(source: .strings, iterationCount: 2))
        let elementDeclaration = try #require(HeistForEachElementDeclaration(
            parameter: "item",
            matching: ElementPredicate(label: "Row"),
            limit: 2
        ))
        let elementSummary = try #require(HeistForEachEvidence(
            source: .elements(matchedCount: 1),
            iterationCount: 1
        ))
        let elementIteration = try #require(HeistForEachEvidence(
            source: .elements(matchedCount: 1),
            iterationCount: 1,
            iteration: .element(ordinal: 0, targetOrdinal: 0, targetSummary: "Row")
        ))
        let predicate = AccessibilityPredicate.exists(.label("Done"))
        let repeatDeclaration = HeistRepeatUntilDeclaration(predicate: predicate, timeout: 1)
        let repeatSummary = try #require(HeistRepeatUntilEvidence.matched(
            iterationCount: 1
        ))
        let repeatIteration = try #require(HeistRepeatUntilEvidence.continued(
            iterationCount: 1,
            iterationOrdinal: 0
        ))
        let passedStringSummary = try #require(HeistPassedForEachEvidence(stringSummary))
        let passedElementSummary = try #require(HeistPassedForEachEvidence(elementSummary))
        let passedElementIteration = try #require(HeistPassedForEachEvidence(elementIteration))
        let passedRepeatSummary = try #require(HeistPassedRepeatUntilEvidence(repeatSummary))
        let passedRepeatIteration = try #require(HeistPassedRepeatUntilIterationEvidence(repeatIteration))

        return [
            HeistResultFixture.action(command: .dismiss, result: .success(payload: .dismiss)),
            HeistExecutionStepResult.forEach(
                path: "$.body[1]",
                declaration: .strings(stringDeclaration),
                completion: .passed(evidence: passedStringSummary)
            ),
            HeistResultFixture.forEachStringIteration(
                path: "$.body[2].for_each_string.iterations[0]",
                count: 2,
                iterationCount: 1,
                ordinal: 0,
                value: "one",
                status: .passed,
                children: []
            ),
            HeistExecutionStepResult.forEach(
                path: "$.body[3]",
                declaration: .elements(elementDeclaration),
                completion: .passed(evidence: passedElementSummary)
            ),
            HeistExecutionStepResult.forEachIteration(
                path: "$.body[4].for_each_element.iterations[0]",
                declaration: .elements(elementDeclaration),
                completion: .passed(evidence: passedElementIteration)
            ),
            HeistExecutionStepResult.repeatUntil(
                path: "$.body[5]",
                declaration: repeatDeclaration,
                completion: .passed(evidence: passedRepeatSummary)
            ),
            HeistExecutionStepResult.repeatUntilIteration(
                path: "$.body[6].repeat_until.iterations[0]",
                declaration: repeatDeclaration,
                completion: .passed(evidence: passedRepeatIteration)
            ),
        ]
    }

    private func replacingNode(
        in step: HeistExecutionStepResult,
        update: (inout [String: Any]) throws -> Void
    ) throws -> [String: Any] {
        var object = try jsonObject(step)
        var node = try #require(object["node"] as? [String: Any])
        try update(&node)
        object["node"] = node
        return object
    }

    private func jsonValue<Value: Encodable>(_ value: Value) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}
