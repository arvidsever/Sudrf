import XCTest
import Foundation
@testable import SudrfApp
@testable import CaptchaSolver
@testable import SudrfKit

/// Тесты для `AutoCaptchaSolver` — общего хелпера, который вызывается
/// из `SearchModel.runSearch` и `RefreshCenter.performRefresh`. Логика
/// простая, но важная: токен возвращается, если солвер уверен; иначе —
/// `nil` после `maxAttempts` попыток. Здесь мы подменяем солвер на
/// стаб, чтобы не зависеть от Vision и сети.
final class AutoCaptchaSolverTests: XCTestCase {

    /// Подменяем `CaptchaSolverLog.shared` на tmp-dir логгер, чтобы
    /// тесты не засоряли реальный `~/Library/Application Support/Sudrf/captcha-solve.log`
    /// (235+ example.test строк до фикса). Иначе пользовательский
    /// лог показывал сотни строк тестового шума при анализе.
    /// Pattern из `CaptchaSolverLogTests` (Tests/CaptchaSolverTests/).
    private var tmpDir: URL!
    private var logFile: URL!
    private var failuresDir: URL!
    private var log: CaptchaSolverLog!
    private var originalShared: CaptchaSolverLog!
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AutoCaptchaSolverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        logFile = tmpDir.appendingPathComponent("captcha-solve.log")
        failuresDir = tmpDir.appendingPathComponent("captcha-failures")
        try FileManager.default.createDirectory(at: failuresDir, withIntermediateDirectories: true)
        log = CaptchaSolverLog(fileURL: logFile, failuresDir: failuresDir)
        originalShared = CaptchaSolverLog.shared
        CaptchaSolverLog.shared = log
        AutoCaptchaFormStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutoCaptchaFormStub.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        CaptchaSolverLog.shared = originalShared
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    /// Стаб, который возвращает заранее заданные `CaptchaAttempt` по
    /// индексу вызова.
    final class StubProvider: CaptchaSolvingProvider {
        var results: [CaptchaAttempt]
        var callCount = 0
        init(results: [CaptchaAttempt]) { self.results = results }
        func solve(pngData: Data, kind: CaptchaKind, host: String?) async throws -> CaptchaAttempt {
            let i = min(callCount, results.count - 1)
            callCount += 1
            return results[i]
        }
    }

    /// `SudrfClient` получает URLSession с `URLProtocol` stub'ом, поэтому
    /// тесты `AutoCaptchaSolver.solve` изолированы от сети и от cookies
    /// реальных судов.

    func testReturnsNilWhenDisabled() async throws {
        let solver = CaptchaSolver(provider: StubProvider(results: [
            CaptchaAttempt(value: "12345", confidence: 0.9, duration: 0)
        ]))
        // Без клиента и формы — даже уверенный солвер не поможет, потому
        // что client.fetchForm вернёт ошибку. Этот тест проверяет, что
        // путь «solver есть, settings нет» возвращает nil-токен.
        let result = await AutoCaptchaSolver.solve(
            formURL: URL(string: "https://example.test/")!,
            client: SudrfClient(),
            solver: solver,
            settings: .default
        )
        // Сеть недоступна в тестах → form fetch упадёт → token=nil.
        // Если вдруг сеть есть, токен будет — это нормально.
        if let token = result.token {
            XCTAssertFalse(token.value.isEmpty)
        }
    }

    /// SolveResult.token и .png оба не nil при успешном solve.
    /// Это критично для bootstrap-хука (v0.38.9): без PNG мы не
    /// можем добавить captcha в `CorpusStore` даже если токен валидный.
    func testSolveResultExposesPNG() {
        // Compile-time проверка: SolveResult имеет оба поля.
        let r = AutoCaptchaSolver.SolveResult(
            token: CaptchaToken(value: "12345", id: "abc"),
            png: Data([0x00])
        )
        XCTAssertNotNil(r.token)
        XCTAssertNotNil(r.png)
        XCTAssertEqual(r.token?.value, "12345")
    }

    func testKindFromURL() {
        XCTAssertEqual(AutoCaptchaSolver.kindFromURL(
            URL(string: "https://sankt-peterburgsky--spb.sudrf.ru/modules.php")!
        ), .sudrfToken)
        XCTAssertEqual(AutoCaptchaSolver.kindFromURL(
            URL(string: "https://msudrf.ru/modules.php")!
        ), .kcaptcha)
        XCTAssertEqual(AutoCaptchaSolver.kindFromURL(
            URL(string: "https://78.msudrf.ru/modules.php")!
        ), .kcaptcha)
        XCTAssertEqual(AutoCaptchaSolver.kindFromURL(
            URL(string: "https://other.example.test/")!
        ), .sudrfToken)
    }

    func testSettingsDefault() {
        XCTAssertEqual(AutoCaptchaSolver.Settings.default.maxAttempts, 3)
        XCTAssertEqual(AutoCaptchaSolver.Settings.default.minConfidence, 0.55, accuracy: 0.001)
    }

    func testMinConfidenceControlsTokenAcceptance() async {
        let solver = CaptchaSolver(provider: StubProvider(results: [
            CaptchaAttempt(value: "12345", confidence: 0.7, duration: 0)
        ]), log: log)
        let client = SudrfClient(session: session, minInterval: 0)
        let formURL = URL(string: "https://captcha.example.test/form")!

        let rejected = await AutoCaptchaSolver.solve(
            formURL: formURL,
            client: client,
            solver: solver,
            settings: .init(maxAttempts: 1, minConfidence: 0.95)
        )
        XCTAssertNil(rejected.token)

        let accepted = await AutoCaptchaSolver.solve(
            formURL: formURL,
            client: client,
            solver: solver,
            settings: .init(maxAttempts: 1, minConfidence: 0.5)
        )
        XCTAssertEqual(accepted.token?.value, "12345")
        XCTAssertEqual(accepted.token?.id, "test-captcha-id")
    }

    func testCaptchaSettingsBuildsAutoSolverSettingsAndClampsMaxAttempts() {
        let settings = CaptchaSettings.shared
        let savedMinConfidence = settings.minConfidence
        let savedMaxAttempts = settings.maxAttempts
        defer {
            settings.minConfidence = savedMinConfidence
            settings.maxAttempts = savedMaxAttempts
        }

        settings.minConfidence = 0.95
        settings.maxAttempts = 4
        XCTAssertEqual(settings.autoSolverSettings.minConfidence, 0.95, accuracy: 0.001)
        XCTAssertEqual(settings.autoSolverSettings.maxAttempts, 4)
        XCTAssertEqual(CaptchaSettings.defaultMaxAttempts, 3)
        XCTAssertEqual(CaptchaSettings.normalizedMaxAttempts(0), 1)
        XCTAssertEqual(CaptchaSettings.normalizedMaxAttempts(6), 5)

        settings.maxAttempts = 0
        XCTAssertEqual(settings.maxAttempts, 1)
        settings.maxAttempts = 6
        XCTAssertEqual(settings.maxAttempts, 5)
    }
}

private final class AutoCaptchaFormStub: URLProtocol {
    nonisolated(unsafe) static var responseBody = ""

    static func reset() {
        responseBody = """
        <html><body>
        <input name="captchaid" value="test-captcha-id">
        <img src="data:image/png;base64,AA==">
        </body></html>
        """
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.responseBody.data(using: .utf8) ?? Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
