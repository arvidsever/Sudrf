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

    @MainActor
    func testMoscowMagistrateOptionKeepsPublishedTitleCodeAndNativeUnitIDSeparate() throws {
        let data = Data(#"{"url":"https://mos-sud.ru/rs/424","name":"Участок 424","alias":"0424","courtFullNameWithMunicipal":"Участок мирового судьи № 424 (Синтетический район)","id":"11111111-1111-4111-8111-111111111111","code":"77MS0424","rsCourtId":"22222222-2222-4222-8222-222222222222","canceledAt":""}"#.utf8)
        let unit = try JSONDecoder().decode(MoscowMagistrateUnit.self, from: data)
        let option = try XCTUnwrap(SearchModel.moscowCourtOption(for: unit))

        XCTAssertEqual(option.domain, "mos-sud.ru")
        XCTAssertEqual(option.id, "mos-sud.ru#77MS0424")
        XCTAssertEqual(option.code, "77MS0424")
        XCTAssertEqual(option.number, 424)
        XCTAssertEqual(option.title, unit.courtFullNameWithMunicipal)
        XCTAssertNotEqual(option.title, unit.url)
        XCTAssertEqual(option.moscowMagistrateUnitPathID, "424")
        XCTAssertNil(option.mosGorSudAlias)
        XCTAssertTrue(option.supportsSearch)

        let canceled = Data(#"{"url":"https://mos-sud.ru/rs/424","name":"Участок 424","alias":"0424","courtFullNameWithMunicipal":"Участок мирового судьи № 424","id":"11111111-1111-4111-8111-111111111111","code":"77MS0424","rsCourtId":"22222222-2222-4222-8222-222222222222","canceledAt":"2026-01-01"}"#.utf8)
        XCTAssertNil(SearchModel.moscowCourtOption(
            for: try JSONDecoder().decode(MoscowMagistrateUnit.self, from: canceled)))
    }

    @MainActor
    func testMoscowMagistrateOptionsFollowClassificationNumberOrder() throws {
        let numbers = [90, 8, 100, 2, 89, 471, 9, 1, 10]
        let options = try numbers.map { number in
            let code = String(format: "77MS%04d", number)
            let nativeID = String(1000 - number)
            let data = Data("""
                {"url":"https://mos-sud.ru/rs/\(nativeID)","name":"Участок",
                "alias":"alias-\(nativeID)","courtFullNameWithMunicipal":"Участок мирового судьи № \(1000 - number)",
                "id":"unit-\(number)","code":"\(code)","rsCourtId":"group","canceledAt":""}
                """.utf8)
            let unit = try JSONDecoder().decode(MoscowMagistrateUnit.self, from: data)
            let option = try XCTUnwrap(SearchModel.moscowCourtOption(for: unit))
            XCTAssertEqual(option.code, code)
            XCTAssertEqual(option.moscowMagistrateUnitPathID, nativeID)
            XCTAssertEqual(option.title, unit.courtFullNameWithMunicipal)
            return option
        }

        XCTAssertEqual(SearchModel.ordered(options).map(\.number),
                       [1, 2, 8, 9, 10, 89, 90, 100, 471])
    }
}
