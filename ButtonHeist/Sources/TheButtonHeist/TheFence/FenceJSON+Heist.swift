import Foundation
import ThePlans

import TheScore

struct PublicHeistCatalogResponse: Encodable {
    let status = PublicResponseStatus.ok
    private let heists: [PublicHeistCatalogEntry]

    init(descriptions: [HeistDescription], detail: HeistCatalogDetail) {
        heists = descriptions.map { PublicHeistCatalogEntry($0, detail: detail) }
    }
}

struct PublicHeistDescriptionResponse: Encodable {
    let status = PublicResponseStatus.ok
    private let heist: PublicHeistDescription

    init(heist: HeistDescription) {
        self.heist = PublicHeistDescription(heist)
    }
}

struct PublicHeistValidationResponse: Encodable {
    private let report: HeistValidation.Report

    private enum CodingKeys: String, CodingKey {
        case status
        case admissible
        case plan
        case invocation
        case lint
        case buildDiagnostics
        case canonicalPlan
    }

    private enum PlanCodingKeys: String, CodingKey {
        case valid
        case version
        case name
        case parameter
        case definitionCount
        case topLevelStepCount
    }

    private enum InvocationCodingKeys: String, CodingKey {
        case status
        case argumentProvided
        case diagnostics
    }

    private enum LintCodingKeys: String, CodingKey {
        case mode
        case status
        case findings
    }

    init(report: HeistValidation.Report) {
        self.report = report
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(PublicResponseStatus.ok, forKey: .status)
        try container.encode(report.admissible, forKey: .admissible)
        try encodePlan(to: container.nestedContainer(keyedBy: PlanCodingKeys.self, forKey: .plan))
        try encodeInvocation(to: container.nestedContainer(
            keyedBy: InvocationCodingKeys.self,
            forKey: .invocation
        ))
        try encodeLint(to: container.nestedContainer(keyedBy: LintCodingKeys.self, forKey: .lint))
        var diagnostics = container.nestedUnkeyedContainer(forKey: .buildDiagnostics)
        try diagnostics.encodePublicHeistBuildDiagnostics(report.plan.diagnostics)
        try container.encodeIfPresent(report.canonicalPlan, forKey: .canonicalPlan)
    }

    private func encodePlan(
        to container: KeyedEncodingContainer<PlanCodingKeys>
    ) throws {
        var container = container
        switch report.plan {
        case .valid(let summary):
            try container.encode(true, forKey: .valid)
            try container.encode(summary.version, forKey: .version)
            try container.encodeIfPresent(summary.name?.description, forKey: .name)
            try container.encode(summary.parameter, forKey: .parameter)
            try container.encode(summary.definitionCount, forKey: .definitionCount)
            try container.encode(summary.topLevelStepCount, forKey: .topLevelStepCount)
        case .invalid:
            try container.encode(false, forKey: .valid)
        }
    }

    private func encodeInvocation(
        to container: KeyedEncodingContainer<InvocationCodingKeys>
    ) throws {
        var container = container
        let status = switch report.invocation {
        case .evaluated(.valid): "valid"
        case .evaluated(.invalid): "invalid"
        case .notEvaluated: "not_evaluated"
        }
        try container.encode(status, forKey: .status)
        try container.encode(report.argumentProvided, forKey: .argumentProvided)
        var diagnostics = container.nestedUnkeyedContainer(forKey: .diagnostics)
        try diagnostics.encodePublicHeistBuildDiagnostics(report.invocation.diagnostics)
    }

    private func encodeLint(
        to container: KeyedEncodingContainer<LintCodingKeys>
    ) throws {
        var container = container
        let status = switch report.lint {
        case .notEvaluated: "not_evaluated"
        case .passed: "passed"
        case .findings: "findings"
        }
        try container.encode(report.lint.mode.rawValue, forKey: .mode)
        try container.encode(status, forKey: .status)
        var findings = container.nestedUnkeyedContainer(forKey: .findings)
        for finding in report.lint.findings {
            try finding.encodePublic(to: findings.superEncoder())
        }
    }
}

private extension HeistPlanLintFinding {
    enum PublicCodingKeys: String, CodingKey {
        case severity
        case path
        case message
        case suggestion
    }

    func encodePublic(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PublicCodingKeys.self)
        try container.encode(severity.rawValue, forKey: .severity)
        try container.encode(path.description, forKey: .path)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(suggestion, forKey: .suggestion)
    }
}

private struct PublicHeistCatalogEntry: Encodable {
    let name: String
    let role: HeistCatalogRole
    let parameterKind: HeistParameterKind
    let requiresArgument: Bool
    let summary: String
    let tags: [String]
    let parameterName: HeistReferenceName?
    let nestedRunHeists: [String]?
    let actionCommands: [String]?
    let waitCount: Int?
    let expectationCount: Int?
    let semanticSurfaces: [String]?

    init(_ description: HeistDescription, detail: HeistCatalogDetail) {
        name = description.identity.displayName
        role = description.role
        parameterKind = description.parameterKind
        requiresArgument = description.requiresArgument
        summary = description.heistCatalogSummary
        tags = description.heistCatalogTags
        switch detail {
        case .summary:
            parameterName = nil
            nestedRunHeists = nil
            actionCommands = nil
            waitCount = nil
            expectationCount = nil
            semanticSurfaces = nil
        case .detailed:
            parameterName = description.parameterName
            nestedRunHeists = description.semanticSurface.nestedRunHeists.isEmpty
                ? nil
                : description.semanticSurface.nestedRunHeists.map(\.heistDiscoveryDisplayValue)
            actionCommands = description.semanticSurface.actionCommands.isEmpty
                ? nil
                : description.semanticSurface.actionCommands.map(\.heistDiscoveryDisplayValue)
            waitCount = description.semanticSurface.waits.count
            expectationCount = description.semanticSurface.expectations.count
            semanticSurfaces = description.semanticSurface.semanticSurfaces.isEmpty
                ? nil
                : description.semanticSurface.semanticSurfaces.map(\.heistDiscoveryDisplayValue)
        }
    }
}

private struct PublicHeistDescription: Encodable {
    let name: String
    let role: HeistCatalogRole
    let parameterKind: HeistParameterKind
    let parameterName: HeistReferenceName?
    let requiresArgument: Bool
    let semanticSurface: PublicHeistSurface

    init(_ description: HeistDescription) {
        name = description.identity.displayName
        role = description.role
        parameterKind = description.parameterKind
        parameterName = description.parameterName
        requiresArgument = description.requiresArgument
        semanticSurface = PublicHeistSurface(description.semanticSurface)
    }
}

private struct PublicHeistSurface: Encodable {
    let actionCommands: [String]
    let targetPredicates: [String]
    let waits: [String]
    let expectations: [String]
    let nestedRunHeists: [String]
    let expectedEffects: [String]
    let semanticSurfaces: [String]

    init(_ surface: HeistSemanticSurface) {
        actionCommands = surface.actionCommands.map(\.heistDiscoveryDisplayValue)
        targetPredicates = surface.targetPredicates.map(\.heistDiscoveryDisplayValue)
        waits = surface.waits.map(\.heistDiscoveryDisplayValue)
        expectations = surface.expectations.map(\.heistDiscoveryDisplayValue)
        nestedRunHeists = surface.nestedRunHeists.map(\.heistDiscoveryDisplayValue)
        expectedEffects = surface.expectedEffects.map(\.heistDiscoveryDisplayValue)
        semanticSurfaces = surface.semanticSurfaces.map(\.heistDiscoveryDisplayValue)
    }
}
