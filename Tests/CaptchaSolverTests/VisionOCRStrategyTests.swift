import XCTest
import Vision
@testable import CaptchaSolver

/// Прогон `VisionOCRStrategy` по unit-тестам (Vision framework в Swift
/// Playground нельзя дёргать для image recognition на реальных PNG
/// — слишком капризно от sandbox), поэтому акцент на чистых функциях
/// (`pick`, regex) и встроенных regex-кейсах.
final class VisionOCRStrategyTests: XCTestCase {

    /// Прогон `VisionOCRStrategy` по нашему набору фикстур
    /// `Tests/CaptchaSolverTests/Fixtures/sudrf/labels.csv` удалён
    /// в v0.39.16. До A4 ожидалось, что Vision на rotated/struck-
    /// through captcha spb прочитает 3-5 цифр, а `expected=667/
    /// 1909/UNREADABLE` в labels.csv — это и было её «успешное»
    /// чтение (3/5 correct из 5 readable). После перелейбла
    /// expected на истинные 5-значные 90299/56667/60984 (verified
    /// человеком с PNG) Vision на тех же captcha даёт 0/10
    /// correct: rotated/struck-through 5-значные — это **out of
    /// scope для Vision** (потому и появился CoreML-солвер).
    /// Тест больше не имеет смысла и не отражает реальной
    /// responsibility VisionOCRStrategy. Удалён вместе с
    /// FixtureLoader.load(kind:) для sudrf (если больше нигде
    /// не используется).
    ///   - см. v0.39.16.md

    func testPicksLongestMatchingCandidate() async throws {
        let tuples: [(text: String, confidence: Float)] = [
            ("кот9", 0.9),
            ("кот9а", 0.6),
            ("кот", 0.99)
        ]
        let attempt = VisionOCRStrategy.pick(tuples: tuples, kind: .kcaptcha)
        XCTAssertEqual(attempt.value, "кот9а")
    }

    func testRejectsNonMatching() async throws {
        let tuples: [(text: String, confidence: Float)] = [
            ("12.34", 0.99),
            ("ABC", 0.95)
        ]
        let attempt = VisionOCRStrategy.pick(tuples: tuples, kind: .sudrfToken)
        XCTAssertEqual(attempt, CaptchaAttempt.empty)
    }

    /// v0.38.9: kcaptcha — lowercase cyrillic + digits, 5-6 chars.
    func testKcaptchaAllowsCyrillic() {
        let tuples: [(text: String, confidence: Float)] = [
            ("кот9а", 0.7)
        ]
        let attempt = VisionOCRStrategy.pick(tuples: tuples, kind: .kcaptcha)
        XCTAssertEqual(attempt.value, "кот9а")
    }

    /// v0.38.9: 6-char kcaptcha тоже валиден.
    func testKcaptchaAllowsSixChars() {
        let tuples: [(text: String, confidence: Float)] = [
            ("слово9", 0.6)
        ]
        let attempt = VisionOCRStrategy.pick(tuples: tuples, kind: .kcaptcha)
        XCTAssertEqual(attempt.value, "слово9")
    }

    /// v0.38.9: kcaptcha отвергает латиницу (только cyrillic + digits).
    func testKcaptchaRejectsLatin() {
        let tuples: [(text: String, confidence: Float)] = [
            ("abcde", 0.99)
        ]
        let attempt = VisionOCRStrategy.pick(tuples: tuples, kind: .kcaptcha)
        XCTAssertEqual(attempt, CaptchaAttempt.empty)
    }

    /// v0.38.9: kcaptcha отвергает uppercase cyrillic.
    func testKcaptchaRejectsUppercase() {
        let tuples: [(text: String, confidence: Float)] = [
            ("Кот9а", 0.99)
        ]
        let attempt = VisionOCRStrategy.pick(tuples: tuples, kind: .kcaptcha)
        XCTAssertEqual(attempt, CaptchaAttempt.empty)
    }

    /// v0.38.9: kcaptcha отвергает < 5 chars (раньше было < 3).
    func testKcaptchaRejectsTooShort() {
        let tuples: [(text: String, confidence: Float)] = [
            ("абвг", 0.99)
        ]
        let attempt = VisionOCRStrategy.pick(tuples: tuples, kind: .kcaptcha)
        XCTAssertEqual(attempt, CaptchaAttempt.empty)
    }
}
