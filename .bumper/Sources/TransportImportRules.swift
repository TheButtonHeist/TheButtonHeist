import BumperBowlingCore

private let tlsBoundary: RelativeFilePath = "ButtonHeist/Sources/TheScore/Core/TLSPreSharedKeyMaterial.swift"

let transportImportRules = RuleSet {
    Rules.importOwnership(
        ["Network", "FoundationNetworking"],
        allowed: .under("ButtonHeist/Sources/TheButtonHeist/TheHandoff/NetworkBoundary")
            .union(.under("ButtonHeist/Sources/TheInsideJob/Server/NetworkBoundary"))
            .union(.files([
                tlsBoundary,
                "ButtonHeist/Sources/ButtonHeistSupport/NetworkTransportFailure.swift",
                "ButtonHeist/Sources/TheButtonHeist/TheHandoff/DeviceDiscovery.swift",
                "ButtonHeist/Sources/TheButtonHeist/TheHandoff/DeviceDiscoveryAdvertisement.swift",
                "ButtonHeist/Sources/TheInsideJob/Server/ServerTransport.swift",
            ])),
        id: "buttonheist.transport_import_ownership"
    )
    Rules.importOwnership(
        ["Security"], allowed: .files([tlsBoundary]),
        id: "buttonheist.security_import_ownership"
    )
}
