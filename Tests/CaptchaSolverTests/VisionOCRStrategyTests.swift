import XCTest
import Vision
@testable import CaptchaSolver

/// Прогон `VisionOCRStrategy` по размеченным фикстурам. Помеченные
/// `UNREADABLE` пропускаются (мы их не размечали, но Vision всё равно
/// их не прочтёт — это «честный ноль»).
final class VisionOCRStrategyTests: XCTestCase {

    func testSudrfFixturesAccuracy() async throws {
        let fixtures = try FixtureLoader.load(kind: .sudrfToken)
        let strategy = VisionOCRStrategy()

        var correct = 0
        var total = 0
        var skipped = 0
        var misses: [(String, expected: String, got: String)] = []

        for f in fixtures {
            if f.expected == "UNREADABLE" || f.expected == "?" {
                skipped += 1
                continue
            }
            let attempt = try await strategy.solve(pngData: f.png, kind: .sudrfToken)
            total += 1
            if attempt.value == f.expected {
                correct += 1
            } else {
                misses.append((f.filename, f.expected, attempt.value))
            }
        }
        // Минимум: 3 из 5 размеченных (фикстуры от spb, nsk — UNREADABLE).
        XCTAssertGreaterThanOrEqual(correct, 3,
            "expected ≥ 3 correct, got \(correct)/\(total) (skipped \(skipped)) misses: \(misses)")
    }

    func testPicksLongestMatchingCandidate() async throws {
        let strategy = VisionOCRStrategy()
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

struct LabeledFixture {
    let filename: String
    let png: Data
    let expected: String
    let kind: CaptchaKind
}

enum FixtureLoader {
    static func load(kind: CaptchaKind) throws -> [LabeledFixture] {
        let bundle = Bundle.module
        let subdir = kind == .sudrfToken ? "sudrf" : "msudrf"
        guard let url = bundle.url(forResource: "Fixtures/\(subdir)/labels", withExtension: "csv"),
              let csv = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let lines = csv.split(separator: "\n").dropFirst()
        var out: [LabeledFixture] = []
        for raw in lines {
            let cols = raw.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 2 else { continue }
            let filename = String(cols[0])
            let expected = String(cols[1])
            guard let imgURL = bundle.url(forResource: "Fixtures/\(subdir)/\(filename)", withExtension: nil),
                  let png = try? Data(contentsOf: imgURL) else { continue }
            out.append(LabeledFixture(filename: filename, png: png, expected: expected, kind: kind))
        }
        return out
    }
}
