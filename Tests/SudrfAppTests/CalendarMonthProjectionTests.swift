import XCTest
@testable import SudrfApp

@MainActor
final class CalendarMonthProjectionTests: XCTestCase {
    private func date(_ value: String) -> Date { DateUtil.parse(value)! }

    private func time(_ date: Date, hour: Int, minute: Int, second: Int = 0) -> Date {
        DateUtil.cal.date(bySettingHour: hour, minute: minute, second: second, of: date)!
    }

    private func event(_ id: String, on date: Date, at time: String = "—",
                       kind: CalEventKind = .hearing, court: String = "",
                       caseNumber: String? = nil, deadlineId: String? = nil,
                       what: String? = nil) -> CalEvent {
        CalEvent(id: id, date: date, sortTime: time, kind: kind, chip: id, time: time,
                 heading: id, title: id, sub: id, caseNumber: caseNumber ?? id,
                 displayCaseNumber: nil, secondaryLabel: nil, deadlineId: deadlineId,
                 court: court, what: what)
    }

    func testMonthGridsContainFourFiveOrSixCompleteWeeks() {
        for (month, weeks) in [("01.02.2021", 4), ("01.09.2026", 5), ("01.08.2026", 6)] {
            let days = DateUtil.datesOfMonthGrid(date(month))
            XCTAssertEqual(days.count, weeks * 7, month)
            XCTAssertEqual(Set(days).count, days.count, month)
            XCTAssertEqual(days.first, DateUtil.startOfWeek(DateUtil.startOfMonth(date(month))))
            XCTAssertEqual(DateUtil.cal.component(.weekday, from: days.first!), 2, month)
            XCTAssertEqual(DateUtil.cal.component(.weekday, from: days.last!), 1, month)
            for (previous, next) in zip(days, days.dropFirst()) {
                XCTAssertEqual(DateUtil.addDays(previous, 1), next, month)
                XCTAssertEqual(DateUtil.daysBetween(previous, next), 1, month)
            }
        }
    }

    func testLeapFebruaryAndDecemberJanuaryGridsUseUniqueCalendarDays() {
        let february = date("01.02.2024")
        let februaryDays = DateUtil.datesOfMonth(february)
        XCTAssertEqual(februaryDays.count, 29)
        XCTAssertEqual(februaryDays.filter { DateUtil.cal.component(.day, from: $0) == 29 }.count, 1)

        let leapGrid = DateUtil.datesOfMonthGrid(february)
        let december = DateUtil.datesOfMonthGrid(date("01.12.2026"))
        let january = DateUtil.datesOfMonthGrid(date("01.01.2027"))
        for grid in [leapGrid, december, january] {
            XCTAssertEqual(Set(grid).count, grid.count)
            for (previous, next) in zip(grid, grid.dropFirst()) {
                XCTAssertEqual(DateUtil.addDays(previous, 1), next)
                XCTAssertEqual(DateUtil.daysBetween(previous, next), 1)
            }
        }
        XCTAssertTrue(leapGrid.contains(date("29.02.2024")))

        let yearBoundaryWeek = (0..<7).map { DateUtil.addDays(date("28.12.2026"), $0) }
        XCTAssertEqual(yearBoundaryWeek.last, date("03.01.2027"))
        XCTAssertTrue(Set(yearBoundaryWeek).isSubset(of: Set(december)))
        XCTAssertTrue(Set(yearBoundaryWeek).isSubset(of: Set(january)))
        XCTAssertEqual(DateUtil.daysBetween(date("31.12.2026"), date("01.01.2027")), 1)
    }

    func testNeighborMonthLabelsAppearOnlyOnBoundaryDatesAndFullDateHasYear() {
        let september = date("01.09.2026")
        let october = date("01.10.2026")
        let septemberGrid = DateUtil.datesOfMonthGrid(september)
        let octoberGrid = DateUtil.datesOfMonthGrid(october)

        XCTAssertEqual(septemberGrid.first, date("31.08.2026"))
        XCTAssertEqual(septemberGrid.last, date("04.10.2026"))
        XCTAssertEqual(octoberGrid.first, date("28.09.2026"))
        XCTAssertEqual(octoberGrid.last, date("01.11.2026"))
        XCTAssertEqual(DateUtil.cal.component(.weekday, from: septemberGrid.last!), 1)
        XCTAssertEqual(DateUtil.cal.component(.weekday, from: octoberGrid.last!), 1)

        let months = DateUtil.cal.shortStandaloneMonthSymbols
        XCTAssertEqual(DateUtil.neighborMonthLabel(for: date("31.08.2026"), month: september), months[7])
        XCTAssertNil(DateUtil.neighborMonthLabel(for: date("01.09.2026"), month: september))
        XCTAssertEqual(DateUtil.neighborMonthLabel(for: date("01.10.2026"), month: september), months[9])
        XCTAssertNil(DateUtil.neighborMonthLabel(for: date("02.10.2026"), month: september))
        XCTAssertNil(DateUtil.neighborMonthLabel(for: date("04.10.2026"), month: september))

        XCTAssertEqual(DateUtil.neighborMonthLabel(for: date("28.09.2026"), month: october), months[8])
        XCTAssertNil(DateUtil.neighborMonthLabel(for: date("29.09.2026"), month: october))
        XCTAssertEqual(DateUtil.neighborMonthLabel(for: date("01.11.2026"), month: october), months[10])
        XCTAssertNil(DateUtil.neighborMonthLabel(for: date("02.11.2026"), month: october))
        XCTAssertEqual(DateUtil.fullDate(date("28.09.2026")), "28 сентября 2026 года")
    }

    func testSeptemberOctoberSharedWeekKeepsEventsCourtLabelsAndOverlapStable() throws {
        let sharedWeekStart = date("28.09.2026")
        let sharedWeek = (0..<7).map { DateUtil.addDays(sharedWeekStart, $0) }
        XCTAssertEqual(sharedWeek.last, date("04.10.2026"))

        let september = date("01.09.2026")
        let october = date("01.10.2026")
        let septemberGrid = DateUtil.datesOfMonthGrid(september)
        let octoberGrid = DateUtil.datesOfMonthGrid(october)
        XCTAssertTrue(Set(sharedWeek).isSubset(of: Set(septemberGrid)))
        XCTAssertTrue(Set(sharedWeek).isSubset(of: Set(octoberGrid)))

        let day = date("28.09.2026")
        let tver = "Центральный районный суд города Твери"
        let barnaul = "Центральный районный суд г. Барнаула"
        let syktyvkar = "Сыктывкарский городской суд"
        let syktyvkarAlias = "Сыктывкарский горсуд"
        let events = [
            event("hearing-14", on: time(day, hour: 14, minute: 0), at: "14:00", court: syktyvkarAlias),
            event("hearing-1030", on: time(day, hour: 10, minute: 30), at: "10:30", court: barnaul),
            event("hearing-1205", on: time(day, hour: 12, minute: 5), at: "12:05", court: syktyvkar),
            event("hearing-1000", on: time(day, hour: 10, minute: 0), at: "10:00", court: tver,
                  caseNumber: "september-series"),
            event("hearing-sep-05", on: date("05.09.2026"), at: "09:00", court: tver,
                  caseNumber: "september-series"),
            event("hearing-sep-15", on: date("15.09.2026"), at: "09:00", court: tver,
                  caseNumber: "september-series"),
            event("hearing-oct-01", on: time(date("01.10.2026"), hour: 9, minute: 0), at: "09:00",
                  court: tver, caseNumber: "october-series"),
            event("hearing-oct-04", on: time(date("04.10.2026"), hour: 9, minute: 0), at: "09:00",
                  court: tver, caseNumber: "october-series"),
            event("hearing-oct-10", on: date("10.10.2026"), at: "09:00", court: tver,
                  caseNumber: "october-series"),
            event("hearing-oct-20", on: date("20.10.2026"), at: "09:00", court: tver,
                  caseNumber: "october-series")
        ]
        let septemberModel = CalendarScreen.buildMonthModel(month: september, events: events)
        let octoberModel = CalendarScreen.buildMonthModel(month: october, events: events)
        let dayKey = DateUtil.startOfDay(day)
        let expectedIDs = ["hearing-1000", "hearing-1030", "hearing-1205", "hearing-14"]

        for model in [septemberModel, octoberModel] {
            let items = try XCTUnwrap(model.itemsByDay[dayKey])
            XCTAssertEqual(items.map(\.id), expectedIDs)
            XCTAssertEqual(items.map(\.time), ["10:00", "10:30", "12:05", "14:00"])
            XCTAssertEqual(model.courtShort[tver], "Центральный р/с г. Твери")
            XCTAssertEqual(model.courtShort[barnaul], "Центральный р/с г. Барнаула")
            XCTAssertEqual(model.courtShort[syktyvkar], "Сыктывкарский")
            XCTAssertEqual(model.courtShort[syktyvkarAlias], "Сыктывкарский")
            XCTAssertEqual(model.overlapByID["hearing-1000"], CalendarMonthOverlap(
                otherID: "hearing-1030", otherCourtShort: "Центральный р/с г. Барнаула",
                otherTime: "10:30", deltaMinutes: 30))
            XCTAssertEqual(model.overlapByID["hearing-1030"], CalendarMonthOverlap(
                otherID: "hearing-1000", otherCourtShort: "Центральный р/с г. Твери",
                otherTime: "10:00", deltaMinutes: 30))
            XCTAssertNil(model.overlapByID["hearing-1205"])
            XCTAssertNil(model.overlapByID["hearing-14"])
            XCTAssertEqual(model.overlapDays, [dayKey])
        }
        XCTAssertEqual(septemberModel.itemsByDay[DateUtil.startOfDay(date("01.10.2026"))]?.map(\.id),
                       ["hearing-oct-01"])
        XCTAssertEqual(septemberModel.itemsByDay[DateUtil.startOfDay(date("04.10.2026"))]?.map(\.id),
                       ["hearing-oct-04"])
        XCTAssertNil(septemberModel.itemsByDay[DateUtil.startOfDay(date("10.10.2026"))])

        for id in ["hearing-1000", "hearing-oct-01", "hearing-oct-04"] {
            XCTAssertEqual(septemberModel.seriesByID[id]?.index, octoberModel.seriesByID[id]?.index, id)
            XCTAssertEqual(septemberModel.seriesByID[id]?.total, octoberModel.seriesByID[id]?.total, id)
        }
        XCTAssertEqual(septemberModel.seriesByID["hearing-1000"]?.index, 3)
        XCTAssertEqual(septemberModel.seriesByID["hearing-1000"]?.total, 3)
        XCTAssertEqual(septemberModel.seriesByID["hearing-oct-01"]?.index, 1)
        XCTAssertEqual(septemberModel.seriesByID["hearing-oct-01"]?.total, 4)
        XCTAssertEqual(septemberModel.seriesByID["hearing-oct-04"]?.index, 2)
        XCTAssertEqual(septemberModel.seriesByID["hearing-oct-04"]?.total, 4)
        XCTAssertEqual(septemberModel.seriesByID["hearing-oct-10"]?.total, 4)
        XCTAssertEqual(septemberModel.overlapDayList, [dayKey])
        XCTAssertTrue(octoberModel.overlapDayList.isEmpty)

        let layout = CalendarMonthLayout.cellLayout(itemCount: expectedIDs.count, availableHeight: 70)
        XCTAssertEqual(layout.mode, .oneLineWithMore)
        XCTAssertEqual(layout.visibleCount, 2)
        XCTAssertEqual(layout.hiddenCount, 2)
        XCTAssertEqual(layout.visibleCount + layout.hiddenCount, expectedIDs.count)
    }

    func testCourtCollisionOutsideGridStillDisambiguatesSharedEvent() {
        let tver = "Центральный районный суд города Твери"
        let barnaul = "Центральный районный суд г. Барнаула"
        let model = CalendarScreen.buildMonthModel(month: date("01.09.2026"), events: [
            event("shared-week", on: date("28.09.2026"), at: "10:00", court: tver),
            event("outside-grid", on: date("10.10.2026"), at: "11:00", court: barnaul)
        ])

        XCTAssertEqual(model.itemsByDay[DateUtil.startOfDay(date("28.09.2026"))]?.map(\.id), ["shared-week"])
        XCTAssertNil(model.itemsByDay[DateUtil.startOfDay(date("10.10.2026"))])
        XCTAssertEqual(model.courtShort[tver], "Центральный р/с г. Твери")
        XCTAssertEqual(model.courtShort[barnaul], "Центральный р/с г. Барнаула")
    }

    func testMonthGridUsesHalfOpenRangeWithTimeOfDayBoundaries() {
        let grid = DateUtil.datesOfMonthGrid(date("01.09.2026"))
        let first = grid[0]
        let last = grid[grid.count - 1]
        let end = DateUtil.addDays(last, 1)
        let events = [
            event("before-start", on: time(DateUtil.addDays(first, -1), hour: 23, minute: 59, second: 59), at: "23:59"),
            event("at-start", on: first, at: "00:00"),
            event("inside-last-day", on: time(last, hour: 23, minute: 59, second: 59), at: "23:59"),
            event("at-end", on: end, at: "00:00")
        ]

        let model = CalendarScreen.buildMonthModel(month: date("01.09.2026"), events: events)
        let included = model.itemsByDay.values.flatMap { $0 }.map(\.id)
        XCTAssertEqual(Set(included), Set(["at-start", "inside-last-day"]))
        XCTAssertEqual(model.itemsByDay[DateUtil.startOfDay(first)]?.first?.date, first)
        XCTAssertEqual(model.itemsByDay[DateUtil.startOfDay(last)]?.first?.date,
                       time(last, hour: 23, minute: 59, second: 59))
    }

    func testSeriesCountsAllHearingsInEachVisibleMonth() {
        let caseNumber = "2-123/2026"
        let events = [
            event("aug-20", on: date("20.08.2026"), at: "09:00", court: "Суд А", caseNumber: caseNumber),
            event("aug-25", on: date("25.08.2026"), at: "10:00", court: "Суд А", caseNumber: caseNumber),
            event("aug-31", on: date("31.08.2026"), at: "11:00", court: "Суд А", caseNumber: caseNumber),
            event("sep-03", on: date("03.09.2026"), at: "09:00", court: "Суд А", caseNumber: caseNumber),
            event("sep-10", on: date("10.09.2026"), at: "10:00", court: "Суд А", caseNumber: caseNumber),
            event("sep-20", on: date("20.09.2026"), at: "11:00", court: "Суд А", caseNumber: caseNumber)
        ]

        let model = CalendarScreen.buildMonthModel(month: date("01.09.2026"), events: events)
        XCTAssertNil(model.itemsByDay[DateUtil.startOfDay(date("20.08.2026"))])
        XCTAssertNil(model.itemsByDay[DateUtil.startOfDay(date("25.08.2026"))])
        for (id, index) in [("aug-20", 1), ("aug-25", 2), ("aug-31", 3),
                            ("sep-03", 1), ("sep-10", 2), ("sep-20", 3)] {
            XCTAssertEqual(model.seriesByID[id]?.index, index, id)
            XCTAssertEqual(model.seriesByID[id]?.total, 3, id)
        }
    }

    func testActiveDeadlinesAndHistoryKeepTheirProjection() throws {
        let day = date("28.09.2026")
        let timestamp = time(day, hour: 11, minute: 2)
        let events = [
            event("proposed", on: timestamp, at: "11:02", kind: .deadlineProposed,
                  caseNumber: "case-proposed", deadlineId: "deadline-proposed", what: "Вид срока proposed"),
            event("confirmed", on: timestamp, at: "11:02", kind: .deadlineConfirmed,
                  caseNumber: "case-confirmed", deadlineId: "deadline-confirmed", what: "Вид срока confirmed"),
            event("overridden", on: timestamp, at: "11:02", kind: .deadlineOverridden,
                  caseNumber: "case-overridden", deadlineId: "deadline-overridden", what: "Вид срока overridden"),
            event("history", on: timestamp, at: "11:02", kind: .deadlineInactive,
                  caseNumber: "case-history", deadlineId: "deadline-history", what: "Вид срока history")
        ]

        let key = DateUtil.startOfDay(day)
        let models = [
            CalendarScreen.buildMonthModel(month: date("01.09.2026"), events: events),
            CalendarScreen.buildMonthModel(month: date("01.10.2026"), events: events)
        ]
        for model in models {
            let active = try XCTUnwrap(model.itemsByDay[key])
            XCTAssertEqual(Set(active.map(\.id)), Set(["proposed", "confirmed", "overridden"]))
            XCTAssertEqual(active.first { $0.id == "proposed" }?.kind, .deadlineProposed)
            XCTAssertEqual(active.first { $0.id == "confirmed" }?.kind, .deadlineConfirmed)
            XCTAssertEqual(active.first { $0.id == "overridden" }?.kind, .deadlineOverridden)
            for item in active {
                XCTAssertEqual(item.date, timestamp)
                XCTAssertEqual(item.time, "11:02")
                XCTAssertEqual(item.caseNumber, "case-\(item.id)")
                XCTAssertEqual(item.deadlineId, "deadline-\(item.id)")
                XCTAssertEqual(item.what, "Вид срока \(item.id)")
            }
            XCTAssertEqual(model.inactiveCountByDay[key], 1)
            XCTAssertFalse(active.contains { $0.id == "history" })
        }
    }
}
