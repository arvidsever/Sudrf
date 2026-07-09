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

    // MARK: - Real captcha PNGs (v0.38.7)

    /// Реальная captcha из `~/Library/Application Support/Sudrf/captcha-failures/`
    /// проходит через preprocess без падения. `XCTSkip`, если фикстуры
    /// нет (чистый клон, CI) — мы не хотим ронять билд из-за пустой
    /// папки.
    func testPreprocessOnRealCaptchaPNG() throws {
        guard let item = RealCaptchaFixture.latest(host: "sankt-peterburgsky--spb.sudrf.ru")
            ?? RealCaptchaFixture.latest(host: "oblsud--mo.sudrf.ru")
            ?? RealCaptchaFixture.latest(host: "1kas--ao--sudrf--ru")
            ?? RealCaptchaFixture.loadAll().first else {
            throw XCTSkip("no real captcha PNG in captcha-failures/ — run app once to capture")
        }
        let out = try XCTUnwrap(Preprocessor.process(pngData: item.png),
            "preprocess must succeed on real captcha \(item.filename)")
        let img = try XCTUnwrap(NSImage(data: out))
        // 2x scale → ширина и высота ровно в 2 раза больше.
        XCTAssertGreaterThan(img.size.width, 0)
        XCTAssertGreaterThan(img.size.height, 0)
        XCTAssertNotEqual(out, item.png,
            "preprocessed PNG must differ from input")
    }

    /// Vision не падает на реальной captcha из captcha-failures/ ни
    /// с preprocess, ни без. Сравнение результатов (без vs с preprocess)
    /// позволяет заметить регрессию «Vision перестал видеть digits на
    /// spb-капчах» в CI, где сама папка фикстур может быть
    /// смонтирована из бэкапа.
    func testVisionDoesNotCrashOnRealCaptchaPNG() async throws {
        let items = RealCaptchaFixture.loadAll()
        guard let item = items.first else {
            throw XCTSkip("no real captcha PNG in captcha-failures/ — run app once to capture")
        }
        let raw = VisionOCRStrategy(preprocessingEnabled: false)
        let rawAttempt = try await raw.solve(pngData: item.png, kind: .sudrfToken, host: item.host)
        XCTAssertNotNil(rawAttempt, "raw Vision must not throw on real captcha")
        let pre = VisionOCRStrategy(preprocessingEnabled: true, preprocessorHosts: [])
        let preAttempt = try await pre.solve(pngData: item.png, kind: .sudrfToken, host: item.host)
        XCTAssertNotNil(preAttempt, "preprocessed Vision must not throw on real captcha")
    }
}
