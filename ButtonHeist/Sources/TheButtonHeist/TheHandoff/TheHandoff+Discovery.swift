import Foundation
import os.log

import TheScore

private let discoveryLogger = ButtonHeistLog.logger(.handoff(.discovery))

@ButtonHeistActor
extension TheHandoff {
    func startDiscovery() {
        guard !discovery.isActive else { return }
        discovery.onEvent = { [weak self] event in
            self?.observeDiscovery(event)
        }
        discovery.start()
    }

    func stopDiscovery() {
        discovery.stop()
        discovery.onEvent = nil
    }

    /// Discover devices and validate each deduped advertisement as it appears.
    func discoverReachableDevices(
        timeout: TimeInterval = 3.0,
        probeTimeout: TimeInterval = 0.5,
        retryInterval: TimeInterval = 0.2
    ) async -> [DiscoveredDevice] {
        let startedTemporaryDiscovery = !discovery.isActive
        if startedTemporaryDiscovery {
            startDiscovery()
        }
        defer {
            if startedTemporaryDiscovery {
                stopDiscovery()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var reachableIDs: Set<DiscoveryDeviceID> = []
        var nextProbeAt: [DiscoveryDeviceID: Date] = [:]

        while Date() < deadline {
            let snapshot = discovery.discoveredDevices
            let currentIDs = Set(snapshot.map(\.id))
            reachableIDs.formIntersection(currentIDs)
            nextProbeAt = nextProbeAt.filter { currentIDs.contains($0.key) }

            let now = Date()
            let dueDevices = snapshot.filter { device in
                !reachableIDs.contains(device.id) &&
                    (nextProbeAt[device.id] ?? .distantPast) <= now
            }
            if !dueDevices.isEmpty {
                let retryAt = Date().addingTimeInterval(retryInterval)
                let reachable = await dueDevices.reachable(
                    token: serverMessageRouter.authToken,
                    timeout: probeTimeout
                )
                let reachableDeviceIDs = Set(reachable.map(\.id))
                for device in dueDevices {
                    if reachableDeviceIDs.contains(device.id) {
                        reachableIDs.insert(device.id)
                        nextProbeAt[device.id] = nil
                    } else {
                        nextProbeAt[device.id] = retryAt
                    }
                }
            }

            guard await Task.cancellableSleep(for: .milliseconds(100)) else { break }
        }

        return discovery.discoveredDevices.filter { reachableIDs.contains($0.id) }
    }

    private func observeDiscovery(_ event: DiscoveryEvent) {
        switch event {
        case .found(let device):
            discoveryLogger.info("Device found: \(device.name)")
            onDeviceFound?(device)
        case .lost(let device):
            discoveryLogger.info("Device lost: \(device.name)")
            onDeviceLost?(device)
        case .stateChanged:
            break
        case .failed(let failure):
            discoveryLogger.error("Discovery failed: \(failure.localizedDescription)")
            discovery.onEvent = nil
        }
    }
}
