import XCTest
import Foundation
@testable import SudrfKit

final class TreasuryClientTests: XCTestCase {
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TreasuryURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TreasuryURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        try super.tearDownWithError()
    }

    func testURLsUseUTF8Base64AndExactSearchParameterNames() {
        let baseURL = URL(string: "https://example.test")!
        let list = TreasuryClient.listURL(baseURL: baseURL, number: "ФС № 049373812")
        let query = try! XCTUnwrap(URLComponents(url: list, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "searchType" })?.value,
                       Data("list".utf8).base64EncodedString())
        XCTAssertEqual(query.first(where: { $0.name == "seriesNumberDoc" })?.value,
                       Data("ФС № 049373812".utf8).base64EncodedString())

        let blank = TreasuryClient.listURL(baseURL: baseURL)
        let blankQuery = try! XCTUnwrap(URLComponents(url: blank, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(blankQuery.first(where: { $0.name == "seriesNumberDoc" })?.value,
                       Data("".utf8).base64EncodedString())
        XCTAssertEqual(TreasuryClient.historyURL(baseURL: baseURL, documentID: "2003463")
            .host, "example.test")
    }

    func testLookupParsesCP1251ListHistoryDetailsAndNormalizesCurrentURLs() async throws {
        let baseURL = URL(string: "https://example.test")!
        TreasuryURLProtocol.setBody(listXML())
        TreasuryURLProtocol.setBody(historyXML(), for: "/roskazna/rss?history")
        TreasuryURLProtocol.setBody(detailsHTML(), for: "/roskazna/spring/document_details")

        let client = TreasuryClient(session: session, minInterval: 0, baseURL: baseURL,
                                     maxAttempts: 1)
        let document = CourtEnforcementDocument(date: "21.08.2025",
                                                blankNumber: "ФС № 049373812",
                                                courtStatus: "Выдан")
        let result = try await client.discover(document: document,
                                               caseNumber: "2-7212/2025",
                                               court: "Сыктывкарский городской суд")

        XCTAssertEqual(result.state, .found)
        let record = try XCTUnwrap(result.record)
        XCTAssertEqual(record.discoveryState, .found)
        XCTAssertEqual(record.sourceRecordID, "2003463")
        XCTAssertEqual(record.status, "Исполнен 05.09.2025")
        XCTAssertEqual(record.organization, "УФК по Республике Коми (Код 1100)")
        XCTAssertEqual(record.subdivision, "Отделение № 1")
        XCTAssertEqual(record.sourceUpdatedRaw, "05.09.2025")
        XCTAssertEqual(record.events.map(\.text), ["Зарегистрирован 01.09.2025", "Исполнен 05.09.2025"])
        XCTAssertTrue(record.events.allSatisfy { $0.id.hasPrefix("guid-") })
        XCTAssertEqual(record.sourceURL?.host, "example.test")
        XCTAssertFalse(record.sourceURL?.absoluteString.contains("zakupki.gov.ru") == true)
        XCTAssertNotNil(record.lastAttemptAt)
        XCTAssertNotNil(record.lastSuccessAt)

        XCTAssertTrue(TreasuryURLProtocol.requests().allSatisfy { $0.host == "example.test" })
    }

    func testStrictMatchingReturnsAmbiguousAndThenUsesExactDiscriminators() async throws {
        let baseURL = URL(string: "https://example.test")!
        TreasuryURLProtocol.setBody(ambiguousListXML())
        let client = TreasuryClient(session: session, minInterval: 0, baseURL: baseURL,
                                     maxAttempts: 1)
        let document = CourtEnforcementDocument(blankNumber: "ФС № 010000001")

        let ambiguous = try await client.discover(document: document)
        XCTAssertEqual(ambiguous.state, .ambiguous)
        XCTAssertEqual(ambiguous.record?.discoveryState, .ambiguous)
        XCTAssertNil(ambiguous.record?.sourceRecordID)

        TreasuryURLProtocol.setBody(listXML())
        TreasuryURLProtocol.setBody(historyXML(), for: "/roskazna/rss?history")
        TreasuryURLProtocol.setBody(detailsHTML(), for: "/roskazna/spring/document_details")
        let resolved = try await client.discover(
                                                  document: CourtEnforcementDocument(
                                                    date: "21.08.2025",
                                                    blankNumber: "ФС № 049373812"),
                                                  caseNumber: "2-7212/2025",
                                                  court: "Сыктывкарский городской суд")
        XCTAssertEqual(resolved.state, .found)
    }

    func testNotFoundIsAnExplicitPersistableState() async throws {
        let baseURL = URL(string: "https://example.test")!
        TreasuryURLProtocol.setBody(emptyListXML())
        let client = TreasuryClient(session: session, minInterval: 0, baseURL: baseURL,
                                     maxAttempts: 1)

        let result = try await client.discover(
            document: CourtEnforcementDocument(blankNumber: "ФС № 999999999"))

        XCTAssertEqual(result.state, .notFound)
        XCTAssertEqual(result.record?.discoveryState, .notFound)
        let record = try XCTUnwrap(result.record)
        XCTAssertNil(record.sourceRecordID)
        XCTAssertTrue(record.status.isEmpty)
        XCTAssertNoThrow(try JSONDecoder().decode(EnforcementRecord.self,
                                                   from: JSONEncoder().encode(record)))
    }

    func testCaptchaPageStopsInsteadOfBecomingNotFound() async throws {
        let baseURL = URL(string: "https://example.test")!
        TreasuryURLProtocol.setBody(Data("<html><body>Введите код с картинки</body></html>".utf8))
        let client = TreasuryClient(session: session, minInterval: 0, baseURL: baseURL,
                                     maxAttempts: 1)

        do {
            _ = try await client.discover(
                document: CourtEnforcementDocument(blankNumber: "ФС № 999999999"))
            XCTFail("CAPTCHA не должна превращаться в успешное «не найдено»")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("CAPTCHA"))
        }
    }

    func testConflictingDiscriminatorsNeverSelectDifferentCandidates() async throws {
        let baseURL = URL(string: "https://example.test")!
        TreasuryURLProtocol.setBody(conflictingListXML())
        let client = TreasuryClient(session: session, minInterval: 0, baseURL: baseURL,
                                     maxAttempts: 1)

        let result = try await client.discover(
            document: CourtEnforcementDocument(date: "02.02.2025",
                                               blankNumber: "ФС № 010000001"),
            caseNumber: "2-1/2025")

        XCTAssertEqual(result.state, .ambiguous)
        XCTAssertNil(result.record?.sourceRecordID)
    }

    func testHistoryPreservesRSSOrderForEqualDates() async throws {
        let baseURL = URL(string: "https://example.test")!
        TreasuryURLProtocol.setBody(listXML())
        TreasuryURLProtocol.setBody(equalDateHistoryXML(), for: "/roskazna/rss?history")
        TreasuryURLProtocol.setBody(detailsHTML(), for: "/roskazna/spring/document_details")
        let client = TreasuryClient(session: session, minInterval: 0, baseURL: baseURL,
                                     maxAttempts: 1)

        let result = try await client.discover(
            document: CourtEnforcementDocument(date: "21.08.2025",
                                               blankNumber: "ФС № 049373812"))
        let events = try XCTUnwrap(result.record?.events)
        XCTAssertEqual(events.map(\.sourceOrder), [0, 1])
        XCTAssertEqual(events.map(\.dateRaw),
                       ["Mon, 01 Sep 2025 00:00:00", "Mon, 01 Sep 2025 00:00:00"])
        XCTAssertEqual(events.map(\.text), ["Исполнен", "Зарегистрирован"])
    }

    private func listXML() -> Data {
        cyrillic1251("""
        <?xml version="1.0" encoding="windows-1251"?>
        <rss><channel><item>
          <title>Исполнительный документ ФС № 049373812</title>
          <link>http://zakupki.gov.ru/roskazna/spring/document_details?documentId=2003463</link>
          <description><![CDATA[<b>Наименование судебного органа, выдавшего исполнительный документ:&nbsp;</b>Сыктывкарский городской суд<br/><b>Дата выдачи исполнительного документа:&nbsp;</b>21.08.2025<br/><b>Номер судебного дела:&nbsp;</b>2-7212/2025<br/><b>Серия и номер исполнительного документа:&nbsp;</b>ФС № 049373812<br/><b>Стадия исполнения:&nbsp;</b>Выдан]]></description>
          <guid>http://zakupki.gov.ru/roskazna/spring/document_details?documentId=2003463</guid>
        </item></channel></rss>
        """)
    }

    private func historyXML() -> Data {
        cyrillic1251("""
        <?xml version="1.0" encoding="windows-1251"?>
        <rss><channel>
        <item><title>Исполнительный документ ФС № 049373812</title><link>http://zakupki.gov.ru/roskazna/spring/document_details?documentId=2003463</link><description><![CDATA[<b>Стадия исполнения:&nbsp;</b>Зарегистрирован 01.09.2025]]></description><guid>guid-1</guid><pubDate>Mon, 01 Sep 2025 00:00:00</pubDate></item>
        <item><title>Исполнительный документ ФС № 049373812</title><link>http://zakupki.gov.ru/roskazna/spring/document_details?documentId=2003463</link><description><![CDATA[<b>Стадия исполнения:&nbsp;</b>Исполнен 05.09.2025]]></description><guid>guid-2</guid><pubDate>Fri, 05 Sep 2025 00:00:00</pubDate></item>
        </channel></rss>
        """)
    }

    private func equalDateHistoryXML() -> Data {
        cyrillic1251("""
        <?xml version="1.0" encoding="windows-1251"?>
        <rss><channel>
        <item><title>Исполнительный документ ФС № 049373812</title><link>http://zakupki.gov.ru/roskazna/spring/document_details?documentId=2003463</link><description><![CDATA[<b>Стадия исполнения:&nbsp;</b>Исполнен]]></description><guid>guid-equal-2</guid><pubDate>Mon, 01 Sep 2025 00:00:00</pubDate></item>
        <item><title>Исполнительный документ ФС № 049373812</title><link>http://zakupki.gov.ru/roskazna/spring/document_details?documentId=2003463</link><description><![CDATA[<b>Стадия исполнения:&nbsp;</b>Зарегистрирован]]></description><guid>guid-equal-1</guid><pubDate>Mon, 01 Sep 2025 00:00:00</pubDate></item>
        </channel></rss>
        """)
    }

    private func detailsHTML() -> Data {
        guard let url = Bundle.module.url(forResource: "treasury_details_utf8",
                                          withExtension: "html", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }

    private func ambiguousListXML() -> Data {
        cyrillic1251("""
        <?xml version="1.0" encoding="windows-1251"?><rss><channel>
        <item><title>Исполнительный документ ФС № 010000001</title><link>https://zakupki.gov.ru/x?documentId=1</link><description><![CDATA[<b>Номер судебного дела:&nbsp;</b>2-1/2025<br/><b>Серия и номер исполнительного документа:&nbsp;</b>ФС № 010000001]]></description></item>
        <item><title>Исполнительный документ ФС № 010000001</title><link>https://zakupki.gov.ru/x?documentId=2</link><description><![CDATA[<b>Номер судебного дела:&nbsp;</b>2-2/2025<br/><b>Серия и номер исполнительного документа:&nbsp;</b>ФС № 010000001]]></description></item>
        </channel></rss>
        """)
    }

    private func emptyListXML() -> Data {
        cyrillic1251("<?xml version=\"1.0\" encoding=\"windows-1251\"?><rss><channel/></rss>")
    }

    private func conflictingListXML() -> Data {
        cyrillic1251("""
        <?xml version="1.0" encoding="windows-1251"?><rss><channel>
        <item><title>Исполнительный документ ФС № 010000001</title><link>https://zakupki.gov.ru/x?documentId=1</link><description><![CDATA[<b>Номер судебного дела:&nbsp;</b>2-1/2025<br/><b>Дата выдачи исполнительного документа:&nbsp;</b>01.01.2025<br/><b>Серия и номер исполнительного документа:&nbsp;</b>ФС № 010000001]]></description></item>
        <item><title>Исполнительный документ ФС № 010000001</title><link>https://zakupki.gov.ru/x?documentId=2</link><description><![CDATA[<b>Номер судебного дела:&nbsp;</b>2-2/2025<br/><b>Дата выдачи исполнительного документа:&nbsp;</b>02.02.2025<br/><b>Серия и номер исполнительного документа:&nbsp;</b>ФС № 010000001]]></description></item>
        </channel></rss>
        """)
    }

    private func cyrillic1251(_ string: String) -> Data {
        Cyrillic1251.encodeBytes(string) ?? Data(string.utf8)
    }
}

private final class TreasuryURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var defaultBody = Data()
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]
    nonisolated(unsafe) private static var seen: [URL] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        defaultBody = Data(); bodies = [:]; seen = []
    }

    static func setBody(_ data: Data, for path: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let path { bodies[path] = data } else { defaultBody = data }
    }

    static func requests() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.seen.append(url)
        let path = url.path
        let body: Data
        if path == "/roskazna/rss", url.query?.contains("documentId=") == true {
            body = Self.bodies["/roskazna/rss?history"] ?? Self.defaultBody
        } else {
            body = Self.bodies[path] ?? Self.defaultBody
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/xml; charset=cp1251"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
