import BumperBowlingCore
import BumperBowlingTestSupport
import BumperRules
import SwiftLintFramework

func evaluateButtonHeistRules(path: String, source: String) throws -> [StyleViolation] {
    try RuleTestHarness(buttonHeistProject.rules).evaluate([.swift(path, source: source)])
}
