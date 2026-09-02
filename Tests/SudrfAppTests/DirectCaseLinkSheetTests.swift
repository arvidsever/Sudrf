import XCTest
import SudrfKit
@testable import SudrfApp

final class DirectCaseLinkSheetTests: XCTestCase {

    private func context() -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001",
            cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-91/2026")
    }

    @MainActor
    func testPreviewProjectsAllConfirmationFieldsAndMissingValues() {
        let preview = DirectCaseLinkPreview(
            context: context(),
            caseNumber: " 2-91/2026 ",
            courtTitle: "Сыктывкарский городской суд",
            judicialUID: "11RS0001-01-2026-000091-00",
            category: "",
            judge: nil,
            result: "Решение")

        XCTAssertEqual(preview.fields.map(\.0),
                       ["Номер дела", "Суд", "УИД", "Категория", "Судья", "Результат"])
        XCTAssertEqual(preview.fields.map(\.1), [
            "2-91/2026",
            "Сыктывкарский городской суд",
            "11RS0001-01-2026-000091-00",
            "—",
            "—",
            "Решение"
        ])
    }

    func testSheetStateKeepsOnlyResolvedPreviewAfterInput() {
        let preview = DirectCaseLinkPreview(
            context: context(), caseNumber: "2-91/2026",
            courtTitle: "Сыктывкарский городской суд")

        XCTAssertEqual(DirectCaseLinkSheetState.input,
                       DirectCaseLinkSheetState.input)
        XCTAssertEqual(DirectCaseLinkSheetState.resolving,
                       DirectCaseLinkSheetState.resolving)
        XCTAssertEqual(DirectCaseLinkSheetState.preview(preview),
                       DirectCaseLinkSheetState.preview(preview))
        XCTAssertEqual(DirectCaseLinkSheetState.failed("Ошибка"),
                       DirectCaseLinkSheetState.failed("Ошибка"))

        var stalePreview = DirectCaseLinkSheetState.preview(preview)
        stalePreview.invalidateForChangedInput()
        XCTAssertEqual(stalePreview, .input)
    }

    @MainActor
    func testTrackReturnsPersistentKeyAndExactContextReusesIt() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let context = context()

        let firstKey = try XCTUnwrap(router.track(context: context, movement: nil))
        let secondKey = try XCTUnwrap(router.track(context: context, movement: nil))
        XCTAssertEqual(secondKey, firstKey)
        XCTAssertEqual(router.cases.count, 1)
    }

    @MainActor
    func testHigherCourtURLReusesSearchTrackedLogicalCaseByJudicialUID() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        var first = context()
        first.caseID = "first-card-id"
        first.caseUID = "first-card-guid"
        first.judicialUID = "11RS0001-01-2026-000091-00"
        let firstKey = try XCTUnwrap(router.track(context: first, movement: nil))

        var appeal = MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Республика Коми",
            searchDomain: "vs--komi.sudrf.ru",
            displayDomain: "vs.komi.sudrf.ru",
            courtTitle: "Верховный суд Республики Коми",
            courtLevelRaw: CourtLevel.subject.rawValue,
            courtCode: nil,
            cartotekaId: "g2",
            cartotekaLevelRaw: CourtLevel.subject.rawValue,
            caseNumber: "33-91/2026",
            caseID: "appeal-card-id",
            caseUID: "appeal-card-guid")
        appeal.judicialUID = first.judicialUID
        appeal.baseInstanceLevelRaw = CaseInstance.Level.appeal.rawValue

        XCTAssertEqual(try XCTUnwrap(router.track(context: appeal, movement: nil)), firstKey)
        XCTAssertEqual(router.cases.count, 1)

        let store = try TrackedStore(container: container, prepared: true)
        let record = try XCTUnwrap(store.record(forKey: firstKey))
        let state = try JSONDecoder().decode(
            LogicalCaseState.self, from: XCTUnwrap(record.identityStateData))
        XCTAssertTrue(state.cards.contains {
            $0.identity.sourceNativeID == "appeal-card-id"
        })
    }
}
