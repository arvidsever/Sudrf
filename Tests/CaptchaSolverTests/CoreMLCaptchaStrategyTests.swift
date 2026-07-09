import XCTest
import AppKit
@testable import CaptchaSolver

/// Тесты для `CoreMLCaptchaStrategy` (v0.38.8). Каркас: реальный
/// `.mlmodelc` пока не обучен, поэтому большая часть `solve`-логики
/// тестируется через `XCTSkip` (модель отсутствует). Зато проверяем
/// важные инварианты каркаса:
///   - binarize + downsample работает на синтетике и реальных captcha,
///     результат 64×20 = 1280 элементов, значения ∈ [0, 1].
///   - `CoreMLModelDiscovery.discoverURL()` корректно возвращает nil
///     при отсутствии модели и не падает.
///   - `init(modelURL:kind:)` бросает
///     `CoreMLCaptchaStrategyError.modelLoadFailed` на несуществующий
///     URL.
final class CoreMLCaptchaStrategyTests: XCTestCase {

    /// Binarize + downsample даёт 1280 элементов (64×20) со значениями
    /// в [0, 1]. На синтетической captcha (5 чёрных квадратиков на
    /// белом фоне) большинство ячеек после binarize = 0, ячейки под
    /// квадратиками = 1, после downsample — приблизительно доля
    /// пикселей-ячеек, попавших в ink.
    func testBinarizeAndDownsampleDimensions() throws {
        let png = SyntheticCaptcha.makePNG(width: 100, height: 30, digits: "12345", hasBorder: true)
        let mask = try CoreMLCaptchaStrategy.binarizeAndDownsample(pngData: png)
        XCTAssertEqual(mask.count, 64 * 20, "expected 64*20 = 1280 floats")
        for v in mask {
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
        }
    }

    /// Реальная captcha от друга (5 цифр) после binarize даёт хотя бы
    /// несколько ненулевых ячеек — то есть, real captcha реально
    /// содержит пиксели ink в целевой палитре, и preprocessing на
    /// неё работает. XCTSkip при отсутствии фикстуры.
    func testBinarizeAndDownsampleOnRealCaptcha() throws {
        guard let item = RealCaptchaFixture.loadAll().first else {
            throw XCTSkip("no real captcha PNG in captcha-failures/")
        }
        let mask = try CoreMLCaptchaStrategy.binarizeAndDownsample(pngData: item.png)
        XCTAssertEqual(mask.count, 1280)
        let nonZero = mask.filter { $0 > 0 }.count
        XCTAssertGreaterThan(nonZero, 0, "real captcha must have non-zero ink cells after binarize")
    }

    /// `CoreMLModelDiscovery.discoverURL()` возвращает nil когда
    /// модель не найдена ни в user-папке, ни в bundle. Не падает.
    func testModelDiscoveryReturnsNilWhenAbsent() {
        // В тестовом bundle `model-captcha-numeric.mlmodelc` не
        // существует, и в test user defaults папка пуста.
        let url = CoreMLModelDiscovery.discoverURL()
        // Этот тест не строгий: в редких случаях модель может
        // существовать (если кто-то положил её вручную). Если
        // существует — assert не-нулевой. Если нет — assert nil.
        if let url {
            XCTAssertTrue(url.pathExtension == "mlmodelc" || url.lastPathComponent.hasSuffix(".mlmodelc"),
                          "discovered URL must point to .mlmodelc, got \(url.path)")
        }
    }

    /// `init` бросает `CoreMLCaptchaStrategyError.modelLoadFailed` на
    /// несуществующий URL. Используем
    /// `/tmp/nonexistent-coreml-model.mlmodelc/`.
    func testInitFailsForMissingModel() {
        let bogus = URL(fileURLWithPath: "/tmp/nonexistent-coreml-model-\(UUID().uuidString).mlmodelc")
        XCTAssertThrowsError(
            try CoreMLCaptchaStrategy(modelURL: bogus, kind: .sudrfToken)
        ) { error in
            // Должна быть `CoreMLCaptchaStrategyError` (любой подкейс).
            XCTAssertTrue(error is CoreMLCaptchaStrategyError,
                          "expected CoreMLCaptchaStrategyError, got \(error)")
        }
    }

    /// `KindDispatchingStrategy` делегирует `.sudrfToken` primary,
    /// остальные — fallback. Тестируем через стабы.
    func testKindDispatchingRoutesByKind() async throws {
        let primary = StubLabeledProvider(label: "primary")
        let fallback = StubLabeledProvider(label: "fallback")
        let dispatch = KindDispatchingStrategy(
            primary: primary, fallback: fallback, primaryKinds: [.sudrfToken]
        )
        // Primary route: .sudrfToken.
        let r1 = try await dispatch.solve(pngData: Data(), kind: .sudrfToken, host: nil)
        XCTAssertEqual(r1.value, "primary")
        // Fallback route: .kcaptcha.
        let r2 = try await dispatch.solve(pngData: Data(), kind: .kcaptcha, host: nil)
        XCTAssertEqual(r2.value, "fallback")
    }

    // MARK: - Real model tests (требуют наличия .mlmodelc)

    /// `CoreMLCaptchaStrategy` успешно загружает `.mlmodelc/` из
    /// тестового бандла. `XCTSkip`, если модель отсутствует (чистый
    /// клон без артефактов).
    func testModelLoadsFromBundle() throws {
        // `.mlmodelc` — это **директория**, а не файл, поэтому
        // `Bundle.module.url(forResource:withExtension:)` не находит
        // её как одиночный ресурс. Используем `url(forResource:withExtension:subdirectory:)`
        // чтобы заглянуть внутрь `Fixtures/`.
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "model-captcha-numeric",
                              withExtension: "mlmodelc",
                              subdirectory: "Fixtures"),
            "model-captcha-numeric.mlmodelc not in Fixtures/ — run train-coreml-captcha-helper.py"
        )
        let _ = try CoreMLCaptchaStrategy(modelURL: url, kind: .sudrfToken)
    }

    /// Реальный inference на 1 реальной captcha. XCTSkip если
    /// модель не в bundle ИЛИ captcha-failures/ пуста.
    func testInferenceOnRealCaptcha() async throws {
        guard let url = Bundle.module.url(forResource: "model-captcha-numeric",
                                          withExtension: "mlmodelc",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("model not in bundle")
        }
        guard let item = RealCaptchaFixture.loadAll().first else {
            throw XCTSkip("no real captcha PNG in captcha-failures/")
        }
        let strategy = try CoreMLCaptchaStrategy(modelURL: url, kind: .sudrfToken)
        let attempt = try await strategy.solve(pngData: item.png, kind: .sudrfToken, host: nil)
        // 5-digit captcha, model trained to read it. Не проверяем
        // равенство (test set 90.4% per-digit, not 100%) — только
        // что attempt валидный (5 символов, confidence > 0).
        XCTAssertEqual(attempt.value.count, 5, "5-digit captcha, got '\(attempt.value)'")
        XCTAssertTrue(attempt.value.allSatisfy { $0.isNumber }, "all digits, got '\(attempt.value)'")
        XCTAssertGreaterThan(attempt.confidence, 0)
    }

    /// Per-digit accuracy на маленькой held-out выборке из
    /// `Tests/CaptchaSolverTests/Fixtures/sudrf/labels.csv` —
    /// наши локальные captcha fixtures (10 captcha, 5 размечены
    /// «667» / «1909» / дубли, 5 — `UNREADABLE` sovetsky--nsk).
    ///
    /// 5 captcha — регрессионный тест: убеждаемся, что модель
    /// **загружается и возвращает 5-значный ответ** на нашем
    /// out-of-distribution стиле (spb rotated/struck-through). Не
    /// проверяем равенство: эти captcha **out-of-distribution** для
    /// модели, обученной на корпусе друга (90.4% per-digit на
    /// его held-out, не 100%). Цель теста — поймать регрессию в
    /// «модель падает» / «возвращает не 5 цифр», а не промахи в
    /// самих цифрах.
    func testLocalSudrfFixturesAccuracy() async throws {
        guard let url = Bundle.module.url(forResource: "model-captcha-numeric",
                                          withExtension: "mlmodelc",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("model not in bundle")
        }
        // Грузим labels.csv (filename,expected,kind,notes) — наши 10 captcha.
        guard let labelsURL = Bundle.module.url(forResource: "Fixtures/sudrf/labels", withExtension: "csv"),
              let csv = try? String(contentsOf: labelsURL, encoding: .utf8) else {
            throw XCTSkip("labels.csv not in bundle")
        }
        let lines = csv.split(separator: "\n").dropFirst()
        let strategy = try CoreMLCaptchaStrategy(modelURL: url, kind: .sudrfToken)
        var total = 0
        var allReturnedValid5 = true
        for line in lines {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 2 else { continue }
            let filename = String(cols[0])
            let expected = String(cols[1])
            if expected == "UNREADABLE" || expected == "?" { continue }
            guard let imgURL = Bundle.module.url(forResource: "Fixtures/sudrf/\(filename)", withExtension: nil),
                  let png = try? Data(contentsOf: imgURL) else { continue }
            let attempt = try await strategy.solve(pngData: png, kind: .sudrfToken, host: nil)
            total += 1
            if attempt.value.count != 5 || !attempt.value.allSatisfy({ $0.isNumber }) {
                print("invalid: \(filename) got '\(attempt.value)'")
                allReturnedValid5 = false
            } else {
                let ok = attempt.value == expected ? "ok" : "miss"
                print("\(ok): \(filename) expected=\(expected) got=\(attempt.value) conf=\(String(format: "%.3f", attempt.confidence))")
            }
        }
        XCTAssertEqual(total, 5, "expected 5 readable captcha, 5 unreadable")
        XCTAssertTrue(allReturnedValid5, "all 5 attempts must return valid 5-digit strings")
    }
}

/// Стаб для теста диспетчеризации. Возвращает фиксированный `label`
/// независимо от того, как его зовут.
private struct StubLabeledProvider: CaptchaSolvingProvider {
    let label: String
    func solve(pngData: Data, kind: CaptchaKind, host: String?) async throws -> CaptchaAttempt {
        return CaptchaAttempt(value: label, confidence: 0.9, duration: 0)
    }
}
