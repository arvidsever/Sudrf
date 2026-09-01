import XCTest
@testable import SudrfKit

final class CaseNumberPresentationTests: XCTestCase {
    func testPrimaryRemovesDecorationsAndPreviousNumbers() {
        XCTAssertEqual(
            CaseNumberPresentation.primary("2-276/2026 (2-45/2025;) ~ М-248/2026"),
            "2-276/2026"
        )
        XCTAssertEqual(
            CaseNumberPresentation.primary("2а-1610/2026 (2а-10843/2025;) ∼ М-9439/2025"),
            "2а-1610/2026"
        )
        XCTAssertEqual(CaseNumberPresentation.primary("№ [88-12/2026]"), "")
    }

    func testPrimaryHandlesLeadingNumberSignAndMaterialTilde() {
        XCTAssertEqual(CaseNumberPresentation.primary(" № 2-1/2026"), "2-1/2026")
        XCTAssertEqual(CaseNumberPresentation.primary("2-3685/2026 ~ М-1951/2026"), "2-3685/2026")
        XCTAssertEqual(CaseNumberPresentation.primary("М-2417/2026"), "М-2417/2026")
        XCTAssertEqual(CaseNumberPresentation.primary("2-1/2026"), "2-1/2026")
    }

    func testDisplayedNumberUsesAcceptedKSOYUProductionNumber() {
        func instance(_ number: String) -> CaseInstance {
            CaseInstance(level: .cassation, court: "3 КСОЮ", caseNumber: number,
                          judge: nil, domain: "3kas.sudrf.ru", foundByUID: true,
                          result: nil, sessions: [])
        }

        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(
                for: instance("8Г-2430/2026 [88-4097/2026]")),
            "88-4097/2026")
        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(
                for: instance("8а-2430/2026 [88а-4097/2026]")),
            "88а-4097/2026")
        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(
                for: instance("7У-1077/2024 [77-762/2024]")),
            "77-762/2024")
        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(
                for: instance("7у-1077/2024 [77У-762/2024]")),
            "77У-762/2024")
        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(
                for: instance("7У-1077/2024 [77у-762/2024]")),
            "77у-762/2024")
        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(
                for: instance("8-2430/2026 [88-4097/2026]")),
            "88-4097/2026")
        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(
                for: instance("7-1077/2024 [77-762/2024]")),
            "77-762/2024")
    }

    func testDisplayedNumberKeepsIncomingNumberBeforeAcceptanceAndOutsideKSOYU() {
        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(for: CaseInstance(
                level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-2430/2026",
                judge: nil, domain: "3kas.sudrf.ru", foundByUID: true, result: nil,
                sessions: [])),
            "8Г-2430/2026")
        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(for: CaseInstance(
                level: .cassation, court: "Суд", caseNumber: "7у-1077/2024 [77-762/2024]",
                judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: true, result: nil,
                sessions: [])),
            "7у-1077/2024")
        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(for: CaseInstance(
                level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-2430/2026 [33-4097/2026]",
                judge: nil, domain: "3kas.sudrf.ru", foundByUID: true, result: nil,
                sessions: [])),
            "8Г-2430/2026")
        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(for: CaseInstance(
                level: .cassation, court: "3 КСОЮ", caseNumber: "8Г-2430/2026 [88а-4097/2026]",
                judge: nil, domain: "3kas.sudrf.ru", foundByUID: true, result: nil,
                sessions: [])),
            "8Г-2430/2026")
        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(for: CaseInstance(
                level: .cassation, court: "Кассационный военный суд",
                caseNumber: "7У-1077/2024 [77У-762/2024]", judge: nil,
                domain: "vkas.sudrf.ru", foundByUID: true, result: nil, sessions: [])),
            "7У-1077/2024")
        XCTAssertEqual(
            CaseNumberPresentation.displayedNumber(for: CaseInstance(
                level: .appeal, court: "3 КСОЮ", caseNumber: "8Г-2430/2026 [88-4097/2026]",
                judge: nil, domain: "3kas.sudrf.ru", foundByUID: true, result: nil,
                sessions: [])),
            "8Г-2430/2026")
    }

    func testSecondaryShowsOnlyDistinctKnownInstanceNumber() {
        XCTAssertEqual(
            CaseNumberPresentation.secondary(" № 33-2267/2026", distinctFrom: "2-8236/2025"),
            "33-2267/2026"
        )
        XCTAssertNil(CaseNumberPresentation.secondary(nil, distinctFrom: "2-8236/2025"))
        XCTAssertNil(CaseNumberPresentation.secondary("2-8236/2025", distinctFrom: "2-8236/2025"))
        XCTAssertNil(CaseNumberPresentation.secondary("—", distinctFrom: "2-8236/2025"))
    }
}
