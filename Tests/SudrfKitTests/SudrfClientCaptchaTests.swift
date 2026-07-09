import XCTest
@testable import SudrfKit

/// Тесты для captcha-token invalidation в `SudrfClient.runVariants`.
/// v0.38.10: фикс wrong-token feedback loop — суд вернул страницу
/// с маркером «неверный проверочный код», наш токен в
/// `CaptchaTokenStore` больше не валиден, дальнейшие search
/// с тем же токеном дадут ту же ошибку.
///
/// Используем `URLProtocol` stub с кастомным `URLSessionConfiguration`
/// (глобально зарегистрированные protocol classes не подхватываются
/// `URLSessionConfiguration.default`, нужна явная конфигурация).
final class SudrfClientCaptchaTests: XCTestCase {

    private var tmpDir: URL!
    private var originalDir: URL!
    private var originalEnabled: Bool!
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Свой каталог для диагностики, чтобы не трогать реальный.
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SudrfClientCaptchaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        originalDir = SearchDiagnostics.setDirForTesting(tmpDir)
        originalEnabled = SearchDiagnostics.enabled
        SearchDiagnostics.enabled = true
        // URLProtocol stub: каждый тест сбрасывает responseBody в setUp.
        CaptchaRejectionStub.reset()
        // Создаём СВОЮ URLSessionConfiguration, явно с protocol class
        // stub'а. URLSession.shared и default configuration НЕ
        // подхватывают глобально зарегистрированные protocol classes.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CaptchaRejectionStub.self] + (cfg.protocolClasses ?? [])
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        SearchDiagnostics.enabled = originalEnabled
        SearchDiagnostics.setDirForTesting(originalDir)
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    /// **Главный тест для v0.38.10:** токен в `CaptchaTokenStore`
    /// инвалидируется, когда сервер возвращает `.captchaRejected`.
    /// Без фикса токен остаётся в хранилище, и следующий search
    /// попадает в ту же петлю (v0.38.7-0.38.9 баг).
    func testCaptchaRejectedInvalidatesToken() async throws {
        CaptchaRejectionStub.responseBody = stubHTML(rejectionMarker: "Неверно указан проверочный код с картинки")

        let store = CaptchaTokenStore()
        await store.store(
            CaptchaToken(value: "12345", id: "abc123"),
            domain: "spb.sudrf.ru"
        )
        let client = SudrfClient(session: session, captchaStore: store)

        do {
            _ = try await client.search(
                court: CaptchaRejectionStub.court,
                cartoteka: CaptchaRejectionStub.cartoteka,
                field: .caseNumber,
                value: "1-1/2026"
            )
            XCTFail("expected searchModuleUnavailable, got success")
        } catch SudrfError.searchModuleUnavailable {
            // expected
        }

        // Токен ДОЛЖЕН быть удалён из хранилища (это и есть фикс v0.38.10).
        let token = await store.token(forDomain: "spb.sudrf.ru")
        XCTAssertNil(token, "captcha token must be invalidated on .captchaRejected")
    }

    /// Дамп пишется в `rejected_<host>_<ts>.html`, не `variant_`.
    /// Без фикса дампы v0.38.6 смешивали «суд отверг токен» с
    /// «суд вернул неизвестный формат» — было сложно фильтровать.
    func testCaptchaRejectedDumpsWithRejectedPrefix() async throws {
        CaptchaRejectionStub.responseBody = stubHTML(rejectionMarker: "Неверно указан проверочный код с картинки")

        let store = CaptchaTokenStore()
        await store.store(
            CaptchaToken(value: "12345", id: "abc123"),
            domain: "spb.sudrf.ru"
        )
        let client = SudrfClient(session: session, captchaStore: store)

        _ = try? await client.search(
            court: CaptchaRejectionStub.court,
            cartoteka: CaptchaRejectionStub.cartoteka,
            field: .caseNumber,
            value: "1-1/2026"
        )

        let files = (try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        )) ?? []
        // Хотя бы один файл с префиксом rejected_, ни одного с variant_.
        let hasRejected = files.contains { $0.lastPathComponent.contains("_rejected") }
        let hasVariant = files.contains { $0.lastPathComponent.contains("_variant") }
        XCTAssertTrue(hasRejected, "expected at least one rejected_*.html, got: \(files.map { $0.lastPathComponent })")
        XCTAssertFalse(hasVariant, "rejection should NOT produce variant_*.html, got: \(files.map { $0.lastPathComponent })")
    }

    /// Если токен не был сохранён (первый search на captcha-включённом
    /// суде), `.captchaRejected` всё равно корректно пробрасывается
    /// без попытки инвалидировать (captcha == nil → skip).
    /// Это страховка от regression в `if captcha != nil` guard.
    func testCaptchaRejectedWithoutTokenDoesNotCrash() async throws {
        CaptchaRejectionStub.responseBody = stubHTML(rejectionMarker: "Invalid security code")

        let store = CaptchaTokenStore()
        // НЕ сохраняем токен — captcha == nil в runVariants.
        let client = SudrfClient(session: session, captchaStore: store)

        do {
            _ = try await client.search(
                court: CaptchaRejectionStub.court,
                cartoteka: CaptchaRejectionStub.cartoteka,
                field: .caseNumber,
                value: "1-1/2026"
            )
            XCTFail("expected searchModuleUnavailable")
        } catch SudrfError.searchModuleUnavailable {
            // expected, no crash
        }
    }

    // MARK: - Helpers

    /// Минимальный валидный HTML с маркером отказа суда.
    /// `rejectionMarker` — один из 5 маркеров из
    /// `SearchPageClassifier.captchaRejectedMarkers`.
    private func stubHTML(rejectionMarker: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta http-equiv="Content-Type" content="text/html; charset=windows-1251">
          <TITLE>Судебное делопроизводство</TITLE>
        </head>
        <body>
          <div id="error">\(rejectionMarker)</div>
        </body>
        </html>
        """
    }
}

// MARK: - URLProtocol stub

/// URLProtocol stub, отдающий захардкоженный HTML на любой запрос.
/// `responseBody` и тестовые Court/Cartoteka — статические, потому
/// что `URLProtocol.registerClass` создаёт экземпляры из самого
/// класса, без нашего участия. Каждый тест сбрасывает
/// `responseBody = ""` в `setUp` (через `reset()`) и выставляет
/// нужное перед клиентским вызовом.
private final class CaptchaRejectionStub: URLProtocol {

    /// Тело ответа, отдаётся на все запросы. Устанавливается из
    /// теста. Доступ через `CaptchaRejectionStub.responseBody = ...`.
    nonisolated(unsafe) static var responseBody: String = ""

    nonisolated(unsafe) static let court = Court(
        domain: "spb.sudrf.ru",
        title: "Санкт-Петербургский городской суд",
        level: .district
    )

    nonisolated(unsafe) static let cartoteka = Cartoteka(
        id: "g1",
        title: "Гражданское, 1-я инстанция",
        prefixes: ["2"],
        deloID: "1540005",
        deloTable: "g1_case",
        caseNumberField: "g1_case__CASE_NUMBERSS",
        uidField: "g1_case__JUDICIAL_UIDSS",
        nameField: "G1_PARTS__NAMESS"
    )

    /// Сбрасывает состояние stub'а перед каждым тестом.
    static func reset() {
        responseBody = ""
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.responseBody.data(using: .windowsCP1251)
            ?? Self.responseBody.data(using: .utf8)
            ?? Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=windows-1251"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
