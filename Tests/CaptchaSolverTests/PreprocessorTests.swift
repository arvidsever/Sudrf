import XCTest
import AppKit
@testable import CaptchaSolver

/// Тесты для `Preprocessor`. Проверяем только геометрию (2x scale,
/// сохранение пропорций) и устойчивость к невалидным входам — Vision
/// accuracy проверяется отдельно (и на живых captcha, в
/// `VisionOCRStrategyTests.testSudrfFixturesAccuracy`).
final class PreprocessorTests: XCTestCase {

    /// 100×30 → 200×60. Самый частый кейс sudrf-капчи.
    func testPreprocessUpscales() throws {
        let png = SyntheticCaptcha.makePNG(width: 100, height: 30, digits: "12345", hasBorder: true)
        let out = try XCTUnwrap(Preprocessor.process(pngData: png))
        let img = try XCTUnwrap(NSImage(data: out))
        XCTAssertEqual(Int(img.size.width), 200, "width should double")
        XCTAssertEqual(Int(img.size.height), 60, "height should double")
    }

    /// 80×40 → 160×80. Текущая реализация делает 2x scale без
    /// letterbox-паддинга. Пропорции сохраняются (2x2), 80×40
    /// становится 160×80 — это и есть суть preprocess: удвоить
    /// пиксельное разрешение для Vision, а не вписать в фиксированный
    /// прямоугольник (что сломанный `ImagePreprocessor` пытался делать
    /// раньше с Y-flip, и что регрессировало на нормальных captcha).
    func testPreprocessPreservesAspectRatio() throws {
        let png = SyntheticCaptcha.makePNG(width: 80, height: 40, digits: "98765", hasBorder: false)
        let out = try XCTUnwrap(Preprocessor.process(pngData: png))
        let img = try XCTUnwrap(NSImage(data: out))
        XCTAssertEqual(Int(img.size.width), 160)
        XCTAssertEqual(Int(img.size.height), 80)
    }

    /// Битый PNG → nil, без крэша. Capture error path.
    func testPreprocessHandlesNonImageData() {
        let bogus = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertNil(Preprocessor.process(pngData: bogus))
    }

    /// End-to-end sanity: Vision не должен крашиться на synthetic
    /// captcha ни с предобработкой, ни без. Конкретное value
    /// не проверяем — synthetic-блобы (чёрные прямоугольники) не
    /// похожи на настоящие цифры, и Vision может читать или не читать
    /// их в зависимости от версии системы. Главное — отсутствие крэша
    /// и возврат `CaptchaAttempt` (даже если `.empty`).
    func testVisionDoesNotCrashOnSyntheticCaptcha() async throws {
        let png = SyntheticCaptcha.makePNG(width: 100, height: 30, digits: "12345", hasBorder: true)
        let raw = VisionOCRStrategy(preprocessingEnabled: false)
        let rawAttempt = try await raw.solve(pngData: png, kind: .sudrfToken)
        XCTAssertNotNil(rawAttempt, "raw Vision must return a CaptchaAttempt, not throw")
        let pre = VisionOCRStrategy(preprocessingEnabled: true)
        let preAttempt = try await pre.solve(pngData: png, kind: .sudrfToken)
        XCTAssertNotNil(preAttempt, "preprocessed Vision must return a CaptchaAttempt, not throw")
    }
}
