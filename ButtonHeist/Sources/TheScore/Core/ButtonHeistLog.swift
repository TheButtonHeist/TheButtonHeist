import OSLog

package enum ButtonHeistLog {
    package enum Channel: Sendable {
        case handoff(Handoff)
        case insideJob(InsideJob)
        case score(Score)
    }

    package enum Handoff: String, Sendable {
        case connection
        case config
        case discovery
        case driverIdentity = "driver-identity"
        case reachability
        case server
        case serverMessage = "server-message"
        case transport
    }

    package enum InsideJob: String, Sendable {
        case accessibility
        case auth
        case autostart
        case server
    }

    package enum Score: String, Sendable {
        case results
    }

    package static func logger(_ channel: Channel) -> Logger {
        Logger(subsystem: channel.subsystem.rawValue, category: channel.category)
    }
}

private extension ButtonHeistLog.Channel {
    var subsystem: ButtonHeistLogSubsystem {
        switch self {
        case .handoff:
            return .handoff
        case .insideJob:
            return .insideJob
        case .score:
            return .score
        }
    }

    var category: String {
        switch self {
        case .handoff(let category):
            return category.rawValue
        case .insideJob(let category):
            return category.rawValue
        case .score(let category):
            return category.rawValue
        }
    }
}

private enum ButtonHeistLogSubsystem: String {
    case handoff = "com.buttonheist.thehandoff"
    case insideJob = "com.buttonheist.theinsidejob"
    case score = "com.buttonheist.thescore"
}
