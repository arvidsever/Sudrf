import XCTest
@testable import SudrfApp

final class DateUtilTests: XCTestCase {
    func testParseRejectsInvalidCalendarDatesAndShortYears() {
        XCTAssertNil(DateUtil.parse("31.02.2026"))
        XCTAssertNil(DateUtil.parse("01.01.26"))
        XCTAssertNil(DateUtil.parse("01.01.2026.12"))
    }

    func testParseKeepsValidDateWithTime() {
        XCTAssertEqual(DateUtil.parse("28.02.2026 14:10"), DateUtil.parse("28.02.2026"))
    }
}
