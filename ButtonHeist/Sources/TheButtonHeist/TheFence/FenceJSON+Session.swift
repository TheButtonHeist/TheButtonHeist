import Foundation

import TheScore

struct PublicSessionStateResponse: Encodable {
    let status = PublicResponseStatus.ok
    let connected: Bool
    let phase: String
    let actionTimeoutSeconds: TimeInterval
    let longActionTimeoutSeconds: TimeInterval
    let deviceName: String?
    let appName: String?
    let connectionType: String?
    let shortId: String?
    let lastFailure: PublicSessionFailure?

    init(payload: SessionStatePayload) {
        self.actionTimeoutSeconds = payload.actionTimeoutSeconds
        self.longActionTimeoutSeconds = payload.longActionTimeoutSeconds
        switch payload.state {
        case .disconnected(let failure):
            connected = false
            phase = "disconnected"
            deviceName = nil
            appName = nil
            connectionType = nil
            shortId = nil
            lastFailure = failure.map(PublicSessionFailure.init)
        case .connecting(let failure):
            connected = false
            phase = "connecting"
            deviceName = nil
            appName = nil
            connectionType = nil
            shortId = nil
            lastFailure = failure.map(PublicSessionFailure.init)
        case .connected(let device):
            connected = true
            phase = "connected"
            deviceName = device.deviceName
            appName = device.appName
            connectionType = device.connectionType.rawValue
            shortId = device.shortId?.description
            lastFailure = nil
        case .failed(let failure):
            connected = false
            phase = "failed"
            deviceName = nil
            appName = nil
            connectionType = nil
            shortId = nil
            lastFailure = PublicSessionFailure(payload: failure)
        }
    }
}

struct PublicSessionFailure: Encodable {
    let code: String
    let phase: String
    let retryable: Bool
    let message: String?
    let hint: String?

    init(payload: SessionFailurePayload) {
        self.code = payload.code
        self.phase = payload.phase.rawValue
        self.retryable = payload.retryable
        self.message = payload.message
        self.hint = payload.hint
    }
}

struct PublicPongResponse: Encodable {
    let status = PublicResponseStatus.ok
    let buttonHeistVersion: String
    let appName: String
    let bundleIdentifier: String
    let appVersion: String?
    let appBuild: String?
    let serverInstanceIdentifier: String?
    let serverTimestampMs: Int64?

    init(payload: PongPayload) {
        self.buttonHeistVersion = payload.buttonHeistVersion.description
        self.appName = payload.appName
        self.bundleIdentifier = payload.bundleIdentifier.description
        self.appVersion = payload.appVersion
        self.appBuild = payload.appBuild
        self.serverInstanceIdentifier = payload.serverInstanceIdentifier?.description
        self.serverTimestampMs = payload.serverTimestampMs
    }
}

struct PublicDevicesResponse: Encodable {
    let status = PublicResponseStatus.ok
    let devices: [PublicDiscoveredDevice]

    init(devices: [DiscoveredDevice]) {
        self.devices = devices.map(PublicDiscoveredDevice.init)
    }
}

struct PublicDiscoveredDevice: Encodable {
    let name: String
    let appName: String
    let deviceName: String
    let connectionType: String
    let shortId: String?
    let simulatorUDID: String?

    init(device: DiscoveredDevice) {
        self.name = device.name
        self.appName = device.appName
        self.deviceName = device.deviceName
        self.connectionType = device.connectionType.rawValue
        self.shortId = device.shortId?.description
        self.simulatorUDID = device.simulatorUDID?.description
    }
}

struct PublicTargetsResponse: Encodable {
    let status = PublicResponseStatus.ok
    let targets: [String: PublicTargetConfig]
    let `default`: String?

    init(targets: [TargetName: TargetConfig], defaultTarget: TargetName?) {
        self.targets = Dictionary(uniqueKeysWithValues: targets.map { name, target in
            (name.rawValue, PublicTargetConfig(target: target))
        })
        self.default = defaultTarget?.rawValue
    }
}

struct PublicTargetConfig: Encodable {
    let device: String
    let hasToken: Bool?

    init(target: TargetConfig) {
        self.device = target.device
        self.hasToken = target.token == nil ? nil : true
    }
}
