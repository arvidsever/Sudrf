import XCTest
import SudrfKit
@testable import SudrfApp

final class CaseNumberMonitoringTests: XCTestCase {
    private func instance(_ level: CaseInstance.Level, number: String,
                          captcha: Bool = false, transient: Bool = false) -> CaseInstance {
        CaseInstance(level: level, court: "Суд", caseNumber: number, judge: nil,
                     domain: "court.sudrf.ru", foundByUID: true, result: nil, sessions: [],
                     captchaFormURL: captcha ? URL(string: "https://court.sudrf.ru/captcha") : nil,
                     transientError: transient)
    }

    func testReviewNumberUsesOnlyRealReviewLevels() {
        XCTAssertEqual(MovementDerivation.reviewNumber(for: instance(.appeal, number: "33-1102/2026 (33-4/2025;)")),
                       "33-1102/2026")
        XCTAssertEqual(MovementDerivation.reviewNumber(for: instance(.vsCassation, number: "88-12/2026")),
                       "88-12/2026")
        XCTAssertNil(MovementDerivation.reviewNumber(for: instance(.first, number: "2-1/2026")))
        XCTAssertNil(MovementDerivation.reviewNumber(for: instance(.material, number: "13-1/2026")))
    }

    func testReviewNumberIgnoresStubsAndTransientInstances() {
        XCTAssertNil(MovementDerivation.reviewNumber(for: instance(.cassation, number: "—")))
        XCTAssertNil(MovementDerivation.reviewNumber(for: instance(.cassation, number: "33-1/2026", captcha: true)))
        XCTAssertNil(MovementDerivation.reviewNumber(for: instance(.supervisory, number: "88-1/2026", transient: true)))
    }
}
