import XCTest
import Foundation
@testable import SudrfKit

final class DistrictResolverTests: XCTestCase {

    // MARK: region code

    func testRegionCodeFromDistrictDomain() {
        XCTAssertEqual(CourtDirectory.regionCode(forDomain: "syktsud--komi.sudrf.ru"), "komi")
        XCTAssertEqual(CourtDirectory.regionCode(forDomain: "http://ezhvinsky--komi.sudrf.ru/"), "komi")
    }

    func testRegionCodeFromSubjectDomain() {
        XCTAssertEqual(CourtDirectory.regionCode(forDomain: "vs.komi.sudrf.ru"), "komi")
        XCTAssertEqual(CourtDirectory.regionCode(forDomain: "oblsud.chel.sudrf.ru"), "chel")
    }

    func testRegionCodeFromRegionName() {
        XCTAssertEqual(CourtDirectory.regionCode(forRegion: "Коми"), "komi")
        XCTAssertEqual(CourtDirectory.regionCode(forRegion: "Свердловская область"), "svd")
        XCTAssertEqual(CourtDirectory.regionCode(forRegion: "Челябинская область"), "chel")
        XCTAssertEqual(CourtDirectory.regionCode(forRegion: "Санкт-Петербург"), "spb")
        XCTAssertEqual(CourtDirectory.regionCode(forRegion: "Нижегородская область"), "nnov")
    }

    func testRegionCodeDisambiguatesAutonomousOkrug() {
        // «Ямало-Ненецкий» не должен схлопнуться в «Ненецкий» из-за общего корня.
        XCTAssertEqual(CourtDirectory.regionCode(forRegion: "Ямало-Ненецкий автономный округ"), "ynao")
        XCTAssertEqual(CourtDirectory.regionCode(forRegion: "Ненецкий автономный округ"), "nao")
    }

    func testRegionCodeUnknown() {
        XCTAssertNil(CourtDirectory.regionCode(forDomain: "example.com"))
    }

    func testSubjectNumericCode() {
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Коми"), "11")
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Свердловская область"), "66")
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Москва"), "77")
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Ямало-Ненецкий автономный округ"), "89")
    }

    // MARK: parser (структура портала id=300)

    private let fixture = """
    <html><body><ul class='search-results'>
      <li><a name='item_0' onclick="listcontrol('court_0','11OS0000');" class='court-result'>Верховный Суд Республики Коми</a>
        <div class='courtInfoCont'><a href='http://vs.komi.sudrf.ru' TARGET='_blank'>http://vs.komi.sudrf.ru</a></div></li>
      <li><a name='item_1' onclick="listcontrol('court_1','78GV0008');" class='court-result'>Воркутинский гарнизонный военный суд</a>
        <div class='courtInfoCont'><a href='http://gvs.komi.sudrf.ru' TARGET='_blank'>http://gvs.komi.sudrf.ru</a></div></li>
      <li><a name='item_2' onclick="listcontrol('court_2','11RS0001');" class='court-result'>Сыктывкарский городской суд Республики Коми</a>
        <div class='courtInfoCont'><a href='mailto:syktsud.komi@sudrf.ru'>mail</a><a href='http://syktsud.komi.sudrf.ru' TARGET='_blank'>http://syktsud.komi.sudrf.ru</a></div></li>
      <li><a name='item_3' onclick="listcontrol('court_3','11RS0010');" class='court-result'>Эжвинский районный суд г. Сыктывкара Республики Коми</a>
        <div class='courtInfoCont'><a href='http://ejvasud.komi.sudrf.ru' TARGET='_blank'>http://ejvasud.komi.sudrf.ru</a></div></li>
    </ul></body></html>
    """

    func testParserSplitsByKind() {
        let courts = DistrictCourtParser.parse(html: fixture)
        XCTAssertEqual(courts.count, 4)
        let districts = courts.filter { $0.kind == .district }
        let military = courts.filter { $0.kind == .military }
        let subject = courts.filter { $0.kind == .subject }
        XCTAssertEqual(districts.count, 2)
        XCTAssertEqual(military.count, 1)
        XCTAssertEqual(subject.count, 1)
        XCTAssertTrue(districts.allSatisfy { $0.subjectNum == "11" })
        XCTAssertTrue(districts.contains { $0.domain == "syktsud.komi.sudrf.ru" && $0.code == "11RS0001" })
        XCTAssertEqual(military.first?.domain, "gvs.komi.sudrf.ru")
    }

    func testParserPicksOfficialSiteNotMailto() {
        let courts = DistrictCourtParser.parse(html: fixture)
        let sykt = courts.first { $0.code == "11RS0001" }
        XCTAssertEqual(sykt?.domain, "syktsud.komi.sudrf.ru") // mailto проигнорирован
    }

    func testHostExtraction() {
        XCTAssertEqual(DistrictCourtParser.sudrfHost(from: "http://syktsud.komi.sudrf.ru/page"),
                       "syktsud.komi.sudrf.ru")
        XCTAssertNil(DistrictCourtParser.sudrfHost(from: "https://google.com"))
        XCTAssertNil(DistrictCourtParser.sudrfHost(from: "mailto:syktsud.komi@sudrf.ru"))
    }
}

// MARK: - Регрессии сопоставления регионов (v12.1)

extension DistrictResolverTests {

    /// Каждое имя пикера (= имя таблицы) обязано вернуть СВОЙ портальный код.
    /// Раньше пять регионов ломались: Курская/Томская/Марий Эл давали пустые
    /// корни (молчаливый ноль судов), Республика Алтай и Сахалинская область
    /// маппились на чужие субъекты (Алтайский край, Якутию).
    func testEveryTableRegionResolvesToItsOwnCode() {
        for (name, code) in CourtDirectory.subjectCodeTable {
            XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: name), code,
                           "регион «\(name)» сопоставился не со своим кодом")
        }
    }

    func testFormerlyBrokenRegions() {
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Курская область"), "46")
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Томская область"), "70")
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Республика Марий Эл"), "12")
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Республика Алтай"), "02")
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Сахалинская область"), "65")
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Город Санкт-Петербург"), "78")
    }

    /// Свободный ввод: точный корень перевешивает префиксное пересечение.
    func testFreeFormQueries() {
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Сахалин"), "65")
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Курск"), "46")
        XCTAssertEqual(CourtDirectory.subjectNumericCode(forRegion: "Марий Эл"), "12")
    }

    /// Пустой ответ портала не должен помечать субъект «загруженным» — иначе
    /// временный сбой навсегда оставлял регион без судов (до чистки кэша).
    /// Косвенно закреплено сигнатурой: parse с меткой портального субъекта.
    func testParserTagsPortalSubject() {
        let html = #"""
        <ul><li><a class="court-result" onclick="listcontrol('x','78RS0001')">Невский районный суд</a>
        <a href="https://nvs.spb.sudrf.ru/">сайт</a></li></ul>
        """#
        let (courts, stats) = DistrictCourtParser.parseDetailed(html: html, portalSubject: "78")
        XCTAssertEqual(stats.anchors, 1)
        XCTAssertEqual(courts.first?.portalSubject, "78")
        XCTAssertEqual(courts.first?.codeLetters, "RS")
    }

    func testUntaggedMilitaryCacheDoesNotMarkSubjectLoaded() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DistrictResolverTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        // Nationwide harvest не передаёт court_subj. Код гарнизонного суда
        // совпадает с кодом субъекта дислокации, но не доказывает, что портал
        // уже загрузил все районные суды этого субъекта.
        let military = DistrictCourt(
            title: "Екатеринбургский гарнизонный военный суд",
            domain: "egvs.svd.sudrf.ru",
            code: "66GV0001",
            regionCode: "svd",
            kind: .military
        )
        try JSONEncoder().encode([military]).write(to: cacheURL)

        DistrictResolverStub.requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DistrictResolverStub.self]
        let client = SudrfClient(
            session: URLSession(configuration: configuration), minInterval: 0)
        let resolver = DistrictCourtResolver(client: client, cacheURL: cacheURL)

        let courts = try await resolver.courts(forRegion: "Свердловская область")

        XCTAssertEqual(DistrictResolverStub.requestCount, 1)
        XCTAssertEqual(courts.map(\.code), ["66RS0001"])
    }

    func testNationwideHarvestPreservesDiskCache() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DistrictResolverTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let persisted = DistrictCourt(
            title: "Сохранённый районный суд",
            domain: "saved.example.sudrf.ru",
            code: "11RS0001",
            regionCode: "komi",
            kind: .district,
            portalSubject: "11"
        )
        try JSONEncoder().encode([persisted]).write(to: cacheURL)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DistrictResolverStub.self]
        let resolver = DistrictCourtResolver(
            client: SudrfClient(session: URLSession(configuration: configuration), minInterval: 0),
            cacheURL: cacheURL
        )

        _ = try await resolver.courtsNationwide(type: "RS")
        let stored = try JSONDecoder().decode([DistrictCourt].self, from: Data(contentsOf: cacheURL))
        XCTAssertTrue(stored.contains { $0.domain == persisted.domain })
        XCTAssertTrue(stored.contains { $0.domain == "leninsky.svd.sudrf.ru" })
    }
}

private final class DistrictResolverStub: URLProtocol {
    nonisolated(unsafe) static var requestCount = 0

    private static let responseBody = """
    <ul><li><a class='court-result' onclick="listcontrol('x','66RS0001')">Ленинский районный суд Екатеринбурга</a>
    <a href='https://leninsky.svd.sudrf.ru/'>сайт</a></li></ul>
    """

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Буквенные типы кодов, снятые с живой выдачи портала (v12.2, проба по СПб)

extension DistrictResolverTests {
    func testKindLettersFromLivePortalProbe() {
        XCTAssertEqual(CourtKind(classificationCode: "78RS0015"), .district)   // Невский райсуд
        XCTAssertEqual(CourtKind(classificationCode: "78OS0000"), .subject)    // горсуд СПб
        XCTAssertEqual(CourtKind(classificationCode: "78OV0000"), .military)   // 1-й Западный ОВС
        XCTAssertEqual(CourtKind(classificationCode: "39GV0005"), .military)   // 224 ГВС (код «чужого» субъекта)
        XCTAssertEqual(CourtKind(classificationCode: "78AJ0002"), .appeal)     // Второй АСОЮ
        XCTAssertEqual(CourtKind(classificationCode: "78KJ0003"), .cassation)  // Третий КСОЮ
    }
}
