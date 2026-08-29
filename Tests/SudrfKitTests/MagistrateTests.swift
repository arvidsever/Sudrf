import XCTest
@testable import SudrfKit

final class MagistrateTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "html", subdirectory: "Fixtures"
        ))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testNumberExtractsFixedWidthMSCode() {
        let expected: [(String, Int)] = [
            ("11MS0001", 1), ("11MS0002", 2),
            ("11MS0010", 10), ("11MS0100", 100)
        ]

        for (code, number) in expected {
            XCTAssertEqual(
                MagistrateCourt(title: "Участок", domain: "example.msudrf.ru", code: code).number,
                number,
                code
            )
        }
    }

    func testNumberIsNilForMalformedCode() {
        for code in ["11MS001", "11MS00001", "11RS0001", "11MS00A1", "ⅪⅪMS0001"] {
            XCTAssertNil(
                MagistrateCourt(title: "Участок", domain: "example.msudrf.ru", code: code).number,
                code
            )
        }
    }

    func testDirectoryParserKeepsSupportedAndUnsupportedSites() {
        let html = """
        <html><body>
        <table class="msSearchResultTbl">
          <tr><td>
            <a onclick="listcontrol(0,&quot;11MS0010&quot;);">Первомайский судебный участок г. Сыктывкара Республики Коми</a>
            <div class="courtInfoCont" id="mir_0">
              <b>Классификационный код:</b> 11MS0010
              <a href="https://pervomaysky.komi.msudrf.ru">сайт</a>
            </div>
          </td></tr>
          <tr><td>
            <a onclick="listcontrol(1,&quot;78MS0001&quot;);">Судебный участок № 1 Санкт-Петербурга</a>
            <div class="courtInfoCont" id="mir_1">
              <a href="https://mirsud.spb.ru/cases">сайт</a>
            </div>
          </td></tr>
        </table>
        </body></html>
        """

        let courts = MagistrateCourtParser.parse(html: html, portalSubject: "11")

        XCTAssertEqual(courts.count, 2)
        XCTAssertTrue(courts.contains {
            $0.code == "11MS0010"
                && $0.domain == "pervomaysky.komi.msudrf.ru"
                && $0.isSupported
        })
        XCTAssertTrue(courts.contains {
            $0.code == "78MS0001"
                && $0.domain == "unsupported-ms:78MS0001"
                && !$0.isSupported
        })
    }

    func testDirectoryPrefersMSudrfLinkOverUnrelatedLink() {
        let html = """
        <table class="msSearchResultTbl"><tr><td>
        <a onclick="listcontrol(0,'11MS0010');">Участок</a>
        <div class="courtInfoCont"><a href="https://example.org">справка</a>
        <a href="https://site.komi.msudrf.ru">сайт</a></div>
        </td></tr></table>
        """
        XCTAssertEqual(MagistrateCourtParser.parse(html: html).first?.domain, "site.komi.msudrf.ru")
    }

    func testURLBuilderUsesUTF8QueryAndNoUIDSearch() throws {
        let court = Court(domain: "petrozavodskoj.komi.msudrf.ru",
                          title: "Петрозаводский судебный участок", level: .magistrate)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "g1"))
        let url = try MagistrateURLBuilder(court: court)
            .searchURL(cartoteka: cart, field: .name, value: "Вороб")

        XCTAssertTrue(url.absoluteString.contains("op=sf"))
        XCTAssertTrue(url.absoluteString.contains("delo_id=1540005"))
        XCTAssertTrue(url.absoluteString.contains("G1_PARTS__NAMESS=%D0%92%D0%BE%D1%80%D0%BE%D0%B1"))
        XCTAssertThrowsError(try MagistrateURLBuilder(court: court)
            .searchURL(cartoteka: cart, field: .uid, value: "11MS..."))
    }

    func testResolverUsesPersistedMagistrateCacheBeforeNetwork() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagistrateTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let persisted = MagistrateCourt(title: "Сохранённый участок",
                                        domain: "saved.komi.msudrf.ru",
                                        code: "11MS0001", portalSubject: "11")
        try JSONEncoder().encode([persisted]).write(to: cacheURL)

        MagistrateCacheStub.requestCount = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MagistrateCacheStub.self]
        let resolver = MagistrateCourtResolver(
            client: SudrfClient(session: URLSession(configuration: config), minInterval: 0),
            cacheURL: cacheURL
        )

        let courts = try await resolver.courts(forRegion: "Республика Коми")
        XCTAssertEqual(courts.map(\.code), ["11MS0001"])
        XCTAssertEqual(MagistrateCacheStub.requestCount, 0)
    }

    func testResultsParserParsesRowsAndPagination() throws {
        let html = """
        <div id="search_results">
          <div class="case-count">Найдено дел: 2</div>
          <a href="/modules.php?name=sud_delo&delo_id=1540005&op=sf&pageNum_Recordset1=1">2</a>
          <table id="tablcont" class="tablcont">
            <tr><td>Номер дела</td><td>Дата поступления</td><td>Информация по делу</td><td>Судья</td><td>Дата решения</td><td>Решение</td><td>Судебные акты</td></tr>
            <tr>
              <td><a href="/modules.php?name=sud_delo&amp;op=cs&amp;case_id=128701125&amp;delo_id=1540005">2-4004/2024</a></td>
              <td>10.10.2024</td><td>ИСТЕЦ: ООО</td><td>Бердашкевич</td><td>14.10.2024</td><td>Иск удовлетворен</td><td></td>
            </tr>
            <tr>
              <td><a href="/modules.php?name=sud_delo&amp;op=cs&amp;case_id=128701125&amp;delo_id=1540005">2-4004/2024</a></td>
              <td>10.10.2024</td><td>дубль стороны</td><td>Бердашкевич</td><td>14.10.2024</td><td>Иск удовлетворен</td><td></td>
            </tr>
          </table>
        </div>
        """
        let court = Court(domain: "petrozavodskoj.komi.msudrf.ru",
                          title: "Петрозаводский судебный участок", level: .magistrate)

        let rows = try MagistrateResultsParser.parse(html: html, court: court)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].caseNumber, "2-4004/2024")
        XCTAssertEqual(rows[0].caseID, "128701125")
        XCTAssertEqual(rows[0].caseUID, nil)
        XCTAssertEqual(rows[0].cardURL?.host, "petrozavodskoj.komi.msudrf.ru")
        XCTAssertEqual(MagistrateResultsParser.pageNumbers(html: html), [1])
    }

    func testUserArchivePositiveListingParsesWithoutFalseZero() throws {
        let html = try fixture("magistrate_results")
        let court = Court(domain: "petrozavodskoj.komi.msudrf.ru",
                          title: "Петрозаводский судебный участок", level: .magistrate)

        XCTAssertEqual(MagistratePageClassifier.classify(html: html), .results)
        let rows = try MagistrateResultsParser.parse(html: html, court: court)

        XCTAssertEqual(rows.map(\.caseNumber), ["2-871/2026", "2-775/2026", "9-452/2026"])
        XCTAssertEqual(rows.map(\.caseID), ["900000001", "900000002", "900000003"])
        XCTAssertEqual(Set(rows.compactMap(\.cardURL?.host)), [court.domain])
        XCTAssertEqual(MagistrateResultsParser.pageNumbers(html: html), [1])
    }

    func testMagistrateClassifierRequiresEvidenceForHonestZero() {
        XCTAssertEqual(MagistratePageClassifier.classify(
            html: #"<div id="search_results"><div class="case-count">Найдено дел: <b>0</b></div></div>"#
        ), .empty)
        XCTAssertEqual(MagistratePageClassifier.classify(
            html: #"<div id="search_results"><div class="case-count">Найдено дел: <b>5</b></div></div>"#
        ), .unrecognized)
        XCTAssertEqual(MagistratePageClassifier.classify(
            html: #"<div id="search_results"><div class="case-count"></div></div>"#
        ), .unrecognized)
        XCTAssertEqual(MagistratePageClassifier.classify(
            html: #"<div id="search_results"><a href="/help?case_id=1">справка</a></div>"#
        ), .unrecognized)
        XCTAssertEqual(MagistratePageClassifier.classify(
            html: #"<div id="search_results"><div class="case-count">Найдено дел:&nbsp;<b>0</b></div></div>"#
        ), .empty)
    }

    func testMagistrateClassifierPrioritizesCaptchaOverResultLinks() {
        let html = """
        <form id="kcaptchaForm">
          <img src="/captcha.php">
          <input type="text" name="captcha-response">
        </form>
        <div id="search_results">
          <a href="/modules.php?name=sud_delo&amp;op=cs&amp;case_id=42">5-42/2026</a>
        </div>
        """

        XCTAssertEqual(MagistratePageClassifier.classify(html: html), .captcha)
    }

    func testNewerMagistrateCardLinkVariantParses() throws {
        let html = """
        <div id="search_results"><div class="case-count">Найдено дел: <b>1</b></div>
          <table><tr><td><a href="/modules.php?name=sud_delo&amp;name_op=case&amp;case_id=42">
            5-42/2026
          </a></td></tr></table>
        </div>
        """
        let court = Court(domain: "example.msudrf.ru", title: "Участок", level: .magistrate)

        XCTAssertEqual(MagistratePageClassifier.classify(html: html), .results)
        XCTAssertEqual(try MagistrateResultsParser.parse(html: html, court: court).map(\.caseID), ["42"])
    }

    func testResultsDeduplicationFallsBackToRelativeCardURLWithoutCaseID() throws {
        let sameURL = try XCTUnwrap(URL(string: "modules.php?name=sud_delo&op=cs&row=same"))
        let otherURL = try XCTUnwrap(URL(string: "modules.php?name=sud_delo&op=cs&row=other"))
        let pageOne = [CaseSearchResult(caseNumber: "5-10/2026", cardURL: sameURL)]
        let pageTwo = [
            CaseSearchResult(caseNumber: "5-10/2026", cardURL: sameURL),
            CaseSearchResult(caseNumber: "5-10/2026", cardURL: otherURL)
        ]
        XCTAssertNil(pageOne[0].caseID)
        let rows = MagistrateResultsParser.deduplicated(pageOne + pageTwo)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0.cardURL?.absoluteString }, [
            "modules.php?name=sud_delo&op=cs&row=same",
            "modules.php?name=sud_delo&op=cs&row=other"
        ])
    }

    func testClientDeduplicatesRowsAcrossPages() async throws {
        MagistrateSearchStub.reset(responses: [
            "first": """
            <div id="search_results">
              <a href="/modules.php?name=sud_delo&amp;op=sf&amp;pageNum_Recordset1=1">2</a>
              <table><tr><td><a href="/modules.php?name=sud_delo&amp;op=cs&amp;case_id=same">5-10/2026</a></td></tr></table>
            </div>
            """,
            "1": """
            <div id="search_results"><table>
              <tr><td><a href="/modules.php?name=sud_delo&amp;op=cs&amp;case_id=same">5-10/2026</a></td></tr>
              <tr><td><a href="/modules.php?name=sud_delo&amp;op=cs&amp;case_id=other">5-10/2026</a></td></tr>
            </table></div>
            """
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MagistrateSearchStub.self]
        let client = MagistrateClient(
            sudrfClient: SudrfClient(session: URLSession(configuration: configuration), minInterval: 0))
        let court = Court(domain: "petrozavodskoj.komi.msudrf.ru",
                          title: "Петрозаводский судебный участок", level: .magistrate)
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "g1"))

        let rows = try await client.search(court: court, cartoteka: cartoteka,
                                           field: .caseNumber, value: "5-10/2026")

        XCTAssertEqual(rows.map(\.caseID), ["same", "other"])
        XCTAssertEqual(MagistrateSearchStub.requestCount, 2)
    }

    func testRejectedCaptchaContinuesManualCaptchaFlow() async throws {
        MagistrateSearchStub.reset(responses: [
            "first": "<main>Неверный проверочный код</main>"
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MagistrateSearchStub.self]
        let client = MagistrateClient(
            sudrfClient: SudrfClient(session: URLSession(configuration: configuration),
                                     minInterval: 0))
        let court = Court(domain: "petrozavodskoj.komi.msudrf.ru",
                          title: "Петрозаводский судебный участок", level: .magistrate)
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "g1"))

        do {
            _ = try await client.search(court: court, cartoteka: cartoteka,
                                        field: .caseNumber, value: "5-10/2026")
            XCTFail("отвергнутая captcha должна открыть ручной captcha-flow")
        } catch SudrfError.captchaRequired(let formURL) {
            XCTAssertEqual(formURL.host, court.domain)
        }
    }

    func testUnknownLaterPageFailsWholeListing() async throws {
        MagistrateSearchStub.reset(responses: [
            "first": """
            <div id="search_results">
              <a href="/modules.php?name=sud_delo&amp;op=sf&amp;pageNum_Recordset1=1">2</a>
              <table><tr><td><a href="/modules.php?name=sud_delo&amp;op=cs&amp;case_id=one">5-10/2026</a></td></tr></table>
            </div>
            """,
            "1": "<html><script>window.location='/protection'</script></html>"
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MagistrateSearchStub.self]
        let client = MagistrateClient(
            sudrfClient: SudrfClient(session: URLSession(configuration: configuration),
                                     minInterval: 0))
        let court = Court(domain: "petrozavodskoj.komi.msudrf.ru",
                          title: "Петрозаводский судебный участок", level: .magistrate)
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "g1"))

        do {
            _ = try await client.search(court: court, cartoteka: cartoteka,
                                        field: .caseNumber, value: "5-10/2026")
            XCTFail("неизвестная следующая страница не должна давать partial rows как полный результат")
        } catch SudrfError.searchModuleUnavailable(let domain) {
            XCTAssertEqual(domain, court.domain)
        }
    }

    func testPositiveCountWithoutParsableRowsIsParserFailureNotHonestZero() async throws {
        MagistrateSearchStub.reset(responses: [
            "first": #"<div id="search_results"><div class="case-count">Найдено дел: <b>5</b></div></div>"#
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MagistrateSearchStub.self]
        let client = MagistrateClient(
            sudrfClient: SudrfClient(session: URLSession(configuration: configuration), minInterval: 0))
        let court = Court(domain: "petrozavodskoj.komi.msudrf.ru",
                          title: "Петрозаводский судебный участок", level: .magistrate)
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "g1"))

        do {
            _ = try await client.search(court: court, cartoteka: cartoteka,
                                        field: .name, value: "Новикова")
            XCTFail("положительный счётчик без разобранных строк не должен давать honest zero")
        } catch SudrfError.searchModuleUnavailable(let domain) {
            XCTAssertEqual(domain, court.domain)
        }
    }

    func testExplicitZeroCrossesTypedBoundaryAsHonestZero() async throws {
        MagistrateSearchStub.reset(responses: [
            "first": #"<div id="search_results"><div class="case-count">Найдено дел: <b>0</b></div></div>"#
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MagistrateSearchStub.self]
        let provider = MagistrateClient(
            sudrfClient: SudrfClient(session: URLSession(configuration: configuration), minInterval: 0))
        let court = Court(domain: "example.msudrf.ru", title: "Участок", level: .magistrate)
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))

        let outcome = try await provider.searchOutcome(
            court: court, cartoteka: cartoteka, field: .name, value: "Нет такого лица"
        )

        guard case .honestZero(let attempt) = outcome else {
            return XCTFail("явный нулевой счётчик должен быть honestZero")
        }
        XCTAssertEqual(attempt.kind, .honestZero)
        XCTAssertEqual(attempt.provenance.sourceFamily, "msudrf")
    }

    func testTransportFailureDoesNotCrossTypedBoundaryAsHonestZero() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MagistrateTransportFailureStub.self]
        let transport = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0)
        await transport.setMaxAttemptsForTesting(1)
        let provider = MagistrateClient(sudrfClient: transport)
        let court = Court(domain: "example.msudrf.ru", title: "Участок", level: .magistrate)
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))

        let outcome = try await provider.searchOutcome(
            court: court, cartoteka: cartoteka, field: .name, value: "Новикова"
        )

        guard case .transportFailure(_, let attempt) = outcome else {
            return XCTFail("таймаут msudrf должен оставаться transportFailure")
        }
        XCTAssertEqual(attempt.kind, .transportFailure)
        XCTAssertEqual(attempt.provenance.attemptCount, 1)
    }

    func testCardParserReadsMagistrateTabs() throws {
        let html = """
        <div class="content lawcase-content">
          <h2>ДЕЛО № 2-4004/2024</h2>
          <div id="contentt">
            <div class="tab-content">
              <table>
                <tr><td>Уникальный идентификатор дела:</td><td>11MS0062-01-2024-005302-40</td></tr>
                <tr><td>Категория</td><td>О взыскании задолженности</td></tr>
                <tr><td>Председательствующий судья:</td><td>Бердашкевич Е. В.</td></tr>
                <tr><td>Дело рассмотрено (выдан приказ):</td><td>14.10.2024</td></tr>
                <tr><td>Результат рассмотрения:</td><td>Иск удовлетворен (Обжаловано)</td></tr>
                <tr><td>Дата вступления в законную силу:</td><td>14.08.2025</td></tr>
              </table>
            </div>
            <div class="tab-content">
              <table>
                <tr><td>Наименование события</td><td>Результат события</td><td>Дата события</td><td>Время события</td><td>Судья</td><td>Дата размещения</td></tr>
                <tr><td>Регистрация иска</td><td>Зарегистрировано</td><td>10.10.2024</td><td>09:00</td><td>Бердашкевич</td><td>10.10.2024</td></tr>
              </table>
            </div>
            <div class="tab-content">
              <table>
                <tr><td>Процессуальный статус лица</td><td>Лицо</td><td>Требования</td></tr>
                <tr><td>ИСТЕЦ</td><td>ООО Север</td><td></td></tr>
                <tr><td>ОТВЕТЧИК</td><td>Иванов И. И.</td><td></td></tr>
              </table>
            </div>
            <div class="tab-content"><div class="WordSection1"><p>РЕШЕНИЕ</p><p>Именем Российской Федерации</p></div></div>
          </div>
        </div>
        """

        let card = try MagistrateCardParser.parse(html: html)

        XCTAssertEqual(card.caseNumber, "2-4004/2024")
        XCTAssertEqual(card.uid, "11MS0062-01-2024-005302-40")
        XCTAssertEqual(card.judge, "Бердашкевич Е. В.")
        XCTAssertEqual(card.decisionDate, "14.10.2024")
        XCTAssertEqual(card.legalForceDate, "14.08.2025")
        XCTAssertEqual(card.sessions.first?.event, "Регистрация иска")
        XCTAssertEqual(card.parties.plaintiffs, ["ООО Север"])
        XCTAssertEqual(card.parties.defendants, ["Иванов И. И."])
        XCTAssertTrue(card.actText?.contains("Именем Российской Федерации") == true)
    }

    func testKCaptchaDetectedAndDateRules() {
        let html = """
        <h2>Для продолжения необходимо пройти дополнительную проверку</h2>
        <form method="post" id="kcaptchaForm">
          <img src="/captcha.php">
          <input type="text" name="captcha-response">
        </form>
        """

        XCTAssertTrue(CaptchaDetector.hasCaptcha(in: html))
        XCTAssertEqual(MagistratePageClassifier.classify(html: html), .captcha)
        XCTAssertTrue(MovementDateRule.before2026.matches(legalForceDate: "14.08.2025"))
        XCTAssertFalse(MovementDateRule.from2026.matches(legalForceDate: "14.08.2025"))
        XCTAssertFalse(MovementDateRule.before2026.matches(legalForceDate: "01.01.2026"))
        XCTAssertTrue(MovementDateRule.from2026.matches(legalForceDate: "01.01.2026"))
        XCTAssertTrue(MovementDateRule.before2026.matches(legalForceDate: nil))
        XCTAssertTrue(MovementDateRule.from2026.matches(legalForceDate: nil))
    }

    func testUnknownHTMLIsNotParsedAsEmptyMagistrateCard() {
        XCTAssertThrowsError(try MagistrateCardParser.parse(
            html: "<html><script>location='/protection'</script></html>"))
    }

    func testMaintenanceHTMLIsNotParsedAsEmptyMagistrateCard() {
        XCTAssertThrowsError(try MagistrateCardParser.parse(
            html: "<main>Информация временно недоступна. Попробуйте обратиться позже.</main>")) {
            guard case SudrfError.caseCardTemporarilyUnavailable = $0 else {
                return XCTFail("ожидалась maintenance-классификация, получено \($0)")
            }
        }
    }
}

private final class MagistrateCacheStub: URLProtocol {
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
    }
    override func stopLoading() {}
}

private final class MagistrateSearchStub: URLProtocol {
    nonisolated(unsafe) static var responseByPage: [String: String] = [:]
    nonisolated(unsafe) static var requestCount = 0

    static func reset(responses: [String: String]) {
        responseByPage = responses
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "pageNum_Recordset1" }?.value ?? "first"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((Self.responseByPage[page] ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MagistrateTransportFailureStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
}
