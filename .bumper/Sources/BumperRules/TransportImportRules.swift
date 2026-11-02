import BumperBowlingCore

private let tlsBoundary = "ButtonHeist/Sources/TheScore/Core/TLSPreSharedKeyMaterial.swift"
private let transportFiles: Set<String> = [
    tlsBoundary,
    "ButtonHeist/Sources/ButtonHeistSupport/NetworkTransportFailure.swift",
    "ButtonHeist/Sources/TheButtonHeist/TheHandoff/DeviceDiscovery.swift",
    "ButtonHeist/Sources/TheButtonHeist/TheHandoff/DeviceDiscoveryAdvertisement.swift",
    "ButtonHeist/Sources/TheInsideJob/Server/ServerTransport.swift",
]

public enum TransportImportOwnershipRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.transport_import_ownership",
        summary: "Network imports stay at transport boundaries."
    )
    public static var body: SyntaxCheck {
        Rules.importOwnership(
            ["Network", "FoundationNetworking"],
            allowed: .files(transportFiles)
                .union(.under("ButtonHeist/Sources/TheButtonHeist/TheHandoff/NetworkBoundary"))
                .union(.under("ButtonHeist/Sources/TheInsideJob/Server/NetworkBoundary"))
        )
    }
}

public enum SecurityImportOwnershipRule: SyntaxRule {
    public static let metadata = RuleMetadata(
        id: "buttonheist.security_import_ownership",
        summary: "Security imports stay in the shared TLS boundary."
    )
    public static var body: SyntaxCheck {
        Rules.importOwnership(["Security"], allowed: .files([tlsBoundary]))
    }
}
