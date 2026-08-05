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

    // MARK: - Экземпляр базы суда (srv_num)
    //
    // У крупных судов несколько экземпляров базы, и дела распределены между ними:
    // обход только первого даёт молча неполную выдачу. Значение по умолчанию
    // обязано сохранять прежние URL — на них завязаны остальные фикстурные тесты.

    func testDefaultSrvNumKeepsFirstInstance() throws {
        let builder = SudrfURLBuilder(court: court)
        XCTAssertEqual(builder.srvNum, 1)
        for s in [
            try builder.searchURL(cartoteka: adm, field: .caseNumber, value: "5-470/2026").absoluteString,
            try builder.formURL(adm).absoluteString,
            try builder.cardURL(caseID: "1", caseUID: "U", deloID: "1500001").absoluteString
        ] {
            XCTAssertTrue(s.contains("&srv_num=1"), s)
            // параметр не задвоился при подстановке
            XCTAssertEqual(s.components(separatedBy: "srv_num=").count - 1, 1, s)
        }
    }

    func testSrvNumAppliesToSearchFormAndCard() throws {
        let builder = SudrfURLBuilder(court: court, srvNum: 3)
        for s in [
            try builder.searchURL(cartoteka: adm, field: .caseNumber, value: "5-470/2026").absoluteString,
            try builder.formURL(adm).absoluteString,
            try builder.cardURL(caseID: "1", caseUID: "U", deloID: "1500001").absoluteString
        ] {
            XCTAssertTrue(s.contains("&srv_num=3"), s)
            XCTAssertFalse(s.contains("&srv_num=1"), s)
        }
    }

    /// Карточку дела, найденного на втором экземпляре, надо забирать оттуда же —
    /// поэтому srv_num живёт на builder'е, а не на отдельном вызове.
    func testCassationListingCarriesSrvNum() throws {
        let g3 = CartotekaRegistry.find(level: .cassation, id: "g3")!
        let ksoyu = Court(domain: "3kas.sudrf.ru", title: "Третий КСОЮ", level: .cassation)
        let s = try SudrfURLBuilder(court: ksoyu, srvNum: 2)
            .searchURL(cartoteka: g3, field: .caseNumber, value: "88-100/2026").absoluteString
        XCTAssertTrue(s.contains("&srv_num=2"))
        XCTAssertTrue(s.contains("&delo_table=g33_case"))
    }

    /// `WorkingVariantStore` кэширует рабочий вариант по его id: вариант, сработавший
    /// на одном экземпляре базы, не должен подставляться вместо другого.
    func testVariantIDDistinguishesSrvNum() throws {
        let first = try SudrfURLBuilder(court: court)
            .searchURLVariants(cartoteka: adm, field: .caseNumber, value: "5-470/2026")
        let second = try SudrfURLBuilder(court: court, srvNum: 2)
            .searchURLVariants(cartoteka: adm, field: .caseNumber, value: "5-470/2026")

        XCTAssertEqual(first.first?.id, "primary")          // прежний ключ не изменился
        XCTAssertEqual(second.first?.id, "primary:srv2")
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
    }

    func testSrvNumBelowOneClampsToFirstInstance() throws {
        let builder = SudrfURLBuilder(court: court, srvNum: 0)
        XCTAssertEqual(builder.srvNum, 1)
        XCTAssertTrue(try builder.formURL(adm).absoluteString.contains("&srv_num=1"))
    }
}
