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
