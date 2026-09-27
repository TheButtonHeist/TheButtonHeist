#if canImport(UIKit)
import XCTest
import ThePlans
@testable import AccessibilitySnapshotParser
@testable import TheInsideJob
@testable import TheScore

/// Tests for the parser-bitmask derivations of `AccessibilityPolicy`.
///
/// The `*Bitmask` and `*Names` values are computed from `Set<HeistTrait>`
/// policy at static-let initialization time. If the conversion ever drops
/// a trait (e.g. an unknown name silently swallowed by
/// `AccessibilityTraits.fromNames`), the consumer's behavior becomes
/// inconsistent with policy. These tests catch that.
final class AccessibilityPolicyBitmaskTests: XCTestCase {

    // MARK: - Bitmask round-trip

    func testInteractiveTraitsBitmaskRoundTrips() {
        let bitmask = AccessibilityPolicy.interactiveTraitsBitmask
        let recoveredNames = Set(bitmask.heistTraitNames)
        let expectedNames = Set(AccessibilityPolicy.interactiveTraits.map(\.rawValue))
        XCTAssertEqual(recoveredNames, expectedNames,
                       "interactiveTraitsBitmask must round-trip the trait names")
    }

    // MARK: - Synthesis priority projections

    func testSynthesisPriorityMaskProjectionsMatchOrdering() {
        let projectionNames = AccessibilityPolicy.synthesisPriorityMaskProjections.map { $0.trait.rawValue }
        let traitNames = AccessibilityPolicy.synthesisPriority.map(\.rawValue)
        XCTAssertEqual(projectionNames, traitNames,
                       "synthesisPriorityMaskProjections must preserve synthesisPriority ordering")
    }

    func testSynthesisPriorityMasksResolveToNonEmptyBits() {
        // Every trait in the priority list must be a name the parser
        // recognises — otherwise `fromNames` returns `.none` and the
        // synthesiser silently skips that trait.
        for projection in AccessibilityPolicy.synthesisPriorityMaskProjections {
            XCTAssertNotEqual(projection.mask, AccessibilityTraits(),
                              "Synthesis priority entry \(projection.trait.rawValue) resolves to no bits — parser does not know this trait")
        }
    }

    // MARK: - Known-trait gate

    func testAllTransientTraitNamesAreKnownToParser() {
        let known = AccessibilityTraits.knownTraitNames
        for trait in AccessibilityPolicy.stateTraits {
            XCTAssertTrue(known.contains(trait.rawValue),
                          "stateTrait \(trait.rawValue) is not in the parser's knownTraitNames")
        }
    }

    func testAllInteractiveTraitNamesAreKnownToParser() {
        let known = AccessibilityTraits.knownTraitNames
        for trait in AccessibilityPolicy.interactiveTraits {
            XCTAssertTrue(known.contains(trait.rawValue),
                          "interactiveTrait \(trait.rawValue) is not in the parser's knownTraitNames")
        }
    }
}

#endif // canImport(UIKit)
