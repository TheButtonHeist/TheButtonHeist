import Foundation
import MCP
@_spi(ButtonHeistInternals) @_spi(ButtonHeistTooling) import ButtonHeist
import TheScore

@main
struct ButtonHeistMCPServer {
    typealias JSONResponseRenderer = (FenceResponse) throws -> PublicJSONRendering

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

    static func renderResponse(
        _ response: FenceResponse,
        jsonRenderer: JSONResponseRenderer = defaultJSONResponse
    ) -> CallTool.Result {
        do {
            let rendering = try jsonRenderer(response)
            let value = try JSONDecoder().decode(Value.self, from: rendering.data)
            return callToolResult(
                rendering.failure.map(FenceResponse.error) ?? response,
                structuredContent: value
            )
        } catch {
            return formattingFailureResult(error)
        }
    }

    private static func callToolResult(
        _ response: FenceResponse,
        structuredContent: Value?
    ) -> CallTool.Result {
        var content: [Tool.Content] = []

        // Screenshots: embed as image content. File-based screenshots fall through
        // to the compact text below.
        if case .screenshotData(let payload, _) = response {
            content.append(.image(data: payload.pngData, mimeType: "image/png", annotations: nil, _meta: nil))
        }

        content.append(.text(
            text: response.compactFormatted(profile: .mcp),
            annotations: nil,
            _meta: nil
        ))
        return .init(
            content: content,
            structuredContent: structuredContent,
            isError: response.isFailure
        )
    }

    private static func defaultJSONResponse(_ response: FenceResponse) throws -> PublicJSONRendering {
        try response.jsonRendering(profile: .mcp, outputFormatting: [])
    }

    private static func formattingFailureResult(_ error: Error) -> CallTool.Result {
        let failure = DiagnosticFailure(
            message: "Failed to project structured tool response: \(error.localizedDescription)",
            details: FailureDetails(code: .formattingJSONEncodingFailed)
        )
        let response = FenceResponse.error(failure)
        let value = try? JSONDecoder().decode(
            Value.self,
            from: response.jsonData(profile: .mcp, outputFormatting: [])
        )
        return callToolResult(response, structuredContent: value)
    }

}

private struct MCPServerContext {
    let fence: TheFence
    let idleMonitor: IdleMonitor?
}
