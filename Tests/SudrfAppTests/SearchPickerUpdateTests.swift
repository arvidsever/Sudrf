import Combine
import XCTest
@testable import SudrfApp
@testable import SudrfKit

@MainActor
final class SearchPickerUpdateTests: XCTestCase {
    func testPickerDoesNotPublishUntilCallbackReturns() async {
        let model = SearchModel()
        model.tier = .supreme
        await model.resolveCourts()
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        model.selectFromPicker(.branch(.military))
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(model.branch, .general)
        await drainPicker()
        XCTAssertEqual(model.branch, .military)
        XCTAssertGreaterThan(publications, 0)
        withExtendedLifetime(subscription) {}
    }

    func testQueuedChoicesPreserveOrderAndReturnToOriginalValue() async {
        let model = SearchModel()
        model.tier = .supreme
        await model.resolveCourts()
        model.selectFromPicker(.branch(.military))
        model.selectFromPicker(.branch(.general))
        model.selectFromPicker(.tier(.subject))
        model.selectFromPicker(.region("77"))
        await drainPicker()
        await model.resolveCourts()
        XCTAssertEqual(model.branch, .general)
        XCTAssertEqual(model.tier, .subject)
        XCTAssertEqual(model.region, "77")
        XCTAssertEqual(model.selectedCourt?.seatRegionCode, "77")
    }

    func testUnavailableCourtAndCartotekaAreNotApplied() async {
        let model = SearchModel()
        model.tier = .subject
        await model.resolveCourts()
        let oldCourt = model.selectedCourtID
        model.selectFromPicker(.tier(.supreme))
        model.selectFromPicker(.court(oldCourt))
        model.selectFromPicker(.cartoteka("not-a-cartoteka"))
        await drainPicker()
        await model.resolveCourts()
        XCTAssertEqual(model.tier, .supreme)
        XCTAssertEqual(model.region, "")
        XCTAssertEqual(model.selectedCourtID, "")
        XCTAssertNotEqual(model.cartotekaId, "not-a-cartoteka")
    }

    func testPendingSelectionPreventsStartingWorkForOldScope() async {
        let model = SearchModel()
        model.tier = .supreme
        await model.resolveCourts()
        let row = CaseSearchResult(caseNumber: "2-1/2026")
        model.results = [row]
        model.selectFromPicker(.branch(.military))
        await model.runSearch()
        await model.openCard(row)
        await model.openMovement(row)
        XCTAssertEqual(model.status, "Верховный Суд РФ — задел на будущее: у него отдельный портал (vsrf.ru), парсинг ещё не подключён.")
        XCTAssertNil(model.selectedResultID)
        await drainPicker()
        XCTAssertTrue(model.results.isEmpty)
    }

    func testSameSelectionDoesNotClearExistingResults() async {
        let model = SearchModel()
        let row = CaseSearchResult(caseNumber: "2-1/2026")
        model.results = [row]
        model.selectFromPicker(.branch(.general))
        await drainPicker()
        XCTAssertEqual(model.results.count, 1)
    }

    private func drainPicker() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
