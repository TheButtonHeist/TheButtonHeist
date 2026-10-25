/// A single change in the discovered device list.
enum DiscoveryMutation: Equatable {
    case found(DiscoveredDevice)
    case lost(DiscoveredDevice)
}

/// Deduplicates Bonjour advertisements by device identity, tracking the newest per identity.
///
/// **Ownership.** Ephemeral index, owned by `DeviceDiscovery` (TheHandoff), for
/// the span of a discovery scan. Key: Bonjour service name, plus device identity
/// for the visible-selection index. Invalidation: `recordLost` evicts a service
/// name; a newer advertisement supersedes an older one for the same identity.
/// It cannot be derived from a result: the network emits raw add/remove
/// events and this is the dedup state that turns them into a stable device list.
/// See `docs/ARCHITECTURE.md#state-has-one-owner`.
struct DiscoveryRegistry {
    struct Advertisement: Sendable {
        let deviceID: DiscoveryDeviceID
        let device: DiscoveredDevice
        let identity: DiscoveryIdentity
        let sequence: UInt64
    }

    private var advertisementsByDeviceID: [DiscoveryDeviceID: Advertisement] = [:]
    private var visibleDeviceIDByIdentity: [DiscoveryIdentity: DiscoveryDeviceID] = [:]
    private var nextSequence: UInt64 = 0

    var visibleAdvertisements: [Advertisement] {
        visibleDeviceIDByIdentity.values
            .compactMap { advertisementsByDeviceID[$0] }
            .sorted { lhs, rhs in lhs.sequence > rhs.sequence }
    }

    var devices: [DiscoveredDevice] {
        visibleAdvertisements.map(\.device)
    }

    mutating func recordFound(_ device: DiscoveredDevice) -> [DiscoveryMutation] {
        nextSequence &+= 1

        let advertisement = Advertisement(
            deviceID: device.id,
            device: device,
            identity: device.discoveryIdentity,
            sequence: nextSequence
        )
        advertisementsByDeviceID[device.id] = advertisement

        let identity = advertisement.identity
        guard let visibleDeviceID = visibleDeviceIDByIdentity[identity] else {
            visibleDeviceIDByIdentity[identity] = device.id
            return [.found(device)]
        }

        guard visibleDeviceID != device.id else {
            return []
        }

        if let previous = advertisementsByDeviceID[visibleDeviceID] {
            visibleDeviceIDByIdentity[identity] = device.id
            return [.lost(previous.device), .found(device)]
        }

        visibleDeviceIDByIdentity[identity] = device.id
        return [.found(device)]
    }

    mutating func recordLost(_ deviceID: DiscoveryDeviceID) -> [DiscoveryMutation] {
        guard let removed = advertisementsByDeviceID.removeValue(forKey: deviceID) else {
            return []
        }

        let identity = removed.identity
        guard visibleDeviceIDByIdentity[identity] == deviceID else {
            return []
        }

        if let replacement = newestAdvertisement(for: identity) {
            visibleDeviceIDByIdentity[identity] = replacement.deviceID
            return [.lost(removed.device), .found(replacement.device)]
        }

        visibleDeviceIDByIdentity.removeValue(forKey: identity)
        return [.lost(removed.device)]
    }

    mutating func recordLost(_ advertisement: Advertisement) -> [DiscoveryMutation] {
        guard advertisementsByDeviceID[advertisement.deviceID]?.sequence == advertisement.sequence else {
            return []
        }
        return recordLost(advertisement.deviceID)
    }

    private func newestAdvertisement(for identity: DiscoveryIdentity) -> Advertisement? {
        advertisementsByDeviceID.values
            .filter { $0.identity == identity }
            .max { lhs, rhs in lhs.sequence < rhs.sequence }
    }
}
