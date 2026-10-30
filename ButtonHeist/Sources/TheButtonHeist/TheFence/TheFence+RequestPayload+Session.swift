import Foundation
import TheScore

extension TheFence {

    enum ConnectRequest {
        case current
        case replacement(target: DeviceResolutionTarget, token: SessionAuthToken?)
    }

    func decodeConnectRequest(_ arguments: CommandArgumentEnvelope) throws -> ConnectRequest {
        let device = try arguments.value(FenceParameters.device)
        let targetName = try arguments.value(FenceParameters.connectionTarget).map(TargetName.init(rawValue:))
        let token: SessionAuthToken? = try arguments.value(for: "token").map {
            try HeistValuePayloadDecoder.decode($0, field: arguments.field("token"), as: SessionAuthToken.self)
        }
        if let device {
            return .replacement(target: DeviceResolutionTarget(filter: device), token: token)
        }
        guard let targetName else { return .current }
        guard let fileConfig = config.fileConfig else {
            throw FenceError.invalidRequest(
                "No config file loaded. Create .buttonheist.json or ~/.config/buttonheist/config.json"
            )
        }
        guard let target = fileConfig.targets[targetName] else {
            let available = fileConfig.targets.keys.map(\.rawValue).sorted()
            throw FenceError.invalidRequest(
                "Unknown target '\(targetName.rawValue)'. Available: \(available.joined(separator: ", "))"
            )
        }
        return .replacement(
            target: DeviceResolutionTarget(config: target, named: targetName),
            token: try token ?? target.token.map(SessionAuthToken.init(validating:))
        )
    }

}
