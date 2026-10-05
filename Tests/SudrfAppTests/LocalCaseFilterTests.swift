import XCTest
import SwiftData
import SudrfKit
@testable import SudrfApp

final class LocalCaseFilterTests: XCTestCase {
    func testNumberNormalizationKeepsSeparatorsAndLeadingZeroes() {
        let row = makeRow(fields: [
            .init(kind: .number, value: "2‑001 / 2026"),
            .init(kind: .category, value: "Ёж")
        ])

        XCTAssertTrue(matches(row, "2 - 001 / 2026"))
        XCTAssertFalse(matches(row, "2-01/2026"))
        XCTAssertTrue(matches(makeRow(fields: [.init(kind: .number, value: "2-123/2026")]), "2-1"))
        XCTAssertTrue(matches(row, "еж"))
    }

    func testOrdinaryWordsCanMatchAcrossFieldsOfOneDossier() {
        let row = makeRow(fields: [
            .init(kind: .collection, value: "Жешарт"),
            .init(kind: .judge, value: "Ермаков Алексей Евгеньевич")
        ])

        XCTAssertTrue(matches(row, "Жешарт Ермаков"))
        XCTAssertFalse(matches(row, "Жешарт Петров"))
        XCTAssertFalse(matches(makeRow(fields: [.init(kind: .collection, value: "Жешарт"), .init(kind: .judge, value: "Ермаков А.Е.")]), "Жешарт А.Е."))
    }

    func testInitialsStayInsideOneNameAndMatchOnlyTheParsedInitials() {
        let row = makeRow(fields: [
            .init(kind: .judge, value: "Ермаков Алексей Евгеньевич"),
            .init(kind: .party, value: "Иванова Анна Петровна")
        ])

        for query in ["Ермаков АЕ", "Ермаков А Е", "Ермаков А.Е.",
                      "Ермаков А. Е.", "ермаков ае", "ермаков а е", "ермаков а.е."] {
            XCTAssertTrue(matches(row, query), query)
        }
        for saved in ["Ермаков А. Е.", "Ермаков А.Е.", "Ермаков А Е", "Ермаков АЕ"] {
            XCTAssertTrue(matches(makeRow(fields: [.init(kind: .judge, value: saved)]), "ермаков а.е."), saved)
        }
        XCTAssertFalse(matches(row, "А.А."))
        XCTAssertFalse(matches(row, "Ермаков А.П."))
        XCTAssertFalse(matches(row, "ермаков а п"))
        XCTAssertTrue(matches(makeRow(fields: [.init(kind: .judge, value: "ермаков алексей евгеньевич")]), "Ермаков А.Е."))
    }

    func testLegalAcronymsAndSingleLetterTypingRemainOrdinaryWords() {
        let row = makeRow(fields: [.init(kind: .article, value: "ст. 20.3 КоАП РФ"),
                                  .init(kind: .court, value: "Верховный Суд РФ"),
                                  .init(kind: .judge, value: "Ермаков Алексей Евгеньевич")])
        for query in ["ст. 20.3 КоАП РФ", "РФ", "Суд РФ", "Е", "е"] {
            XCTAssertTrue(matches(row, query), query)
        }
        XCTAssertTrue(matches(makeRow(fields: [.init(kind: .uid, value: "11RS0001-01-2026-000007-01")]), "11RS0001-01-2026"))
    }

    func testDifferentCompleteNamesDoNotCollapseToTheSameInitials() {
        let row = makeRow(fields: [
            .init(kind: .party, value: "Иванов Игорь Ильич")
        ])

        XCTAssertFalse(matches(row, "Иванов Иван Иванович"))
    }

    @MainActor
    func testSavedHigherCourtNumberExplainsItsOwnCourtAndNumber() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        _ = try LocalFilter403Fixture.seed(container, count: 1)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let row = try XCTUnwrap(router.cases.first)

        let explanation = try XCTUnwrap(
            LocalCaseFilter.explanation(for: row, query: "Ермаков 33-40001/2026"))
        XCTAssertTrue(explanation.contains("Проверочный областной суд"), explanation)
        XCTAssertTrue(explanation.contains("33-40001/2026"), explanation)
        XCTAssertTrue(LocalCaseFilter.matches(row, query: .init(row.statusText)))
    }

    @MainActor
    func testOnlySavedJudicialUIDIsSearchableAndCaptchaStubsAreIgnored() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let context = LocalFilter403Fixture.context(7)
        var movement = LocalFilter403Fixture.movement(7)
        movement.instances.append(CaseInstance(
            level: .appeal, court: "Временный технический суд",
            caseNumber: "99-99999/2026", judge: "Неиндексируемый Судья",
            domain: "transient.sudrf.ru", foundByUID: false, result: nil,
            sessions: [], captchaFormURL: URL(string: "https://transient.sudrf.ru/captcha"),
            transientError: true))
        let snapshot = MovementDerivation.snapshot(
            from: movement, context: context, today: DateUtil.parse("05.10.2026")!)
        let record = try store.upsert(context: context, snapshot: snapshot,
                                      movement: movement, collections: [])
        try store.save()
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let row = try XCTUnwrap(router.cases.first)

        XCTAssertTrue(LocalCaseFilter.matches(
            row, query: .init("11RS0001-01-2026-000007-01")))
        XCTAssertFalse(AppRouter.matches(row, query: "technical-guid-7"))
        XCTAssertFalse(AppRouter.matches(row, query: "99-99999/2026"))
        XCTAssertFalse(AppRouter.matches(row, query: "Неиндексируемый Судья"))
        XCTAssertEqual(row.recordKey, record.key)
    }

    private func matches(_ row: TrackedCase, _ query: String) -> Bool {
        LocalCaseFilter.matches(row, query: .init(query))
    }

    private func makeRow(fields: [LocalCaseFilter.Field]) -> TrackedCase {
        TrackedCase(
            recordKey: "filter-test", caseNumber: "2-1/2026", searchFields: fields, collections: [],
            stage: .first, stageTag: "Первая инстанция", subject: "Тест",
            court: "Тестовый суд", recordCourt: "Тестовый суд", courtTier: nil,
            production: nil, partiesShort: "", leadCharges: nil,
            secondPartyLine: nil, statusText: "В производстве", statusChip: .gray,
            last: "—", next: "—", nextChip: .gray, isNew: false, steps: [],
            newDot: false, lastEventDate: nil, nextEventDate: nil)
    }
}
