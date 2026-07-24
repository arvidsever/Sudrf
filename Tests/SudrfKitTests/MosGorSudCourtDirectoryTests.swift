import XCTest
@testable import SudrfKit

/// Справочник районных судов Москвы и идентификация региона по коду субъекта.
final class MosGorSudCourtDirectoryTests: XCTestCase {

    func testDistrictCourtsCount() {
        XCTAssertEqual(MosGorSudCourtDirectory.districtCourts.count, 35)
    }

    func testAliasLookup() {
        XCTAssertEqual(MosGorSudCourtDirectory.title(forAlias: "tverskoj"), "Тверской районный суд")
        XCTAssertTrue(MosGorSudCourtDirectory.districtCourts.contains { $0.alias == "savelovskij" })
        XCTAssertTrue(MosGorSudCourtDirectory.districtCourts.contains { $0.alias == "presnenskij" })
        XCTAssertNil(MosGorSudCourtDirectory.title(forAlias: "mgs"))   // МГС — звено субъекта
    }

    func testAliasesAndCodesUnique() {
        let aliases = MosGorSudCourtDirectory.districtCourts.map(\.alias)
        let codes = MosGorSudCourtDirectory.districtCourts.map(\.code)
        XCTAssertEqual(Set(aliases).count, aliases.count)
        XCTAssertEqual(Set(codes).count, codes.count)
    }

    func testSortedByTitle() {
        let titles = MosGorSudCourtDirectory.districtCourts.map(\.title)
        XCTAssertEqual(titles, titles.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
    }

    func testMoscowSubjectCode() {
        XCTAssertEqual(MosGorSudCourtDirectory.moscowSubjectCode, "77")
    }

    // MARK: - регион по коду субъекта

    func testSubjectRegionsPairing() {
        let regions = CourtDirectory.subjectRegions
        XCTAssertFalse(regions.isEmpty)
        XCTAssertTrue(regions.contains { $0.code == "77" && $0.name == "Город Москва" })
        XCTAssertTrue(regions.contains { $0.code == "50" && $0.name == "Московская область" })
        // Москва (77) и Московская область (50) — разные записи: словесный гейт
        // «contains(Москва)» их путал, кодовый — нет.
        XCTAssertNotEqual(regions.first { $0.code == "77" }?.name,
                          regions.first { $0.code == "50" }?.name)
    }

    func testSubjectNameByCode() {
        XCTAssertEqual(CourtDirectory.subjectName(forSubjectCode: "77"), "Город Москва")
        XCTAssertEqual(CourtDirectory.subjectName(forSubjectCode: "50"), "Московская область")
        XCTAssertEqual(CourtDirectory.subjectName(forSubjectCode: "11"), "Республика Коми")
    }
}
