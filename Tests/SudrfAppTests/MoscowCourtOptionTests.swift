import XCTest
import SudrfKit
@testable import SudrfApp

/// Регресс-тест: у судов Москвы портальный alias (`savelovskij`) и
/// классификационный код (`77RS0023`) — РАЗНЫЕ поля. Alias, положенный в
/// `courtCode`, ломает вычисление вышестоящих судов: `normalizedSubjectCode`
/// возвращает для него пустую (но не nil) строку и глушит фолбэк на код
/// субъекта, из-за чего движение теряло кассацию (2 КСОЮ).
final class MoscowCourtOptionTests: XCTestCase {

    private func higherDomains(courtCode: String?) -> [String] {
        MovementContext.expandedHigherDomains(
            branch: .general, courtLevel: .district,
            courtTitle: "Савёловский районный суд", courtCode: courtCode,
            region: "Город Москва", displayDomain: MosGorSudEndpoint.host)
    }

    func testClassificationCodeYieldsCassation() {
        // 77RS0023 → субъект 77 → 2 КСОЮ.
        XCTAssertTrue(higherDomains(courtCode: "77RS0023").contains("2kas.sudrf.ru"))
    }

    func testAliasInCourtCodeWouldLoseCassation() {
        // Документируем причину бага: alias не является кодом субъекта.
        XCTAssertEqual(CourtDirectory.normalizedSubjectCode("savelovskij"), "")
        XCTAssertFalse(higherDomains(courtCode: "savelovskij").contains("2kas.sudrf.ru"))
    }

    func testDirectoryCodesAreClassificationCodes() {
        for court in MosGorSudCourtDirectory.districtCourts {
            XCTAssertTrue(court.code.hasPrefix("77RS"), "\(court.alias): \(court.code)")
            XCTAssertEqual(CourtDirectory.normalizedSubjectCode(court.code), "77")
            XCTAssertFalse(court.alias.isEmpty)
        }
    }
}
