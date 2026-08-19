import XCTest
@testable import SudrfApp

final class DateUtilTests: XCTestCase {
    func testRussianGoldenFormats() throws {
        let date = try XCTUnwrap(DateUtil.cal.date(from: DateComponents(year: 2026, month: 5, day: 14)))

        XCTAssertEqual(DateUtil.fmt(date), "14 мая")
        XCTAssertEqual(DateUtil.shortDM(date), "14.05")
        XCTAssertEqual(DateUtil.weekday(date), "Четверг")
        XCTAssertEqual(DateUtil.monthTitle(date), "Май 2026")
        XCTAssertEqual(DateUtil.weekdayShort, ["ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ", "ВС"])
    }

    func testParseRejectsInvalidCalendarDatesAndShortYears() {
        XCTAssertNil(DateUtil.parse("31.02.2026"))
        XCTAssertNil(DateUtil.parse("01.01.26"))
        XCTAssertNil(DateUtil.parse("01.01.2026.12"))
    }

    func testParseKeepsValidDateWithTime() {
        XCTAssertEqual(DateUtil.parse("28.02.2026 14:10"), DateUtil.parse("28.02.2026"))
    }
}
