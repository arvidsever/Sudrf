import Foundation
import XCTest
@testable import SudrfKit

final class FSSPClientTests: XCTestCase {
    private var session: URLSession!
    private let endpoint = URL(string: "https://example.test/ajax_search")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        FSSPURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FSSPURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        FSSPURLProtocol.reset()
        try super.tearDownWithError()
    }

    func testInitialJSONPRequestUsesElectronicIDAndAllRegionsOnly() async throws {
        FSSPURLProtocol.enqueue(body: fixture("captcha"))
        let document = CourtEnforcementDocument(
            blankNumber: "ФС № 049373812", electronicID: "11RS0001#2-9143/2025#1")

        let step = try await client().discover(document: document)
        guard case .captchaRequired(let challenge) = step else {
            return XCTFail("Ожидалась CAPTCHA, получено \(step)")
        }
        XCTAssertEqual(challenge.codeID, "old-code")
        XCTAssertEqual(challenge.imagePNG, Data([251]), "HTML-encoded + в base64 должен восстановиться")
        XCTAssertEqual(challenge.courtDocumentID, document.id)

        let request = try XCTUnwrap(FSSPURLProtocol.requests().first)
        let query = try XCTUnwrap(URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "is[variant]" })?.value, "4")
        XCTAssertEqual(query.first(where: { $0.name == "is[region_id][0]" })?.value, "-1")
        XCTAssertEqual(query.first(where: { $0.name == "is[id_number]" })?.value,
                       "11RS0001#2-9143/2025#1")
        XCTAssertNil(query.first(where: { $0.name.lowercased().contains("name") }),
                     "В ФССП отправляется только опубликованный номер документа")
    }

    func testRejectedManualCodeReturnsFreshChallengeAndPreservesExactQuery() async throws {
        FSSPURLProtocol.enqueue(body: fixture("captcha"))
        FSSPURLProtocol.enqueue(body: fixture("new-captcha"))
        let document = searchedDocument()
        let first = try await client().discover(document: document)
        guard case .captchaRequired(let challenge) = first else {
            return XCTFail("Ожидалась первая CAPTCHA")
        }

        let second = try await client().submit(code: "12345", for: challenge, document: document)
        guard case .captchaRequired(let replacement) = second else {
            return XCTFail("Неверный код обязан вернуть новую CAPTCHA")
        }
        XCTAssertEqual(replacement.codeID, "new-code")
        XCTAssertNotEqual(replacement.codeID, challenge.codeID)

        let requests = FSSPURLProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        let submitted = try XCTUnwrap(URLComponents(url: requests[1], resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(submitted.first(where: { $0.name == "code" })?.value, "12345")
        XCTAssertEqual(submitted.first(where: { $0.name == "t" })?.value,
                       "eb6237r6793v6f")
        XCTAssertEqual(submitted.first(where: { $0.name == "code_id" })?.value, "old-code")
        XCTAssertEqual(submitted.first(where: { $0.name == "is[id_number]" })?.value,
                       "11RS0001#2-9143/2025#1")
    }

    func testManualSubmissionRejectsCrossOriginChallengeURL() async throws {
        let document = searchedDocument()
        let challenge = FSSPCaptchaChallenge(
            courtDocumentID: document.id,
            codeID: "cross-origin",
            imagePNG: Data([1]),
            requestURL: URL(string: "https://attacker.example/collect?code_id=cross-origin")!)

        let step = try await client().submit(code: "12345", for: challenge, document: document)
        guard case .error(let message) = step else {
            return XCTFail("Cross-origin CAPTCHA URL must be rejected")
        }
        XCTAssertTrue(message.contains("небезопасный адрес"))
        XCTAssertTrue(FSSPURLProtocol.requests().isEmpty)
    }

    func testFoundFixtureParsesExactFSSPFields() async throws {
        FSSPURLProtocol.enqueue(body: fixture("found"))

        let step = try await client().discover(document: searchedDocument())
        guard case .found(let lookup) = step, let record = lookup.record,
              let details = record.bailiffDetails else {
            return XCTFail("Ожидалась одна точно сопоставленная строка")
        }
        XCTAssertEqual(lookup.state, .found)
        XCTAssertEqual(record.source, .bailiffs)
        XCTAssertEqual(record.status, "")
        XCTAssertEqual(details.proceedingNumber, "587893/26/98078-ИП")
        XCTAssertEqual(details.proceedingOpenedRaw, "09.12.2025")
        XCTAssertEqual(details.previousProceedingNumbers, ["737102/25/98078-ИП"])
        XCTAssertEqual(details.debtor, "МКУ «ДЕКАБРИСТ» 199058, Санкт-Петербург, ул. Кораблестроителей, д. 35, ИНН 7801291202")
        XCTAssertEqual(details.executiveDocumentDetails,
                       "Исполнительный лист от 08.12.2025 № 11RS0001#2-9143/2025#1 СЫКТЫВКАРСКИЙ ГОРОДСКОЙ СУД")
        XCTAssertEqual(details.subjectAndOutstandingBalance,
                       "Иной вид исполнения неимущественного характера")
        XCTAssertEqual(details.department,
                       "СОСП по г. Санкт-Петербургу 190000, Россия, г. Санкт-Петербург, ул. Большая Морская, д. 59")
        XCTAssertEqual(details.bailiff, "ДЯДЧЕНКО Е. В.")
        XCTAssertEqual(details.bailiffPhone, "+7(920)084-63-47")
    }

    func testEmptyAndNonExactRowsBecomeNotFoundRatherThanFirstMatch() async throws {
        FSSPURLProtocol.enqueue(body: fixture("empty"))
        let empty = try await client().discover(document: searchedDocument())
        guard case .notFound = empty else { return XCTFail("Пустая выдача — notFound") }

        FSSPURLProtocol.enqueue(body: fixture("found"))
        let noExact = try await client().discover(document: CourtEnforcementDocument(
            electronicID: "11RS0001#2-9143/2025#10"))
        guard case .notFound = noExact else {
            return XCTFail("Нельзя выбирать первую приблизительную строку ФССП")
        }
    }

    func testMultipleExactRowsRemainAmbiguous() async throws {
        FSSPURLProtocol.enqueue(body: fixture("multiple"))
        let step = try await client().discover(document: searchedDocument())
        guard case .ambiguous(let lookup) = step else {
            return XCTFail("Несколько точных строк нельзя выбирать автоматически")
        }
        XCTAssertEqual(lookup.record?.discoveryState, .ambiguous)
        XCTAssertNil(lookup.record?.sourceRecordID)
    }

    func testHeaderMappingSurvivesColumnOrderDrift() async throws {
        FSSPURLProtocol.enqueue(body: fixture("columns-drift"))
        let step = try await client().discover(document: searchedDocument())
        guard case .found(let lookup) = step, let details = lookup.record?.bailiffDetails else {
            return XCTFail("Перестановка столбцов не должна превращать выдачу в ошибку")
        }
        XCTAssertEqual(details.proceedingNumber, "587893/26/98078-ИП")
        XCTAssertEqual(details.endOrTermination, "Окончено")
        XCTAssertEqual(details.department, "СОСП по г. Санкт-Петербургу")
        XCTAssertEqual(details.bailiff, "СИДОРОВ С. С.")
        XCTAssertEqual(details.bailiffPhone, "+7 901 111-22-33")
    }

    func testMalformedJSONPIsExplicitError() async throws {
        FSSPURLProtocol.enqueue(body: fixture("malformed"))
        let step = try await client().discover(document: searchedDocument())
        guard case .error(let message) = step else {
            return XCTFail("Повреждённый ответ не должен стать notFound")
        }
        XCTAssertTrue(message.contains("JSONP"))
    }

    func testTemporaryResponseRetriesOnceAndHonorsRetryAfterHeader() async throws {
        FSSPURLProtocol.enqueue(status: 503, headers: ["Retry-After": "0"], body: Data())
        FSSPURLProtocol.enqueue(body: fixture("empty"))

        let step = try await client(maxAttempts: 9).discover(document: searchedDocument())
        guard case .notFound = step else { return XCTFail("Вторая попытка должна использовать ответ") }
        XCTAssertEqual(FSSPURLProtocol.requests().count, 2,
                       "Только один повтор после временной ошибки")
    }

    func testOldEnforcementJSONDecodesWithoutBailiffDetails() throws {
        let old = """
        {"courtDocumentID":"court-document","source":"bailiffs","discoveryState":"found","status":"","events":[]}
        """
        let decoded = try JSONDecoder().decode(EnforcementRecord.self, from: Data(old.utf8))
        XCTAssertNil(decoded.bailiffDetails)
        XCTAssertEqual(decoded.discoveryState, .found)

        let new = EnforcementRecord(courtDocumentID: "court-document", source: .bailiffs,
                                    status: "", bailiffDetails: BailiffEnforcementDetails(
                                        proceedingNumber: "1/2/3-ИП"))
        XCTAssertEqual(try JSONDecoder().decode(EnforcementRecord.self,
                                                from: JSONEncoder().encode(new)).bailiffDetails,
                       new.bailiffDetails)
    }

    private func client(maxAttempts: Int = 2) -> FSSPClient {
        FSSPClient(session: session, minInterval: 0, endpoint: endpoint, maxAttempts: maxAttempts)
    }

    private func searchedDocument() -> CourtEnforcementDocument {
        CourtEnforcementDocument(electronicID: "11RS0001#2-9143/2025#1")
    }

    private func fixture(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "jsonp",
                                          subdirectory: "Fixtures/fssp"),
              let data = try? Data(contentsOf: url) else {
            XCTFail("Нет фикстуры FSSP \(name)")
            return Data()
        }
        return data
    }
}

private final class FSSPURLProtocol: URLProtocol {
    private struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    nonisolated(unsafe) private static var responses: [Response] = []
    nonisolated(unsafe) private static var seen: [URL] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responses = []
        seen = []
    }

    static func enqueue(status: Int = 200, headers: [String: String] = [:], body: Data) {
        lock.lock(); defer { lock.unlock() }
        responses.append(Response(status: status, headers: headers, body: body))
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
        let response = Self.responses.isEmpty
            ? Response(status: 500, headers: [:], body: Data())
            : Self.responses.removeFirst()
        Self.lock.unlock()

        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                                   headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
