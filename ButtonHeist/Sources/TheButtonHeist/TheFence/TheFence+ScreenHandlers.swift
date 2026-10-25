import Foundation
import TheScore

@ButtonHeistActor
extension TheFence {

    // MARK: - Handler: Screen

    func handleGetScreen(_ request: ScreenRequest, timeout: TimeInterval) async throws -> FenceResponse {
        let observationTimeout = try WaitTimeout(validatingSeconds: timeout)
        let screen = try await sendAndAwaitScreen(
            .requestScreen(ScreenRequestPayload(
                mode: request.mode,
                timeout: observationTimeout
            )),
            timeout: screenTransportTimeout(for: observationTimeout)
        )
        let options = ScreenshotResponseOptions()

        if case .inlineData = request.destination {
            let byteCount = screen.pngData.utf8.count
            guard byteCount <= DecodeLimits.maxInlineScreenshotBase64Bytes else {
                return .error(DiagnosticFailure(
                    message: "Inline screenshot payload is too large: \(byteCount) bytes exceeds " +
                        "\(DecodeLimits.maxInlineScreenshotBase64Bytes) bytes",
                    details: FailureDetails(code: .screenInlinePayloadTooLarge)
                ))
            }
            return .screenshotData(payload: screen, options: options)
        }

        do {
            let destination: ScreenshotArtifactWriter.Destination = switch request.destination {
            case .artifact(.some(let outputPath)):
                .userExplicitOutputPath(outputPath)
            case .artifact(.none):
                .automaticPrivateArtifact
            case .inlineData:
                .automaticPrivateArtifact
            }
            let url = try await screenshotArtifacts.writeScreenshot(
                base64Data: screen.pngData,
                destination: destination,
                command: .getScreen
            )
            return .screenshot(path: url.path, payload: screen, options: options)
        } catch StorageError.unsafePath {
            throw FenceError.invalidRequest(
                "Invalid output path: must not contain '..' components or control characters"
            )
        } catch StorageError.base64DecodingFailed {
            throw FenceError.serverError(
                ServerError(kind: .general, message: "Failed to decode screenshot data")
            )
        }
    }

    func screenTransportTimeout(for observationTimeout: WaitTimeout) -> TimeInterval {
        observationTimeout.seconds + config.postActionExpectationTimeoutBuffer
    }
}
