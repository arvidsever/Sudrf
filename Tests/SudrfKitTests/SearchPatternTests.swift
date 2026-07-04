import XCTest
@testable import SudrfKit

/// Справочник винтажных судов и сборка VNKOD-вариантов поискового URL.
/// Эталонные строки выверены по боевым паттернам tochno-st/sudrfscraper
/// (searchpatterns/*.properties, VNKOD_PATTERN).
final class SearchPatternTests: XCTestCase {

    // Аннинский районный суд Воронежской области — из среза VNKODCourts.json.
    private let vnkodCourt = Court(domain: "anninsky--vrn.sudrf.ru",
                                   title: "Аннинский районный суд", level: .district)

    // MARK: - справочник

    func testDirectoryLoads101Courts() {
        let unique = Set(SearchPatternDirectory.byDomain.values.map(\.vnkod))
        XCTAssertEqual(unique.count, 101)
    }

    func testKnownCourtResolvesInBothHostForms() {
        XCTAssertEqual(SearchPatternDirectory.pattern(forDomain: "anninsky--vrn.sudrf.ru"), .vnkod)
        XCTAssertEqual(SearchPatternDirectory.pattern(forDomain: "anninsky.vrn.sudrf.ru"), .vnkod)
        XCTAssertEqual(SearchPatternDirectory.vnkod(forDomain: "anninsky--vrn.sudrf.ru"), "36RS0007")
        XCTAssertEqual(SearchPatternDirectory.vnkod(forDomain: "ANNINSKY--VRN.sudrf.ru"), "36RS0007")
    }

    func testUnknownCourtDefaultsToPrimary() {
        XCTAssertEqual(SearchPatternDirectory.pattern(forDomain: "syktsud--komi.sudrf.ru"), .primary)
        XCTAssertNil(SearchPatternDirectory.vnkod(forDomain: "syktsud--komi.sudrf.ru"))
    }

    // MARK: - варианты URL

    func testPrimaryCourtYieldsSingleVariant() throws {
        let court = Court(domain: "syktsud--komi.sudrf.ru", title: "Сыктывкарский", level: .district)
        let u1 = CartotekaRegistry.find(level: .district, id: "u1")!
        let variants = try SudrfURLBuilder(court: court)
            .searchURLVariants(cartoteka: u1, field: .caseNumber, value: "1-25/2026")
        XCTAssertEqual(variants.map(\.id), ["primary"])
        XCTAssertTrue(variants[0].url.absoluteString.contains("&delo_id=1540006"))
    }

    func testVNKODCriminalFirstInstanceVariants() throws {
        let u1 = CartotekaRegistry.find(level: .district, id: "u1")!
        let variants = try SudrfURLBuilder(court: vnkodCourt)
            .searchURLVariants(cartoteka: u1, field: .caseNumber, value: "1-25/2026")
        XCTAssertEqual(variants.map(\.id), ["vnkod:1540006:0:pt", "vnkod:1540006:0", "primary"])

        let s = variants[0].url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://anninsky--vrn.sudrf.ru/modules.php?name=sud_delo"))
        XCTAssertTrue(s.contains("&_deloId=1540006"))
        XCTAssertTrue(s.contains("&_new=0"))
        XCTAssertTrue(s.contains("&vnkod=36RS0007"))
        XCTAssertTrue(s.contains("&case__vnkod=36RS0007"))
        XCTAssertTrue(s.contains("&case__num_build=1"))
        XCTAssertTrue(s.contains("&process-type=1540006_0_0"))
        XCTAssertTrue(s.contains("&case__case_numberss=1-25%2F2026"))
        XCTAssertFalse(s.contains("&Submit="))              // винтажная форма без Submit
        XCTAssertFalse(variants[1].url.absoluteString.contains("process-type"))
    }

    func testVNKODUIDUsesGenericField() throws {
        let g1 = CartotekaRegistry.find(level: .district, id: "g1")!
        let variants = try SudrfURLBuilder(court: vnkodCourt)
            .searchURLVariants(cartoteka: g1, field: .uid, value: "36RS0007-01-2024-000123-45")
        XCTAssertTrue(variants[0].url.absoluteString.contains("&case__judicial_uidss=36RS0007-01-2024-000123-45"))
    }

    func testVNKODNameFieldHasPartFallback() throws {
        let g1 = CartotekaRegistry.find(level: .district, id: "g1")!
        let variants = try SudrfURLBuilder(court: vnkodCourt)
            .searchURLVariants(cartoteka: g1, field: .name, value: "Иванов")
        XCTAssertEqual(variants.map(\.id),
                       ["vnkod:1540005:0:pt", "vnkod:1540005:0", "vnkod:1540005:0:part", "primary"])
        // «Иванов» в cp1251: %C8%E2%E0%ED%EE%E2
        XCTAssertTrue(variants[0].url.absoluteString.contains("&parts__namess=%C8%E2%E0%ED%EE%E2"))
        XCTAssertTrue(variants[2].url.absoluteString.contains("&part__namess=%C8%E2%E0%ED%EE%E2"))
    }

    func testVNKODAppealMapsToFirstInstanceDeloID() throws {
        // Винтажная апелляция использует _deloId первой инстанции с _new
        // (в отличие от primary: delo_id=4&new=4).
        let u2 = CartotekaRegistry.find(level: .district, id: "u2")!
        let variants = try SudrfURLBuilder(court: vnkodCourt)
            .searchURLVariants(cartoteka: u2, field: .caseNumber, value: "10-1/2026")
        XCTAssertEqual(variants.map(\.id), ["vnkod:1540006:4", "primary"])
        let s = variants[0].url.absoluteString
        XCTAssertTrue(s.contains("&_deloId=1540006"))
        XCTAssertTrue(s.contains("&_new=4"))
        XCTAssertFalse(s.contains("process-type"))
    }

    func testVNKODKASTriesBothTables() throws {
        // На части винтажных судов КАС живёт в гражданской таблице (_deloId=1540005).
        let p1 = CartotekaRegistry.find(level: .district, id: "p1")!
        let variants = try SudrfURLBuilder(court: vnkodCourt)
            .searchURLVariants(cartoteka: p1, field: .caseNumber, value: "2а-1/2026")
        XCTAssertEqual(variants.map(\.id),
                       ["vnkod:41:0:pt", "vnkod:41:0", "vnkod:1540005:0:pt", "vnkod:1540005:0", "primary"])
    }

    func testVNKODCassationFallsBackToPrimary() throws {
        // Кассация/президиум: винтажная форма неизвестна — перебор из одного
        // primary-варианта, классификатор оценит ответ.
        let kraevoi = Court(domain: "kraevoi--krd.sudrf.ru",
                            title: "Краснодарский краевой суд", level: .subject)
        let u33 = CartotekaRegistry.find(level: .subject, id: "u33")!
        let variants = try SudrfURLBuilder(court: kraevoi)
            .searchURLVariants(cartoteka: u33, field: .caseNumber, value: "44у-1/2026")
        XCTAssertEqual(variants.map(\.id), ["primary"])
        XCTAssertTrue(variants[0].url.absoluteString.contains("&delo_id=2450001"))
    }

    func testCaptchaPairAppendedToEveryVariant() throws {
        let p1 = CartotekaRegistry.find(level: .district, id: "p1")!
        let token = CaptchaToken(value: "1234", id: "999888777")
        let variants = try SudrfURLBuilder(court: vnkodCourt)
            .searchURLVariants(cartoteka: p1, field: .caseNumber, value: "2а-1/2026",
                               captcha: token)
        XCTAssertEqual(variants.count, 5)
        for v in variants {
            XCTAssertTrue(v.url.absoluteString.hasSuffix("&captcha=1234&captchaid=999888777"),
                          v.url.absoluteString)
        }
        // Без токена суффикса нет.
        let plain = try SudrfURLBuilder(court: vnkodCourt)
            .searchURLVariants(cartoteka: p1, field: .caseNumber, value: "2а-1/2026")
        XCTAssertFalse(plain[0].url.absoluteString.contains("captcha="))
    }

    func testVNKODCardURL() throws {
        // Эталон — живой URL карточки Заволжского районного суда г. Ульяновска
        // (фикстура zavolgskiy_card.html из webarchive).
        let zavolgskiy = Court(domain: "zavolgskiy--uln.sudrf.ru",
                               title: "Заволжский районный суд", level: .district)
        let url = try SudrfURLBuilder(court: zavolgskiy).cardURL(
            caseID: "137806682", caseUID: "f455716b-ca7a-448d-91cf-55a56d28fb5a",
            deloID: "1540005", new: "0")
        XCTAssertEqual(url.absoluteString,
            "https://zavolgskiy--uln.sudrf.ru/modules.php?name=sud_delo&name_op=case"
          + "&_id=137806682&_uid=f455716b-ca7a-448d-91cf-55a56d28fb5a"
          + "&_deloId=1540005&_caseType=0&_new=0&srv_num=1")
    }

    func testVNKODCardURLMapsAppealDeloID() throws {
        // Апелляция: delo_id=4/new=4 современного модуля → _deloId=1540006&_new=4.
        let url = try SudrfURLBuilder(court: vnkodCourt).cardURL(
            caseID: "1", caseUID: "u", deloID: "4", new: "4")
        let s = url.absoluteString
        XCTAssertTrue(s.contains("&_deloId=1540006"))
        XCTAssertTrue(s.contains("&_new=4"))
    }

    func testPrimaryCardURLUnchanged() throws {
        let court = Court(domain: "syktsud--komi.sudrf.ru", title: "СГС", level: .district)
        let url = try SudrfURLBuilder(court: court).cardURL(
            caseID: "98765", caseUID: "GUID-1", deloID: "1500001")
        XCTAssertTrue(url.absoluteString.contains("&case_id=98765"))
        XCTAssertFalse(url.absoluteString.contains("&_id="))
    }

    func testVNKODFormURL() throws {
        let u1 = CartotekaRegistry.find(level: .district, id: "u1")!
        let url = try SudrfURLBuilder(court: vnkodCourt).formURL(u1)
        let s = url.absoluteString
        XCTAssertTrue(s.contains("&name_op=sf"))
        XCTAssertTrue(s.contains("&_deloId=1540006"))
        XCTAssertTrue(s.contains("&_caseType=0"))
        XCTAssertTrue(s.contains("&_new=0"))
    }
}
