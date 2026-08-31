import XCTest
@testable import SudrfKit
@testable import SudrfApp

@MainActor
final class RegionCourtSyncTests: XCTestCase {
    func testTerritorialCourtSeatRegionsAreExplicit() {
        XCTAssertEqual(CourtDirectory.appealCourts.map(\.seatRegionCode), ["77", "78", "23", "52", "54"])
        XCTAssertEqual(CourtDirectory.cassationCourts.map(\.seatRegionCode),
                       ["64", "77", "78", "23", "26", "63", "74", "42", "25"])
    }

    func testRegionSelectsJurisdictionCourt() async {
        let model = SearchModel()
        model.tier = .appeal
        model.region = "11"
        await model.resolveCourts()
        XCTAssertEqual(model.selectedCourt?.domain, "2ap.sudrf.ru")

        model.region = "01"
        await model.resolveCourts()
        XCTAssertEqual(model.selectedCourt?.domain, "3ap.sudrf.ru")
    }

    func testRegionSelectsSubjectCourt() async {
        let model = SearchModel()
        model.tier = .subject
        model.region = "11"
        await model.resolveCourts()

        XCTAssertEqual(model.selectedCourt?.domain, "vs--komi.sudrf.ru")
    }

    func testRegionSelectsCassationCourt() async {
        let model = SearchModel()
        model.tier = .cassation
        model.region = "11"
        await model.resolveCourts()
        XCTAssertEqual(model.selectedCourt?.domain, "3kas.sudrf.ru")
    }

    func testUnsupportedSubjectCourtStaysDisabledAfterAutoSelection() async {
        let model = SearchModel()
        model.tier = .subject
        model.region = "52"
        await model.resolveCourts()

        XCTAssertEqual(model.selectedCourt?.domain, "nnoblsud.ru")
        XCTAssertFalse(model.selectedCourt?.supportsSearch ?? true)
        XCTAssertNotNil(model.selectedCourt?.unsupportedReason)
    }

    func testManualTerritorialCourtSelectsItsSeatRegion() async throws {
        let model = SearchModel()
        model.tier = .cassation
        await model.resolveCourts()

        let first = try XCTUnwrap(model.courts.first { $0.domain == "1kas.sudrf.ru" })
        model.selectedCourtID = first.id
        XCTAssertEqual(model.region, "64")
    }

    func testManualSubjectCourtSelectsItsRegion() async throws {
        let model = SearchModel()
        model.tier = .subject
        await model.resolveCourts()

        let moscow = try XCTUnwrap(model.courts.first { $0.domain == "www.mos-gorsud.ru" })
        model.selectedCourtID = moscow.id
        XCTAssertEqual(model.region, "77")
    }

    func testManualCourtSeatDoesNotBecomeMovementOrigin() async throws {
        let model = SearchModel()
        model.tier = .cassation
        await model.resolveCourts()
        let first = try XCTUnwrap(model.courts.first { $0.domain == "1kas.sudrf.ru" })
        model.selectedCourtID = first.id
        model.queryUID = "11RS0001-01-2026-000001-10"
        let result = CaseSearchResult(caseNumber: "2-1/2026")
        model.results = [result]
        model.selectedResultID = result.stableID
        XCTAssertEqual(model.currentContext()?.region, "Республика Коми")

        model.queryUID = ""
        XCTAssertEqual(model.currentContext()?.region, "")
    }

    func testTierChangeTurnsExistingRegionBackIntoJurisdiction() async throws {
        let model = SearchModel()
        model.tier = .cassation
        await model.resolveCourts()
        let first = try XCTUnwrap(model.courts.first { $0.domain == "1kas.sudrf.ru" })
        model.selectedCourtID = first.id
        XCTAssertEqual(model.region, "64")

        model.tier = .appeal
        await model.resolveCourts()
        XCTAssertEqual(model.selectedCourt?.domain, "4ap.sudrf.ru")
        let result = CaseSearchResult(caseNumber: "2-1/2026")
        model.results = [result]
        model.selectedResultID = result.stableID
        XCTAssertEqual(model.currentContext()?.region, "Саратовская область")
    }

    func testOnlyGeneralNonSupremeTiersUseRegion() {
        let model = SearchModel()
        for tier in [CourtTier.subject, .appeal, .cassation] {
            model.branch = .general
            model.tier = tier
            XCTAssertTrue(model.usesRegion, "\(tier)")
        }
        model.branch = .military
        model.tier = .appeal
        XCTAssertFalse(model.usesRegion)
        model.branch = .general
        model.tier = .supreme
        XCTAssertFalse(model.usesRegion)
    }

    func testSupremeClearsAndDoesNotUseRegion() async {
        let model = SearchModel()
        model.region = "77"
        model.tier = .supreme
        await model.resolveCourts()

        XCTAssertFalse(model.usesRegion)
        XCTAssertEqual(model.region, "")
        XCTAssertTrue(model.courts.isEmpty)

        model.tier = .subject
        await model.resolveCourts()
        XCTAssertEqual(model.region, "11")
        XCTAssertEqual(model.selectedCourt?.domain, "vs--komi.sudrf.ru")
    }
}
