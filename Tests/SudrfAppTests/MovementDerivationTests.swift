import XCTest
import Foundation
import SudrfKit
@testable import SudrfApp

/// Производные данные мониторинга (MovementDerivation) — сроки и заседания,
/// самая ответственная для практикующего юриста логика приложения.
final class MovementDerivationTests: XCTestCase {

    // Фиксированное «сегодня», чтобы тесты не зависели от системной даты.
    private let today = DateUtil.parse("01.05.2026")!

    private func context(cartoteka: String = "g") -> MovementContext {
        MovementContext(branchRaw: "general", region: "Республика Коми",
                        searchDomain: "syktsud--komi.sudrf.ru",
                        displayDomain: "syktsud.komi.sudrf.ru",
                        courtTitle: "Сыктывкарский городской суд",
                        courtLevelRaw: "district", courtCode: "11RS0001",
                        cartotekaId: cartoteka, cartotekaLevelRaw: "district",
                        caseNumber: "2-100/2026")
    }

    private func movement(inForce: Bool = false,
                          sessions: [CaseSession],
                          instances extra: [CaseInstance] = []) -> CaseMovement {
        let first = CaseInstance(level: .first, court: "СГС", caseNumber: "2-100/2026",
                                 judge: nil, domain: "syktsud.komi.sudrf.ru",
                                 foundByUID: false, result: "Иск удовлетворён",
                                 sessions: sessions)
        return CaseMovement(uid: "11RS0001-01-2026-000100-11", caseNumber: "2-100/2026",
                            inForce: inForce, instances: [first] + extra,
                            complaints: [:], acts: [])
    }

    // MARK: Заседания

    func testFutureHearingsFilterAndOrder() {
        let sessions = [
            StoredSession(dateRaw: "30.04.2026", time: "10:00", room: nil,
                          event: "Судебное заседание", result: nil, court: "СГС", levelRaw: "first"),
            StoredSession(dateRaw: "10.05.2026", time: "14:00", room: nil,
                          event: "Судебное заседание", result: nil, court: "СГС", levelRaw: "first"),
            StoredSession(dateRaw: "05.05.2026", time: nil, room: nil,
                          event: "Регистрация иска", result: nil, court: "СГС", levelRaw: "first"),
            StoredSession(dateRaw: "05.05.2026", time: nil, room: nil,
                          event: "Рассмотрение жалобы", result: nil, court: "СГС", levelRaw: "first"),
        ]
        let out = MovementDerivation.futureHearings(sessions, today: today)
        // Вчерашнее заседание и «Регистрация иска» отсечены; порядок — по дате.
        XCTAssertEqual(out.map(\.dateRaw), ["05.05.2026", "10.05.2026"])
        XCTAssertEqual(out.first?.event, "Рассмотрение жалобы")
    }

    func testFutureHearingsUseNumericTimeAndExcludeTerminalSessionToday() {
        let sessions = [
            StoredSession(dateRaw: "01.05.2026", time: "11:00", room: nil,
                          event: "Судебное заседание", result: nil,
                          court: "СГС", levelRaw: "first"),
            StoredSession(dateRaw: "01.05.2026", time: "9:00", room: nil,
                          event: "Судебное заседание", result: nil,
                          court: "СГС", levelRaw: "first"),
            StoredSession(dateRaw: "01.05.2026", time: "10.30", room: nil,
                          event: "Судебное заседание", result: nil,
                          court: "СГС", levelRaw: "first"),
            StoredSession(dateRaw: "01.05.2026", time: "08:00", room: nil,
                          event: "Судебное заседание",
                          result: "Жалоба оставлена без удовлетворения",
                          court: "СГС", levelRaw: "appeal"),
        ]

        let out = MovementDerivation.futureHearings(sessions, today: today)

        XCTAssertEqual(out.map(\.time), ["9:00", "10.30", "11:00"])
    }

    // MARK: Сроки

    func testAppealDeadlineProposedForCivilCase() {
        let mv = movement(sessions: [
            CaseSession(date: "10.04.2026", event: "Судебное заседание",
                        result: "иск удовлетворён"),
        ])
        let snap = MovementDerivation.snapshot(from: mv, context: context(cartoteka: "g"),
                                               today: today)
        let dl = snap.deadlines.first { $0.kind == "appeal" }
        XCTAssertNotNil(dl, "по ГПК должен считаться срок апелляции")
        XCTAssertEqual(dl?.statusRaw, "proposed", "расчётный срок всегда требует подтверждения")
        XCTAssertEqual(dl?.date, DateUtil.addDays(DateUtil.parse("10.04.2026")!, 30))
    }

    func testNoAppealDeadlineWhenAppealExists() {
        let appeal = CaseInstance(level: .appeal, court: "ВС Коми", caseNumber: "33-1/2026",
                                  judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: true,
                                  result: nil, sessions: [])
        let mv = movement(sessions: [CaseSession(date: "10.04.2026", event: "Судебное заседание",
                                                 result: "иск удовлетворён")],
                          instances: [appeal])
        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)
        XCTAssertNil(snap.deadlines.first { $0.kind == "appeal" },
                     "дело уже в апелляции — срок апелляции не считается")
    }

    func testUndatedAppealSuppressesDeadlineWithoutPromotingOrCompletingFirstInstance() {
        let appeal = CaseInstance(level: .appeal, court: "ВС Коми", caseNumber: "33-неполное",
                                  judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: true,
                                  result: nil, sessions: [])
        let mv = movement(sessions: [
            CaseSession(date: "10.04.2026", event: "Решение", result: "Иск удовлетворён"),
        ], instances: [appeal])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.first.rawValue)
        XCTAssertNil(snap.deadlines.first { $0.kind == "appeal" })
    }

    func testFirstInstanceTerminalKeepsProposedDeadlineThroughSeventhDay() {
        let mv = movement(sessions: [CaseSession(date: "01.04.2026", event: "Решение",
                                                 result: "Иск удовлетворён")])
        let initial = MovementDerivation.snapshot(from: mv, context: context(),
                                                   today: DateUtil.parse("01.04.2026")!)
        let deadline = initial.deadlines.first { $0.kind == "appeal" }!
        let daySeven = DateUtil.addDays(deadline.date, 7)
        let presentation = MovementDerivation.lifecyclePresentation(
            from: mv, snapshot: initial, context: context(), today: daySeven)

        XCTAssertEqual(presentation.stage, .first)
        XCTAssertTrue(presentation.nextEvent.hasPrefix("срок апелляции:"))
        XCTAssertEqual(presentation.nextEventDate, daySeven)

        let dayEight = DateUtil.addDays(deadline.date, 8)
        XCTAssertEqual(MovementDerivation.lifecyclePresentation(
            from: mv, snapshot: initial, context: context(), today: dayEight).stage, .done)
    }

    func testFirstInstanceTerminalWithoutDeadlineCompletesImmediately() {
        let mv = movement(sessions: [CaseSession(date: "01.05.2026", event: "Решение",
                                                 result: "Иск удовлетворён")])
        let resolution = CaseLifecycleResolver.resolve(movement: mv, deadlines: [], today: today)
        XCTAssertEqual(resolution.stage, .done)
    }

    func testUndatedReliableFirstResultsCompleteButAdministrativeTextDoesNot() {
        func resolved(_ result: String) -> CaseLifecycleResolver.Resolution {
            let first = CaseInstance(level: .first, court: "СГС", caseNumber: "2-1", judge: nil,
                                     domain: "court.sudrf.ru", foundByUID: false, result: result, sessions: [],
                                     actID: "published-act")
            return CaseLifecycleResolver.resolve(
                movement: CaseMovement(uid: "u", caseNumber: "2-1", inForce: false,
                                       instances: [first], complaints: [:], acts: []),
                deadlines: [], today: today)
        }
        for result in [
            "Иск оставлен без рассмотрения",
            "Заявление оставлено без рассмотрения",
            "Жалоба оставлена без рассмотрения",
            "Дело оставлено без рассмотрения",
        ] {
            XCTAssertEqual(resolved(result).stage, .done, result)
        }
        XCTAssertEqual(resolved("Иск удовлетворён").stage, .done)
        XCTAssertEqual(resolved("Вынесен приговор").stage, .done)
        XCTAssertEqual(resolved("Приговор: назначено наказание").stage, .done)
        XCTAssertEqual(resolved("Постановление о назначении административного наказания").stage, .done)
        XCTAssertEqual(resolved("Карточка принята к обработке").stage, .first)
        XCTAssertEqual(resolved("Ходатайство оставлено без рассмотрения").stage, .first)
        XCTAssertEqual(resolved("Ходатайство по делу оставлено без рассмотрения").stage, .first)
    }

    func testReactivationSurvivesLaterAdministrativeRow() {
        let mv = movement(inForce: true, sessions: [
            CaseSession(date: "10.04.2026", event: "Решение вступило в законную силу"),
            CaseSession(date: "20.04.2026", event: "Производство возобновлено"),
            CaseSession(date: "21.04.2026", event: "Жалоба принята к производству"),
        ])
        XCTAssertEqual(MovementDerivation.snapshot(from: mv, context: context(), today: today).stageRaw,
                       CaseStageKind.first.rawValue)
    }

    func testRemandToNewFirstRoundCalculatesNewAppealDeadline() {
        let returnedFirst = CaseInstance(level: .first, court: "СГС", caseNumber: "2-2", judge: nil,
                                         domain: "court.sudrf.ru", foundByUID: true,
                                         result: "Иск удовлетворён", sessions: [
                                            CaseSession(date: "20.04.2026", event: "Решение",
                                                        result: "Иск удовлетворён"),
                                         ])
        let cassation = CaseInstance(level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-2", judge: nil,
                                     domain: "3kas.sudrf.ru", foundByUID: true,
                                     result: "Направлено на новое рассмотрение", sessions: [
                                        CaseSession(date: "10.04.2026", event: "Рассмотрено"),
                                     ])
        let historicalAppeal = CaseInstance(level: .appeal, court: "ВС Коми", caseNumber: "33-1",
                                            judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: true,
                                            result: "Жалоба оставлена без удовлетворения", sessions: [
                                                CaseSession(date: "01.03.2026", event: "Рассмотрено"),
                                            ])
        let mv = movement(sessions: [CaseSession(date: "01.02.2026", event: "Решение",
                                                  result: "Иск удовлетворён")],
                          instances: [historicalAppeal, cassation, returnedFirst])
        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)
        XCTAssertEqual(snap.deadlines.first { $0.kind == "appeal" }?.date,
                       DateUtil.addDays(DateUtil.parse("20.04.2026")!, 30))
    }

    func testReturnedDatedFirstRoundBeatsHistoricalUndatedReviewResult() {
        let historicalAppeal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-старое", judge: nil,
            domain: "vs.komi.sudrf.ru", foundByUID: true,
            result: "Жалоба оставлена без удовлетворения", sessions: [])
        let remand = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-1", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Направлено на новое рассмотрение", sessions: [])
        let returnedFirst = CaseInstance(
            level: .first, court: "Сыктывкарский городской суд", caseNumber: "2-новое",
            judge: nil, domain: "syktsud.komi.sudrf.ru", foundByUID: true,
            result: "Иск удовлетворён", sessions: [
                CaseSession(date: "20.04.2026", event: "Решение", result: "Иск удовлетворён"),
            ])
        let mv = movement(sessions: [CaseSession(date: "01.02.2026", event: "Решение")],
                          // Кэш сортирует недатированные карточки в хвост:
                          // граница нового круга не должна от этого исчезать.
                          instances: [historicalAppeal, returnedFirst, remand])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)
        let presentation = MovementDerivation.lifecyclePresentation(
            from: mv, snapshot: snap, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.first.rawValue)
        XCTAssertEqual(presentation.currentTier, .district)
        XCTAssertNotEqual(snap.statusText, historicalAppeal.result)
        XCTAssertEqual(snap.deadlines.first { $0.kind == "appeal" }?.date,
                       DateUtil.addDays(DateUtil.parse("20.04.2026")!, 30))
    }

    func testSecondDatedAppealAfterReturnedFirstSuppressesNewDeadline() {
        let historicalAppeal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-старое", judge: nil,
            domain: "old.vs.komi.sudrf.ru", foundByUID: true,
            result: "Жалоба оставлена без удовлетворения", sessions: [])
        let remand = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-1", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Направлено на новое рассмотрение", sessions: [
                CaseSession(date: "10.04.2026", event: "Рассмотрено"),
            ])
        let returnedFirst = CaseInstance(
            level: .first, court: "СГС", caseNumber: "2-новое", judge: nil,
            domain: "syktsud.komi.sudrf.ru", foundByUID: true, result: "Иск удовлетворён",
            sessions: [
                CaseSession(date: "20.04.2026", event: "Решение", result: "Иск удовлетворён"),
                CaseSession(date: "30.04.2026", event: "Дело сдано в архив"),
            ])
        let secondAppeal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-новое", judge: nil,
            domain: "new.vs.komi.sudrf.ru", foundByUID: true, result: nil,
            sessions: [CaseSession(date: "25.04.2026", event: "Регистрация производства")])
        let mv = movement(sessions: [CaseSession(date: "01.02.2026", event: "Решение")],
                          instances: [historicalAppeal, remand, returnedFirst, secondAppeal])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.appeal.rawValue)
        XCTAssertNil(snap.deadlines.first { $0.kind == "appeal" })
    }

    func testHistoricalCassationDoesNotSuppressDeadlineInReturnedRound() {
        let historicalAppeal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-старое", judge: nil,
            domain: "old.vs.komi.sudrf.ru", foundByUID: true,
            result: "Жалоба оставлена без удовлетворения", sessions: [
                CaseSession(date: "01.03.2026", event: "Рассмотрено"),
            ])
        let historicalCassation = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-старое", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Направлено на новое рассмотрение", sessions: [
                CaseSession(date: "10.04.2026", event: "Рассмотрено"),
            ])
        let returnedFirst = CaseInstance(
            level: .first, court: "СГС", caseNumber: "2-новое", judge: nil,
            domain: "syktsud.komi.sudrf.ru", foundByUID: true, result: "Иск удовлетворён",
            sessions: [CaseSession(date: "20.04.2026", event: "Решение", result: "Иск удовлетворён")])
        let returnedAppeal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-новое", judge: nil,
            domain: "new.vs.komi.sudrf.ru", foundByUID: true,
            result: "Жалоба оставлена без удовлетворения", sessions: [
                CaseSession(date: "01.05.2026", event: "Рассмотрено"),
            ])
        let mv = movement(inForce: true, sessions: [
            CaseSession(date: "01.02.2026", event: "Решение"),
        ], instances: [historicalAppeal, historicalCassation, returnedFirst, returnedAppeal])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(snap.deadlines.first { $0.kind == "cassation" }?.date,
                       DateUtil.addDays(DateUtil.parse("01.05.2026")!, 90))
    }

    func testRemandToNewAppealUsesTargetRoundAndTier() {
        let oldAppeal = CaseInstance(
            level: .appeal, court: "Верховный Суд Республики Коми", caseNumber: "33-старое",
            judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: true, result: nil,
            sessions: [CaseSession(date: "01.03.2026", event: "Рассмотрено")])
        let remand = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-1", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Направлено на новое апелляционное рассмотрение", sessions: [
                CaseSession(date: "10.04.2026", event: "Рассмотрено"),
            ])
        let newAppeal = CaseInstance(
            level: .appeal, court: "Первый апелляционный суд общей юрисдикции",
            caseNumber: "33-новое", judge: nil, domain: "1ap.sudrf.ru", foundByUID: true,
            result: nil, sessions: [CaseSession(date: "20.04.2026", event: "Регистрация производства")])
        let mv = movement(sessions: [CaseSession(date: "01.02.2026", event: "Решение")],
                          instances: [oldAppeal, remand, newAppeal])
        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)
        let presentation = MovementDerivation.lifecyclePresentation(
            from: mv, snapshot: snap, context: context(), today: today)

        XCTAssertEqual(presentation.stage, .appeal)
        XCTAssertEqual(presentation.currentTier, .appeal)
    }

    func testUndatedAppealAfterReturnedFirstSuppressesDeadlineWithoutPromotingStage() {
        let remand = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-1", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Направлено на новое рассмотрение", sessions: [
                CaseSession(date: "10.04.2026", event: "Рассмотрено"),
            ])
        let returnedFirst = CaseInstance(
            level: .first, court: "СГС", caseNumber: "2-новое", judge: nil,
            domain: "syktsud.komi.sudrf.ru", foundByUID: true, result: "Иск удовлетворён",
            sessions: [CaseSession(date: "20.04.2026", event: "Решение", result: "Иск удовлетворён")])
        let undatedAppeal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-неполное", judge: nil,
            domain: "vs.komi.sudrf.ru", foundByUID: true,
            result: "Жалоба принята к производству", sessions: [])
        let mv = movement(sessions: [CaseSession(date: "01.02.2026", event: "Решение")],
                          // Порядок недатированных карточек после merge кэша
                          // не является процессуальной хронологией.
                          instances: [undatedAppeal, returnedFirst, remand])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.first.rawValue)
        XCTAssertNil(snap.deadlines.first { $0.kind == "appeal" })
    }

    func testMagistrateAppealAndUnparsedRemandHaveActiveTier() {
        var magistrateContext = context()
        magistrateContext.courtLevelRaw = "magistrate"
        let districtAppeal = CaseInstance(level: .appeal, court: "Сыктывкарский городской суд",
                                          caseNumber: "11-1", judge: nil, domain: "city.sudrf.ru",
                                          foundByUID: true, result: nil, sessions: [])
        XCTAssertEqual(MovementDerivation.courtTier(for: districtAppeal, context: magistrateContext), .district)
        let cassation = CaseInstance(level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-1", judge: nil,
                                     domain: "3kas.sudrf.ru", foundByUID: true,
                                     result: "Направлено на новое апелляционное рассмотрение", sessions: [])
        let presentation = MovementDerivation.lifecyclePresentation(
            from: movement(sessions: [], instances: [cassation]),
            snapshot: MovementDerivation.snapshot(
                from: movement(sessions: [], instances: [cassation]), context: magistrateContext, today: today),
            context: magistrateContext, today: today)
        XCTAssertEqual(presentation.currentTier, .district)
    }

    func testFederalCitySubjectCourtsPrecedeGenericCityHeuristic() {
        let moscow = CaseInstance(level: .appeal, court: "Московский городской суд",
                                  caseNumber: "33-1", judge: nil, domain: "www.mos-gorsud.ru",
                                  foundByUID: true, result: nil, sessions: [])
        let petersburg = CaseInstance(level: .appeal, court: "Санкт-Петербургский городской суд",
                                      caseNumber: "33-2", judge: nil,
                                      domain: "sankt-peterburgsky.spb.sudrf.ru",
                                      foundByUID: true, result: nil, sessions: [])
        XCTAssertEqual(MovementDerivation.courtTier(for: moscow, context: nil), .subject)
        XCTAssertEqual(MovementDerivation.courtTier(for: petersburg, context: nil), .subject)
    }

    func testLaterLegalForceSessionOverridesCardResultAndIsNotHearing() {
        let mv = movement(sessions: [
            CaseSession(date: "01.05.2026", time: "10:00", event: "Заседание",
                        result: "Решение вступило в законную силу"),
        ])
        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)
        XCTAssertEqual(snap.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertTrue(MovementDerivation.futureHearings(snap.sessions, today: today).isEmpty)
    }

    func testNoRemandForFormulaWithoutDirection() {
        XCTAssertFalse(CaseLifecycleResolver.isReactivation(
            event: "", result: "Отменить без направления на новое рассмотрение"))
        let cassation = CaseInstance(level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-9/2026",
                                     judge: nil, domain: "3kas.sudrf.ru", foundByUID: true,
                                     result: "Отменить без направления на новое рассмотрение", sessions: [])
        XCTAssertEqual(CaseLifecycleResolver.resolve(
            movement: movement(sessions: [], instances: [cassation]), deadlines: [], today: today).stage,
            .done)
    }

    func testCourtTierClassificationIncludesMilitarySupremeAndRemandTarget() {
        func instance(_ level: CaseInstance.Level, _ court: String, _ domain: String) -> CaseInstance {
            CaseInstance(level: level, court: court, caseNumber: "x", judge: nil, domain: domain,
                         foundByUID: true, result: nil, sessions: [])
        }
        XCTAssertEqual(MovementDerivation.courtTier(for: instance(.first, "Мировой судья", "msudrf.ru"), context: nil), .magistrate)
        XCTAssertEqual(MovementDerivation.courtTier(for: instance(.first, "Гарнизонный военный суд", "gvs.sudrf.ru"), context: nil), .district)
        XCTAssertEqual(MovementDerivation.courtTier(for: instance(.appeal, "Окружной (флотский) военный суд", "ovs.sudrf.ru"), context: nil), .subject)
        XCTAssertEqual(MovementDerivation.courtTier(for: instance(.appeal, "Первый апелляционный суд", "1ap.sudrf.ru"), context: nil), .appeal)
        XCTAssertEqual(MovementDerivation.courtTier(for: instance(.cassation, "Третий кассационный суд", "3kas.sudrf.ru"), context: nil), .cassation)
        XCTAssertEqual(MovementDerivation.courtTier(for: instance(.vsCassation, "Верховный Суд РФ", "vsrf.ru"), context: nil), .supreme)
        let appeal = instance(.appeal, "Областной суд", "vs.komi.sudrf.ru")
        let cassation = CaseInstance(level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-1",
                                     judge: nil, domain: "3kas.sudrf.ru", foundByUID: true,
                                     result: "Направлено на новое апелляционное рассмотрение", sessions: [])
        let resolution = CaseLifecycleResolver.resolve(
            movement: movement(sessions: [], instances: [appeal, cassation]), deadlines: [], today: today)
        XCTAssertEqual(MovementDerivation.courtTier(for: resolution.currentInstance, context: nil), .subject)
    }

    func testNoCassationDeadlineWithoutLegalForceEvidence() {
        let mv = movement(inForce: true, sessions: [
            CaseSession(date: "10.04.2026", event: "Судебное заседание", result: "иск удовлетворён"),
        ])
        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)
        XCTAssertNil(snap.deadlines.first { $0.kind == "cassation" })
    }

    func testPreservingConfirmedDeadlines() {
        let mv = movement(sessions: [CaseSession(date: "10.04.2026", event: "Судебное заседание",
                                                 result: "иск удовлетворён")])
        var old = MovementDerivation.snapshot(from: mv, context: context(), today: today)
        // Пользователь подтвердил срок и сдвинул дату.
        let userDate = DateUtil.addDays(today, 3).timeIntervalSinceReferenceDate
        old.deadlines[0].statusRaw = "confirmed"
        old.deadlines[0].dateRef = userDate

        let fresh = MovementDerivation.snapshot(from: mv, context: context(), today: today)
        let merged = MovementDerivation.preservingConfirmedDeadlines(fresh, old: old)
        XCTAssertEqual(merged.deadlines[0].statusRaw, "confirmed")
        XCTAssertEqual(merged.deadlines[0].dateRef, userDate,
                       "подтверждённая пользователем дата не сбрасывается пересчётом")
    }

    // MARK: Стадии

    func testStageAndStepsForAppealInProgress() {
        let appeal = CaseInstance(level: .appeal, court: "ВС Коми", caseNumber: "33-1/2026",
                                  judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: true,
                                  result: nil, sessions: [
                                    CaseSession(date: "20.04.2026",
                                                event: "Регистрация производства"),
                                  ])
        let mv = movement(sessions: [CaseSession(date: "10.04.2026", event: "Судебное заседание")],
                          instances: [appeal])
        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)
        XCTAssertEqual(snap.stageRaw, "appeal")
        XCTAssertEqual(snap.steps, ["done", "active", "todo"])
    }

    func testUndatedHigherInstanceDoesNotOverrideDatedRound() {
        let undatedCassation = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-1/2026", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true, result: nil, sessions: [])
        let mv = movement(
            sessions: [CaseSession(date: "20.04.2026", event: "Регистрация дела")],
            instances: [undatedCassation])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.first.rawValue)
        XCTAssertEqual(snap.steps, ["active", "todo", "done"])
    }

    func testAllUndatedRealInstancesUseConservativeFallback() {
        let undatedAppeal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-1/2026", judge: nil,
            domain: "vs.komi.sudrf.ru", foundByUID: true, result: nil, sessions: [])
        let mv = movement(sessions: [], instances: [undatedAppeal])

        let resolution = CaseLifecycleResolver.resolve(
            movement: mv, deadlines: [], today: today)

        XCTAssertEqual(resolution.stage, .appeal)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, "33-1/2026")
    }

    func testUndatedHigherInstanceWithAuthoritativeResultIsNotLost() {
        let undatedAppeal = CaseInstance(
            level: .appeal, court: "Мосгорсуд", caseNumber: "33-1/2026", judge: nil,
            domain: "mos-gorsud.ru", foundByUID: false,
            result: "Жалоба оставлена без удовлетворения", sessions: [])
        let mv = movement(
            sessions: [CaseSession(date: "20.04.2026", event: "Решение")],
            instances: [undatedAppeal])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(snap.statusText, "Жалоба оставлена без удовлетворения")
    }

    func testCaptchaAndTransientStubsDoNotChangeStageOrDeadlines() {
        let captcha = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "—", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: false, result: nil, sessions: [],
            captchaFormURL: URL(string: "https://3kas.sudrf.ru/modules.php?name=sud_delo"))
        let transient = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "—", judge: nil,
            domain: "vs--komi.sudrf.ru", foundByUID: false, result: nil, sessions: [],
            transientError: true)
        let mv = movement(sessions: [
            CaseSession(date: "10.04.2026", event: "Судебное заседание",
                        result: "иск удовлетворён"),
        ], instances: [captcha, transient])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, "first")
        XCTAssertEqual(snap.steps, ["active", "todo", "todo"])
        XCTAssertNotNil(snap.deadlines.first { $0.kind == "appeal" })
    }

    func testLatestChronologicalRoundWinsAfterCassationRemand() {
        func instance(_ level: CaseInstance.Level, _ number: String, _ date: String,
                      result: String? = nil) -> CaseInstance {
            CaseInstance(level: level, court: "Суд", caseNumber: number, judge: nil,
                         domain: "\(number).example", foundByUID: true, result: result,
                         sessions: [CaseSession(date: date, event: "Регистрация производства")])
        }
        let appeal1 = instance(.appeal, "33-1/2025", "01.09.2025")
        let cassation = instance(
            .cassation, "8Г-1/2026", "01.03.2026",
            result: "Апелляционное определение отменено с направлением дела на новое апелляционное рассмотрение")
        let appeal2 = instance(.appeal, "33-2/2026", "01.04.2026")
        let mv = movement(sessions: [CaseSession(date: "01.08.2025", event: "Решение")],
                          instances: [appeal2, cassation, appeal1])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, "appeal")
        XCTAssertEqual(snap.steps, ["done", "active", "done"])
    }

    func testFutureHearingOverridesBaseLegalForce() {
        let cassation = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-1/2026", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true, result: nil,
            sessions: [CaseSession(date: "10.05.2026", time: "11:00",
                                   event: "Судебное заседание")])
        let mv = movement(inForce: true, sessions: [], instances: [cassation])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, "cassation")
        XCTAssertEqual(snap.statusText, "Назначено заседание")
        XCTAssertEqual(snap.steps, ["done", "todo", "active"])
    }

    func testExplicitLegalForceEventCompletesWithoutStructuredDate() {
        let mv = movement(sessions: [
            CaseSession(date: "20.04.2026", event: "Решение вступило в законную силу"),
        ])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, "done")
        XCTAssertEqual(snap.statusText, "Вступило в силу")
        XCTAssertTrue(snap.nextEvent.hasPrefix("срок кассации:"))
    }

    func testTerminalCassationResultCompletesCase() {
        let cassation = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-1/2026", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Жалоба оставлена без удовлетворения",
            sessions: [CaseSession(date: "01.05.2026", event: "Рассмотрение завершено")])
        let mv = movement(sessions: [CaseSession(date: "10.01.2026", event: "Решение")],
                          instances: [cassation])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, "done")
        XCTAssertEqual(snap.steps, ["done", "todo", "done"])
        XCTAssertEqual(snap.statusText, "Жалоба оставлена без удовлетворения")
    }

    func testTerminalCassationInfinitiveFormulaCompletesCase() {
        let cassation = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-2/2026", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Оставить судебные акты без изменения, кассационную жалобу без удовлетворения",
            sessions: [CaseSession(date: "01.05.2026", event: "Рассмотрение завершено")])
        let mv = movement(sessions: [CaseSession(date: "10.01.2026", event: "Решение")],
                          instances: [cassation])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, "done")
        XCTAssertEqual(snap.statusText, cassation.result)
    }

    func testInstanceResultOverridesOlderRemandSession() {
        let cassation = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-3/2026", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Жалоба оставлена без удовлетворения",
            sessions: [
                CaseSession(date: "10.04.2026", event: "Рассмотрено",
                            result: "Направлено на новое апелляционное рассмотрение"),
                CaseSession(date: "01.05.2026", event: "Опубликован результат"),
            ])
        let mv = movement(sessions: [CaseSession(date: "10.01.2026", event: "Решение")],
                          instances: [cassation])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(snap.statusText, cassation.result)
    }

    func testLaterTerminalSessionOverridesOlderRemandSession() {
        let cassation = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-4/2026", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true, result: nil,
            sessions: [
                CaseSession(date: "10.04.2026", event: "Рассмотрено",
                            result: "Направлено на новое апелляционное рассмотрение"),
                CaseSession(date: "01.05.2026", event: "Рассмотрено",
                            result: "Жалоба оставлена без удовлетворения"),
            ])
        let mv = movement(sessions: [CaseSession(date: "10.01.2026", event: "Решение")],
                          instances: [cassation])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(snap.statusText, "Жалоба оставлена без удовлетворения")
    }

    func testLaterReactivationOverridesOldLegalForce() {
        let mv = movement(inForce: true, sessions: [
            CaseSession(date: "10.04.2026", event: "Решение вступило в законную силу"),
            CaseSession(date: "20.04.2026", event: "Производство возобновлено"),
        ])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.first.rawValue)
        XCTAssertEqual(snap.steps, ["active", "todo", "todo"])
        XCTAssertTrue(snap.deadlines.isEmpty,
                      "возобновление отменяет основанный на старом вступлении в силу срок")
    }

    func testRestorationGrantedReactivatesButDenialCompletesReview() {
        func snapshot(result: String) -> CaseSnapshot {
            let appeal = CaseInstance(
                level: .appeal, court: "ВС Коми", caseNumber: "33-5/2026", judge: nil,
                domain: "vs.komi.sudrf.ru", foundByUID: true, result: result,
                sessions: [CaseSession(date: "20.04.2026", event: "Результат рассмотрения")])
            return MovementDerivation.snapshot(
                from: movement(inForce: true, sessions: [
                    CaseSession(date: "10.04.2026", event: "Решение вступило в законную силу"),
                ], instances: [appeal]),
                context: context(), today: today)
        }

        XCTAssertEqual(snapshot(result: "Срок обжалования восстановлен").stageRaw,
                       CaseStageKind.appeal.rawValue)
        let denied = snapshot(result: "Отказано в восстановлении срока обжалования")
        XCTAssertEqual(denied.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(denied.statusText, "Отказано в восстановлении срока обжалования")
        XCTAssertNotNil(denied.deadlines.first { $0.kind == "cassation" })
        XCTAssertFalse(CaseLifecycleResolver.isReactivation(
            event: "Ходатайство о восстановлении процессуального срока", result: nil))
    }

    func testDenialOfAcceptanceIsNotActiveProceeding() {
        let appeal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-6/2026", judge: nil,
            domain: "vs.komi.sudrf.ru", foundByUID: true,
            result: "Отказано в принятии жалобы к производству",
            sessions: [CaseSession(date: "20.04.2026", event: "Опубликован результат")])
        let snap = MovementDerivation.snapshot(
            from: movement(sessions: [CaseSession(date: "10.04.2026", event: "Решение")],
                           instances: [appeal]),
            context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(snap.statusText, "Отказано в принятии жалобы к производству")
    }

    func testOldFirstInstanceLegalForceDoesNotCreateDeadlineDuringActiveAppeal() {
        let appeal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-7/2026", judge: nil,
            domain: "vs.komi.sudrf.ru", foundByUID: true, result: nil,
            sessions: [CaseSession(date: "20.04.2026", event: "Жалоба принята к производству")])
        let mv = movement(inForce: true, sessions: [
            CaseSession(date: "10.04.2026", event: "Решение вступило в законную силу"),
        ], instances: [appeal])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.appeal.rawValue)
        XCTAssertNil(snap.deadlines.first { $0.kind == "cassation" })
    }

    func testCompletedRoundDoesNotPresentEarlierHearingFromToday() {
        let appeal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-8/2026", judge: nil,
            domain: "vs.komi.sudrf.ru", foundByUID: true, result: nil,
            sessions: [
                CaseSession(date: "01.05.2026", time: "09:00", event: "Судебное заседание"),
                CaseSession(date: "01.05.2026", time: "11:00", event: "Результат",
                            result: "Жалоба оставлена без удовлетворения"),
            ])
        let mv = movement(sessions: [CaseSession(date: "10.04.2026", event: "Решение")],
                          instances: [appeal])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(snap.nextEvent, "завершено")
        let presentation = MovementDerivation.lifecyclePresentation(
            from: mv, snapshot: snap, context: context(), today: today)
        XCTAssertNil(presentation.nextEventDate)
    }

    func testExpandedTerminalReviewResultsAndBareChangedWord() {
        func snapshot(result: String) -> CaseSnapshot {
            let appeal = CaseInstance(
                level: .appeal, court: "ВС Коми", caseNumber: "33-2/2026", judge: nil,
                domain: "vs.komi.sudrf.ru", foundByUID: true, result: result,
                sessions: [CaseSession(date: "01.05.2026", event: "Опубликован результат")])
            return MovementDerivation.snapshot(
                from: movement(sessions: [CaseSession(date: "10.01.2026", event: "Решение")],
                               instances: [appeal]),
                context: context(), today: today)
        }

        XCTAssertEqual(snapshot(result: "Вынесено решение по существу").stageRaw,
                       CaseStageKind.done.rawValue)
        XCTAssertEqual(snapshot(result: "Приговор изменён").stageRaw,
                       CaseStageKind.done.rawValue)
        XCTAssertEqual(snapshot(result: "Изменено постановление суда").stageRaw,
                       CaseStageKind.done.rawValue)
        XCTAssertEqual(snapshot(result: "Срок изменён").stageRaw,
                       CaseStageKind.appeal.rawValue)
    }

    func testCassationRemandWithoutNewRoundReturnsToAppeal() {
        let cassation = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-1/2026", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Апелляционное определение отменено с направлением на новое апелляционное рассмотрение",
            sessions: [CaseSession(date: "20.04.2026", event: "Рассмотрено")])
        let mv = movement(sessions: [CaseSession(date: "10.01.2026", event: "Решение")],
                          instances: [cassation])

        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)

        XCTAssertEqual(snap.stageRaw, "appeal")
        XCTAssertEqual(snap.steps, ["done", "active", "done"])
    }

    func testOnlyExpiredConfirmedDeadlineCompletesCase() {
        let mv = movement(sessions: [])
        let expired = DateUtil.addDays(today, -1).timeIntervalSinceReferenceDate
        let deadline = StoredDeadline(kind: "appeal", what: "Апелляционная жалоба",
                                      basis: "подтверждено", calLabel: "апел.",
                                      dateRef: expired, statusRaw: "proposed")

        let proposed = CaseLifecycleResolver.resolve(
            movement: mv, deadlines: [deadline], today: today)
        var confirmedDeadline = deadline
        confirmedDeadline.statusRaw = DeadlineStatus.confirmed.rawValue
        let confirmed = CaseLifecycleResolver.resolve(
            movement: mv, deadlines: [confirmedDeadline], today: today)

        let activeAppeal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-1/2026", judge: nil,
            domain: "vs.komi.sudrf.ru", foundByUID: true, result: nil,
            sessions: [CaseSession(date: "20.04.2026", event: "Регистрация производства")])
        let movementWithReview = movement(
            sessions: [CaseSession(date: "10.01.2026", event: "Решение")],
            instances: [activeAppeal])
        let active = CaseLifecycleResolver.resolve(
            movement: movementWithReview, deadlines: [confirmedDeadline], today: today)

        XCTAssertEqual(proposed.stage, .first)
        XCTAssertEqual(confirmed.stage, .done)
        XCTAssertEqual(confirmed.completionReason, .confirmedDeadline)
        XCTAssertEqual(active.stage, .appeal)
        XCTAssertNil(active.completionReason)
    }

    func testCompletedCaseStillPresentsFutureCassationDeadline() {
        let mv = movement(inForce: true, sessions: [
            CaseSession(date: "20.04.2026", event: "Решение вступило в законную силу"),
        ])
        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)
        let presentation = MovementDerivation.lifecyclePresentation(
            from: mv, snapshot: snap, context: context(), today: today)

        XCTAssertEqual(presentation.stage, .done)
        XCTAssertEqual(presentation.statusText, "Вступило в силу")
        XCTAssertTrue(presentation.nextEvent.hasPrefix("срок кассации:"))
        XCTAssertEqual(presentation.nextEventDate,
                       DateUtil.addDays(DateUtil.parse("20.04.2026")!, 90))
    }

    func testMaterialAndUndatedStubDoNotBecomeCurrentStage() {
        let material = CaseInstance(
            level: .material, court: "СГС", caseNumber: "13-1/2026", judge: nil,
            domain: "syktsud.komi.sudrf.ru", foundByUID: true, result: nil,
            sessions: [CaseSession(date: "10.05.2026", time: "09:00",
                                   event: "Судебное заседание")])
        let stub = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "—", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: false, result: nil, sessions: [],
            captchaFormURL: URL(string: "https://3kas.sudrf.ru/form"))
        let mv = movement(sessions: [], instances: [material, stub])

        let resolution = CaseLifecycleResolver.resolve(movement: mv, deadlines: [], today: today)

        XCTAssertEqual(resolution.stage, .first)
        XCTAssertEqual(resolution.steps, ["active", "todo", "todo"])
    }

    func testDynamicPresentationRepairsLegacyCaptchaStageWithoutMigration() {
        let captcha = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "—", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: false, result: nil, sessions: [],
            captchaFormURL: URL(string: "https://3kas.sudrf.ru/form"))
        let live = movement(sessions: [CaseSession(date: "10.04.2026", event: "Решение")],
                            instances: [captcha])
        let persisted = MovementCachePolicy.stripped(forPersist: live)
        var legacySnapshot = MovementDerivation.snapshot(
            from: persisted, context: context(), today: today)
        // Так выглядят сохранённые снимки до исправления: stub уже вырезан из
        // movementData, но успел сделать snapshot кассационным.
        legacySnapshot.stageRaw = CaseStageKind.cassation.rawValue
        legacySnapshot.stageTag = "кассация"
        legacySnapshot.steps = ["done", "todo", "active"]

        let presentation = MovementDerivation.lifecyclePresentation(
            from: persisted, snapshot: legacySnapshot, context: context(), today: today)

        XCTAssertEqual(presentation.stage, .first)
        XCTAssertEqual(presentation.stageTag, "1-я инст.")
        XCTAssertEqual(presentation.steps, ["active", "todo", "todo"])
    }

    func testDynamicPresentationRepairsStageWithoutDecodableContext() {
        let live = movement(sessions: [CaseSession(date: "10.04.2026", event: "Решение")])
        var legacySnapshot = MovementDerivation.snapshot(
            from: live, context: context(), today: today)
        legacySnapshot.stageRaw = CaseStageKind.cassation.rawValue
        legacySnapshot.stageTag = "кассация"

        let presentation = MovementDerivation.lifecyclePresentation(
            from: live, snapshot: legacySnapshot, context: nil, today: today)

        XCTAssertEqual(presentation.stage, .first)
        XCTAssertEqual(presentation.stageTag, "1-я инст.")
    }

    func testMaterialResultCannotOverrideCaseOutcomeStatus() {
        let material = CaseInstance(level: .material, court: "СГС", caseNumber: "13-1/2026",
                                    judge: nil, domain: "syktsud.komi.sudrf.ru", foundByUID: false,
                                    result: "Материал оставлен без движения", sessions: [])
        let snap = MovementDerivation.snapshot(from: movement(sessions: [], instances: [material]),
                                               context: context(), today: today)
        XCTAssertEqual(snap.statusText, "Иск удовлетворён")
    }

    func testSnapshotChangesWhenJudicialActIsPublished() {
        let initial = movement(sessions: [])
        var withAct = initial
        withAct.acts = [CaseAct(id: "act-1", title: "Решение", date: "10.04.2026",
                                courtShort: "СГС", instanceLevel: .first)]

        let before = MovementDerivation.snapshot(from: initial, context: context(), today: today)
        let after = MovementDerivation.snapshot(from: withAct, context: context(), today: today)

        XCTAssertNil(before.actsFingerprint)
        XCTAssertEqual(after.actsFingerprint, ["act-1|10.04.2026|Решение|СГС|first"])
        XCTAssertNotEqual(before, after,
                          "новый акт должен считаться изменением при фоновом обновлении")
    }

    func testLegacySnapshotWithoutActFingerprintStillDecodes() throws {
        let snapshot = MovementDerivation.snapshot(from: movement(sessions: []), context: context(), today: today)
        let data = try JSONEncoder().encode(snapshot)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "actsFingerprint")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        XCTAssertNil(try JSONDecoder().decode(CaseSnapshot.self, from: legacyData).actsFingerprint)
    }
}
