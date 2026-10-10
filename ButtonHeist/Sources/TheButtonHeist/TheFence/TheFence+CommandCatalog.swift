import Foundation
import ThePlans
import TheScore

@_spi(ButtonHeistTooling) public enum FenceCommandFamily: String, Sendable, CaseIterable {
    case session
    case observation
    case action
    case heistRuntime
}

@_spi(ButtonHeistTooling) public enum FenceCommandFixedTimeout: String, Sendable, Equatable, CaseIterable {
    case health
    case standardAction
    case longAction
    case explore
    case screenCapture

    public var seconds: TimeInterval {
        switch self {
        case .health:
            return 3
        case .standardAction:
            return 15
        case .longAction:
            return 30
        case .explore:
            return 60
        case .screenCapture:
            return 30
        }
    }
}

@_spi(ButtonHeistTooling) public enum FenceCommandTimeoutSemantics: Sendable, Equatable {
    case none
    case fixed(FenceCommandFixedTimeout)
    case action
    case performStep
    case heist

    public var fixedSeconds: TimeInterval? {
        guard case .fixed(let timeout) = self else { return nil }
        return timeout.seconds
    }
}

@_spi(ButtonHeistTooling) public struct FenceCommandDescriptor: Sendable, Equatable {
    public let command: TheFence.Command
    public let family: FenceCommandFamily
    public let requiresConnectionBeforeDispatch: Bool
    public let parameters: [FenceParameterSpec]
    public let timeout: FenceCommandTimeoutSemantics
    public let cliExposure: CLIExposure
    public let mcpExposure: MCPExposure
    public let mcpAnnotations: MCPToolAnnotationSpec?
    public let description: String

    public var isPublicRequestContract: Bool {
        cliExposure != .notExposed || mcpExposure != .notExposed
    }

    public var topLevelParameterKeys: Set<String> {
        Set(parameters.map(\.key))
    }

    public func parameter(named key: String) -> FenceParameterSpec? {
        let matches = parameters.flatMap { $0.parameters(named: key) }
        guard let first = matches.first,
              matches.dropFirst().allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }

    public func defaultValue<Value>(for parameter: FenceParameter<Value>) -> Value? {
        _ = resolvedParameter(for: parameter)
        return parameter.defaultValue
    }

    public func requiredDefaultValue<Value>(for parameter: FenceParameter<Value>) -> Value {
        guard let value = defaultValue(for: parameter) else {
            preconditionFailure("No default registered for \(command.rawValue).\(parameter.key)")
        }
        return value
    }

    public func allowedRawValues<Value>(for parameter: FenceParameter<Value>) -> [String] {
        _ = resolvedParameter(for: parameter)
        guard let values = parameter.allowedRawValues else {
            preconditionFailure("No enum values registered for \(command.rawValue).\(parameter.key)")
        }
        return values
    }

    private func resolvedParameter<Value>(for parameter: FenceParameter<Value>) -> FenceParameterSpec {
        guard let spec = self.parameter(named: parameter.key),
              spec == parameter.spec else {
            preconditionFailure("No matching parameter registered for \(command.rawValue).\(parameter.key)")
        }
        return spec
    }
}

typealias FenceCommandAdmission = @ButtonHeistActor @Sendable (
    TheFence,
    TheFence.CommandArgumentEnvelope
) throws -> TheFence.CommandExecution

extension TheFence {
    public enum Command: String, CaseIterable, Hashable, Sendable {
        case ping
        case listDevices = "list_devices"
        case getInterface = "get_interface"
        case getScreen = "get_screen"
        case getNotifications = "get_notifications"
        case action
        case getPasteboard = "get_pasteboard"
        case perform
        case runHeist = "run_heist"
        case validateHeist = "validate_heist"
        case listHeists = "list_heists"
        case describeHeist = "describe_heist"
        case getSessionState = "get_session_state"
        case connect
        case listTargets = "list_targets"
    }
}

extension TheFence.Command {
    struct Contract: Sendable {
        let descriptor: FenceCommandDescriptor
        let admission: FenceCommandAdmission

        init(
            command: TheFence.Command,
            family: FenceCommandFamily,
            requiresConnectionBeforeDispatch: Bool,
            parameters: [FenceParameterSpec],
            timeout: FenceCommandTimeoutSemantics,
            description: String,
            cliExposure: CLIExposure,
            mcpExposure: MCPExposure,
            mcpAnnotations: MCPToolAnnotationSpec?,
            admission: @escaping FenceCommandAdmission
        ) {
            precondition(
                Set(parameters.map(\.key)).count == parameters.count,
                "Command parameter keys must be unique"
            )
            descriptor = FenceCommandDescriptor(
                command: command,
                family: family,
                requiresConnectionBeforeDispatch: requiresConnectionBeforeDispatch,
                parameters: parameters,
                timeout: timeout,
                cliExposure: cliExposure,
                mcpExposure: mcpExposure,
                mcpAnnotations: mcpAnnotations,
                description: description
            )
            self.admission = admission
        }
    }
}

@_spi(ButtonHeistTooling) public extension TheFence.Command {
    var descriptor: FenceCommandDescriptor {
        contract.descriptor
    }

    static var descriptors: [FenceCommandDescriptor] {
        allCases.map(\.descriptor)
    }

    static var cliDirectCommandDescriptors: [FenceCommandDescriptor] {
        descriptors.filter { $0.cliExposure == .directCommand }
    }
}

extension TheFence.Command {
    private func executionContract(
        family: FenceCommandFamily,
        requiresConnectionBeforeDispatch: Bool = true,
        parameters: [FenceParameterSpec] = [],
        timeout: FenceCommandTimeoutSemantics = .none,
        description: String,
        cliExposure: CLIExposure = .directCommand,
        mcpExposure: MCPExposure = .notExposed,
        mcpAnnotations: MCPToolAnnotationSpec? = nil,
        admission: @escaping FenceCommandAdmission
    ) -> Contract {
        Contract(
            command: self,
            family: family,
            requiresConnectionBeforeDispatch: requiresConnectionBeforeDispatch,
            parameters: parameters,
            timeout: timeout,
            description: description,
            cliExposure: cliExposure,
            mcpExposure: mcpExposure,
            mcpAnnotations: mcpAnnotations,
            admission: admission
        )
    }

    private func fixedExecutionContract(
        family: FenceCommandFamily,
        requiresConnectionBeforeDispatch: Bool = true,
        parameters: [FenceParameterSpec] = [],
        timeout: FenceCommandFixedTimeout,
        description: String,
        cliExposure: CLIExposure = .directCommand,
        mcpExposure: MCPExposure = .notExposed,
        mcpAnnotations: MCPToolAnnotationSpec? = nil,
        admission: @escaping @ButtonHeistActor @Sendable (
            TheFence,
            TheFence.CommandArgumentEnvelope,
            TimeInterval
        ) throws -> TheFence.CommandExecution
    ) -> Contract {
        executionContract(
            family: family,
            requiresConnectionBeforeDispatch: requiresConnectionBeforeDispatch,
            parameters: parameters,
            timeout: .fixed(timeout),
            description: description,
            cliExposure: cliExposure,
            mcpExposure: mcpExposure,
            mcpAnnotations: mcpAnnotations,
            admission: { fence, arguments in try admission(fence, arguments, timeout.seconds) }
        )
    }

    // This exhaustive switch is the canonical command contract and policy table.
    var contract: Contract {
        switch self {
        case .ping:
            return fixedExecutionContract(
                family: .session,
                requiresConnectionBeforeDispatch: false,
                timeout: .health,
                description: "Check connection health without reading accessibility state.",
                mcpAnnotations: MCPToolAnnotationSpec(readOnlyHint: true, idempotentHint: true)
            ) { _, _, timeout in
                .init { fence in try await fence.handlePing(timeout: timeout) }
            }
        case .listDevices:
            return executionContract(
                family: .session,
                requiresConnectionBeforeDispatch: false,
                description: "List discovered iOS devices and configured connection targets.",
                mcpAnnotations: MCPToolAnnotationSpec(readOnlyHint: true, idempotentHint: true)
            ) { _, _ in
                .init { fence in try await fence.handleListDevices() }
            }
        case .getInterface:
            return fixedExecutionContract(
                family: .observation,
                parameters: [
                    FenceParameterBlocks.interfaceSubtree,
                    FenceParameters.interfaceDetail.spec,
                    FenceParameters.maxScrollsPerContainer.spec,
                    FenceParameters.maxScrollsPerDiscovery.spec,
                ],
                timeout: .explore,
                description: Self.getInterfaceDescription,
                mcpExposure: .directTool,
                mcpAnnotations: MCPToolAnnotationSpec(readOnlyHint: true, idempotentHint: true)
            ) { fence, arguments, timeout in
                let request = try fence.makeGetInterfaceRequest(arguments)
                return .init { fence in try await fence.handleGetInterface(request, timeout: timeout) }
            }
        case .getScreen:
            return fixedExecutionContract(
                family: .observation,
                parameters: [
                    FenceParameters.output.spec,
                    FenceParameters.inlineData.spec,
                    FenceParameters.screenMode.spec,
                ],
                timeout: .screenCapture,
                description: "Capture a PNG screenshot with visible interface state. Pass mode=accessibility to render accessibility markers and legend.",
                mcpExposure: .directTool,
                mcpAnnotations: MCPToolAnnotationSpec(readOnlyHint: true, idempotentHint: true)
            ) { fence, arguments, timeout in
                let request = try fence.makeScreenRequest(arguments)
                return .init { fence in try await fence.handleGetScreen(request, timeout: timeout) }
            }
        case .getNotifications:
            return fixedExecutionContract(
                family: .observation,
                timeout: .health,
                description: """
                    Read the ordered accessibility notifications retained by observation history, \
                    including spoken text and attached element semantics.
                    """,
                mcpExposure: .directTool,
                mcpAnnotations: MCPToolAnnotationSpec(readOnlyHint: true, idempotentHint: true)
            ) { _, _, timeout in
                .init { fence in try await fence.handleGetNotifications(timeout: timeout) }
            }
        case .action:
            return executionContract(
                family: .action,
                parameters: [FenceParameters.action] + FenceParameterBlocks.expectation,
                timeout: .action,
                description: "Execute one canonical HeistActionCommand. Durable actions enter the heist pipeline; "
                    + "transient viewport and custom-duration actions dispatch directly."
            ) { fence, arguments in
                try TheFence.appInteractionExecution(
                    fence.decodeAction(arguments),
                    expectationPayload: TheFence.ExpectationPayload(arguments: arguments)
                )
            }
        case .getPasteboard:
            return fixedExecutionContract(
                family: .observation,
                timeout: .health,
                description: "Read text from the general pasteboard.",
                mcpExposure: .directTool,
                mcpAnnotations: MCPToolAnnotationSpec(readOnlyHint: true)
            ) { _, _, timeout in
                .init { fence in try await fence.handleGetPasteboard(timeout: timeout) }
            }
        case .perform:
            return executionContract(
                family: .heistRuntime,
                parameters: [FenceParameters.performStep.spec],
                timeout: .performStep,
                description: Self.performDescription,
                mcpExposure: .directTool
            ) { fence, arguments in
                let request = try fence.decodePerformRequest(arguments)
                return .init { fence in try await fence.handlePerform(request) }
            }
        case .runHeist:
            return executionContract(
                family: .heistRuntime,
                parameters: [Self.rootArgumentParameter, FenceParameters.heistTimeout.spec] + Self.planSourceParameters,
                timeout: .heist,
                description: Self.runHeistDescription,
                mcpExposure: .directTool
            ) { fence, arguments in
                let request = try fence.decodeRunHeistRequest(arguments)
                return .init { fence in try await fence.handleRunHeist(request) }
            }
        case .validateHeist:
            return executionContract(
                family: .heistRuntime,
                requiresConnectionBeforeDispatch: false,
                parameters: [
                    Self.rootArgumentParameter,
                    FenceParameters.heistValidationLint.spec,
                ] + Self.planSourceParameters,
                description: Self.validateHeistDescription,
                mcpExposure: .directTool,
                mcpAnnotations: MCPToolAnnotationSpec(readOnlyHint: true, idempotentHint: true)
            ) { fence, arguments in
                let request = try fence.decodeValidateHeistRequest(arguments)
                return .init { fence in try fence.handleValidateHeist(request) }
            }
        case .listHeists:
            return executionContract(
                family: .heistRuntime,
                requiresConnectionBeforeDispatch: false,
                parameters: [
                    FenceParameters.heistCatalogDetail.spec,
                ] + Self.planSourceParameters,
                description: "List the root entry and reusable heists in a plan. Use `detail: \"detailed\"` "
                    + "when composing against available capabilities.",
                mcpExposure: .directTool,
                mcpAnnotations: MCPToolAnnotationSpec(readOnlyHint: true, idempotentHint: true)
            ) { fence, arguments in
                let request = try fence.decodeListHeistsRequest(arguments)
                return .init { fence in fence.handleListHeists(request) }
            }
        case .describeHeist:
            return executionContract(
                family: .heistRuntime,
                requiresConnectionBeforeDispatch: false,
                parameters: [FenceParameters.heistName.spec] + Self.planSourceParameters,
                description: "Describe one root entry or reusable heist from a plan so an agent can call it safely.",
                mcpExposure: .directTool,
                mcpAnnotations: MCPToolAnnotationSpec(readOnlyHint: true, idempotentHint: true)
            ) { fence, arguments in
                let request = try fence.decodeDescribeHeistRequest(arguments)
                return .init { fence in fence.handleDescribeHeist(request) }
            }
        case .getSessionState:
            return executionContract(
                family: .session,
                requiresConnectionBeforeDispatch: false,
                description: "Inspect connection, device, and last-action session state.",
                mcpExposure: .directTool,
                mcpAnnotations: MCPToolAnnotationSpec(readOnlyHint: true, idempotentHint: true)
            ) { _, _ in
                .init { fence in .sessionState(payload: fence.currentSessionState()) }
            }
        case .connect:
            return executionContract(
                family: .session,
                requiresConnectionBeforeDispatch: false,
                parameters: [
                    FenceParameters.connectionTarget.spec,
                    FenceParameters.device.spec,
                    FenceParameters.token.spec,
                ],
                description: "Establish or switch the active connection to an app running The Button Heist.",
                mcpExposure: .directTool
            ) { fence, arguments in
                let request = try fence.decodeConnectRequest(arguments)
                return .init { fence in try await fence.handleConnect(request) }
            }
        case .listTargets:
            return executionContract(
                family: .session,
                requiresConnectionBeforeDispatch: false,
                description: "List configured connection targets and the default target.",
                mcpAnnotations: MCPToolAnnotationSpec(readOnlyHint: true, idempotentHint: true)
            ) { _, _ in
                .init { fence in fence.handleListTargets() }
            }
        }
    }

    private static let getInterfaceDescription = """
        Read the app accessibility hierarchy, optionally scoped to a subtree.

        Build DSL targets from returned accessibility language: `.label("Pay")`,
        `.identifier("pay_button")`, `.value("Milk")`, `.element(.label("Pay"),
        .traits([.button]))`, or `.target(..., ordinal: n)` for duplicates.
        Pass `subtree` a canonical accessibility target. Element target checks use
        `{ "kind": "label|identifier|value|hint|customContent", "match": ... }`,
        `{ "kind": "traits|actions|rotors", "values": [...] }`, or
        `{ "kind": "exclude", "check": { ... } }`.
        Custom actions use `{ "custom": "Sub" }`.
        `containerName` is for inspection and viewport/debug commands only; it is
        not a semantic target or durable heist selector.
        `maxScrollsPerContainer` and `maxScrollsPerDiscovery` bound the command-owned
        interface discovery pass; omit them to use Inside Job runtime defaults.
        """
}
