import ButtonHeistTestSupport
import XCTest
@_spi(ButtonHeistTooling) @testable import ButtonHeist

final class PrivateStorageTests: XCTestCase {

    func testBaseDirectoryUsesExplicitStorageDirectory() {
        let directory = PrivateStorage.resolveBaseDirectory(environment: environment([
            .buttonheistStorageDirectory: "/tmp/buttonheist-storage"
        ]))

        XCTAssertEqual(directory.path, "/tmp/buttonheist-storage")
    }

    func testBaseDirectoryUsesXDGDataHomeWhenStorageDirectoryIsMissing() {
        let directory = PrivateStorage.resolveBaseDirectory(environment: environment([
            .xdgDataHome: "/tmp/xdg-data"
        ]))

        XCTAssertEqual(directory.path, "/tmp/xdg-data/buttonheist")
    }

    func testBaseDirectoryPrefersStorageDirectoryOverXDGDataHome() {
        let directory = PrivateStorage.resolveBaseDirectory(environment: environment([
            .buttonheistStorageDirectory: "/tmp/buttonheist-storage",
            .xdgDataHome: "/tmp/xdg-data"
        ]))

        XCTAssertEqual(directory.path, "/tmp/buttonheist-storage")
    }

    func testWritePrivateDataReplacesExistingFileWithPrivatePermissions() throws {
        try withTemporaryDirectory(prefix: "private-storage") { directory in
            let url = directory.appendingPathComponent("driver-id")
            try PrivateStorage.writePrivateData(Data("old".utf8), to: url)

            try PrivateStorage.writePrivateData(Data("new".utf8), to: url)

            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
            XCTAssertEqual(try permissions(at: url), 0o600)
        }
    }

    func testWritePrivateDataPreservesExistingFileWhenReplacementFails() throws {
        try withTemporaryDirectory(prefix: "private-storage") { directory in
            let url = directory.appendingPathComponent("driver-id")
            try PrivateStorage.writePrivateData(Data("old".utf8), to: url)
            var replacementURL: URL?

            XCTAssertThrowsError(try PrivateStorage.writePrivateData(
                Data("new".utf8),
                to: url,
                replaceItem: { _, replacement in
                    replacementURL = replacement
                    throw ReplacementFailure.failed
                }
            ))

            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old")
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(replacementURL).path))
        }
    }

    private func environment(_ values: [StorageEnvironmentKey: String]) -> StorageEnvironment {
        StorageEnvironment(testValues: values)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int) & 0o777
    }

    private enum ReplacementFailure: Error {
        case failed
    }
}
