import Foundation

/// A scratch directory for tests that need to retain files across several operations.
public final class TemporaryDirectoryFixture {
    public let url: URL

    public init(
        prefix: String = "buttonheist-tests",
        rootDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        url = rootDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Runs `body` with a per-test scratch directory under `rootDirectory`.
@discardableResult
public func withTemporaryDirectory<Result>(
    prefix: String,
    rootDirectory: URL = FileManager.default.temporaryDirectory,
    _ body: (URL) throws -> Result
) throws -> Result {
    let directory = rootDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    do {
        let result = try body(directory)
        try removeTemporaryDirectory(directory)
        return result
    } catch {
        try? removeTemporaryDirectory(directory)
        throw error
    }
}

/// Runs async `body` with a per-test scratch directory under `rootDirectory`.
@discardableResult
public func withTemporaryDirectory<Result: Sendable>(
    prefix: String,
    rootDirectory: URL = FileManager.default.temporaryDirectory,
    isolation: isolated (any Actor)? = #isolation,
    _ body: (URL) async throws -> Result
) async throws -> Result {
    let directory = rootDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    do {
        let result = try await body(directory)
        try removeTemporaryDirectory(directory)
        return result
    } catch {
        try? removeTemporaryDirectory(directory)
        throw error
    }
}

/// Runs `body` with a per-test result directory.
@discardableResult
public func withResultDirectory<Result>(
    prefix: String = "buttonheist-results",
    rootDirectory: URL = FileManager.default.temporaryDirectory,
    _ body: (URL) throws -> Result
) throws -> Result {
    try withTemporaryDirectory(prefix: prefix, rootDirectory: rootDirectory, body)
}

/// Runs async `body` with a per-test result directory.
@discardableResult
public func withResultDirectory<Result: Sendable>(
    prefix: String = "buttonheist-results",
    rootDirectory: URL = FileManager.default.temporaryDirectory,
    isolation: isolated (any Actor)? = #isolation,
    _ body: (URL) async throws -> Result
) async throws -> Result {
    try await withTemporaryDirectory(
        prefix: prefix,
        rootDirectory: rootDirectory,
        isolation: isolation,
        body
    )
}

public func resultArtifactURLs(
    in directory: URL,
    matchingSuffix suffix: String = ".json.gz"
) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
        throw ResultDirectoryFixtureError.unreadableDirectory(directory.path)
    }

    var urls: [URL] = []
    for case let url as URL in enumerator {
        guard url.lastPathComponent.hasSuffix(suffix) else { continue }
        let isRegularFile = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile ?? false
        guard isRegularFile else { continue }
        urls.append(url)
    }
    return urls.sorted { $0.path < $1.path }
}

public func assertSingleResultArtifactURL(
    in directory: URL,
    matchingSuffix suffix: String = ".json.gz"
) throws -> URL {
    let urls = try resultArtifactURLs(in: directory, matchingSuffix: suffix)
    guard urls.count == 1 else {
        throw ResultDirectoryFixtureError.unexpectedResultCount(
            expected: 1,
            actualPaths: urls.map(\.path)
        )
    }
    return urls[0]
}

public enum ResultDirectoryFixtureError: Error, Equatable, CustomStringConvertible, Sendable {
    case unreadableDirectory(String)
    case unexpectedResultCount(expected: Int, actualPaths: [String])

    public var description: String {
        switch self {
        case .unreadableDirectory(let path):
            return "Could not enumerate result directory at \(path)"
        case .unexpectedResultCount(let expected, let actualPaths):
            return "Expected \(expected) result artifact(s), found \(actualPaths.count): \(actualPaths.joined(separator: ", "))"
        }
    }
}

private func removeTemporaryDirectory(_ directory: URL) throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
}
