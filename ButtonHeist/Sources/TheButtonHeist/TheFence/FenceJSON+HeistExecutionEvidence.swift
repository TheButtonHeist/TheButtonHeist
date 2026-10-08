import ThePlans
import TheScore

extension HeistReport.Evidence {
    private enum CodingKeys: String, CodingKey {
        case action, wait, caseSelection, forEachString, forEachElement, repeatUntil, invocation, warning
    }

    func encode(to encoder: Encoder, profile: ProjectionProfile) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .action(let command, let evidence, _):
            try encode(
                command,
                evidence: evidence,
                expectation: expectationResult,
                to: container.superEncoder(forKey: .action),
                profile: profile
            )
        case .wait(let evidence, _, let outcome):
            try encode(
                evidence: evidence,
                expectation: expectationResult,
                outcome: outcome,
                to: container.superEncoder(forKey: .wait),
                profile: profile
            )
        case .caseSelection(let evidence):
            try encode(evidence, to: container.superEncoder(forKey: .caseSelection), profile: profile)
        case .forEachString(let declaration, let evidence):
            try encode(declaration, evidence: evidence, to: container.superEncoder(forKey: .forEachString))
        case .forEachElement(let declaration, let evidence):
            try encode(declaration, evidence: evidence, to: container.superEncoder(forKey: .forEachElement))
        case .repeatUntil(let declaration, let evidence):
            try encode(
                declaration,
                evidence: evidence,
                to: container.superEncoder(forKey: .repeatUntil)
            )
        case .invocation(let invocation, let evidence):
            try encode(
                invocation,
                evidence: evidence,
                to: container.superEncoder(forKey: .invocation)
            )
        case .warning(let warning):
            try container.encode(warning, forKey: .warning)
        }
    }

    private enum ActionCodingKeys: String, CodingKey {
        case commandName, target, result, expectation, expectationTiming
    }

    private func encode(
        _ command: HeistActionCommand,
        evidence: HeistActionEvidence,
        expectation: ExpectationResult?,
        to encoder: Encoder,
        profile: ProjectionProfile
    ) throws {
        var container = encoder.container(keyedBy: ActionCodingKeys.self)
        try container.encode(command.wireType.rawValue, forKey: .commandName)
        try container.encodeIfPresent(command.reportTarget, forKey: .target)
        switch evidence {
        case .commandResolutionFailure:
            break
        case .completed(let result, _):
            try container.encode(
                ActionProjection(
                    method: command.wireType.rawValue,
                    result: result,
                    announcementOverride: expectation?.matchedAnnouncement,
                    profile: profile,
                    publicContext: .heistReportEvidence
                ),
                forKey: .result
            )
            try container.encodeIfPresent(
                expectation.map { ExpectationProjection(result: $0) },
                forKey: .expectation
            )
            try container.encodeIfPresent(
                evidence.expectationEvidence?.timing,
                forKey: .expectationTiming
            )
        }
    }

    private enum WaitCodingKeys: String, CodingKey {
        case outcome, expectation, timing, baselineSummary, finalSummary, delta
    }

    private func encode(
        evidence: HeistExpectationEvidence,
        expectation: ExpectationResult?,
        outcome: HeistPredicateEvidenceOutcome,
        to encoder: Encoder,
        profile: ProjectionProfile
    ) throws {
        var container = encoder.container(keyedBy: WaitCodingKeys.self)
        let observation = evidence.observation
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(
            expectation.map { ExpectationProjection(result: $0) },
            forKey: .expectation
        )
        try container.encode(evidence.timing, forKey: .timing)
        try container.encodeIfPresent(observation.baseline?.summary, forKey: .baselineSummary)
        try container.encodeIfPresent(observation.current?.summary, forKey: .finalSummary)
        if let delta = DeltaProjection(
            evidence: observation,
            profile: profile,
            includeScreenInterface: true
        ) {
            try container.encode(
                PublicDelta(projection: delta, screenPolicy: .screenSummary),
                forKey: .delta
            )
        }
    }

    private enum CaseSelectionCodingKeys: String, CodingKey {
        case outcome, elapsedMs, timeout, lastObservedSummary, caseCount, cases, omittedCaseCount
    }

    private func encode(
        _ evidence: HeistCaseSelectionEvidence,
        to encoder: Encoder,
        profile: ProjectionProfile
    ) throws {
        let selection = evidence.selection
        let visibleCases = Array(selection.cases.prefix(profile.limits.caseResults))
        let omittedCount = selection.cases.count - visibleCases.count

        var container = encoder.container(keyedBy: CaseSelectionCodingKeys.self)
        try container.encode(selection.outcome, forKey: .outcome)
        try container.encode(selection.elapsedMs, forKey: .elapsedMs)
        try container.encodeIfPresent(selection.timeout, forKey: .timeout)
        try container.encodeIfPresent(selection.lastObservedSummary, forKey: .lastObservedSummary)
        try container.encode(selection.cases.count, forKey: .caseCount)
        try container.encodeIfPresent(visibleCases.isEmpty ? nil : visibleCases, forKey: .cases)
        try container.encodeIfPresent(omittedCount > 0 ? omittedCount : nil, forKey: .omittedCaseCount)
    }

    private enum RepeatUntilCodingKeys: String, CodingKey {
        case outcome, predicate, timeout, iterationCount, iterationOrdinal
        case lastObservedSummary, failureReason
    }

    private func encode(
        _ declaration: HeistRepeatUntilDeclaration,
        evidence: HeistRepeatUntilEvidence,
        to encoder: Encoder
    ) throws {
        var container = encoder.container(keyedBy: RepeatUntilCodingKeys.self)
        try container.encode(evidence.outcome, forKey: .outcome)
        try container.encode(declaration.predicate, forKey: .predicate)
        try container.encode(declaration.timeout.seconds, forKey: .timeout)
        try container.encode(evidence.iterationCount, forKey: .iterationCount)
        try container.encodeIfPresent(evidence.iterationOrdinal, forKey: .iterationOrdinal)
        try container.encodeIfPresent(evidence.lastObservedSummary, forKey: .lastObservedSummary)
        try container.encodeIfPresent(evidence.failureReason, forKey: .failureReason)
    }

    private enum ForEachStringCodingKeys: String, CodingKey {
        case parameter, count, iterationCount, iterationOrdinal, value, failureReason
    }

    private func encode(
        _ declaration: HeistForEachStringDeclaration,
        evidence: HeistForEachStringEvidence,
        to encoder: Encoder
    ) throws {
        var container = encoder.container(keyedBy: ForEachStringCodingKeys.self)
        try container.encode(declaration.parameter, forKey: .parameter)
        try container.encode(declaration.count, forKey: .count)
        try container.encode(evidence.iterationCount, forKey: .iterationCount)
        try container.encodeIfPresent(evidence.iterationOrdinal, forKey: .iterationOrdinal)
        try container.encodeIfPresent(evidence.value, forKey: .value)
        try container.encodeIfPresent(evidence.failureReason, forKey: .failureReason)
    }

    private enum ForEachElementCodingKeys: String, CodingKey {
        case parameter, matching, limit, matchedCount, iterationCount, iterationOrdinal
        case targetOrdinal, targetSummary, failureReason
    }

    private func encode(
        _ declaration: HeistForEachElementDeclaration,
        evidence: HeistForEachElementEvidence,
        to encoder: Encoder
    ) throws {
        var container = encoder.container(keyedBy: ForEachElementCodingKeys.self)
        try container.encode(declaration.parameter, forKey: .parameter)
        try container.encode(declaration.matching, forKey: .matching)
        try container.encode(declaration.limit, forKey: .limit)
        try container.encode(evidence.matchedCount, forKey: .matchedCount)
        try container.encode(evidence.iterationCount, forKey: .iterationCount)
        try container.encodeIfPresent(evidence.iterationOrdinal, forKey: .iterationOrdinal)
        try container.encodeIfPresent(evidence.targetOrdinal, forKey: .targetOrdinal)
        try container.encodeIfPresent(evidence.targetSummary, forKey: .targetSummary)
        try container.encodeIfPresent(evidence.failureReason, forKey: .failureReason)
    }

    private enum InvocationCodingKeys: String, CodingKey {
        case capability, argument, childFailedPath
    }

    private func encode(
        _ invocation: HeistInvocationStep,
        evidence: HeistInvocationEvidence,
        to encoder: Encoder
    ) throws {
        var container = encoder.container(keyedBy: InvocationCodingKeys.self)
        try container.encode(invocation.path.description, forKey: .capability)
        try container.encodeIfPresent(
            invocation.argument == .none ? nil : invocation.runHeistSummary,
            forKey: .argument
        )
        try container.encodeIfPresent(evidence.childFailedPath?.description, forKey: .childFailedPath)
    }
}
