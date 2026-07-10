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
                                                        file: StaticString = #file,
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
