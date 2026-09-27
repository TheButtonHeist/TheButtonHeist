#if canImport(UIKit)
#if DEBUG
import UIKit

import ThePlans
import TheScore

import AccessibilitySnapshotParser

// MARK: - AccessibilityPolicy UIKit Derivations

/// Parser-bitmask projections of `AccessibilityPolicy` policy sets.
///
/// Each `*Bitmask` value is derived from the corresponding `Set<HeistTrait>`
/// via ButtonHeist's trait-name projection so the two forms cannot drift.
/// Consumers that work with parser traits read these directly instead of
/// building their own.
extension AccessibilityPolicy {

    struct HeistTraitMaskProjection: Sendable, Equatable {
        let trait: HeistTrait
        let mask: AccessibilityTraits
    }

    /// Bitmask form of `interactiveTraits`. Consumed by
    /// `TheVault.Interactivity.hasInteractiveTraits`.
    static let interactiveTraitsBitmask: AccessibilityTraits =
        AccessibilityTraits.fromNames(interactiveTraits.map(\.rawValue))

    /// Synthesis priority resolved to trait/mask projections in priority
    /// order. Consumed by `HeistIdAssignment.synthesizeBaseId` to find
    /// the first matching trait an element carries.
    static let synthesisPriorityMaskProjections: [HeistTraitMaskProjection] =
        synthesisPriority.map { trait in
            HeistTraitMaskProjection(
                trait: trait,
                mask: AccessibilityTraits.fromNames([trait.rawValue])
            )
        }
}

#endif // DEBUG
#endif // canImport(UIKit)
