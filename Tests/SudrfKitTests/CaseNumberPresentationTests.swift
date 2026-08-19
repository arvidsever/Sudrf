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
}
