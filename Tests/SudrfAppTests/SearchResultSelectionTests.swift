import XCTest
import SudrfKit
@testable import SudrfApp
@testable import CaptchaSolver

final class SearchResultSelectionTests: XCTestCase {
    func testStableIDPrefersCardURLAndFallbackIsNonEmpty() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/modules.php?case_id=1"))
        let withURL = CaseSearchResult(caseNumber: "2-1/2026", cardURL: url)
        XCTAssertEqual(withURL.stableID, "url:\(url.absoluteString)")

        let fallback = CaseSearchResult(caseNumber: "2-2/2026",
                                        receiptDate: "01.02.2026",
                                        judge: "Иванов И. И.",
                                        result: "Решение")
        XCTAssertFalse(fallback.stableID.isEmpty)
    }

    @MainActor
    func testSelectedResultUsesStableIDAndClearsWhenRowsDisappear() throws {
        let model = SearchModel()
        let url = try XCTUnwrap(URL(string: "https://example.test/card?id=1"))
        let row = CaseSearchResult(caseNumber: "2-1/2026", cardURL: url)

        model.results = [row]
        model.selectedResultIndex = 0

        XCTAssertEqual(model.selectedResultID, row.stableID)
        XCTAssertEqual(model.selectedResult?.caseNumber, "2-1/2026")

        model.results = []

        XCTAssertNil(model.selectedResult)
        XCTAssertNil(model.selectedResultIndex)
    }

    @MainActor
    func testActionsIgnoreStaleRows() async throws {
        let model = SearchModel()
        let url = try XCTUnwrap(URL(string: "https://example.test/card?id=stale"))
        let stale = CaseSearchResult(caseNumber: "2-1/2026", cardURL: url)

        model.results = []

        await model.openCard(stale)
        await model.openMovement(stale)

        XCTAssertNil(model.selectedResultID)
        XCTAssertNil(model.selectedResult)
    }

    @MainActor
    func testCaptchaCorpusBootstrapUsesSubmittedTokenAfterStoreOverwrite() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SearchModelCorpusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let corpus = CorpusStore(baseDir: dir)
        let model = SearchModel(corpusStore: corpus)
        let host = "court.sudrf.ru"
        model.lastSubmittedCaptcha = (
            png: Data([0x01]),
            token: CaptchaToken(value: "sent-token", id: "sent-id")
        )
        await CaptchaTokenStore.shared.store(
            CaptchaToken(value: "overwritten-token", id: "new-id"), domain: host
        )
        defer { Task { await CaptchaTokenStore.shared.invalidate(domain: host) } }

        await model.bootstrapCaptchaToCorpus(
            host: host,
            results: [CaseSearchResult(caseNumber: "2-1/2026")]
        )

        let files = try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("solved-numeric"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].lastPathComponent.hasPrefix("sent-token_"))
        XCTAssertNil(model.lastSubmittedCaptcha)
    }
}
