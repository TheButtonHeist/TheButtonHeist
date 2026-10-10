import Foundation
import ButtonHeistSupport
import Network
import os

import TheScore

private let logger = ButtonHeistLog.logger(.handoff(.discovery))

enum DeviceDiscoveryBrowserState: Equatable, Sendable {
    case setup
    case waiting
    case ready
    case failed(String)
    case cancelled
}

protocol DeviceDiscoveryBrowsing: AnyObject, Sendable {
    func start(
        queue: DispatchQueue,
        onResultsChanged: @escaping @Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void,
        onStateChanged: @escaping @Sendable (DeviceDiscoveryBrowserState) -> Void
    )
    func invalidate()
}

final class NWDeviceDiscoveryBrowser: DeviceDiscoveryBrowsing {
    private let browser: NWBrowser
    private let isInvalidated = OSAllocatedUnfairLock(initialState: false)

    init() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: buttonHeistServiceType, domain: "local."),
            using: parameters
        )
    }

    func start(
        queue: DispatchQueue,
        onResultsChanged: @escaping @Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void,
        onStateChanged: @escaping @Sendable (DeviceDiscoveryBrowserState) -> Void
    ) {
        browser.browseResultsChangedHandler = onResultsChanged
        browser.stateUpdateHandler = { state in
            onStateChanged(Self.browserState(from: state))
        }
        browser.start(queue: queue)
    }

    func invalidate() {
        let shouldInvalidate = isInvalidated.withLock { isInvalidated in
            guard !isInvalidated else { return false }
            isInvalidated = true
            return true
        }
        guard shouldInvalidate else { return }
        browser.browseResultsChangedHandler = nil
        browser.stateUpdateHandler = nil
        browser.cancel()
    }

    private static func browserState(from state: NWBrowser.State) -> DeviceDiscoveryBrowserState {
        switch state {
        case .setup:
            return .setup
        case .waiting:
            return .waiting
        case .ready:
            return .ready
        case .failed(let error):
            return .failed(error.localizedDescription)
        case .cancelled:
            return .cancelled
        @unknown default:
            return .failed(String(describing: state))
        }
    }
}

/// Discovers Button Heist services via Bonjour and emits device found/lost events.
@ButtonHeistActor
final class DeviceDiscovery: DeviceDiscovering {

    nonisolated static let callbackBufferLimit = 512

    private enum BrowserEvent: Sendable {
        case resultsChanged(Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>)
        case stateChanged(DeviceDiscoveryBrowserState)
    }

    private final class CallbackBridge: Sendable {
        enum Admission: Sendable {
            case accepted
            case overflow
            case terminated
        }

        enum TerminalReason: Sendable {
            case finished
            case continuationTerminated
            case overflow
        }

        private enum State {
            case accepting
            case invalidated(TerminalReason)
        }

        let events: AsyncStream<BrowserEvent>

        private let continuation: AsyncStream<BrowserEvent>.Continuation
        private let state = OSAllocatedUnfairLock(initialState: State.accepting)

        init() {
            let stream = AsyncStream<BrowserEvent>.makeStream(
                bufferingPolicy: .bufferingOldest(DeviceDiscovery.callbackBufferLimit)
            )
            events = stream.stream
            continuation = stream.continuation
        }

        func yield(_ event: BrowserEvent) -> Admission {
            let admission = state.withLock { state in
                guard case .accepting = state else { return Admission.terminated }
                switch continuation.yield(event) {
                case .enqueued:
                    return .accepted
                case .dropped:
                    state = .invalidated(.overflow)
                    return .overflow
                case .terminated:
                    state = .invalidated(.continuationTerminated)
                    return .terminated
                @unknown default:
                    state = .invalidated(.overflow)
                    return .overflow
                }
            }
            if case .overflow = admission {
                continuation.finish()
            }
            return admission
        }

        func finish() {
            let shouldFinish = state.withLock { state in
                guard case .accepting = state else { return false }
                state = .invalidated(.finished)
                return true
            }
            if shouldFinish {
                continuation.finish()
            }
        }

        var isActive: Bool {
            state.withLock { state in
                guard case .accepting = state else { return false }
                return true
            }
        }

        var terminalReason: TerminalReason? {
            state.withLock { state in
                guard case .invalidated(let reason) = state else { return nil }
                return reason
            }
        }
    }

    private enum State {
        case idle
        case active(Session)
    }

    private struct Session {
        enum BrowserPhase: Equatable {
            case setup
            case waiting
            case ready
        }

        let id: UUID
        let browser: any DeviceDiscoveryBrowsing
        let callbacks: CallbackBridge
        let eventConsumerTask: Task<Void, Never>
        var registry: DiscoveryRegistry
        var reachabilityTask: Task<Void, Never>?
        var browserPhase: BrowserPhase

        func invalidate() {
            callbacks.finish()
            eventConsumerTask.cancel()
            reachabilityTask?.cancel()
            browser.invalidate()
        }
    }

    private var state: State = .idle
    private let browserQueue = DispatchQueue(label: "com.buttonheist.thehandoff.discovery.browser")
    private let reachabilityValidationInterval: TimeInterval
    private let makeBrowser: () -> any DeviceDiscoveryBrowsing

    var discoveredDevices: [DiscoveredDevice] {
        switch state {
        case .idle:
            return []
        case .active(let session):
            return session.registry.devices
        }
    }

    var isActive: Bool {
        guard case .active = state else { return false }
        return true
    }

    var isReady: Bool {
        guard case .active(let session) = state else { return false }
        return session.browserPhase == .ready
    }

    var onEvent: (@ButtonHeistActor (DiscoveryEvent) -> Void)?

    init(
        reachabilityValidationInterval: TimeInterval = 3.0,
        makeBrowser: @escaping () -> any DeviceDiscoveryBrowsing = { NWDeviceDiscoveryBrowser() }
    ) {
        self.reachabilityValidationInterval = reachabilityValidationInterval
        self.makeBrowser = makeBrowser
    }

    func start() {
        guard case .idle = state else { return }

        let sessionID = UUID()
        let browser = makeBrowser()
        let callbacks = CallbackBridge()
        let eventConsumerTask = Task { @ButtonHeistActor [weak self, callbacks, sessionID] in
            for await event in callbacks.events {
                guard callbacks.isActive else { break }
                guard let self else { return }
                self.handleBrowserEvent(event)
            }
            guard let terminalReason = callbacks.terminalReason else { return }
            switch terminalReason {
            case .overflow:
                self?.handleEventStreamOverflow(sessionID: sessionID)
            case .finished, .continuationTerminated:
                return
            }
        }

        state = .active(Session(
            id: sessionID,
            browser: browser,
            callbacks: callbacks,
            eventConsumerTask: eventConsumerTask,
            registry: DiscoveryRegistry(),
            reachabilityTask: nil,
            browserPhase: .setup
        ))
        let receiveBrowserEvent: @Sendable (BrowserEvent) -> Void = { [weak browser, callbacks] event in
            guard case .overflow = callbacks.yield(event) else { return }
            browser?.invalidate()
        }
        browser.start(
            queue: browserQueue,
            onResultsChanged: { results, changes in
                receiveBrowserEvent(.resultsChanged(results, changes: changes))
            },
            onStateChanged: { state in
                receiveBrowserEvent(.stateChanged(state))
            }
        )
    }

    func stop() {
        guard case .active(let session) = state else { return }
        state = .idle
        session.invalidate()
    }

    private func handleBrowserEvent(_ event: BrowserEvent) {
        switch event {
        case .resultsChanged(_, let changes):
            handleResults(changes)
        case .stateChanged(let state):
            handleStateUpdate(state)
        }
    }

    private func handleStateUpdate(_ state: DeviceDiscoveryBrowserState) {
        guard case .active(var session) = self.state else { return }

        switch state {
        case .ready:
            session.browserPhase = .ready
            self.state = .active(session)
            onEvent?(.stateChanged(isReady: true))
            startReachabilityValidation(sessionID: session.id)
        case .setup, .waiting:
            session.browserPhase = state == .setup ? .setup : .waiting
            session.reachabilityTask?.cancel()
            session.reachabilityTask = nil
            self.state = .active(session)
            onEvent?(.stateChanged(isReady: false))
        case .failed(let description):
            finishTerminalBrowserState(
                session,
                failure: .connectionFailed("Bonjour discovery failed: \(description)")
            )
        case .cancelled:
            finishTerminalBrowserState(
                session,
                failure: .connectionFailed("Bonjour discovery was cancelled")
            )
        }
    }

    private func handleEventStreamOverflow(sessionID: UUID) {
        guard case .active(let session) = state,
              session.id == sessionID else { return }
        finishTerminalBrowserState(
            session,
            failure: .discoveryBacklogOverflow(capacity: Self.callbackBufferLimit)
        )
    }

    private func finishTerminalBrowserState(
        _ session: Session,
        failure: HandoffConnectionError
    ) {
        state = .idle
        session.invalidate()
        onEvent?(.failed(failure))
    }

    private func handleResults(_ changes: Set<NWBrowser.Result.Change>) {
        guard case .active(var session) = state else { return }
        for change in changes {
            switch change {
            case .added(let result):
                if let device = makeDevice(from: result) {
                    let mutations = session.registry.recordFound(device)
                    state = .active(session)
                    apply(mutations)
                }
            case .removed(let result):
                if case let .service(name, _, _, _) = result.endpoint,
                   let deviceID = try? DiscoveryDeviceID(validating: name) {
                    let mutations = session.registry.recordLost(deviceID)
                    state = .active(session)
                    apply(mutations)
                }
            case .changed(let old, let new, _):
                if case let .service(oldName, _, _, _) = old.endpoint,
                   case let .service(newName, _, _, _) = new.endpoint,
                   oldName != newName,
                   let oldDeviceID = try? DiscoveryDeviceID(validating: oldName) {
                    let mutations = session.registry.recordLost(oldDeviceID)
                    state = .active(session)
                    apply(mutations)
                }
                if let device = makeDevice(from: new) {
                    let mutations = session.registry.recordFound(device)
                    state = .active(session)
                    apply(mutations)
                }
            case .identical:
                break
            @unknown default:
                logger.warning("Unknown change type")
            }
        }
    }

    private func apply(_ mutations: [DiscoveryMutation]) {
        for mutation in mutations {
            switch mutation {
            case .found(let device):
                onEvent?(.found(device))
            case .lost(let device):
                onEvent?(.lost(device))
            }
        }
    }

    private func startReachabilityValidation(sessionID: UUID) {
        guard case .active(var session) = state,
              session.id == sessionID,
              session.browserPhase == .ready else { return }
        session.reachabilityTask?.cancel()
        let task = Task { [weak self, sessionID] in
            while !Task.isCancelled {
                guard let self else { return }
                guard await Task.cancellableSleep(for: .seconds(self.reachabilityValidationInterval)) else { return }
                guard !Task.isCancelled else { return }
                await self.validateVisibleDevicesReachability(sessionID: sessionID)
            }
        }
        session.reachabilityTask = task
        state = .active(session)
    }

    private func validateVisibleDevicesReachability(sessionID: UUID) async {
        guard case .active(let session) = state,
              session.id == sessionID,
              session.browserPhase == .ready else { return }
        let visibleDevices = session.registry.devices
        guard !visibleDevices.isEmpty else { return }

        let unreachableDeviceIDs = await withTaskGroup(of: DiscoveryDeviceID?.self) { group in
            for device in visibleDevices {
                group.addTask {
                    await device.isReachable(timeout: 0.75) ? nil : device.id
                }
            }

            var unreachable: [DiscoveryDeviceID] = []
            for await deviceID in group {
                if let deviceID {
                    unreachable.append(deviceID)
                }
            }
            return unreachable
        }

        guard case .active(var session) = state,
              session.id == sessionID else {
            return
        }
        for deviceID in unreachableDeviceIDs {
            let mutations = session.registry.recordLost(deviceID)
            state = .active(session)
            apply(mutations)
        }
    }
}
