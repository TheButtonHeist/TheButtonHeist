import Foundation
import ThePlans

public enum HeistPredicateEvidenceOutcome: String, Codable, Sendable, Equatable {
    case matched
    case continued
    case handledElse = "handled_else"
    case failed
}

public struct HeistForEachEvidence: Codable, Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case strings
        case elements(matchedCount: Int)
    }

    public enum Iteration: Sendable, Equatable {
        case string(ordinal: Int, value: String)
        case element(ordinal: Int, targetOrdinal: Int, targetSummary: String)

        public var ordinal: Int {
            switch self {
            case .string(let ordinal, _), .element(let ordinal, _, _): ordinal
            }
        }
    }

    public let source: Source
    public let iterationCount: Int
    public let iteration: Iteration?
    public let failureReason: String?

    public var iterationOrdinal: Int? {
        iteration?.ordinal
    }

    public var matchedCount: Int? {
        guard case .elements(let matchedCount) = source else { return nil }
        return matchedCount
    }

    public var value: String? {
        guard case .string(_, let value) = iteration else { return nil }
        return value
    }

    public var targetOrdinal: Int? {
        guard case .element(_, let targetOrdinal, _) = iteration else { return nil }
        return targetOrdinal
    }

    public var targetSummary: String? {
        guard case .element(_, _, let targetSummary) = iteration else { return nil }
        return targetSummary
    }

    public init?(
        source: Source,
        iterationCount: Int,
        iteration: Iteration? = nil,
        failureReason: String? = nil
    ) {
        guard Self.isValid(source: source, iterationCount: iterationCount, iteration: iteration) else {
            return nil
        }
        self.init(
            admittedSource: source,
            iterationCount: iterationCount,
            iteration: iteration,
            failureReason: failureReason
        )
    }

    package static func executed(
        source: Source,
        iterationCount: Int,
        iteration: Iteration? = nil,
        failureReason: String? = nil
    ) -> Self {
        Self(
            admittedSource: source,
            iterationCount: iterationCount,
            iteration: iteration,
            failureReason: failureReason
        )
    }

    private init(
        admittedSource source: Source,
        iterationCount: Int,
        iteration: Iteration?,
        failureReason: String?
    ) {
        precondition(Self.isValid(source: source, iterationCount: iterationCount, iteration: iteration))
        self.source = source
        self.iterationCount = iterationCount
        self.iteration = iteration
        self.failureReason = failureReason
    }

    private static func isValid(source: Source, iterationCount: Int, iteration: Iteration?) -> Bool {
        guard iterationCount >= 0 else { return false }
        switch (source, iteration) {
        case (.strings, nil):
            return true
        case (.strings, .string(let ordinal, _)):
            return ordinal >= 0 && ordinal < iterationCount
        case (.elements(let matchedCount), nil):
            return matchedCount >= 0 && iterationCount <= matchedCount
        case (.elements(let matchedCount), .element(let ordinal, let targetOrdinal, _)):
            return matchedCount >= 0
                && iterationCount <= matchedCount
                && ordinal >= 0
                && ordinal < iterationCount
                && targetOrdinal >= 0
                && targetOrdinal < matchedCount
        case (.strings, .element), (.elements, .string):
            return false
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case matchedCount
        case iterationCount
        case iterationOrdinal
        case value
        case targetOrdinal
        case targetSummary
        case failureReason
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "HeistForEachEvidence")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let matchedCount = try container.decodeIfPresent(Int.self, forKey: .matchedCount)
        let iterationOrdinal = try container.decodeIfPresent(Int.self, forKey: .iterationOrdinal)
        let value = try container.decodeIfPresent(String.self, forKey: .value)
        let targetOrdinal = try container.decodeIfPresent(Int.self, forKey: .targetOrdinal)
        let targetSummary = try container.decodeIfPresent(String.self, forKey: .targetSummary)
        let failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        let iterationCount = try container.decode(Int.self, forKey: .iterationCount)
        let source: Source
        let iteration: Iteration?
        switch (matchedCount, iterationOrdinal, value, targetOrdinal, targetSummary) {
        case (nil, nil, nil, nil, nil):
            source = .strings
            iteration = nil
        case (nil, .some(let ordinal), .some(let value), nil, nil):
            source = .strings
            iteration = .string(ordinal: ordinal, value: value)
        case (.some(let matchedCount), nil, nil, nil, nil):
            source = .elements(matchedCount: matchedCount)
            iteration = nil
        case (
            .some(let matchedCount),
            .some(let ordinal),
            nil,
            .some(let targetOrdinal),
            .some(let targetSummary)
        ):
            source = .elements(matchedCount: matchedCount)
            iteration = .element(
                ordinal: ordinal,
                targetOrdinal: targetOrdinal,
                targetSummary: targetSummary
            )
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "for_each evidence fields do not form one string or element iteration"
            ))
        }
        guard let admitted = Self(
            source: source,
            iterationCount: iterationCount,
            iteration: iteration,
            failureReason: failureReason
        ) else {
            let invalid: (CodingKeys, String)
            if iterationCount < 0 {
                invalid = (.iterationCount, "for_each iterationCount must be nonnegative")
            } else if let matchedCount, matchedCount < 0 {
                invalid = (.matchedCount, "for_each matchedCount must be nonnegative")
            } else if let matchedCount, iterationCount > matchedCount {
                invalid = (.iterationCount, "for_each element iterationCount must not exceed matchedCount")
            } else if let iterationOrdinal, iterationOrdinal < 0 {
                invalid = (.iterationOrdinal, "for_each iterationOrdinal must be nonnegative")
            } else if let iterationOrdinal, iterationOrdinal >= iterationCount {
                invalid = (.iterationOrdinal, "for_each iterationOrdinal must be less than iterationCount")
            } else if let targetOrdinal, targetOrdinal < 0 {
                invalid = (.targetOrdinal, "for_each element targetOrdinal must be nonnegative")
            } else {
                invalid = (.targetOrdinal, "for_each element targetOrdinal must be less than matchedCount")
            }
            throw DecodingError.dataCorruptedError(
                forKey: invalid.0,
                in: container,
                debugDescription: invalid.1
            )
        }
        self = admitted
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(matchedCount, forKey: .matchedCount)
        try container.encode(iterationCount, forKey: .iterationCount)
        try container.encodeIfPresent(iterationOrdinal, forKey: .iterationOrdinal)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(targetOrdinal, forKey: .targetOrdinal)
        try container.encodeIfPresent(targetSummary, forKey: .targetSummary)
        try container.encodeIfPresent(failureReason, forKey: .failureReason)
    }
}

public struct HeistRepeatUntilEvidence: Codable, Sendable, Equatable {
    public let iterationCount: Int
    public let iterationOrdinal: Int?
    public let lastObservedSummary: String?
    public let outcome: HeistPredicateEvidenceOutcome
    public let failureReason: String?

    private init?(
        iterationCount: Int = 0,
        iterationOrdinal: Int?,
        lastObservedSummary: String?,
        outcome: HeistPredicateEvidenceOutcome,
        failureReason: String?
    ) {
        guard iterationCount >= 0 else { return nil }
        guard iterationOrdinal.map({ $0 >= 0 && $0 < iterationCount }) ?? true else { return nil }
        guard Self.fieldsMatch(
            outcome: outcome,
            iterationOrdinal: iterationOrdinal,
            failureReason: failureReason
        ) else { return nil }
        self.iterationCount = iterationCount
        self.iterationOrdinal = iterationOrdinal
        self.lastObservedSummary = lastObservedSummary
        self.outcome = outcome
        self.failureReason = failureReason
    }

    private init(
        executedIterationCount iterationCount: Int,
        iterationOrdinal: Int?,
        lastObservedSummary: String?,
        outcome: HeistPredicateEvidenceOutcome,
        failureReason: String?
    ) {
        self = requireValidLiteralPayload {
            guard let evidence = Self(
                iterationCount: iterationCount,
                iterationOrdinal: iterationOrdinal,
                lastObservedSummary: lastObservedSummary,
                outcome: outcome,
                failureReason: failureReason
            ) else {
                throw ReportAdmissionError(description: "invalid executed repeat_until evidence")
            }
            return evidence
        }
    }

    package static func executedMatched(
        iterationCount: Int,
        iterationOrdinal: Int? = nil,
        lastObservedSummary: String? = nil
    ) -> HeistRepeatUntilEvidence {
        HeistRepeatUntilEvidence(
            executedIterationCount: iterationCount,
            iterationOrdinal: iterationOrdinal,
            lastObservedSummary: lastObservedSummary,
            outcome: .matched,
            failureReason: nil
        )
    }

    package static func executedContinued(
        iterationCount: Int,
        iterationOrdinal: Int,
        lastObservedSummary: String? = nil
    ) -> HeistRepeatUntilEvidence {
        HeistRepeatUntilEvidence(
            executedIterationCount: iterationCount,
            iterationOrdinal: iterationOrdinal,
            lastObservedSummary: lastObservedSummary,
            outcome: .continued,
            failureReason: nil
        )
    }

    package static func executedFailed(
        iterationCount: Int,
        iterationOrdinal: Int? = nil,
        lastObservedSummary: String?,
        failureReason: String
    ) -> HeistRepeatUntilEvidence {
        HeistRepeatUntilEvidence(
            executedIterationCount: iterationCount,
            iterationOrdinal: iterationOrdinal,
            lastObservedSummary: lastObservedSummary,
            outcome: .failed,
            failureReason: failureReason
        )
    }

    public static func matched(
        iterationCount: Int,
        iterationOrdinal: Int? = nil,
        lastObservedSummary: String? = nil
    ) -> HeistRepeatUntilEvidence? {
        HeistRepeatUntilEvidence(
            iterationCount: iterationCount,
            iterationOrdinal: iterationOrdinal,
            lastObservedSummary: lastObservedSummary,
            outcome: .matched,
            failureReason: nil
        )
    }

    public static func continued(
        iterationCount: Int,
        iterationOrdinal: Int,
        lastObservedSummary: String? = nil
    ) -> HeistRepeatUntilEvidence? {
        HeistRepeatUntilEvidence(
            iterationCount: iterationCount,
            iterationOrdinal: iterationOrdinal,
            lastObservedSummary: lastObservedSummary,
            outcome: .continued,
            failureReason: nil
        )
    }

    public static func failed(
        iterationCount: Int,
        iterationOrdinal: Int? = nil,
        lastObservedSummary: String?,
        failureReason: String
    ) -> HeistRepeatUntilEvidence? {
        HeistRepeatUntilEvidence(
            iterationCount: iterationCount,
            iterationOrdinal: iterationOrdinal,
            lastObservedSummary: lastObservedSummary,
            outcome: .failed,
            failureReason: failureReason
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case outcome
        case iterationCount
        case iterationOrdinal
        case lastObservedSummary
        case failureReason
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: CodingKeys.self, typeName: "repeat_until evidence")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(HeistPredicateEvidenceOutcome.self, forKey: .outcome)
        let iterationCount = try container.decode(Int.self, forKey: .iterationCount)
        let iterationOrdinal = try container.decodeIfPresent(Int.self, forKey: .iterationOrdinal)
        let lastObservedSummary = try container.decodeIfPresent(String.self, forKey: .lastObservedSummary)
        let failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        guard let admitted = Self(
            iterationCount: iterationCount,
            iterationOrdinal: iterationOrdinal,
            lastObservedSummary: lastObservedSummary,
            outcome: outcome,
            failureReason: failureReason
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "repeat_until outcome does not match its iteration and failure fields"
            ))
        }
        self = admitted
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(iterationCount, forKey: .iterationCount)
        try container.encodeIfPresent(iterationOrdinal, forKey: .iterationOrdinal)
        try container.encodeIfPresent(lastObservedSummary, forKey: .lastObservedSummary)
        try container.encodeIfPresent(failureReason, forKey: .failureReason)
    }

    private static func fieldsMatch(
        outcome: HeistPredicateEvidenceOutcome,
        iterationOrdinal: Int?,
        failureReason: String?
    ) -> Bool {
        switch outcome {
        case .matched:
            failureReason == nil
        case .continued:
            iterationOrdinal != nil && failureReason == nil
        case .failed:
            failureReason != nil
        case .handledElse:
            false
        }
    }
}
