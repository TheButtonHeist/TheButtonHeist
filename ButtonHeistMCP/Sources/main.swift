import Foundation
import MCP
@_spi(ButtonHeistInternals) @_spi(ButtonHeistTooling) import ButtonHeist
import TheScore

@main
struct ButtonHeistMCPServer {
    static func main() async throws {
        let context = try await setUp()

        let server = Server(
            name: "buttonheist",
            version: buttonHeistVersion.description,
            instructions: TheFence.Command.mcpServerInstructions,
            capabilities: .init(tools: .init())
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ToolDefinitions.all)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await handleToolCall(params, context: context)
        }

        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    @ButtonHeistActor
    private static func setUp() throws -> MCPServerContext {
        let config = try EnvironmentConfig.resolve()
        let fence = TheFence(configuration: config.fenceConfiguration)
        let idleMonitor = config.sessionTimeout.seconds.map { timeout in
            IdleMonitor(timeout: timeout) { [fence] in
                fence.stop()
            }
        }
        return MCPServerContext(fence: fence, idleMonitor: idleMonitor)
    }

    @ButtonHeistActor
    private static func handleToolCall(
        _ params: CallTool.Parameters,
        context: MCPServerContext
    ) async -> CallTool.Result {
        defer { context.idleMonitor?.resetTimer() }
        do {
            let arguments = try MCPValueBridge.commandEnvelope(from: params.arguments)
            switch TheFence.Command.routeToolRequest(named: params.name, arguments: arguments) {
            case .success(let input):
                let response = try await context.fence.execute(try context.fence.admit(input))
                return renderResponse(response)
            case .failure(let error):
                return renderResponse(.failure(error))
            }
        } catch {
            let response = FenceResponse.failure(error)
            return renderResponse(response)
        }
    }

    static func renderResponse(_ response: FenceResponse) -> CallTool.Result {
        renderResponse(response, structuredContent: structuredContent(for: response))
    }

    static func renderResponse(
        _ response: FenceResponse,
        structuredContent: MCPValueBridge.StructuredContent
    ) -> CallTool.Result {
        let renderedResponse = structuredContent.failure.map(FenceResponse.error) ?? response
        var content: [Tool.Content] = []

        // Screenshots: embed as image content. File-based screenshots fall through
        // to the compact text below.
        if case .screenshotData(let payload, _) = renderedResponse {
            content.append(.image(data: payload.pngData, mimeType: "image/png", annotations: nil, _meta: nil))
        }

        content.append(.text(
            text: renderedResponse.compactFormatted(profile: .mcp),
            annotations: nil,
            _meta: nil
        ))
        return .init(
            content: content,
            structuredContent: Optional.some(structuredContent.value),
            isError: renderedResponse.isFailure
        )
    }

    private static func structuredContent(
        for response: FenceResponse
    ) -> MCPValueBridge.StructuredContent {
        do {
            return try MCPValueBridge.structuredContent(for: response)
        } catch {
            let failure = DiagnosticFailure(
                message: "Failed to encode structured tool response: \(error.localizedDescription)",
                details: FailureDetails(code: .formattingJSONEncodingFailed)
            )
            let value = try? MCPValueBridge.structuredContent(for: .error(failure)).value
            return .fallback(
                value ?? .object([
                    "status": .string("error"),
                    "message": .string(failure.message),
                ]),
                failure
            )
        }
    }

}

private struct MCPServerContext {
    let fence: TheFence
    let idleMonitor: IdleMonitor?
}
