import BumperBowlingCore
import Foundation
import Testing

// shortcut: Bumper 0.6 drops unowned files before evaluation, remove this filesystem guard after upstream #55.
private func sourceOwnershipFailures(root: URL, configuration: ArchitectureConfiguration) throws -> [String] {
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    let rules = try ArchitectureRules(configuration: configuration)
    var failures: [String] = []
    var readError: (any Error)?
    guard let entries = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
        errorHandler: { _, error in readError = error; return false }
    ) else { throw CocoaError(.fileReadUnknown) }
    for case let url as URL in entries {
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
        let path = try RelativeFilePath(String(filePath.dropFirst(root.path.count + 1)))
        if rules.excludedPaths.contains(where: { $0.contains(path) }) {
            entries.skipDescendants()
            continue
        }
        guard url.pathExtension == "swift", rules.includes(path),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let owners = rules.components.filter { component in component.paths.contains { $0.contains(path) } }
        if owners.count != 1 {
            failures.append("\(path.rawValue): expected one component owner, found \(owners.count)")
        }
    }
    if let readError { throw readError }
    return failures.sorted()
}

@Suite("Source ownership coverage")
struct SourceOwnershipTests {
    @Test
    func includedProductionSwiftFilesHaveExactlyOneOwner() throws {
        let path = try #require(ProcessInfo.processInfo.environment["BUTTONHEIST_SOURCE_ROOT"])
        let failures = try sourceOwnershipFailures(root: URL(fileURLWithPath: path), configuration: bumper.architecture)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test
    func coverageRejectsUnownedAndOverlappingFilesButHonorsExclusionsAndNativeSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Sources/Core/Owned.swift", "Sources/New/Unowned.swift", "Sources/Ignored/Excluded.swift",
                     "Sources/Native/Bootstrap.m"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "".write(to: file, atomically: true, encoding: .utf8)
        }
        let configuration = ArchitectureConfiguration(
            excludedPaths: ["Sources/Ignored"],
            components: [ComponentConfiguration(name: "core", paths: ["Sources/Core"])]
        )
        let missingOwners = try sourceOwnershipFailures(root: root, configuration: configuration)
        #expect(missingOwners == [
            "Sources/New/Unowned.swift: expected one component owner, found 0",
        ])
        let overlap = ArchitectureConfiguration(components: [
            ComponentConfiguration(name: "all", paths: ["Sources"]),
            ComponentConfiguration(name: "core", paths: ["Sources/Core"]),
        ])
        let overlappingOwners = try sourceOwnershipFailures(root: root, configuration: overlap)
        #expect(overlappingOwners == [
            "Sources/Core/Owned.swift: expected one component owner, found 2",
        ])
    }
}
