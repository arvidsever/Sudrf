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
}
