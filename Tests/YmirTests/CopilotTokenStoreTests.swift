import XCTest
@testable import Ymir

final class CopilotTokenStoreTests: XCTestCase {
    private var directory: URL!
    private var store: CopilotTokenStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ymir-token-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = CopilotTokenStore(tokenURL: directory.appendingPathComponent("github_token"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testMissingTokenIsSignedOutAndRemovalIsIdempotent() throws {
        XCTAssertFalse(store.isSignedIn)
        try store.removeToken()
        try store.removeToken()
        XCTAssertFalse(store.isSignedIn)
    }

    func testEmptyTokenIsSignedOut() throws {
        try Data().write(to: store.tokenURL)
        XCTAssertFalse(store.isSignedIn)
        try store.removeToken()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.tokenURL.path))
    }

    func testTokenIsTrimmedAndWhitespaceOnlyIsSignedOut() throws {
        try Data(" test-token\n".utf8).write(to: store.tokenURL)
        XCTAssertEqual(store.token, "test-token")
        XCTAssertTrue(store.isSignedIn)

        try Data(" \n\t".utf8).write(to: store.tokenURL)
        XCTAssertNil(store.token)
        XCTAssertFalse(store.isSignedIn)
    }

    func testSignOutRemovesOnlyCopilotToken() throws {
        try Data("test-token".utf8).write(to: store.tokenURL)
        let configURL = directory.appendingPathComponent("config.json")
        let otherCredentialsURL = directory.appendingPathComponent("codex_credentials.json")
        let config = Data("{\"setting\":true}".utf8)
        let otherCredentials = Data("test-other-provider".utf8)
        try config.write(to: configURL)
        try otherCredentials.write(to: otherCredentialsURL)

        XCTAssertTrue(store.isSignedIn)
        try store.removeToken()

        XCTAssertFalse(store.isSignedIn)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.tokenURL.path))
        XCTAssertEqual(try Data(contentsOf: configURL), config)
        XCTAssertEqual(try Data(contentsOf: otherCredentialsURL), otherCredentials)
    }

    func testDirectoryAtTokenPathIsNotRemoved() throws {
        try FileManager.default.createDirectory(at: store.tokenURL, withIntermediateDirectories: true)
        let childURL = store.tokenURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: childURL)

        XCTAssertFalse(store.isSignedIn)
        XCTAssertThrowsError(try store.removeToken())
        XCTAssertTrue(FileManager.default.fileExists(atPath: childURL.path))
    }
}
