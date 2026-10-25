import Foundation

import TheScore

final class ScreenshotArtifactWriter: Sendable {

    enum Destination: Sendable {
        case automaticPrivateArtifact
        case userExplicitOutputPath(String)
    }

    private let baseDirectory: URL

    init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory ?? PrivateStorage.resolveBaseDirectory()
    }

    @concurrent
    func writeScreenshot(
        base64Data: String,
        destination: Destination,
        command: TheFence.Command
    ) async throws -> URL {
        let data = try decodeScreenshotData(base64Data)
        switch destination {
        case .automaticPrivateArtifact:
            return try writeStandaloneScreenshot(data, command: command)
        case .userExplicitOutputPath(let outputPath):
            return try write(data, toOutputPath: outputPath)
        }
    }

    private func write(_ data: Data, toOutputPath outputPath: String) throws -> URL {
        guard let resolvedURL = outputPath.validatedOutputURL() else {
            throw StorageError.unsafePath(outputPath)
        }
        try data.write(to: resolvedURL, options: .atomic)
        return resolvedURL
    }

    private func writeStandaloneScreenshot(_ data: Data, command: TheFence.Command) throws -> URL {
        let subdirectory = baseDirectory.appendingPathComponent("screenshots")
        let filename = "\(PrivateStorage.timestampString())-\(UUID().uuidString)-\(command.rawValue).png"
        let fileURL = subdirectory.appendingPathComponent(filename)
        try PrivateStorage.writePrivateData(data, to: fileURL)
        return fileURL
    }

    private func decodeScreenshotData(_ base64Data: String) throws -> Data {
        guard let data = Data(base64Encoded: base64Data) else {
            throw StorageError.base64DecodingFailed
        }
        return data
    }
}
