import XCTest
@testable import CaptchaSolver
import SudrfKit

/// Базовая проверка скелета солвера. Полные тесты (точность на размеченных
/// фикстурах) добавляются в фазе 5 после `VisionOCRStrategy` и сбора 30+
/// фикстур в `Fixtures/sudrf` и `Fixtures/msudrf`.
final class CaptchaSolverTests: XCTestCase {

    func testStubReturnsEmptyAttempt() async throws {
        let solver = CaptchaSolver(provider: VisionOCRStrategy())
        let attempt = try await solver.solve(pngData: Data([0x00]), kind: .sudrfToken)
        XCTAssertEqual(attempt.value, "")
        XCTAssertEqual(attempt.confidence, 0.0)
    }

    func testDisabledKindReturnsEmpty() async throws {
        var config = CaptchaConfiguration.default
        config.enabledKinds = [.kcaptcha]
        let solver = CaptchaSolver(provider: VisionOCRStrategy(), configuration: config)
        let attempt = try await solver.solve(pngData: Data([0x00]), kind: .sudrfToken)
        XCTAssertEqual(attempt.value, "")
        XCTAssertEqual(attempt.confidence, 0.0)
    }

    func testEnabledKindPassesThrough() async throws {
        var config = CaptchaConfiguration.default
        config.enabledKinds = [.kcaptcha]
        let solver = CaptchaSolver(provider: VisionOCRStrategy(), configuration: config)
        let attempt = try await solver.solve(pngData: Data([0x00]), kind: .kcaptcha)
        XCTAssertEqual(attempt.value, "")
        XCTAssertEqual(attempt.confidence, 0.0)
    }

    func testConfigurationDefaults() {
        let config = CaptchaConfiguration.default
        XCTAssertEqual(config.maxAttempts, 3)
        XCTAssertEqual(config.minConfidence, 0.55, accuracy: 0.001)
        XCTAssertEqual(config.minIntervalMs, 50)
        XCTAssertEqual(config.enabledKinds, [.sudrfToken, .kcaptcha])
    }

    func testAttemptIsConfident() {
        let high = CaptchaAttempt(value: "12345", confidence: 0.9, duration: 0.01)
        XCTAssertTrue(high.isConfident(min: 0.55))
        let low = CaptchaAttempt(value: "12", confidence: 0.4, duration: 0.01)
        XCTAssertFalse(low.isConfident(min: 0.55))
    }

    func testKindLabels() {
        XCTAssertEqual(CaptchaKind.sudrfToken.label, "sudrfToken")
        XCTAssertEqual(CaptchaKind.kcaptcha.label, "kcaptcha")
    }

    // MARK: - Live preprocess provider (v0.38.7)

    /// Live-флаг preprocess меняется между вызовами: один и тот же
    /// PNG обрабатывается и как raw, и как preprocessed без
    /// пересоздания солвера. Это основной контракт тоггла в меню.
    @MainActor
    func testPreprocessLiveProviderToggle() async throws {
        let png = SyntheticCaptcha.makePNG(width: 100, height: 30, digits: "12345", hasBorder: true)
        var strategy = VisionOCRStrategy()
        let flag = PreprocessingFlag(false)
        strategy.preprocessingProvider = { flag.value }
        let solver = CaptchaSolver(provider: strategy)
        // raw
        let (_, offPre) = await solver.topCandidates(pngData: png, kind: .sudrfToken, n: 3)
        XCTAssertFalse(offPre)
        // переключаем
        flag.value = true
        let (_, onPre) = await solver.topCandidates(pngData: png, kind: .sudrfToken, n: 3)
        XCTAssertTrue(onPre)
        // обратно
        flag.value = false
        let (_, offPre2) = await solver.topCandidates(pngData: png, kind: .sudrfToken, n: 3)
        XCTAssertFalse(offPre2)
    }

    /// Если `preprocessingProvider = nil`, стратегия использует
    /// фиксированный флаг `preprocessingEnabled`. Backward compat.
    func testPreprocessWithoutProviderFallsBackToFixedFlag() async throws {
        let png = SyntheticCaptcha.makePNG(width: 100, height: 30, digits: "12345", hasBorder: true)
        let strategy = VisionOCRStrategy(preprocessingEnabled: false)
        let solver = CaptchaSolver(provider: strategy)
        let (_, pre0) = await solver.topCandidates(pngData: png, kind: .sudrfToken, n: 3)
        XCTAssertFalse(pre0)
        let onStrategy = VisionOCRStrategy(preprocessingEnabled: true, preprocessorHosts: [])
        let onSolver = CaptchaSolver(provider: onStrategy)
        let (_, pre1) = await onSolver.topCandidates(pngData: png, kind: .sudrfToken, n: 3)
        XCTAssertTrue(pre1)
    }

    @MainActor
    func testPreprocessLiveProviderRespectsHostAllowlist() async {
        let png = SyntheticCaptcha.makePNG(width: 100, height: 30, digits: "12345", hasBorder: true)
        var strategy = VisionOCRStrategy(preprocessorHosts: ["a.sudrf.ru"])
        strategy.preprocessingProvider = { true }

        let (_, allowedPreprocessed) = await strategy.resolveEffectiveData(
            pngData: png, host: "A.SUDRF.RU"
        )
        let (_, blockedPreprocessed) = await strategy.resolveEffectiveData(
            pngData: png, host: "b.sudrf.ru"
        )

        XCTAssertTrue(allowedPreprocessed)
        XCTAssertFalse(blockedPreprocessed)
    }

    // MARK: - Real captcha PNGs (v0.38.7)

    /// `CaptchaSolverLog.logCandidates` пишет диагностический файл
    /// с топ-3 кандидатами Vision и пометкой, был ли применён
    /// preprocess. Тест грузит реальный PNG из `captcha-failures/`
    /// (если есть) и проверяет структуру файла. Делаем XCTSkip, если
    /// папка пуста.
    @MainActor
    func testCandidatesDiagnosticForRealPNG() async throws {
        guard let item = RealCaptchaFixture.loadAll().first else {
            throw XCTSkip("no real captcha PNG in captcha-failures/")
        }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CandidatesDiag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let logFile = tmpDir.appendingPathComponent("captcha-solve.log")
        let failures = tmpDir.appendingPathComponent("captcha-failures")
        let diagnostics = tmpDir.appendingPathComponent("diagnostics")
        try FileManager.default.createDirectory(at: failures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        let log = CaptchaSolverLog(fileURL: logFile, failuresDir: failures, diagnosticsDir: diagnostics)

        var strategy = VisionOCRStrategy()
        let flag = PreprocessingFlag(false)
        strategy.preprocessingProvider = { flag.value }
        let solver = CaptchaSolver(provider: strategy)
        let host = item.host

        let (off, offPre) = await solver.topCandidates(
            pngData: item.png, kind: .sudrfToken, host: host, n: 3
        )
        XCTAssertFalse(offPre, "preprocess should be off when provider returns false")

        flag.value = true
        let (on, onPre) = await solver.topCandidates(
            pngData: item.png, kind: .sudrfToken, host: host, n: 3
        )
        XCTAssertTrue(onPre, "preprocess should be on when provider returns true")

        let url = log.logCandidates(
            host: host,
            kind: .sudrfToken,
            submitted: off.first?.text ?? "",
            confidence: off.first?.confidence ?? 0,
            alternatives: Array(off.dropFirst()),
            preprocessed: false
        )
        let written = try XCTUnwrap(url, "logCandidates must return a URL")
        let content = try String(contentsOf: written, encoding: .utf8)
        XCTAssertTrue(content.contains("host=\(host)"),
            "diagnostic must include host")
        XCTAssertTrue(content.contains("kind=sudrfToken"),
            "diagnostic must include kind")
        XCTAssertTrue(content.contains("preprocessed=no"),
            "diagnostic must mark preprocessed=no")
        _ = on
    }
}

@MainActor
private final class PreprocessingFlag {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}
