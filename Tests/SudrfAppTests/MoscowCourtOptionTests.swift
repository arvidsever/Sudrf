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

    // MARK: - идентичность дела (домен Москвы общий у всех судов)

    func testMoscowIdentityKeysDifferByCourt() {
        // Один и тот же номер дела в разных райсудах Москвы — разные дела.
        let savelovskij = MovementContext.identityKey(
            displayDomain: MosGorSudEndpoint.host, courtCode: "77RS0023",
            caseNumber: "02-1234/2025")
        let tverskoj = MovementContext.identityKey(
            displayDomain: MosGorSudEndpoint.host, courtCode: "77RS0027",
            caseNumber: "02-1234/2025")
        XCTAssertNotEqual(savelovskij, tverskoj)
        XCTAssertTrue(savelovskij.contains("77RS0023"))
    }

    func testNonMoscowIdentityKeyUnchanged() {
        // У остальных судов домен свой — формула прежняя, миграции не нужно.
        XCTAssertEqual(
            MovementContext.identityKey(displayDomain: "syktsud.komi.sudrf.ru",
                                        courtCode: "11RS0001",
                                        caseNumber: "2-1/2025"),
            "syktsud.komi.sudrf.ru/2-1/2025")
    }

    func testMoscowIdentityKeyWithoutCodeFallsBackToDomain() {
        // Мосгорсуд (звено субъекта) кода не несёт — ключ как раньше.
        XCTAssertEqual(
            MovementContext.identityKey(displayDomain: MosGorSudEndpoint.host,
                                        courtCode: nil, caseNumber: "33-1/2025"),
            MosGorSudEndpoint.host + "/33-1/2025")
    }

    func testDirectoryCodesAreClassificationCodes() {
        for court in MosGorSudCourtDirectory.districtCourts {
            XCTAssertTrue(court.code.hasPrefix("77RS"), "\(court.alias): \(court.code)")
            XCTAssertEqual(CourtDirectory.normalizedSubjectCode(court.code), "77")
            XCTAssertFalse(court.alias.isEmpty)
        }
    }
}
