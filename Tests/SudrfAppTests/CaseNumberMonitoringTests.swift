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

    func testReviewNumberUsesAcceptedKSOYUProductionNumberWithoutChangingRawValue() {
        let raw = "7У-1077/2024 [77-762/2024]"
        let sourceURL = URL(string: "https://3kas.sudrf.ru/modules.php?name=sud_delo")!
        let accepted = CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: raw, judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true, result: nil, sessions: [],
            sourceURL: sourceURL)

        XCTAssertEqual(MovementDerivation.reviewNumber(for: accepted), "77-762/2024")
        XCTAssertEqual(accepted.caseNumber, raw)
        XCTAssertEqual(accepted.id, "3kas.sudrf.ru/\(raw)")
        XCTAssertEqual(accepted.sourceURL, sourceURL)
    }

    func testReviewNumberKeepsNonKSOYUCompositeNumber() {
        let instance = instance(.cassation, number: "8Г-41/2026 [88-12/2026]")
        XCTAssertEqual(MovementDerivation.reviewNumber(for: instance), "8Г-41/2026")
    }

    func testReviewNumberIgnoresStubsAndTransientInstances() {
        XCTAssertNil(MovementDerivation.reviewNumber(for: instance(.cassation, number: "—")))
        XCTAssertNil(MovementDerivation.reviewNumber(for: instance(.cassation, number: "33-1/2026", captcha: true)))
        XCTAssertNil(MovementDerivation.reviewNumber(for: instance(.supervisory, number: "88-1/2026", transient: true)))
    }
}
