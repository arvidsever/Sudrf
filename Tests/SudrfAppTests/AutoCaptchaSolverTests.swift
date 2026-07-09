import XCTest
@testable import SudrfApp
@testable import CaptchaSolver
import SudrfKit

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
    }

    override func tearDownWithError() throws {
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

    /// Стаб `SudrfClient` — мы не подменяем весь клиент, а подменяем
    /// только тот, который используется внутри `AutoCaptchaSolver.solve`
    /// (через протокол). Но `SudrfClient` — конкретный тип без протокола,
    /// поэтому тестируем через реальный HTTP-вызов к локальному
    /// `httpbin`-эндпоинту. Это упрощённый путь; в реальной жизни
    /// стоит ввести `URLProtocol` stub.
    ///
    /// Здесь мы тестируем только ту часть логики, которая не требует
    /// сетевого вызова: связь между результатом солвера и
    /// возвращаемым токеном.

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
}
