import XCTest
@testable import SudrfKit

final class URLBuilderTests: XCTestCase {

    private let court = Court.syktyvkarskiy
    private var adm: Cartoteka {
        CartotekaRegistry.find(level: .district, id: "adm")!
    }

    func testSearchURLForAdminCase() throws {
        let builder = SudrfURLBuilder(court: court)
        let url = try builder.searchURL(cartoteka: adm, field: .caseNumber, value: "5-470/2026")
        let s = url.absoluteString

        XCTAssertTrue(s.hasPrefix("https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo"))
        XCTAssertTrue(s.contains("&name_op=r"))
        XCTAssertTrue(s.contains("&delo_id=1500001"))
        XCTAssertTrue(s.contains("&delo_table=adm_case"))
        XCTAssertTrue(s.contains("&adm_case__CASE_NUMBERSS=5-470%2F2026"))
        XCTAssertTrue(s.contains("&Submit=%CD%E0%E9%F2%E8"))
    }

    func testCardURL() throws {
        let builder = SudrfURLBuilder(court: court)
        let url = try builder.cardURL(caseID: "98765", caseUID: "GUID-1", deloID: "1500001")
        let s = url.absoluteString
        XCTAssertTrue(s.contains("&name_op=case"))
        XCTAssertTrue(s.contains("&case_id=98765"))
        XCTAssertTrue(s.contains("&case_uid=GUID-1"))
    }

    /// case_id/case_uid приходят из выдачи percent-декодированными — «враждебные»
    /// значения (пробелы, спецсимволы, кириллица) не должны ронять сборку URL,
    /// а обязаны перекодироваться.
    func testCardURLEscapesHostileValues() throws {
        let builder = SudrfURLBuilder(court: court)
        let url = try builder.cardURL(caseID: "98 765&x=1", caseUID: "GUID №1", deloID: "1500001")
        let s = url.absoluteString
        XCTAssertTrue(s.contains("&case_id=98%20765%26x%3D1"))
        XCTAssertFalse(s.contains("x=1&"))          // инъекция параметра не прошла
        XCTAssertTrue(s.contains("&case_uid=GUID%20%E2%84%961"))
    }

    func testFormURL() throws {
        let builder = SudrfURLBuilder(court: court)
        let url = try builder.formURL(adm)
        let s = url.absoluteString
        XCTAssertTrue(s.contains("&name_op=sf"))
        XCTAssertTrue(s.contains("&delo_id=1500001"))
    }

    func testSubjectAppealCarriesNew() throws {
        let g2 = CartotekaRegistry.find(level: .subject, id: "g2")!
        let c = Court(domain: "vs--komi.sudrf.ru", title: "ВС Коми", level: .subject)
        let url = try SudrfURLBuilder(court: c)
            .searchURL(cartoteka: g2, field: .caseNumber, value: "33-100/2026")
        XCTAssertTrue(url.absoluteString.contains("&new=5"))
    }
}
