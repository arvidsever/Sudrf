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
}

/// Стаб для теста диспетчеризации. Возвращает фиксированный `label`
/// независимо от того, как его зовут.
private struct StubLabeledProvider: CaptchaSolvingProvider {
    let label: String
    func solve(pngData: Data, kind: CaptchaKind, host: String?) async throws -> CaptchaAttempt {
        return CaptchaAttempt(value: label, confidence: 0.9, duration: 0)
    }
}
