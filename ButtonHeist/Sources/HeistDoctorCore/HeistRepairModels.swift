import ThePlans
import TheScore

// MARK: - Heist Repair Evidence

package enum HeistRepairEvidenceOutcome: Sendable, Equatable {
    case passed
    case failed(failureKind: ActionFailure.Kind?, message: String?)
}

package struct HeistRepairEvidence: Sendable, Equatable {
    package let heistFingerprint: String?
    package let stepPath: HeistExecutionPath
    package let command: HeistActionCommand
    package let target: AccessibilityTarget
    package let beforeSnapshot: Interface
    package let observedChanges: [RepairChangeFactObservation]
    package let semanticEvidence: [String]
    package let method: ActionMethod?
    package let expectation: ExpectationResult?
    package let outcome: HeistRepairEvidenceOutcome

    package init(
        heistFingerprint: String? = nil,
        stepPath: HeistExecutionPath,
        command: HeistActionCommand,
        target: AccessibilityTarget,
        beforeSnapshot: Interface,
        observedChanges: [RepairChangeFactObservation] = [],
        semanticEvidence: [String] = [],
        method: ActionMethod? = nil,
        expectation: ExpectationResult? = nil,
        outcome: HeistRepairEvidenceOutcome
    ) {
        self.heistFingerprint = heistFingerprint
        self.stepPath = stepPath
        self.command = command
        self.target = target
        self.beforeSnapshot = beforeSnapshot
        self.observedChanges = observedChanges
        self.semanticEvidence = semanticEvidence
        self.method = method
        self.expectation = expectation
        self.outcome = outcome
    }
}

package struct HeistRepairRequest: Sendable, Equatable {
    package let lastSuccess: HeistRepairEvidence
    package let currentFailure: HeistRepairEvidence

    package init(
        lastSuccess: HeistRepairEvidence,
        currentFailure: HeistRepairEvidence
    ) throws {
        guard case .passed = lastSuccess.outcome else {
            throw ValidationError.lastSuccessDidNotPass
        }
        guard case .failed = currentFailure.outcome else {
            throw ValidationError.currentFailureDidNotFail
        }
        self.lastSuccess = lastSuccess
        self.currentFailure = currentFailure
    }

    private enum ValidationError: Error, CustomStringConvertible {
        case lastSuccessDidNotPass
        case currentFailureDidNotFail

        var description: String {
            switch self {
            case .lastSuccessDidNotPass:
                return "lastSuccess repair evidence must have a passed outcome"
            case .currentFailureDidNotFail:
                return "currentFailure repair evidence must have a failed outcome"
            }
        }
    }
}

// MARK: - Heist Repair Suggestion

package enum HeistRepairFailureKind: String, Codable, Sendable, Equatable {
    case missingTarget
    case ambiguousTarget
    case wrongCapability
}

package enum RepairConfidence: String, Codable, Sendable, Equatable {
    case high
    case medium
    case low
}

package enum HeistRepairPipelineStage: String, Codable, Sendable, Equatable {
    case evidenceEligibility
    case candidateRanking
    case candidateValidation
}

package enum HeistRepairRefusalReason: String, Codable, Sendable, Equatable {
    case differentStepPaths
    case incompatibleHeistFingerprints
    case oldTargetDidNotResolveExactlyOnce
    case containerTargetUnsupported
    case targetReferenceUnsupported
    case unresolvedTargetExpression
    case oldTargetStillResolvesAndSupportsRequestedAction
    case noCandidateMetScoreThreshold
    case noCandidateValidated
}

package struct HeistRepairRefusal: Codable, Sendable, Equatable {
    package let stage: HeistRepairPipelineStage
    package let reason: HeistRepairRefusalReason
    package let message: String

    package init(
        stage: HeistRepairPipelineStage,
        reason: HeistRepairRefusalReason,
        message: String
    ) {
        self.stage = stage
        self.reason = reason
        self.message = message
    }
}

package enum RepairCandidateSource: String, Codable, Sendable, Hashable {
    case semanticContinuityScan
    case currentAmbiguousMatch
}

package enum RepairCandidateRejectionReason: String, Codable, Sendable, Equatable {
    case noUniqueDurableMatcher
    case unsupportedActionFamily
}

package struct HeistRepairElementEvidence: Codable, Sendable, Equatable {
    package let element: HeistElement
    package let siblingText: [String]
    package let headerText: [String]

    package init(
        element: HeistElement,
        siblingText: [String] = [],
        headerText: [String] = []
    ) {
        self.element = element
        self.siblingText = siblingText
        self.headerText = headerText
    }
}

package enum RepairCandidateValidation: Codable, Sendable, Equatable {
    case notEvaluated
    case suggested(target: AccessibilityTarget, confidence: RepairConfidence)
    case rejected(reason: RepairCandidateRejectionReason)
}

package struct HeistRepairCandidateDiagnosis: Codable, Sendable, Equatable {
    package let source: RepairCandidateSource
    package let resolvedElement: HeistRepairElementEvidence
    package let score: Int
    package let reasons: [RepairScoringReason]
    package let caveats: [RepairCaveat]
    package let validation: RepairCandidateValidation

    package init(
        source: RepairCandidateSource,
        resolvedElement: HeistRepairElementEvidence,
        score: Int,
        reasons: [RepairScoringReason],
        caveats: [RepairCaveat] = [],
        validation: RepairCandidateValidation
    ) {
        self.source = source
        self.resolvedElement = resolvedElement
        self.score = score
        self.reasons = reasons.uniqued(on: \.self)
        self.caveats = caveats.uniqued(on: \.self)
        self.validation = validation
    }
}

package enum HeistRepairDiagnosis: Codable, Sendable, Equatable {
    case suggested(HeistRepairSuggestedDiagnosis)
    case refused(HeistRepairRefusedDiagnosis)

    package var suggestions: [HeistRepairSuggestion] {
        switch self {
        case .suggested(let diagnosis):
            return diagnosis.suggestions
        case .refused:
            return []
        }
    }

    package var noSuggestionReason: String? {
        switch self {
        case .suggested:
            return nil
        case .refused(let diagnosis):
            return diagnosis.refusal.message
        }
    }
}

package struct HeistRepairSuggestedDiagnosis: Codable, Sendable, Equatable {
    package let stepPath: HeistExecutionPath
    package let failureKind: HeistRepairFailureKind
    package let oldTarget: AccessibilityTarget
    package let oldResolvedElement: HeistRepairElementEvidence
    package let currentMatchCount: Int
    package let candidates: [HeistRepairCandidateDiagnosis]
    package let suggestions: [HeistRepairSuggestion]

    package init(
        stepPath: HeistExecutionPath,
        failureKind: HeistRepairFailureKind,
        oldTarget: AccessibilityTarget,
        oldResolvedElement: HeistRepairElementEvidence,
        currentMatchCount: Int,
        candidates: [HeistRepairCandidateDiagnosis],
        suggestions: [HeistRepairSuggestion]
    ) {
        self.stepPath = stepPath
        self.failureKind = failureKind
        self.oldTarget = oldTarget
        self.oldResolvedElement = oldResolvedElement
        self.currentMatchCount = currentMatchCount
        self.candidates = candidates
        self.suggestions = suggestions
    }
}

package enum HeistRepairRefusalEvidence: Codable, Sendable, Equatable {
    case evidenceEligibility
    case eligible(HeistRepairEligibleRefusalEvidence)
}

package struct HeistRepairEligibleRefusalEvidence: Codable, Sendable, Equatable {
    package let failureKind: HeistRepairFailureKind
    package let oldResolvedElement: HeistRepairElementEvidence
    package let currentMatchCount: Int
    package let candidates: [HeistRepairCandidateDiagnosis]

    package init(
        failureKind: HeistRepairFailureKind,
        oldResolvedElement: HeistRepairElementEvidence,
        currentMatchCount: Int,
        candidates: [HeistRepairCandidateDiagnosis]
    ) {
        self.failureKind = failureKind
        self.oldResolvedElement = oldResolvedElement
        self.currentMatchCount = currentMatchCount
        self.candidates = candidates
    }
}

package struct HeistRepairRefusedDiagnosis: Codable, Sendable, Equatable {
    package let stepPath: HeistExecutionPath
    package let oldTarget: AccessibilityTarget
    package let evidence: HeistRepairRefusalEvidence
    package let refusal: HeistRepairRefusal

    package init(
        stepPath: HeistExecutionPath,
        oldTarget: AccessibilityTarget,
        evidence: HeistRepairRefusalEvidence,
        refusal: HeistRepairRefusal
    ) {
        self.stepPath = stepPath
        self.oldTarget = oldTarget
        self.evidence = evidence
        self.refusal = refusal
    }
}

package struct HeistRepairSuggestion: Codable, Sendable, Equatable {
    package let stepPath: HeistExecutionPath
    package let failureKind: HeistRepairFailureKind
    package let oldTarget: AccessibilityTarget
    package let oldResolvedElement: HeistRepairElementEvidence
    package let newTarget: AccessibilityTarget
    package let newResolvedElement: HeistRepairElementEvidence
    package let confidence: RepairConfidence
    package let reasons: [RepairSuggestionReason]
    package let caveats: [RepairCaveat]

    package init(
        stepPath: HeistExecutionPath,
        failureKind: HeistRepairFailureKind,
        oldTarget: AccessibilityTarget,
        oldResolvedElement: HeistRepairElementEvidence,
        newTarget: AccessibilityTarget,
        newResolvedElement: HeistRepairElementEvidence,
        confidence: RepairConfidence,
        reasons: [RepairSuggestionReason],
        caveats: [RepairCaveat] = []
    ) {
        self.stepPath = stepPath
        self.failureKind = failureKind
        self.oldTarget = oldTarget
        self.oldResolvedElement = oldResolvedElement
        self.newTarget = newTarget
        self.newResolvedElement = newResolvedElement
        self.confidence = confidence
        self.reasons = reasons.uniqued(on: \.self)
        self.caveats = caveats.uniqued(on: \.self)
    }

}
