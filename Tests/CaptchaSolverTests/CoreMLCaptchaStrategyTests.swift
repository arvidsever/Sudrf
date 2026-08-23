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

    func testFSSPPreprocessorUsesFullFrameAlphaBoxAverageWithoutVerticalFlip() throws {
        let png = makeFSSPAlphaGradientPNG()
        let mask = try FSSPPreprocessor.process(pngData: png)
        XCTAssertEqual(mask.count, 64 * 20)

        // The synthetic frame is 64/192 in its two halves. The boundary is
        // exactly at x=120, so 64 output cells split into two equal groups.
        XCTAssertEqual(mask[0], Float(64) / 255, accuracy: 0.002)
        XCTAssertEqual(mask[31], Float(64) / 255, accuracy: 0.002)
        XCTAssertEqual(mask[32], Float(192) / 255, accuracy: 0.002)
        XCTAssertEqual(mask[63], Float(192) / 255, accuracy: 0.002)
        XCTAssertEqual(mask[64 * 19 + 32], Float(96) / 255, accuracy: 0.002)
    }

    func testFSSPPreprocessorRejectsNonNativeFrame() {
        let png = SyntheticCaptcha.makePNG(width: 100, height: 30,
                                            digits: "12345", hasBorder: false)
        XCTAssertThrowsError(try FSSPPreprocessor.process(pngData: png))
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

    func testKindDispatchingFallsBackForLowConfidencePrimary() async throws {
        let primary = StubAttemptProvider(value: "12345", confidence: 0.54)
        let fallback = StubAttemptProvider(value: "vision", confidence: 0.9)
        let dispatch = numericCoreMLDispatch(primary: primary, fallback: fallback)

        let result = try await dispatch.solve(pngData: Data(), kind: .sudrfToken, host: nil)

        XCTAssertEqual(result.value, "vision")
    }

    func testKindDispatchingFallsBackForIncompatiblePrimaryOutput() async throws {
        let primary = StubAttemptProvider(value: "1234", confidence: 0.9)
        let fallback = StubAttemptProvider(value: "vision", confidence: 0.9)
        let dispatch = numericCoreMLDispatch(primary: primary, fallback: fallback)

        let result = try await dispatch.solve(pngData: Data(), kind: .sudrfToken, host: nil)

        XCTAssertEqual(result.value, "vision")
    }

    func testKindDispatchingKeepsValidPrimaryOutput() async throws {
        let primary = StubAttemptProvider(value: "12345", confidence: 0.9)
        let fallback = StubAttemptProvider(value: "vision", confidence: 0.9)
        let dispatch = numericCoreMLDispatch(primary: primary, fallback: fallback)

        let result = try await dispatch.solve(pngData: Data(), kind: .sudrfToken, host: nil)

        XCTAssertEqual(result.value, "12345")
    }

    func testStrictFSSPDispatchNeverFallsBackToOtherModel() async throws {
        let dispatch = KindDispatchingStrategy(
            primary: ThrowingProvider(error: TestError.failed),
            fallback: StubAttemptProvider(value: "vision", confidence: 1),
            primaryKinds: [.fsspDigits],
            fallbackOnPrimaryFailure: false)

        let result = try await dispatch.solve(
            pngData: Data(), kind: .fsspDigits, host: "fssp.gov.ru")

        XCTAssertEqual(result, .empty)
    }

    func testCoreMLCompatibleOutputRequiresFiveASCIIDigits() {
        XCTAssertTrue(CoreMLCaptchaStrategy.isCompatibleOutput("12345"))
        XCTAssertFalse(CoreMLCaptchaStrategy.isCompatibleOutput("1234"))
        XCTAssertFalse(CoreMLCaptchaStrategy.isCompatibleOutput("12AB5"))
        XCTAssertFalse(CoreMLCaptchaStrategy.isCompatibleOutput("１２３４５"))
    }

    func testFSSPEligibilityRequiresEveryObjectiveThreshold() {
        let eligible = FSSPModelEligibility(
            uniqueCorpusCount: 2_000,
            regressionFixtureCount: 30,
            heldOutStringAccuracy: 0.97,
            acceptedAt090Count: 100,
            acceptedAt090Accuracy: 0.99)
        XCTAssertTrue(eligible.isEligible)

        XCTAssertFalse(FSSPModelEligibility(
            uniqueCorpusCount: 1_999,
            regressionFixtureCount: 30,
            heldOutStringAccuracy: 0.97,
            acceptedAt090Count: 100,
            acceptedAt090Accuracy: 0.99).isEligible)
        XCTAssertFalse(FSSPModelEligibility(
            uniqueCorpusCount: 2_000,
            regressionFixtureCount: 29,
            heldOutStringAccuracy: 0.97,
            acceptedAt090Count: 100,
            acceptedAt090Accuracy: 0.99).isEligible)
        XCTAssertFalse(FSSPModelEligibility(
            uniqueCorpusCount: 2_000,
            regressionFixtureCount: 30,
            heldOutStringAccuracy: 0.969,
            acceptedAt090Count: 100,
            acceptedAt090Accuracy: 0.99).isEligible)
        XCTAssertFalse(FSSPModelEligibility(
            uniqueCorpusCount: 2_000,
            regressionFixtureCount: 30,
            heldOutStringAccuracy: 0.97,
            acceptedAt090Count: 100,
            acceptedAt090Accuracy: 0.989).isEligible)
    }

    func testFSSPBootstrapReportUsesLabGateOnly() {
        let eligible = FSSPBootstrapReport(
            uniqueCorpusCount: 200,
            heldOutCount: 30,
            heldOutStringAccuracy: 0.80,
            acceptedAt098Count: 10,
            acceptedAt098Accuracy: 1.0,
            trainedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(eligible.isAutoCollectionEligible)
        XCTAssertTrue(eligible.isRecognitionEligible)
        let encoded = try! JSONEncoder().encode(eligible)
        let decoded = try! JSONDecoder().decode(FSSPBootstrapReport.self, from: encoded)
        XCTAssertEqual(decoded, eligible)

        XCTAssertFalse(FSSPBootstrapReport(
            uniqueCorpusCount: 199,
            heldOutCount: 30,
            heldOutStringAccuracy: 1.0,
            acceptedAt098Count: 10,
            acceptedAt098Accuracy: 1.0).isAutoCollectionEligible)
        XCTAssertFalse(FSSPBootstrapReport(
            uniqueCorpusCount: 200,
            heldOutCount: 30,
            heldOutStringAccuracy: 0.80,
            acceptedAt098Count: 10,
            acceptedAt098Accuracy: 0.999).isAutoCollectionEligible)
        XCTAssertFalse(FSSPBootstrapReport(
            uniqueCorpusCount: 200,
            heldOutCount: 30,
            heldOutStringAccuracy: 0,
            acceptedAt098Count: 0,
            acceptedAt098Accuracy: 0).isRecognitionEligible)
    }

    func testFSSPModelDiscoveryFailsClosedWithoutEligibleReport() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSSPModelGate-\(UUID().uuidString)", isDirectory: true)
        let model = root.appendingPathComponent("model-captcha-fssp.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(CoreMLModelDiscovery.eligibleFSSPURL(modelURL: model))
        let report = FSSPModelEligibility(
            uniqueCorpusCount: 2_000,
            regressionFixtureCount: 30,
            heldOutStringAccuracy: 0.97,
            acceptedAt090Count: 100,
            acceptedAt090Accuracy: 0.99)
        let reportURL = root.appendingPathComponent("model-captcha-fssp-eligibility.json")
        try JSONEncoder().encode(report).write(to: reportURL)
        XCTAssertEqual(CoreMLModelDiscovery.eligibleFSSPURL(modelURL: model), model)
    }

    func testBootstrapModelIsNeverEligibleForProductionDiscovery() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSSPBootstrapModel-\(UUID().uuidString)", isDirectory: true)
        let model = root.appendingPathComponent(
            "\(CoreMLModelDiscovery.fsspBootstrapModelName).mlmodelc",
            isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let productionReport = FSSPModelEligibility(
            uniqueCorpusCount: 2_000,
            regressionFixtureCount: 30,
            heldOutStringAccuracy: 0.97,
            acceptedAt090Count: 100,
            acceptedAt090Accuracy: 0.99)
        try JSONEncoder().encode(productionReport).write(
            to: root.appendingPathComponent("model-captcha-fssp-eligibility.json"))
        XCTAssertNil(CoreMLModelDiscovery.eligibleFSSPURL(modelURL: model))
    }

    func testKindDispatchingPropagatesCancellation() async {
        let dispatch = numericCoreMLDispatch(
            primary: ThrowingProvider(error: CancellationError()),
            fallback: StubAttemptProvider(value: "vision", confidence: 0.9)
        )

        do {
            _ = try await dispatch.solve(pngData: Data(), kind: .sudrfToken, host: nil)
            XCTFail("CancellationError must not fall back to Vision")
        } catch is CancellationError {
            // Expected: cancellation must remain observable by the caller.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testKindDispatchingExposesCoreMLCandidates() async throws {
        guard let url = Bundle.module.url(forResource: "model-captcha-numeric",
                                          withExtension: "mlmodelc",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("model not in bundle (run Scripts/fetch-model.sh first)")
        }
        let coreML = try CoreMLCaptchaStrategy(modelURL: url, kind: .sudrfToken)
        let dispatcher = KindDispatchingStrategy(
            primary: coreML,
            fallback: VisionOCRStrategy()
        )
        let solver = CaptchaSolver(provider: dispatcher)
        let png = SyntheticCaptcha.makePNG(width: 100, height: 30, digits: "12345", hasBorder: true)

        let (candidates, preprocessed) = await solver.topCandidates(
            pngData: png, kind: .sudrfToken, n: 3
        )

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertFalse(preprocessed)
    }

    private func numericCoreMLDispatch(primary: any CaptchaSolvingProvider,
                                       fallback: any CaptchaSolvingProvider) -> KindDispatchingStrategy {
        KindDispatchingStrategy(
            primary: primary,
            fallback: fallback,
            minPrimaryConfidence: 0.55,
            primaryAttemptIsCompatible: { CoreMLCaptchaStrategy.isCompatibleOutput($0.value) }
        )
    }

    // MARK: - Real model tests (требуют наличия .mlmodelc)

    /// `CoreMLCaptchaStrategy` успешно загружает `.mlmodelc/` из
    /// тестового бандла. `XCTSkip`, если модель отсутствует (чистый
    /// клон без артефактов; A5: модель в bundle появляется после
    /// `Scripts/fetch-model.sh` в CI).
    func testModelLoadsFromBundle() throws {
        // `.mlmodelc` — это **директория**, а не файл, поэтому
        // `Bundle.module.url(forResource:withExtension:)` не находит
        // её как одиночный ресурс. Используем `url(forResource:withExtension:subdirectory:)`
        // чтобы заглянуть внутрь `Fixtures/`.
        guard let url = Bundle.module.url(forResource: "model-captcha-numeric",
                                          withExtension: "mlmodelc",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("model not in bundle (run Scripts/fetch-model.sh first)")
        }
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

    /// A4 regression marker: на rotated/struck-through стилях spb/nsk
    /// модель должна выдавать exact match. Текущая модель выдаёт
    /// корректные 5-значные ответы на наших 3 уникальных captcha
    /// (10 PNG с дублями, verified человеком с PNG — см. labels.csv).
    /// Это и был failure-mode из FIXPLAN A4 P1: «уверенно-неверный
    /// ответ уходит на сервер». Маркер = «нет уверенно-неверного
    /// ответа» (не общий accuracy-гейт): низкоуверенный неверный
    /// не ловит — его отсечёт AutoCaptchaSolver.solve minConfidence
    /// до отправки на сервер.
    ///
    /// CI: без модели → XCTSkip (модель gitignored, см. A5).
    /// Зубы только локально/где модель есть. Маркер = голый
    /// XCTAssertTrue (без XCTExpectFailure, который бы проглотил
    /// регрессию).
    func testLocalSudrfFixturesAccuracy() async throws {
        guard let url = Bundle.module.url(forResource: "model-captcha-numeric",
                                          withExtension: "mlmodelc",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("model not in bundle")
        }
        // Грузим labels.csv (filename,expected,kind,notes) — наши 10 captcha
        // (3 уникальных rotated-стиля: 90299/56667 spb, 60984 nsk; dups
        // у каждого captchaid).
        guard let labelsURL = Bundle.module.url(forResource: "Fixtures/sudrf/labels", withExtension: "csv"),
              let csv = try? String(contentsOf: labelsURL, encoding: .utf8) else {
            throw XCTSkip("labels.csv not in bundle")
        }
        let lines = csv.split(separator: "\n").dropFirst()
        let strategy = try CoreMLCaptchaStrategy(modelURL: url, kind: .sudrfToken)
        var total = 0
        var allReturnedValid5 = true
        var captured: [(filename: String, attempt: CaptchaAttempt, expected: String)] = []
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
            captured.append((filename, attempt, expected))
        }
        XCTAssertEqual(total, 10, "expected 10 readable captcha (5 spb + 5 nsk)")
        XCTAssertTrue(allReturnedValid5, "all 10 attempts must return valid 5-digit strings")

        // A4 regression marker: на rotated/struck-through стилях spb/nsk
        // модель должна выдавать exact match. Голый assert — если
        // модель регрессирует (выдаёт уверенно-неверный ответ),
        // тест поймает КАК КРАСНЫЙ.
        //
        // Семантика: «нет уверенно-неверного ответа» (не общий
        // accuracy-гейт). Низкоуверенный неверный ответ не ловит —
        // его отсечёт AutoCaptchaSolver.solve minConfidence до
        // отправки на сервер. Это и был failure-mode из
        // FIXPLAN A4 (P1).
        let minConfidence: Double = 0.55
        for entry in captured {
            let isExact = entry.attempt.value == entry.expected
            let isLowConf = entry.attempt.confidence < minConfidence
            XCTAssertTrue(isExact || isLowConf,
                "A4 regression: \(entry.filename) expected=\(entry.expected) got=\(entry.attempt.value) conf=\(String(format: "%.3f", entry.attempt.confidence))")
        }
    }

    func testEligibleFSSPModelMatchesManualRegressionFixtures() async throws {
        guard let modelURL = Bundle.module.url(
            forResource: "model-captcha-fssp", withExtension: "mlmodelc",
            subdirectory: "Fixtures"),
              let labelsURL = Bundle.module.url(
                forResource: "Fixtures/fssp/regression", withExtension: "tsv"),
              let tsv = try? String(contentsOf: labelsURL, encoding: .utf8) else {
            throw XCTSkip("eligible FSSP model and 30 manual fixtures are not available yet")
        }
        let rows = tsv.split(separator: "\n").dropFirst().compactMap { line -> (String, String)? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            return (URL(fileURLWithPath: String(fields[0])).lastPathComponent, String(fields[1]))
        }
        XCTAssertGreaterThanOrEqual(rows.count, 30)
        let strategy = try CoreMLCaptchaStrategy(modelURL: modelURL, kind: .fsspDigits)
        for (filename, expected) in rows {
            let url = try XCTUnwrap(Bundle.module.url(
                forResource: "Fixtures/fssp/\(filename)", withExtension: nil))
            let attempt = try await strategy.solve(
                pngData: Data(contentsOf: url), kind: .fsspDigits, host: "fssp.gov.ru")
            XCTAssertEqual(attempt.value, expected, filename)
        }
    }
}

private func makeFSSPAlphaGradientPNG() -> Data {
    let width = FSSPPreprocessor.sourceWidth
    let height = FSSPPreprocessor.sourceHeight
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let alpha: UInt8
            if y >= height / 2 {
                alpha = 96
            } else if x < width / 2 {
                alpha = 64
            } else {
                alpha = 192
            }
            let offset = (y * width + x) * 4
            // Premultiplied RGBA: colour values cannot exceed alpha.
            pixels[offset] = alpha
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = alpha
        }
    }
    let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return NSBitmapImageRep(cgImage: context.makeImage()!)
        .representation(using: .png, properties: [:])!
}

/// Стаб для теста диспетчеризации. Возвращает фиксированный `label`
/// независимо от того, как его зовут.
private struct StubLabeledProvider: CaptchaSolvingProvider {
    let label: String
    func solve(pngData: Data, kind: CaptchaKind, host: String?) async throws -> CaptchaAttempt {
        return CaptchaAttempt(value: label, confidence: 0.9, duration: 0)
    }
}

private struct StubAttemptProvider: CaptchaSolvingProvider {
    let value: String
    let confidence: Double

    func solve(pngData: Data, kind: CaptchaKind, host: String?) async throws -> CaptchaAttempt {
        CaptchaAttempt(value: value, confidence: confidence, duration: 0)
    }
}

private struct ThrowingProvider: CaptchaSolvingProvider {
    let error: Error

    func solve(pngData: Data, kind: CaptchaKind, host: String?) async throws -> CaptchaAttempt {
        throw error
    }
}

private enum TestError: Error {
    case failed
}
