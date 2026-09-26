import XCTest
import SudrfKit
import CaptchaSolver
@testable import SudrfApp

final class DirectCaseLinkSheetTests: XCTestCase {

    private actor LinkedCourtMovement: MovementProviding {
        let snapshots: [CaseMovement]
        private(set) var calls = 0

        init(_ snapshots: [CaseMovement]) { self.snapshots = snapshots }

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            defer { calls += 1 }
            return snapshots[min(calls, snapshots.count - 1)]
        }
    }

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

    @MainActor
    func testConfirmDirectLinkContinuesTwoCaptchasAfterSheetClosesAndSurvivesReopen()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-339-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let settings = CaptchaSettings.shared
        let oldEnabled = settings.autoSolveEnabled
        let oldDisabled = settings.forceDisabled
        settings.autoSolveEnabled = true
        settings.forceDisabled = false
        defer {
            settings.autoSolveEnabled = oldEnabled
            settings.forceDisabled = oldDisabled
        }
        let ctx = context()
        let subjectURL = URL(string: "https://vs--komi.sudrf.ru/modules.php?name=sud_delo")!
        let cassationURL = URL(string: "https://3kas.sudrf.ru/modules.php?name=sud_delo")!
        let base = CaseInstance(level: .first, court: ctx.courtTitle,
                                caseNumber: ctx.caseNumber, judge: nil,
                                domain: ctx.searchDomain, foundByUID: false,
                                result: nil, sessions: [])
        let subjectStub = CaseInstance(level: .appeal, court: "Верховный суд Республики Коми",
                                       caseNumber: "—", judge: nil,
                                       domain: "vs--komi.sudrf.ru", foundByUID: false,
                                       result: nil, sessions: [], captchaFormURL: subjectURL)
        let cassationStub = CaseInstance(level: .cassation, court: "Третий кассационный суд",
                                         caseNumber: "—", judge: nil,
                                         domain: "3kas.sudrf.ru", foundByUID: false,
                                         result: nil, sessions: [], captchaFormURL: cassationURL)
        let subjectCard = CaseInstance(level: .appeal, court: "Верховный суд Республики Коми",
                                       caseNumber: "33-91/2026", judge: nil,
                                       domain: "vs--komi.sudrf.ru", foundByUID: true,
                                       result: "Решение", sessions: [])
        let first = CaseMovement(
            uid: "11RS0001-01-2026-000091-00", caseNumber: ctx.caseNumber,
            inForce: false, instances: [base, subjectStub, cassationStub],
            complaints: [:], acts: [],
            incompleteHigherCourtDomains: ["vs--komi.sudrf.ru", "3kas.sudrf.ru"])
        let second = CaseMovement(
            uid: first.uid, caseNumber: ctx.caseNumber, inForce: false,
            instances: [base, subjectCard, cassationStub], complaints: [:], acts: [],
            incompleteHigherCourtDomains: ["3kas.sudrf.ru"])
        let final = CaseMovement(
            uid: first.uid, caseNumber: ctx.caseNumber, inForce: false,
            instances: [base, subjectCard], complaints: [:], acts: [],
            honestZeroDomains: ["3kas.sudrf.ru"])
        let service = LinkedCourtMovement([first, second, final])
        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true,
            refreshCenterFactory: { store, client in
                RefreshCenter(
                    store: store, client: client,
                    captchaSolver: CaptchaSolverFactory.make(settings: settings),
                    captchaSettings: settings,
                    autoSolve: { url, _, _, _ in
                        AutoCaptchaSolver.SolveResult(
                            token: CaptchaToken(value: "12345", id: url.host ?? ""), png: nil)
                    },
                    serviceBuilder: { _ in service })
            })
        router.refreshCenter.repairBeforeRefresh = nil

        let key = try XCTUnwrap(router.addDirectCaseLink(ctx))
        router.closeCase()
        let result = await router.refreshCenter.refresh(key: key)?.value

        guard case .partial = result?.outcome else {
            return XCTFail("пустая выдача остаётся честным partial")
        }
        let calls = await service.calls
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(try XCTUnwrap(router.addDirectCaseLink(ctx)), key)
        XCTAssertEqual(router.cases.count, 1)

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let saved = try XCTUnwrap(reopened.record(forKey: key))
        XCTAssertEqual(saved.movement?.instances.first {
            $0.domain == "vs--komi.sudrf.ru"
        }?.caseNumber, "33-91/2026")
        XCTAssertFalse(saved.movement?.instances.contains {
            $0.domain == "3kas.sudrf.ru" || $0.captchaFormURL != nil
        } ?? true)
        XCTAssertEqual(saved.sourceRefreshAttempt?.kind, .partial)
        XCTAssertNil(saved.movementFetchedAt)
    }
}
