import XCTest
import SudrfKit
@testable import SudrfApp

final class MovementContextTests: XCTestCase {
    private func context(level: CourtLevel, cartoteka: String,
                         base: CaseInstance.Level? = nil) -> MovementContext {
        var ctx = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: level == .district ? "syktsud--komi.sudrf.ru" : "vs--komi.sudrf.ru",
            displayDomain: level == .district ? "syktsud.komi.sudrf.ru" : "vs.komi.sudrf.ru",
            courtTitle: level == .district ? "Сыктывкарский городской суд" : "Верховный Суд Республики Коми",
            courtLevelRaw: level.rawValue, courtCode: "11",
            cartotekaId: cartoteka, cartotekaLevelRaw: level.rawValue,
            caseNumber: cartoteka.hasSuffix("2") ? "33-1/2026" : "2-1/2025")
        ctx.baseInstanceLevelRaw = base?.rawValue
        return ctx
    }

    func testLegacyContextDecodesAndInfersBaseLevel() throws {
        let original = context(level: .subject, cartoteka: "g2")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)) as? [String: Any])
        json["judicialUID"] = nil
        json["baseInstanceLevelRaw"] = nil
        json["sourceKnownCard"] = nil

        let decoded = try JSONDecoder().decode(
            MovementContext.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertNil(decoded.judicialUID)
        XCTAssertEqual(decoded.baseInstanceLevel, .appeal)
        XCTAssertNil(decoded.sourceKnownCard)
    }

    func testTargetsRespectActualAnchorLevel() {
        let district = context(level: .district, cartoteka: "g1")
        XCTAssertTrue(district.expandedHigherDomains().contains("vs--komi.sudrf.ru"))
        XCTAssertTrue(district.expandedHigherDomains().contains("3kas.sudrf.ru"))

        let subjectFirst = context(level: .subject, cartoteka: "g1", base: .first)
        XCTAssertTrue(subjectFirst.expandedHigherDomains().contains("2ap.sudrf.ru"))
        XCTAssertTrue(subjectFirst.expandedHigherDomains().contains("3kas.sudrf.ru"))

        let appeal = context(level: .subject, cartoteka: "g2", base: .appeal)
        XCTAssertFalse(appeal.expandedHigherDomains().contains("2ap.sudrf.ru"))
        XCTAssertTrue(appeal.expandedHigherDomains().contains("3kas.sudrf.ru"))

        let cassation = context(level: .cassation, cartoteka: "g3", base: .cassation)
        XCTAssertTrue(cassation.expandedHigherDomains().isEmpty)

        var militaryAppeal = context(level: .appeal, cartoteka: "g2", base: .appeal)
        militaryAppeal.branchRaw = CourtBranch.military.rawValue
        militaryAppeal.searchDomain = "vap.sudrf.ru"
        militaryAppeal.displayDomain = "vap.sudrf.ru"
        XCTAssertEqual(militaryAppeal.expandedHigherDomains(), ["vkas.sudrf.ru"])
    }

    @MainActor
    func testSwiftDataRecordAllowsMissingDenormalizedUID() {
        let store = TrackedStore(inMemory: true)
        let legacy = context(level: .district, cartoteka: "g1")

        let record = store.upsert(context: legacy, snapshot: nil, collections: [])

        XCTAssertNil(record.judicialUID)
        XCTAssertEqual(record.context?.baseInstanceLevel, .first)
        XCTAssertEqual(store.all().count, 1)
    }
}
