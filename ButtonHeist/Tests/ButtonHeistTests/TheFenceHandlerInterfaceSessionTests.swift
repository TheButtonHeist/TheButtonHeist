import ButtonHeistTestSupport
import XCTest
import Network
import ButtonHeistSupport
@_spi(ButtonHeistTooling) @testable import ButtonHeist
@_spi(ButtonHeistInternals) import ThePlans
@_spi(ButtonHeistInternals) import TheScore

extension TheFenceHandlerTests {
    // MARK: - Connect

    @ButtonHeistActor
    func testConnectReturnsSessionStateWithoutInterfaceObservation() async throws {
        let mockConn = MockConnection()
        mockConn.serverInfo = TheFenceFixtures.testServerInfo

        let mockDiscovery = MockDiscovery()
        mockDiscovery.discoveredDevices = [TheFenceFixtures.testDevice]

        let fence = TheFence(
            configuration: .init(
                connectionTarget: DeviceResolutionTarget(filter: "MockApp"),
                autoReconnect: false
            ),
            handoff: TheHandoff(discovery: mockDiscovery)
        )
        fence.handoff.makeConnection = { _ in mockConn }

        let previousReachability = makeReachabilityConnection
        makeReachabilityConnection = { _ in
            let probe = MockConnection()
            probe.emitTransportReadyOnConnect = true
            probe.responseScript = { message in
                if case .status = message {
                    return .status(StatusPayload(
                        identity: StatusIdentity(
                            appName: "Mock", bundleIdentifier: "com.test",
                            appBuild: "1", deviceName: "Mock",
                            systemVersion: "18.0", buttonHeistVersion: "0.0.1"
                        ),
                        session: StatusSession(active: false, watchersAllowed: false, activeConnections: 0)
                    ))
                }
                return .actionResult(ActionResult.success(payload: .activate))
            }
            return probe
        }
        defer { makeReachabilityConnection = previousReachability }

        XCTAssertFalse(fence.handoff.connectionLifecycle.isConnected)
        XCTAssertFalse(mockConn.isConnected)
        let response = try await fence.execute(command: .connect)

        guard case .sessionState(let payload) = response else {
            return XCTFail("Expected sessionState response, got \(response)")
        }
        guard case .connected = payload.state else {
            return XCTFail("Expected connected session state, got \(payload.state)")
        }
        XCTAssertEqual(mockConn.connectCount, 1)

        for (message, _) in mockConn.sent {
            switch message {
            case .requestInterface:
                XCTFail("connect must not send UI observation message \(message)")
            default:
                break
            }
        }
    }

    // MARK: - Pasteboard Validation

    func testSetPasteboardCatalogDeclaresNonEmptyText() throws {
        let parameter = try XCTUnwrap(
            TheFence.Command.setPasteboard.descriptor.parameters.first {
                $0.key == FenceParameterKey.text.rawValue
            }
        )

        XCTAssertEqual(parameter.minLength, 1)
        guard case .object(let schema) = parameter.schema.heistValue else {
            return XCTFail("Expected text parameter schema")
        }
        XCTAssertEqual(schema["minLength"], .int(1))
    }

    @ButtonHeistActor
    func testGetPasteboardRejectsExpectationBecauseItIsARead() async {
        await assertValidationError(
            command: .getPasteboard,
            arguments: ["expect": .object([
                "type": .string("notification"),
            ])],
            contains: "valid get_pasteboard parameter"
        )
    }

    @ButtonHeistActor
    func testPureReadCommandsRemainDirectWireMessages() async throws {
        let cases: [(command: TheFence.Command, wireType: ClientWireMessageType)] = [
            (.getInterface, .requestInterface),
            (.getPasteboard, .getPasteboard),
        ]

        for testCase in cases {
            let (fence, connection) = makeConnectedFence()
            _ = try await fence.execute(command: testCase.command)

            XCTAssertEqual(connection.sent.last?.0.wireType, testCase.wireType, testCase.command.rawValue)
        }
    }

    // MARK: - Ping

    @ButtonHeistActor
    func testPingSendsRequestScopedClientPingAndReturnsPayload() async throws {
        let (fence, mockConn) = makeConnectedFence()
        fence.handoff.connect(to: TheFenceFixtures.testDevice)

        let response = try await fence.execute(command: .ping)

        guard case .pong(let payload) = response else {
            return XCTFail("Expected pong response, got \(response)")
        }
        XCTAssertEqual(payload.appName, "MockApp")
        XCTAssertEqual(payload.bundleIdentifier, "com.test.mock")
        XCTAssertEqual(payload.serverTimestampMs, 1_700_000_000_000)

        guard let sent = mockConn.sent.last else {
            return XCTFail("Expected ping to be sent")
        }
        guard case .ping = sent.0 else {
            return XCTFail("Expected ClientMessage.ping, got \(sent.0)")
        }
        XCTAssertNotNil(sent.1)
    }

    @ButtonHeistActor
    func testPingDoesNotAutoConnectWhenDisconnected() async {
        let device = DiscoveredDevice(host: "127.0.0.1", port: 1234)
        let mockConn = MockConnection()
        let fence = TheFence(configuration: .init(
            connectionTarget: DeviceResolutionTarget(kind: .direct(device)),
            autoReconnect: false
        ))
        fence.handoff.makeConnection = { _ in mockConn }

        do {
            _ = try await fence.execute(command: .ping)
            XCTFail("Expected notConnected")
        } catch FenceError.notConnected {
            XCTAssertEqual(mockConn.connectCount, 0)
        } catch {
            XCTFail("Expected notConnected, got \(error)")
        }
    }

    @ButtonHeistActor
    func testPingTimeoutUsesPongTracker() async throws {
        let (fence, mockConn) = makeConnectedFence()
        fence.handoff.connect(to: TheFenceFixtures.testDevice)
        mockConn.responseScript = nil

        do {
            _ = try await fence.sendAndAwaitPong(timeout: 0.01)
            XCTFail("Expected actionTimeout")
        } catch FenceError.actionTimeout {
            guard let sent = mockConn.sent.last else {
                return XCTFail("Expected ping to be sent")
            }
            guard case .ping = sent.0 else {
                return XCTFail("Expected ClientMessage.ping, got \(sent.0)")
            }
            XCTAssertNotNil(sent.1)
        } catch {
            XCTFail("Expected actionTimeout, got \(error)")
        }
    }

    // MARK: - get_interface

    @ButtonHeistActor
    func testGetInterfaceDefaultSendsRequestInterfaceQuery() async {
        let (fence, mockConn) = makeConnectedFence()
        _ = try? await fence.execute(command: .getInterface)
        guard let (message, _) = mockConn.sent.last,
              case .requestInterface(let query) = message else {
            XCTFail("Expected requestInterface message, got \(String(describing: mockConn.sent.last))")
            return
        }
        XCTAssertNil(query.subtree)
        XCTAssertNil(query.maxScrollsPerContainer)
        XCTAssertNil(query.maxScrollsPerDiscovery)
    }

    @ButtonHeistActor
    func testCommandContractsRejectInvalidParameters() async {
        let cases: [(TheFence.Command, [String: HeistValue], String)] = [
            (
                .activate,
                ["target": targetValue(identifier: "save"), "mode": .string("tap")],
                "schema validation failed for mode: observed string \"tap\"; expected valid activate parameter"
            ),
            (
                .getScreen,
                ["target": targetValue(label: "Save")],
                "schema validation failed for target: observed object; expected valid get_screen parameter"
            ),
            (
                .getInterface,
                ["timeout": .int(15)],
                "schema validation failed for timeout: observed integer 15; expected valid get_interface parameter"
            ),
            (
                .getInterface,
                ["maxScrollsPerContainer": .int(0)],
                "schema validation failed for maxScrollsPerContainer: observed integer 0; expected integer between 1 and 2000"
            ),
        ]

        for (command, arguments, message) in cases {
            await assertValidationError(command: command, arguments: arguments, equals: message)
        }
    }

    @ButtonHeistActor
    func testGetInterfaceDefaultNoSubtreeReturnsWholeHierarchy() async throws {
        let (fence, mockConn) = makeConnectedFence()
        let interfaceFixture = selectionTestInterface()
        mockConn.responseScript = { message in
            switch message {
            case .requestInterface:
                return .interface(interfaceFixture)
            default:
                return .actionResult(ActionResult.success(payload: .activate))
            }
        }

        let response = try await fence.execute(command: .getInterface)

        let interface = try publicJSONProbe(response).object("interface")
        XCTAssertEqual(try interface.string("screenDescription"), "Menu — 2 buttons")
        XCTAssertEqual(try interface.string("screenId"), "menu")
        let navigation = try interface.object("navigation")
        XCTAssertEqual(try navigation.string("screenTitle"), "Menu")
        try navigation.assertMissing("backButton")
        try navigation.assertMissing("tabBarItems")
        let tree = try interface.array("tree")
        XCTAssertEqual(tree.count, 3)
        let container = try tree[1].object("container")
        XCTAssertEqual(try container.string("containerName"), "semantic_actions__actions")
        let children = try container.array("children")
        XCTAssertEqual(children.count, 2)
    }

    @ButtonHeistActor
    func testGetInterfaceQueryIsSentToInsideJobBoundaryAndReturnsSelectedInterface() async throws {
        let (fence, mockConn) = makeConnectedFence()
        mockConn.responseScript = { message in
            switch message {
            case .requestInterface:
                let source = self.selectionTestInterface()
                let selectedNode = source.tree[1]
                let annotations = source.annotations(
                    forSubtree: selectedNode,
                    originalPath: TreePath([1]),
                    rootPath: TreePath([0])
                )
                do {
                    return .interface(try Interface(
                        timestamp: source.timestamp,
                        tree: [selectedNode],
                        annotations: annotations,
                        observationIdentities: .empty
                    ))
                } catch {
                    preconditionFailure("Test interface fixture failed admission: \(error)")
                }
            default:
                return .actionResult(ActionResult.success(payload: .activate))
            }
        }

        let response = try await fence.execute(command: .getInterface, values: [
            "subtree": .object([
                "container": .object([
                    "checks": .array([
                        containerPredicateCheckValue(
                            kind: "identifier",
                            match: stringMatchValue(mode: "exact", value: "actions")
                        ),
                    ]),
                ]),
            ]),
            "maxScrollsPerContainer": .int(25),
            "maxScrollsPerDiscovery": .int(40),
        ])

        guard let (message, _) = mockConn.sent.last,
              case .requestInterface(let query) = message else {
            XCTFail("Expected requestInterface query, got \(String(describing: mockConn.sent.last))")
            return
        }
        XCTAssertNotNil(query.subtree)
        XCTAssertEqual(query.maxScrollsPerContainer, 25)
        XCTAssertEqual(query.maxScrollsPerDiscovery, 40)

        let tree = try publicJSONProbe(response).object("interface").array("tree")
        XCTAssertEqual(tree.count, 1)
        let container = try tree[0].object("container")
        XCTAssertEqual(try container.string("containerName"), "semantic_actions__actions")
        let children = try container.array("children")
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(try children[0].object("element").string("label"), "Submit")
        try children[0].object("element").assertMissing("heistId")
        XCTAssertEqual(try children[1].object("element").string("label"), "Cancel")
    }

    @ButtonHeistActor
    func testGetInterfaceSubtreeRejectsUnknownTargetFields() async {
        let cases: [(subtree: [String: HeistValue], field: String)] = [
            (
                [
                    "heistId": .string("button_save"),
                    "ordinal": .int(1),
                ],
                "heistId"
            ),
            (
                [
                    "checks": .array([
                        predicateCheckValue(kind: "label", match: stringMatchValue(mode: "exact", value: "Save")),
                    ]),
                    "unexpectedTargetField": .string("button_save"),
                ],
                "unexpectedTargetField"
            ),
        ]

        for testCase in cases {
            await assertValidationError(
                command: .getInterface,
                arguments: ["subtree": .object(testCase.subtree)],
                contains: testCase.field
            )
        }
    }

    func testContainerNameAppearsInSummaryJsonAndCompactOutput() throws {
        let response = FenceResponse.interface(selectionTestInterface(), detail: .summary)

        let tree = try publicJSONProbe(response)
            .object("interface")
            .array("tree")
        let container = try tree[1].object("container")
        XCTAssertEqual(try container.string("containerName"), "semantic_actions__actions")
        try container.assertMissing("frameX")

        let compact = response.compactFormatted()
        XCTAssertTrue(
            compact.contains(#"── group "Actions" id="actions" "semantic_actions__actions" ──"#),
            compact
        )
        XCTAssertFalse(compact.contains("stableId"), compact)
    }

    @ButtonHeistActor
    func testGetInterfaceDetailDoesNotChangeObservationDispatch() async {
        let (fullFence, fullMock) = makeConnectedFence()
        _ = try? await fullFence.execute(command: .getInterface, values: ["detail": .string("full")])
        guard let (fullMessage, _) = fullMock.sent.last,
              case .requestInterface = fullMessage else {
            XCTFail("Expected detail=full on get_interface to send requestInterface, got \(String(describing: fullMock.sent.last))")
            return
        }
    }

    @ButtonHeistActor
    func testGetInterfaceRejectsScopeParameter() async {
        await assertValidationError(
            command: .getInterface,
            arguments: ["scope": .string("current")],
            equals: "schema validation failed for scope: observed string \"current\"; expected valid get_interface parameter"
        )
    }

}
