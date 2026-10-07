import Foundation

enum StorageEnvironmentKey: String, Sendable {
    case buttonheistStorageDirectory = "BUTTONHEIST_STORAGE_DIR"
    case xdgDataHome = "XDG_DATA_HOME"
}

struct StorageEnvironment: Equatable, Sendable {
    static let empty = StorageEnvironment()
    static var current: StorageEnvironment {
        StorageEnvironment(rawValues: ProcessInfo.processInfo.environment)
    }

    private let values: [StorageEnvironmentKey: String]

    init(
        storageDirectory: String? = nil,
        xdgDataHome: String? = nil
    ) {
        var values: [StorageEnvironmentKey: String] = [:]
        values[.buttonheistStorageDirectory] = storageDirectory
        values[.xdgDataHome] = xdgDataHome
        self.values = values
    }

    init(testValues values: [StorageEnvironmentKey: String]) {
        self.values = values
    }

    fileprivate init(rawValues: [String: String]) {
        self.values = Dictionary(uniqueKeysWithValues: [
            StorageEnvironmentKey.buttonheistStorageDirectory,
            .xdgDataHome,
        ].compactMap { key in
            rawValues[key.rawValue].map { (key, $0) }
        })
    }

    var storageDirectory: String? {
        values[.buttonheistStorageDirectory]
    }

    var xdgDataHome: String? {
        values[.xdgDataHome]
    }
}

enum PrivateStorage {
    typealias ReplacementOperation = (URL, URL) throws -> Void

    // MARK: - Paths

    static func resolveBaseDirectory(
        environment: StorageEnvironment = .current
    ) -> URL {
        if let override = environment.storageDirectory {
            return URL(fileURLWithPath: override)
        }
        if let xdgDataHome = environment.xdgDataHome {
            return URL(fileURLWithPath: xdgDataHome)
                .appendingPathComponent("buttonheist")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/buttonheist")
    }

    static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }

    // MARK: - Private File I/O

    static func createPrivateDirectory(at directory: URL) throws {
        let fileManager = FileManager.default
        let attributes = PrivateFileAttributes.privateDirectory
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: attributes.foundationAttributes
            )
            try fileManager.setAttributes(attributes.foundationAttributes, ofItemAtPath: directory.path)
        } catch {
            throw StorageError.storage(.directoryCreationFailed(
                path: directory.path,
                reason: String(describing: error)
            ))
        }
    }

    static func createPrivateFile(at url: URL, contents: Data? = nil) throws {
        let fileManager = FileManager.default
        let attributes = PrivateFileAttributes.privateFile
        if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.setAttributes(attributes.foundationAttributes, ofItemAtPath: url.path)
                if let contents {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: contents)
                }
            } catch {
                throw StorageError.storage(.privateFileCreationFailed(
                    path: url.path,
                    reason: String(describing: error)
                ))
            }
            return
        }

        guard fileManager.createFile(
            atPath: url.path,
            contents: contents,
            attributes: attributes.foundationAttributes
        ) else {
            throw StorageError.storage(.privateFileCreationFailed(
                path: url.path,
                reason: "FileManager.createFile returned false"
            ))
        }

        do {
            try fileManager.setAttributes(attributes.foundationAttributes, ofItemAtPath: url.path)
        } catch {
            throw StorageError.storage(.privateFileCreationFailed(
                path: url.path,
                reason: String(describing: error)
            ))
        }
    }

    static func writePrivateData(
        _ data: Data,
        to url: URL,
        replaceItem: ReplacementOperation = defaultReplaceItem
    ) throws {
        let fileManager = FileManager.default
        let attributes = PrivateFileAttributes.privateFile
        try createPrivateDirectory(at: url.deletingLastPathComponent())
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try createPrivateFile(at: temporaryURL, contents: data)
        do {
            if fileManager.fileExists(atPath: url.path) {
                try replaceItem(url, temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
            try fileManager.setAttributes(attributes.foundationAttributes, ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func defaultReplaceItem(destination: URL, replacement: URL) throws {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: replacement)
    }

}

/// FileManager exposes file attributes through an untyped Foundation map. Keep
/// that bridge named and private so storage code stays permission-typed.
private typealias FoundationFileAttributeDictionary = [FileAttributeKey: Any]

private struct PrivateFileAttributes {
    let permissions: PrivateFilePermissions

    static let privateDirectory = PrivateFileAttributes(permissions: .ownerOnlyDirectory)
    static let privateFile = PrivateFileAttributes(permissions: .ownerOnlyFile)

    var foundationAttributes: FoundationFileAttributeDictionary {
        [.posixPermissions: permissions.rawValue]
    }
}

private enum PrivateFilePermissions: Int {
    case ownerOnlyDirectory = 0o700
    case ownerOnlyFile = 0o600
}
