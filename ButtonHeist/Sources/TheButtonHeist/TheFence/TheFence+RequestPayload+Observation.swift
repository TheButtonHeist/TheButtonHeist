import Foundation
import ThePlans

import TheScore

extension TheFence {

    struct GetInterfaceRequest {
        let detail: InterfaceDetail
        let query: InterfaceQuery
    }

    struct ScreenRequest {
        let destination: ScreenshotDestination
        let mode: ScreenCaptureMode
    }

    package enum ScreenshotDestination: Sendable, Equatable {
        case artifact(outputPath: String?)
        case inlineData
    }

    func makeGetInterfaceRequest(_ arguments: CommandArgumentEnvelope) throws -> GetInterfaceRequest {
        return GetInterfaceRequest(
            detail: try arguments.value(
                FenceParameters.interfaceDetail,
                defaultFrom: Command.getInterface.descriptor
            ),
            query: InterfaceQuery(
                subtree: try decodeInterfaceSubtreeTarget(arguments),
                maxScrollsPerContainer: try interfaceDiscoveryLimit(
                    arguments,
                    FenceParameters.maxScrollsPerContainer
                ),
                maxScrollsPerDiscovery: try interfaceDiscoveryLimit(
                    arguments,
                    FenceParameters.maxScrollsPerDiscovery
                )
            )
        )
    }

    private func interfaceDiscoveryLimit(
        _ arguments: CommandArgumentEnvelope,
        _ parameter: FenceParameter<Int>
    ) throws -> InterfaceDiscoveryLimit? {
        guard let value = try arguments.value(parameter) else { return nil }
        return try InterfaceDiscoveryLimit(validating: value)
    }

    func makeScreenRequest(_ arguments: CommandArgumentEnvelope) throws -> ScreenRequest {
        return ScreenRequest(
            destination: try screenshotDestination(arguments),
            mode: try arguments.value(FenceParameters.screenMode, defaultFrom: Command.getScreen.descriptor)
        )
    }

    private func screenshotDestination(_ arguments: CommandArgumentEnvelope) throws -> ScreenshotDestination {
        let outputPath = try arguments.value(FenceParameters.output)
        let inlineData = try arguments.value(FenceParameters.inlineData, defaultFrom: Command.getScreen.descriptor)
        switch (inlineData, outputPath) {
        case (true, nil):
            return .inlineData
        case (false, let outputPath):
            return .artifact(outputPath: outputPath)
        case (true, .some):
            throw SchemaValidationError(
                field: "inlineData/output",
                observed: "inlineData=true with output",
                expected: "choose output for an artifact path or inlineData=true for inline PNG data, not both"
            )
        }
    }

    private func decodeInterfaceSubtreeTarget(_ arguments: CommandArgumentEnvelope) throws -> AccessibilityTarget? {
        guard let subtree = arguments.value(for: "subtree") else { return nil }
        guard case .object(let object) = subtree else {
            throw SchemaValidationError(
                field: arguments.field("subtree"),
                observed: subtree.schemaObservedDescription,
                expected: "object"
            )
        }
        return try CommandArgumentEnvelope(
            values: object,
            fieldPrefix: arguments.field("subtree")
        ).decodeAccessibilityTargetPayload()
    }

}
