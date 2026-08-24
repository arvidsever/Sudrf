import XCTest
import AppKit
import CryptoKit
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

    func testFSSPPreprocessorKeepsDominantColourAndNormalizesItsSpan() throws {
        let png = makeFSSPPNG { pixels, width in
            drawFSSPRect(&pixels, width: width, x: 100...170, y: 20...59,
                         colour: (20, 18, 49, 255))
            // Opaque coloured noise in the crop margin must not become ink.
            drawFSSPRect(&pixels, width: width, x: 96...99, y: 20...59,
                         colour: (183, 181, 212, 255))
        }
        let mask = try FSSPPreprocessor.process(pngData: png)
        XCTAssertEqual(mask.count, 64 * 20)

        XCTAssertEqual(mask[5 * 64], 0, accuracy: 0.001)
        XCTAssertEqual(mask[5 * 64 + 32], 1, accuracy: 0.001)
        XCTAssertEqual(mask[0], 0, accuracy: 0.001)
        XCTAssertEqual(mask[19 * 64 + 32], 0, accuracy: 0.001)
    }

    func testFSSPPreprocessorChoosesLargestSpanIncludingRightSide() throws {
        let png = makeFSSPPNG { pixels, width in
            drawFSSPRect(&pixels, width: width, x: 10...79, y: 20...59,
                         colour: (20, 18, 49, 255))
            drawFSSPRect(&pixels, width: width, x: 130...220, y: 20...59,
                         colour: (20, 18, 49, 255))
        }
        let mask = try FSSPPreprocessor.process(pngData: png)

        // The left span is deliberately ignored: the wider right span is
        // stretched into the model frame without clipping its final digit.
        XCTAssertEqual(mask[5 * 64], 0, accuracy: 0.001)
        XCTAssertEqual(mask[5 * 64 + 32], 1, accuracy: 0.001)
        XCTAssertGreaterThan(mask[5 * 64 + 60], 0)
    }

    func testFSSPPreprocessorRejectsUnknownFramesAndExpandsNarrowSpan() throws {
        XCTAssertThrowsError(try FSSPPreprocessor.process(pngData: makeFSSPPNG { _, _ in }))
        let opaque = makeFSSPPNG { pixels, width in
            drawFSSPRect(&pixels, width: width, x: 0...239, y: 0...79,
                         colour: (20, 18, 49, 255))
        }
        XCTAssertThrowsError(try FSSPPreprocessor.process(pngData: opaque))
        let invalidSpan = makeFSSPPNG { pixels, width in
            drawFSSPRect(&pixels, width: width, x: 120...120, y: 20...59,
                         colour: (20, 18, 49, 255))
        }
        XCTAssertThrowsError(try FSSPPreprocessor.process(pngData: invalidSpan))
        let partialAlpha = makeFSSPPNG { pixels, width in
            drawFSSPRect(&pixels, width: width, x: 100...170, y: 20...59,
                         colour: (10, 9, 24, 128))
        }
        XCTAssertThrowsError(try FSSPPreprocessor.process(pngData: partialAlpha))
        let narrow = makeFSSPPNG { pixels, width in
            drawFSSPRect(&pixels, width: width, x: 100...145, y: 20...59,
                         colour: (20, 18, 49, 255))
        }
        let mask = try FSSPPreprocessor.process(pngData: narrow)
        XCTAssertEqual(mask[5 * 64 + 32], 1, accuracy: 0.001)
    }

    func testFSSPPreprocessorAcceptsThreeRealParityFixtures() throws {
        guard let directory = Bundle.module.url(
            forResource: "Fixtures/fssp/parity", withExtension: nil
        ) else {
            throw XCTSkip("FSSP parity fixtures are not available yet")
        }
        let images = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "png" }
        XCTAssertEqual(images.count, 3)
        let expectedDigests = [
            "08212_136d6d2dc3d1590fbf0fb6da6b951acfd3758f5a584f1ee06d89cf7e85d20b2e.png":
                "eaead2cbe2e5b1fb8b15e9e3d1fe2f139c70eb77d4fa3a2baa4a53cb8d76e940",
            "17758_c7d58b9cfa1ec518a7e4f2bc0ad271a710c01587ef3fae2a0c09075f50f03b0c.png":
                "6ccc056cff8cc20bed8fed7cb7062631e6f172abda05b0d78af967ec8658fcdf",
            "62442_a2ec40e6966369d794d68caaf970beee7eef7f83f7b0104398564b1ffca5fdd2.png":
                "aa8222ae7ae7b8924c7c10a38e645b29ebe94ad32478e77ba70a9986ac11d198"
        ]
        for image in images {
            let mask = try FSSPPreprocessor.process(pngData: Data(contentsOf: image))
            XCTAssertEqual(mask.count, 64 * 20, image.lastPathComponent)
            XCTAssertGreaterThan(mask.filter { $0 > 0 }.count, 0, image.lastPathComponent)
            XCTAssertEqual(
                fsspMaskDigest(mask), expectedDigests[image.lastPathComponent], image.lastPathComponent
            )
        }
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
        let eligible = makeFSSPModelEligibility()
        XCTAssertTrue(eligible.isEligible)

        XCTAssertFalse(makeFSSPModelEligibility(uniqueCorpusCount: 1_999).isEligible)
        XCTAssertFalse(makeFSSPModelEligibility(regressionFixtureCount: 29).isEligible)
        XCTAssertFalse(makeFSSPModelEligibility(examStringAccuracy: 0.969).isEligible)
        XCTAssertFalse(makeFSSPModelEligibility(acceptedAt090Accuracy: 0.989).isEligible)
        XCTAssertFalse(makeFSSPModelEligibility(coreMLParityPassed: false).isEligible)
        XCTAssertFalse(makeFSSPModelEligibility(coreMLMaxLogitDifference: 0.0011).isEligible)
    }

    func testFSSPBootstrapReportUsesLabGateOnly() {
        let eligible = makeFSSPBootstrapReport()
        XCTAssertTrue(eligible.isAutoCollectionEligible)
        XCTAssertTrue(eligible.isRecognitionEligible)
        let encoded = try! JSONEncoder().encode(eligible)
        let decoded = try! JSONDecoder().decode(FSSPBootstrapReport.self, from: encoded)
        XCTAssertEqual(decoded, eligible)

        XCTAssertFalse(makeFSSPBootstrapReport(uniqueCorpusCount: 199).isRecognitionEligible)
        XCTAssertFalse(makeFSSPBootstrapReport(examStringAccuracy: 0.499).isRecognitionEligible)
        XCTAssertFalse(makeFSSPBootstrapReport(acceptedAt050Accuracy: 0.499).isAutoCollectionEligible)
        XCTAssertFalse(makeFSSPBootstrapReport(coreMLParityPassed: false).isRecognitionEligible)
        XCTAssertFalse(makeFSSPBootstrapReport(version: 1).isCurrentContract)
    }

    func testFSSPBootstrapReportRejectsV1Schema() {
        let legacy = """
        {"version":1,"modelName":"model-captcha-fssp-bootstrap","split":"sha256-mod5-v1","uniqueCorpusCount":600,"heldOutCount":122,"heldOutStringAccuracy":0.0,"acceptedAt098Count":0,"acceptedAt098Accuracy":0.0,"trainedAt":"2026-08-24T00:00:00Z","preprocessorVersion":"fssp-alpha-box-v2"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(FSSPBootstrapReport.self, from: legacy))
    }

    func testFSSPModelDiscoveryFailsClosedWithoutEligibleReport() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSSPModelGate-\(UUID().uuidString)", isDirectory: true)
        let model = root.appendingPathComponent("model-captcha-fssp.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(CoreMLModelDiscovery.eligibleFSSPURL(modelURL: model))
        let report = makeFSSPModelEligibility()
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

        let productionReport = makeFSSPModelEligibility()
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

private func makeFSSPModelEligibility(
    uniqueCorpusCount: Int = 2_000,
    regressionFixtureCount: Int = 30,
    examStringAccuracy: Double = 0.97,
    acceptedAt090Accuracy: Double = 0.99,
    coreMLParityPassed: Bool = true,
    coreMLMaxLogitDifference: Double = 0
) -> FSSPModelEligibility {
    FSSPModelEligibility(
        uniqueCorpusCount: uniqueCorpusCount,
        regressionFixtureCount: regressionFixtureCount,
        trainCount: 1_600,
        trainStringAccuracy: 0.99,
        trainDigitAccuracy: 0.99,
        validationCount: 200,
        validationStringAccuracy: 0.97,
        validationDigitAccuracy: 0.99,
        examCount: 200,
        examStringAccuracy: examStringAccuracy,
        examDigitAccuracy: 0.99,
        acceptedAt090Count: 100,
        acceptedAt090Accuracy: acceptedAt090Accuracy,
        trainedAt: "2026-08-24T00:00:00Z",
        coreMLParityPassed: coreMLParityPassed,
        coreMLMaxLogitDifference: coreMLMaxLogitDifference
    )
}

private func makeFSSPBootstrapReport(
    version: Int = 2,
    uniqueCorpusCount: Int = 300,
    examStringAccuracy: Double = 0.50,
    acceptedAt050Accuracy: Double = 0.50,
    coreMLParityPassed: Bool = true
) -> FSSPBootstrapReport {
    FSSPBootstrapReport(
        version: version,
        uniqueCorpusCount: uniqueCorpusCount,
        trainCount: 240,
        trainStringAccuracy: 0.80,
        trainDigitAccuracy: 0.90,
        validationCount: 30,
        validationStringAccuracy: 0.50,
        validationDigitAccuracy: 0.70,
        examCount: 30,
        examStringAccuracy: examStringAccuracy,
        examDigitAccuracy: 0.70,
        acceptedAt050Count: 10,
        acceptedAt050Accuracy: acceptedAt050Accuracy,
        trainedAt: "2026-08-24T00:00:00Z",
        coreMLParityPassed: coreMLParityPassed,
        coreMLMaxLogitDifference: 0
    )
}

private func makeFSSPPNG(
    paint: (inout [UInt8], Int) -> Void
) -> Data {
    let width = FSSPPreprocessor.sourceWidth
    let height = FSSPPreprocessor.sourceHeight
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    paint(&pixels, width)
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

private func drawFSSPRect(_ pixels: inout [UInt8], width: Int,
                          x: ClosedRange<Int>, y: ClosedRange<Int>,
                          colour: (UInt8, UInt8, UInt8, UInt8)) {
    for row in y {
        for column in x {
            let offset = (row * width + column) * 4
            pixels[offset] = colour.0
            pixels[offset + 1] = colour.1
            pixels[offset + 2] = colour.2
            pixels[offset + 3] = colour.3
        }
    }
}

private func fsspMaskDigest(_ mask: [Float]) -> String {
    let quantized = Data(mask.map { UInt8((Double($0) * 48).rounded()) })
    return SHA256.hash(data: quantized).map { String(format: "%02x", $0) }.joined()
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
