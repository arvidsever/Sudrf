import XCTest
@testable import SudrfKit

final class Cyrillic1251Tests: XCTestCase {

    func testEncodeFindButton() {
        // «Найти» → cp1251 → percent — эталон из навыка.
        XCTAssertEqual(Cyrillic1251.percentEncodeQueryValue("Найти"), "%CD%E0%E9%F2%E8")
    }

    func testSingleCyrillicLetter() {
        XCTAssertEqual(Cyrillic1251.percentEncodeQueryValue("а"), "%E0")
    }

    func testKasCaseNumber() {
        // «2а-3021/2023» (а — кириллическая) → 2%E0-3021%2F2023
        XCTAssertEqual(Cyrillic1251.percentEncodeQueryValue("2а-3021/2023"), "2%E0-3021%2F2023")
    }

    func testAdminCaseNumberSlash() {
        XCTAssertEqual(Cyrillic1251.percentEncodeQueryValue("5-470/2026"), "5-470%2F2026")
    }

    func testSurname() {
        XCTAssertEqual(Cyrillic1251.percentEncodeQueryValue("Новожилов"),
                       "%CD%EE%E2%EE%E6%E8%EB%EE%E2")
    }

    func testSpaceBecomesPlus() {
        XCTAssertEqual(Cyrillic1251.percentEncodeQueryValue("Иванов Иван"),
                       "%C8%E2%E0%ED%EE%E2+%C8%E2%E0%ED")
    }

    func testRoundTrip() {
        let s = "Постановление № 5-470/2026"
        let data = Cyrillic1251.encodeBytes(s)
        XCTAssertNotNil(data)
        XCTAssertEqual(Cyrillic1251.decode(data!), s)
    }
}
