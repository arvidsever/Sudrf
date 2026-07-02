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
                                  result: nil, sessions: [])
        let mv = movement(sessions: [CaseSession(date: "10.04.2026", event: "Судебное заседание")],
                          instances: [appeal])
        let snap = MovementDerivation.snapshot(from: mv, context: context(), today: today)
        XCTAssertEqual(snap.stageRaw, "appeal")
        XCTAssertEqual(snap.steps, ["done", "active", "todo"])
    }
}
