import XCTest
@testable import Ymir

final class GatewayLogTests: XCTestCase {
    private var directory: URL!
    private var logURL: URL { directory.appendingPathComponent("logs/copilot-api.log") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ymir-log-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRestartAppendsWithoutLosingPreviousRequests() throws {
        let first = try GatewayLog.open(at: logURL)
        try first.write(contentsOf: Data("request-before-restart\n".utf8))
        try first.close()
        let second = try GatewayLog.open(at: logURL)
        try second.write(contentsOf: Data("request-after-restart\n".utf8))
        try second.close()
        XCTAssertEqual(try String(contentsOf: logURL), "request-before-restart\nrequest-after-restart\n")
    }

    func testOverlappingHandlesAppendWithoutOverwritingEachOther() throws {
        let first = try GatewayLog.open(at: logURL)
        let second = try GatewayLog.open(at: logURL)
        defer { try? first.close(); try? second.close() }
        try first.write(contentsOf: Data("first\n".utf8))
        try second.write(contentsOf: Data("second\n".utf8))
        try first.write(contentsOf: Data("third\n".utf8))
        XCTAssertEqual(try String(contentsOf: logURL), "first\nsecond\nthird\n")
    }

    func testStartupRotationRetainsThreePreviousLogsInOrder() throws {
        for index in 1...5 {
            let handle = try GatewayLog.open(at: logURL, maxBytes: 1)
            try handle.write(contentsOf: Data("session-\(index)".utf8))
            try handle.close()
        }
        XCTAssertEqual(try String(contentsOf: logURL), "session-5")
        for index in 1...3 {
            XCTAssertEqual(try String(contentsOfFile: logURL.path + ".\(index)"), "session-\(5 - index)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path + ".4"))
    }

    func testNewLogIsReadableOnlyByOwner() throws {
        let handle = try GatewayLog.open(at: logURL)
        try handle.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
