import XCTest
import Foundation
@testable import SudrfApp

final class OverviewModelTests: XCTestCase {
    private let today = DateUtil.parse("03.07.2026")!

    private func hearing(_ number: String, plus days: Int, time: String = "09:00") -> TrackedHearing {
        TrackedHearing(recordKey: "court/\(number)", date: DateUtil.addDays(today, days),
                       time: time, caseNumber: number, parties: "Иванов А. А. ⚔ ООО «Ромашка»",
                       court: "Сыктывкарский городской суд", room: "215",
                       dateLabel: DateUtil.dateLabel(DateUtil.addDays(today, days)))
    }

    private func deadline(_ id: String, plus days: Int,
                          status: DeadlineStatus = .proposed) -> TrackedDeadline {
        TrackedDeadline(id: "court/2-\(id)/2026#appeal", recordKey: "court/2-\(id)/2026",
                        what: "Апелляционная жалоба", caseNumber: "2-\(id)/2026",
                        basis: "1 мес. со дня решения — расчётный",
                        calLabel: "апел. жалоба", date: DateUtil.addDays(today, days),
                        status: status)
    }

    private func feed(_ id: String, kind: FeedEntryKind, plus days: Int,
                      unread: Bool, text: String = "Назначено судебное заседание") -> FeedEntry {
        FeedEntry(id: id, dayHead: nil, date: DateUtil.addDays(today, days),
                  time: "09:41", recordKey: "court/2-1/2026", caseNumber: "2-1/2026",
                  client: "Новожилова", kind: kind, text: text,
                  actID: kind == .act ? "act-\(id)" : nil, isUnread: unread)
    }

    func testHearingBucketsKeepNextSevenDaysPinned() {
        let buckets = AppRouter.hearingBuckets([
            hearing("2-1/2026", plus: 2),
            hearing("2-2/2026", plus: 9),
            hearing("2-3/2026", plus: 7)
        ], today: today)

        XCTAssertEqual(buckets.next7Days.map(\.caseNumber), ["2-1/2026", "2-3/2026"])
        XCTAssertEqual(buckets.later.map(\.caseNumber), ["2-2/2026"])
        XCTAssertEqual(buckets.firstLaterDays, 9)
    }

    func testTimelessHearingsHaveDistinctStableIDsFromSource() {
        let date = DateUtil.addDays(today, 2)
        let a = TrackedHearing(recordKey: "court/2-1", date: date, time: "", caseNumber: "2-1/2026",
                               parties: "", court: "СГС", room: "", dateLabel: "", identitySuffix: "Назначено#")
        let b = TrackedHearing(recordKey: "court/2-1", date: date, time: "", caseNumber: "2-1/2026",
                               parties: "", court: "СГС", room: "", dateLabel: "", identitySuffix: "Отложено#")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: Retention расчётных сроков (#98)

    /// Недавно пропущенный расчётный срок остаётся задачей: его ещё можно
    /// подтвердить или исправить.
    func testRecentlyMissedProposalStaysActionable() {
        let recent = deadline("20", plus: -3)

        XCTAssertTrue(AppRouter.isActionableDeadline(recent, today: today))
        XCTAssertEqual(AppRouter.overdueDeadlines([recent], today: today).map(\.id), [recent.id])
        XCTAssertEqual(AppRouter.pendingDeadlines([recent], today: today).map(\.id), [recent.id])
    }

    /// Граница grace period — ровно 14 дней, включительно.
    func testGracePeriodBoundaryIsInclusive() {
        let lastDay = deadline("21", plus: -AppRouter.deadlineGraceDays)
        let dayAfter = deadline("22", plus: -AppRouter.deadlineGraceDays - 1)

        XCTAssertTrue(AppRouter.isActionableDeadline(lastDay, today: today))
        XCTAssertFalse(AppRouter.isActionableDeadline(dayAfter, today: today))
    }

    /// Древний расчётный срок уходит и из «Просроченных», и из счётчиков —
    /// ради этого issue и заведён: колонка превратилась в архив расчётов.
    func testStaleProposalLeavesOverdueAndCounters() {
        let stale = deadline("23", plus: -120)
        let fresh = deadline("24", plus: -2)

        XCTAssertEqual(AppRouter.overdueDeadlines([stale, fresh], today: today).map(\.id),
                       [fresh.id])
        XCTAssertEqual(AppRouter.pendingDeadlines([stale, fresh], today: today).map(\.id),
                       [fresh.id])
        XCTAssertNil(AppRouter.pinnedDeadline([stale], today: today))
    }

    /// Подтверждённый срок — обязательство пользователя, а не наша догадка:
    /// по возрасту он не архивируется никогда.
    func testConfirmedDeadlineNeverExpiresByAge() {
        let ancient = deadline("25", plus: -900, status: .confirmed)

        XCTAssertTrue(AppRouter.isActionableDeadline(ancient, today: today))
    }

    /// «Ближайший» не должен подставлять древний расчётный срок, когда
    /// актуальных нет.
    func testPinnedFallbackSkipsStaleProposals() {
        let stale = deadline("26", plus: -200)
        let recent = deadline("27", plus: -1)

        XCTAssertEqual(AppRouter.pinnedDeadline([stale, recent], today: today)?.id, recent.id)
    }

    func testPinnedDeadlinePrefersUpcomingProposal() {
        let old = deadline("10", plus: -3)
        let next = deadline("11", plus: 4)
        let confirmed = deadline("12", plus: 1, status: .confirmed)

        XCTAssertEqual(AppRouter.pinnedDeadline([old, next, confirmed], today: today)?.id, next.id)
        XCTAssertEqual(AppRouter.overdueDeadlines([old, next, confirmed], today: today).map(\.id), [old.id])
    }

    func testFeedFilteringByKindUnreadAndQuery() {
        let rows = [
            feed("a", kind: .hearing, plus: 0, unread: true),
            feed("b", kind: .act, plus: -1, unread: false, text: "Опубликован судебный акт"),
            feed("c", kind: .movement, plus: -2, unread: true, text: "Материалы переданы судье")
        ]

        XCTAssertEqual(AppRouter.filteredFeedEntries(rows, filter: .hearing,
                                                     unreadOnly: false, query: "").map(\.id), ["a"])
        XCTAssertEqual(AppRouter.filteredFeedEntries(rows, filter: .all,
                                                     unreadOnly: true, query: "").map(\.id), ["a", "c"])
        XCTAssertEqual(AppRouter.filteredFeedEntries(rows, filter: .all,
                                                     unreadOnly: false, query: "акт").map(\.id), ["b"])
    }

    func testEnforcementFeedUsesRSSGUIDAndStaysUnreadIndependentlyOfCaseState() {
        let id = AppRouter.enforcementFeedID(recordKey: "court/2-1/2026", guid: "rss-guid-42")
        XCTAssertEqual(id, "court/2-1/2026#enforcement#rss-guid-42")

        let entry = feed(id, kind: .enforcement, plus: 0, unread: true,
                         text: "Исполнительный документ принят")
        XCTAssertEqual(
            AppRouter.filteredFeedEntries([entry], filter: .enforcement,
                                          unreadOnly: true, query: "").map(\.id),
            [id])
    }

    func testRecentFeedUsesRollingSevenDays() {
        let rows = [
            feed("today", kind: .movement, plus: 0, unread: false),
            feed("six", kind: .movement, plus: -6, unread: false),
            feed("seven", kind: .movement, plus: -7, unread: false)
        ]

        XCTAssertEqual(AppRouter.recentFeedEntries(rows, today: today, days: 7).map(\.id),
                       ["today", "six"])
    }

    // MARK: Идентификатор записи ленты (#99)

    /// Вид записи — производная классификация. Пока он входил в id, уточнение
    /// правил (#99 перевёл канцелярские события из «заседаний» в «движение»)
    /// меняло id у давно прочитанных записей: они возвращались непрочитанными
    /// и порождали уведомления о событиях месячной давности.
    func testFeedIDMigrationDropsKindSegment() {
        XCTAssertEqual(
            AppRouter.feedIDDroppingKind("syktsud.komi.sudrf.ru/2-476/2026#feed#hearing#12345#11:00#Дело сдано"),
            "syktsud.komi.sudrf.ru/2-476/2026#feed#12345#11:00#Дело сдано")
        XCTAssertEqual(
            AppRouter.feedIDDroppingKind("host/2-1/2026#feed#movement#1#—#Регистрация"),
            "host/2-1/2026#feed#1#—#Регистрация")
        XCTAssertEqual(
            AppRouter.feedIDDroppingKind("host/2-1/2026#feed#act#1#—#doc1"),
            "host/2-1/2026#feed#1#—#doc1")
    }

    /// У судов Москвы `recordKey` сам содержит «#» (MovementContext.identityKey),
    /// поэтому разбор по разделителю сломался бы — снимаем сегмент строго после
    /// маркера «#feed#».
    func testFeedIDMigrationSurvivesHashInRecordKey() {
        XCTAssertEqual(
            AppRouter.feedIDDroppingKind("mos-gorsud.ru#77RS0023/2-5/2026#feed#hearing#9#10:00#Заседание"),
            "mos-gorsud.ru#77RS0023/2-5/2026#feed#9#10:00#Заседание")
    }

    /// Миграция идемпотентна: новый id второй раз не режется.
    func testFeedIDMigrationIsIdempotent() {
        let migrated = "host/2-1/2026#feed#12345#11:00#Дело сдано"
        XCTAssertEqual(AppRouter.feedIDDroppingKind(migrated), migrated)
        // Текст записи, начинающийся со слова-вида, не должен быть срезан.
        let tricky = "host/2-1/2026#feed#12345#—#hearing#что-то"
        XCTAssertEqual(AppRouter.feedIDDroppingKind(tricky), tricky)
    }
}
