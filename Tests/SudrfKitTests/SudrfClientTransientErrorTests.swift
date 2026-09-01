import XCTest
import Foundation
@testable import SudrfKit

/// Тесты transient-классификации `URLError → SudrfError.transientNetworkError`
/// в `SudrfClient.fetchHTMLData` (A16). Используем `URLProtocol` stub с
/// кастомным `URLSessionConfiguration` (по образцу `SudrfClientCaptchaTests`):
/// `URLSession.shared` / `.default` НЕ подхватывают глобально зарегистрированные
/// protocol classes, нужна явная конфигурация.
///
/// Скоуп A16: «защита от исчерпанных URLError с транзиентным кодом
/// (timeout / DNS / connection lost) после 3 попыток (= 2 повтора после первой)».
/// 5xx (`SudrfError.http`) и `.cancelled` НЕ входят в transient-классификацию
/// (тесты `testFatalURLErrorNotMarkedTransient_BadURL` и `_Cancelled`).
final class SudrfClientTransientErrorTests: XCTestCase {

    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Своя URLSession с явной конфигурацией protocol class — глобально
        // зарегистрированные классы не подхватываются default config'ом.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TransientErrorStub.self] + (cfg.protocolClasses ?? [])
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        TransientErrorStub.reset()
        try super.tearDownWithError()
    }

    /// Главный сценарий A16: 3 попытки с `URLError(.timedOut)` →
    /// `SudrfError.transientNetworkError` с `attempt == 3` (= maxAttempts).
    /// `requestCount == 3` (3 попытки = 2 повтора после первой).
    /// Pattern matching (SudrfError не Equatable): проверяем ассоциированные значения.
    func testTransientRetriesExhaustedThenThrowsTransientNetworkError() async throws {
        TransientErrorStub.failureCode = .timedOut
        let client = SudrfClient(session: session)
        let url = URL(string: "https://test.example/modules.html")!

        do {
            _ = try await client.fetchHTML(url)
            XCTFail("Ожидалось transientNetworkError после 3 попыток, получено success")
        } catch let thrownError {
            guard case SudrfError.transientNetworkError(let domain, let code, let attempt) = thrownError else {
                XCTFail("Ожидался SudrfError.transientNetworkError, получено \(thrownError)")
                return
            }
            XCTAssertEqual(domain, "test.example", "domain из url.host")
            XCTAssertEqual(code, .timedOut, "код URLError сохранён в typed error")
            XCTAssertEqual(attempt, 3, "attempt = maxAttempts (3 попытки = 2 повтора + 1 начальная)")
        }

        XCTAssertEqual(TransientErrorStub.requestCount, 3,
                       "3 попытки: 1 начальная + 2 повтора через backoff")
    }

    /// Параметризованный helper для двух кейсов: .badURL и .cancelled.
    /// `requestCount == 3` (3 попытки = 2 повтора), НЕ transient
    /// (isTransient для обоих false), проброс исходного URLError.
    private func assertFatalURLErrorNotMarkedTransient(code: URLError.Code,
                                                        file: StaticString = #filePath,
                                                        line: UInt = #line) async throws {
        TransientErrorStub.failureCode = code
        let client = SudrfClient(session: session)
        let url = URL(string: "https://test.example/modules.html")!

        do {
            _ = try await client.fetchHTML(url)
            XCTFail("Ожидался проброс URLError.\(code), получено success", file: file, line: line)
        } catch let thrownError {
            // НЕ transient (isTransient для .badURL / .cancelled == false)
            if case SudrfError.transientNetworkError = thrownError {
                XCTFail("Fatal URLError.\(code) не должен становиться transientNetworkError",
                        file: file, line: line)
            }
            // Пробросился именно исходный URLError с тем же кодом
            guard let urlErr = thrownError as? URLError else {
                XCTFail("Ожидался URLError.\(code), получено \(thrownError)", file: file, line: line)
                return
            }
            XCTAssertEqual(urlErr.code, code,
                           "исходный URLError.\(code) пробросился как есть", file: file, line: line)
        }

        XCTAssertEqual(TransientErrorStub.requestCount, 3,
                       "3 попытки = 2 повтора даже для fatal URLError",
                       file: file, line: line)
    }

    /// Fatal URLError: `.badURL` НЕ входит в `isTransient` (isTransient для
    /// .badURL false) → после 3 попыток проброс исходного `URLError(.badURL)`.
    /// `requestCount == 3` (3 попытки = 2 повтора) — `.badURL` это URLError,
    /// попадает в `catch let e as URLError`, ретраится как и все URLError'ы.
    func testFatalURLErrorNotMarkedTransient_BadURL() async throws {
        try await assertFatalURLErrorNotMarkedTransient(code: .badURL)
    }

    /// Fatal URLError: `.cancelled` НЕ входит в `isTransient` (isTransient
    /// для .cancelled false) → после 3 попыток проброс исходного
    /// `URLError(.cancelled)`. `requestCount == 3` (3 попытки = 2 повтора).
    /// Task-отмена не оставляет transient-stub в Movement (проверяется в
    /// `MovementServiceTests.testCancelledDoesNotCreateTransientStub`).
    func testFatalURLErrorNotMarkedTransient_Cancelled() async throws {
        try await assertFatalURLErrorNotMarkedTransient(code: .cancelled)
    }

    func testVariantTransportFailureFallsThroughToNextVariant() async throws {
        VariantFallbackStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [VariantFallbackStub.self]
        let client = SudrfClient(session: URLSession(configuration: cfg), minInterval: 0)
        await client.setMaxAttemptsForTesting(1)
        let court = Court(domain: "anninsky--vrn.sudrf.ru", title: "Аннинский районный суд", level: .district)
        let cartoteka = Cartoteka(id: "g1", title: "Гражданское", prefixes: ["2"],
                                  deloID: "1540005", deloTable: "g1_case",
                                  caseNumberField: "g1_case__CASE_NUMBERSS",
                                  uidField: "g1_case__JUDICIAL_UIDSS",
                                  nameField: "G1_PARTS__NAMESS")

        let results = try await client.search(court: court, cartoteka: cartoteka,
                                              field: .caseNumber, value: "2-1/2026")

        XCTAssertEqual(VariantFallbackStub.requestCount, 2)
        XCTAssertEqual(results.map(\.caseNumber), ["2-1/2026"])
    }

    func testMaintenanceHTMLNeverBecomesHonestZero() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MaintenanceStub.self]
        let client = SudrfClient(session: URLSession(configuration: cfg), minInterval: 0)
        await client.setMaxAttemptsForTesting(1)
        let court = Court(domain: "court--test.sudrf.ru", title: "Тестовый суд",
                          level: .district)
        let cartoteka = Cartoteka(id: "g1", title: "Гражданское", prefixes: ["2"],
                                  deloID: "1540005", deloTable: "g1_case",
                                  caseNumberField: "g1_case__CASE_NUMBERSS",
                                  uidField: "g1_case__JUDICIAL_UIDSS",
                                  nameField: "G1_PARTS__NAMESS")

        do {
            _ = try await client.search(court: court, cartoteka: cartoteka,
                                        field: .caseNumber, value: "2-1/2026")
            XCTFail("maintenance нельзя возвращать как пустую выдачу")
        } catch SudrfError.sourceMaintenance(let domain) {
            XCTAssertEqual(SudrfHost.moduleHost(domain),
                           SudrfHost.moduleHost(court.domain))
        }
    }

    func testMaintenanceRetriesSameURLBeforeReturningHTML() async throws {
        MaintenanceThenResultsStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MaintenanceThenResultsStub.self]
        let client = SudrfClient(session: URLSession(configuration: cfg), minInterval: 0)

        let url = URL(string: "https://court--test.sudrf.ru/modules.php?name=sud_delo&name_op=r")!
        let html = try await client.fetchHTML(url)

        XCTAssertTrue(html.contains("2-1/2026"), "последний пригодный ответ должен вернуться")
        XCTAssertEqual(MaintenanceThenResultsStub.requestURLs, [url, url, url],
                       "maintenance должен повторять тот же URL в той же сессии")
    }

    func testCardMaintenanceRetriesBeforeParsingCard() async throws {
        MaintenanceThenResultsStub.reset(finalBody:
            "<div class='casenumber'>ДЕЛО № 7У-1077/2024 [77-762/2024]</div>")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MaintenanceThenResultsStub.self]
        let client = SudrfClient(session: URLSession(configuration: cfg), minInterval: 0)
        let url = URL(string: "https://3kas.sudrf.ru/modules.php?name=sud_delo&name_op=case")!

        let card = try await client.fetchCard(url: url)

        XCTAssertEqual(card.caseNumber, "7У-1077/2024 [77-762/2024]")
        XCTAssertEqual(MaintenanceThenResultsStub.requestURLs, [url, url, url])
    }

    func testEmptyVariantMixedWithFailureIsNotHonestZero() async throws {
        EmptyThenFailureStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [EmptyThenFailureStub.self]
        let client = SudrfClient(session: URLSession(configuration: cfg), minInterval: 0)
        await client.setMaxAttemptsForTesting(1)
        let court = Court(domain: "court--test.sudrf.ru", title: "Тестовый суд",
                          level: .district)
        let cartoteka = Cartoteka(id: "g1", title: "Гражданское", prefixes: ["2"],
                                  deloID: "1540005", deloTable: "g1_case",
                                  caseNumberField: "g1_case__CASE_NUMBERSS",
                                  uidField: "g1_case__JUDICIAL_UIDSS",
                                  nameField: "G1_PARTS__NAMESS")

        do {
            let rows = try await client.search(court: court, cartoteka: cartoteka,
                                               field: .caseNumber, value: "2-1/2026")
            XCTFail("mixed empty + failure нельзя считать honest-zero: \(rows)")
        } catch {
            XCTAssertGreaterThan(EmptyThenFailureStub.requestCount, 1)
        }
    }

    func testCaptchaRejectedRemainsMonotonicAcrossUnknownVariant() async throws {
        RejectedThenUnknownStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RejectedThenUnknownStub.self]
        let client = SudrfClient(session: URLSession(configuration: cfg), minInterval: 0)
        await client.setMaxAttemptsForTesting(1)
        let court = Court(domain: "court--test.sudrf.ru", title: "Тестовый суд",
                          level: .district)
        let cartoteka = Cartoteka(id: "g1", title: "Гражданское", prefixes: ["2"],
                                  deloID: "1540005", deloTable: "g1_case",
                                  caseNumberField: "g1_case__CASE_NUMBERSS",
                                  uidField: "g1_case__JUDICIAL_UIDSS",
                                  nameField: "G1_PARTS__NAMESS")

        do {
            _ = try await client.search(court: court, cartoteka: cartoteka,
                                        field: .caseNumber, value: "2-1/2026")
            XCTFail("captcha rejection хотя бы одного варианта должен продолжить captcha-flow")
        } catch SudrfError.captchaRequired(let formURL) {
            XCTAssertEqual(SudrfHost.moduleHost(formURL.host ?? ""),
                           SudrfHost.moduleHost(court.domain))
            XCTAssertGreaterThan(RejectedThenUnknownStub.requestCount, 1)
        }
    }

    func testCaptchaRejectedTakesPrecedenceOverMaintenanceVariant() async throws {
        RejectedThenMaintenanceStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RejectedThenMaintenanceStub.self]
        let client = SudrfClient(session: URLSession(configuration: cfg), minInterval: 0)
        await client.setMaxAttemptsForTesting(1)
        let court = Court(domain: "court--test.sudrf.ru", title: "Тестовый суд",
                          level: .district)
        let cartoteka = Cartoteka(id: "g1", title: "Гражданское", prefixes: ["2"],
                                  deloID: "1540005", deloTable: "g1_case",
                                  caseNumberField: "g1_case__CASE_NUMBERSS",
                                  uidField: "g1_case__JUDICIAL_UIDSS",
                                  nameField: "G1_PARTS__NAMESS")

        do {
            _ = try await client.search(court: court, cartoteka: cartoteka,
                                        field: .caseNumber, value: "2-1/2026")
            XCTFail("rejected CAPTCHA должен сохранять continuation при maintenance другого варианта")
        } catch SudrfError.captchaRequired {
            XCTAssertGreaterThan(RejectedThenMaintenanceStub.requestCount, 1)
        }
    }

    func testCancelledPrimaryHostDoesNotFallBack() async throws {
        CancelThenSuccessStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CancelThenSuccessStub.self]
        let client = SudrfClient(session: URLSession(configuration: cfg), minInterval: 0)
        await client.setMaxAttemptsForTesting(1)
        let court = Court(domain: "court--test.sudrf.ru", title: "Тестовый суд",
                          level: .district)
        let cartoteka = Cartoteka(id: "g1", title: "Гражданское", prefixes: ["2"],
                                  deloID: "1540005", deloTable: "g1_case",
                                  caseNumberField: "g1_case__CASE_NUMBERSS",
                                  uidField: "g1_case__JUDICIAL_UIDSS",
                                  nameField: "G1_PARTS__NAMESS")

        do {
            _ = try await client.search(court: court, cartoteka: cartoteka,
                                        field: .caseNumber, value: "2-1/2026")
            XCTFail("cancelled primary host не должен запускать alternate-host fallback")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(CancelThenSuccessStub.requestCount, 1)
        }
    }
}

/// URLProtocol-stub, отдающий `didFailWithError(URLError(code))` на каждый
/// запрос. Считает `requestCount` (static) для ассертов в тестах.
private final class TransientErrorStub: URLProtocol {

    nonisolated(unsafe) static var failureCode: URLError.Code = .timedOut
    nonisolated(unsafe) static private(set) var requestCount: Int = 0

    static func reset() {
        requestCount = 0
        failureCode = .timedOut
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let err = URLError(Self.failureCode)
        client?.urlProtocol(self, didFailWithError: err)
    }

    override func stopLoading() {}
}

private final class VariantFallbackStub: URLProtocol {
    nonisolated(unsafe) static private(set) var requestCount = 0

    static func reset() { requestCount = 0 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        if Self.requestCount == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let html = "<table><tr><td><a href='?name_op=case&case_id=1&case_uid=u'>2-1/2026</a></td></tr></table>"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=windows-1251"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MaintenanceStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let html = "<main>Информация временно недоступна. Попробуйте обратиться позже.</main>"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MaintenanceThenResultsStub: URLProtocol {
    nonisolated(unsafe) static private(set) var requestURLs: [URL] = []
    nonisolated(unsafe) static private var finalBody =
        "<table><tr><td><a href='modules.php?name=sud_delo&name_op=case&case_id=1&case_uid=u'>2-1/2026</a></td></tr></table>"

    static func reset(finalBody: String? = nil) {
        requestURLs = []
        self.finalBody = finalBody
            ?? "<table><tr><td><a href='modules.php?name=sud_delo&name_op=case&case_id=1&case_uid=u'>2-1/2026</a></td></tr></table>"
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requestURL = request.url!
        Self.requestURLs.append(requestURL)
        let body: String
        if Self.requestURLs.count < 3 {
            body = "<main>Информация временно недоступна. Попробуйте обратиться позже.</main>"
        } else {
            body = Self.finalBody
        }
        let response = HTTPURLResponse(url: requestURL, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class EmptyThenFailureStub: URLProtocol {
    nonisolated(unsafe) static private(set) var requestCount = 0

    static func reset() { requestCount = 0 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard Self.requestCount == 1 else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let html = "<main>Данных по запросу не обнаружено</main>"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RejectedThenUnknownStub: URLProtocol {
    nonisolated(unsafe) static private(set) var requestCount = 0

    static func reset() { requestCount = 0 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let html: String
        switch Self.requestCount {
        case 1: html = "<html><form id='search-form'></form></html>" // form precheck
        case 2: html = "<main>Неверный проверочный код</main>"
        default: html = "<html><script>window.location='/protection'</script></html>"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RejectedThenMaintenanceStub: URLProtocol {
    nonisolated(unsafe) static private(set) var requestCount = 0
    static func reset() { requestCount = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        let html: String
        switch Self.requestCount {
        case 1: html = "<html><form id='search-form'></form></html>"
        case 2: html = "<main>Неверный проверочный код</main>"
        default: html = "<main>Информация временно недоступна. Попробуйте обратиться позже.</main>"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CancelThenSuccessStub: URLProtocol {
    nonisolated(unsafe) static private(set) var requestCount = 0

    static func reset() { requestCount = 0 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        if Self.requestCount == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let html = "<main>Данных по запросу не обнаружено</main>"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
