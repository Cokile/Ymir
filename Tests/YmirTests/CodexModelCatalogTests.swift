import XCTest
@testable import Ymir

final class CodexModelCatalogTests: XCTestCase {
    private var directory: URL!
    private var destination: URL { directory.appendingPathComponent("catalog/models.json") }
    private let valid = Data(#"{"models":[{"slug":"gpt-6-astra","visibility":"list","context_window":1000000,"max_context_window":1050000,"model_messages":{"instructions_template":"Keep instructions unchanged."}}]}"#.utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPersistsCompleteCatalogWithoutChangingMetadata() throws {
        XCTAssertTrue(try CodexModelCatalog.save(valid, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), valid)
    }

    func testUnchangedCatalogDoesNotRewriteFile() throws {
        try CodexModelCatalog.save(valid, to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertFalse(try CodexModelCatalog.save(valid, to: destination))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date,
                       attributes[.modificationDate] as? Date)
    }

    func testRejectsBrokenCatalogsWithoutReplacingLastGoodCopy() throws {
        try CodexModelCatalog.save(valid, to: destination)
        for json in [
            "not JSON", #"{"models":[]}"#, #"{"data":[{"id":"gpt-6-astra"}]}"#,
            #"{"models":[{"slug":""}]}"#, #"{"models":[{}]}"#,
            #"{"models":[{"slug":"a"},{"slug":"a"}]}"#,
            #"{"models":[{"slug":"a","visibility":"hide"}]}"#
        ] {
            XCTAssertThrowsError(try CodexModelCatalog.save(Data(json.utf8), to: destination), json)
            XCTAssertEqual(try Data(contentsOf: destination), valid)
        }
    }

    func testRejectsOversizedCatalogWithoutReplacingLastGoodCopy() throws {
        try CodexModelCatalog.save(valid, to: destination)
        XCTAssertThrowsError(try CodexModelCatalog.save(Data(repeating: 32, count: 1024 * 1024 + 1), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), valid)
    }
}
