import Foundation
import ThePlans
import TheScore

struct PublicErrorResponse: Encodable {
    let status = PublicResponseStatus.error
    let message: String
    let code: KnownFailureCode
    let details: PublicErrorDetails

    init(failure: DiagnosticFailure) {
        self.message = failure.message
        self.code = failure.details.code
        self.details = PublicErrorDetails(failure: failure)
    }
}

struct PublicErrorDetails: Encodable {
    private let failure: DiagnosticFailure

    private enum CodingKeys: String, CodingKey {
        case kind
        case phase
        case retryable
        case hint
        case buildDiagnostics
    }

    init(failure: DiagnosticFailure) {
        self.failure = failure
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(failure.details.code.kind, forKey: .kind)
        try container.encode(failure.details.phase, forKey: .phase)
        try container.encode(failure.details.retryable, forKey: .retryable)
        try container.encodeIfPresent(failure.details.hint, forKey: .hint)
        if !failure.buildDiagnostics.isEmpty {
            var diagnostics = container.nestedUnkeyedContainer(forKey: .buildDiagnostics)
            try diagnostics.encodePublicHeistBuildDiagnostics(failure.buildDiagnostics)
        }
    }
}

extension UnkeyedEncodingContainer {
    mutating func encodePublicHeistBuildDiagnostics(_ diagnostics: [HeistBuildDiagnostic]) throws {
        for diagnostic in diagnostics {
            try diagnostic.encodePublic(to: superEncoder())
        }
    }
}

private extension HeistBuildDiagnostic {
    enum PublicCodingKeys: String, CodingKey {
        case code
        case kind
        case phase
        case message
        case hint
        case path
        case sourceSpan
    }

    func encodePublic(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PublicCodingKeys.self)
        try container.encode(code.rawValue, forKey: .code)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(phase.rawValue, forKey: .phase)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(hint, forKey: .hint)
        try container.encodeIfPresent(path, forKey: .path)
        if let sourceSpan {
            try sourceSpan.encodePublic(to: container.superEncoder(forKey: .sourceSpan))
        }
    }
}

private extension HeistBuildSourceSpan {
    enum PublicCodingKeys: String, CodingKey {
        case sourceName
        case offset
        case line
        case column
        case length
    }

    func encodePublic(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PublicCodingKeys.self)
        try container.encode(sourceName, forKey: .sourceName)
        try container.encode(offset, forKey: .offset)
        try container.encode(line, forKey: .line)
        try container.encode(column, forKey: .column)
        try container.encodeIfPresent(length, forKey: .length)
    }
}

struct PublicResponseModel: Encodable {
    let response: FenceResponse
    let profile: ProjectionProfile

    init(response: FenceResponse, profile: ProjectionProfile = .summary) {
        self.response = response
        self.profile = profile
    }

    func encode(to encoder: Encoder) throws {
        switch response {
        case .ok(let message):
            try PublicOKResponse(message: message).encode(to: encoder)
        case .error(let failure):
            try PublicErrorResponse(failure: failure).encode(to: encoder)
        case .status(let connected, let deviceName):
            try PublicStatusResponse(connected: connected, device: deviceName).encode(to: encoder)
        case .pong(let payload):
            try PublicPongResponse(payload: payload).encode(to: encoder)
        case .devices(let devices):
            try PublicDevicesResponse(devices: devices).encode(to: encoder)
        case .interface(let interface, let detail):
            try PublicInterfaceResponse(interface: interface, detail: detail, profile: profile).encode(to: encoder)
        case .notifications(let notifications):
            try PublicNotificationsResponse(notifications: notifications).encode(to: encoder)
        case .action(let command, let result, let expectation):
            let expectationHint = expectation.flatMap {
                FenceResponse.expectationFailureHint($0, command: command, result: result)
            }
            try ActionProjection(
                method: command.rawValue,
                result: result,
                expectation: expectation,
                expectationHint: expectationHint,
                profile: profile
            ).encode(to: encoder)
        case .screenshot(let path, let payload, let options):
            try PublicScreenshotResponse(projection: ScreenshotProjection(
                storage: .artifact(path: path),
                payload: payload,
                includeInterface: options.includeInterface,
                profile: profile
            )).encode(to: encoder)
        case .screenshotData(let payload, let options):
            try PublicScreenshotResponse(projection: ScreenshotProjection(
                storage: .inlinePNG(payload.pngData),
                payload: payload,
                includeInterface: options.includeInterface,
                profile: profile
            )).encode(to: encoder)
        case .heistExecution(_, let report):
            try PublicHeistExecutionResponse(
                report: report,
                profile: profile
            ).encode(to: encoder)
        case .heistValidation(let report):
            try PublicHeistValidationResponse(report: report).encode(to: encoder)
        case .heistCatalog(let descriptions, let detail):
            try PublicHeistCatalogResponse(descriptions: descriptions, detail: detail).encode(to: encoder)
        case .heistDescription(let description):
            try PublicHeistDescriptionResponse(heist: description).encode(to: encoder)
        case .sessionState(let payload):
            try PublicSessionStateResponse(payload: payload).encode(to: encoder)
        case .targets(let targets, let defaultTarget):
            try PublicTargetsResponse(targets: targets, defaultTarget: defaultTarget).encode(to: encoder)
        }
    }
}

struct PublicNotificationsResponse: Encodable {
    let status = PublicResponseStatus.ok
    let notifications: [Observation.Notification]

    private enum CodingKeys: String, CodingKey {
        case status
        case notifications
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(notifications, forKey: .notifications)
    }
}
