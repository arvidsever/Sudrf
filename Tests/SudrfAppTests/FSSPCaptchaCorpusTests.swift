import Foundation
import XCTest
@testable import SudrfApp

final class FSSPCaptchaCorpusTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSSPCaptchaCorpusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStoresOnlyAcceptedFiveDigitPairsAndDeduplicatesByImage() async throws {
        let corpus = FSSPCaptchaCorpus(baseDirectory: directory)
        let png = Data([0x89, 0x50, 0x4e, 0x47])

        let shortCode = await corpus.addAccepted(png: png, code: "1234")
        let emptyImage = await corpus.addAccepted(png: Data(), code: "12345")
        XCTAssertNil(shortCode)
        XCTAssertNil(emptyImage)
        let firstResult = await corpus.addAccepted(png: png, code: "12345")
        let duplicateResult = await corpus.addAccepted(png: png, code: "12345")
        let first = try XCTUnwrap(firstResult)
        let duplicate = try XCTUnwrap(duplicateResult)

        XCTAssertEqual(first, duplicate)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("12345_"))
        let count = await corpus.count()
        XCTAssertEqual(count, 1)
    }
}
