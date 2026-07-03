import XCTest
import Foundation
import SudrfKit
@testable import SudrfApp

/// Модель редизайна «Моих дел» (v20): вид производства по номеру дела,
/// разделитель сторон «⚔», сортировка и живой фильтр таблицы «Списком».
final class MyCasesModelTests: XCTestCase {

    // MARK: Вид производства по префиксу номера

    func testProductionTypeByPrefix() {
        XCTAssertEqual(ProductionType.of("1-45/2026"), .crim)
        XCTAssertEqual(ProductionType.of("5-120/2026"), .koap)
        XCTAssertEqual(ProductionType.of("2а-77/2026"), .kas)
        XCTAssertEqual(ProductionType.of("3а-5/2026"), .kas)
        XCTAssertEqual(ProductionType.of("8а-1/2026"), .kas)
        XCTAssertEqual(ProductionType.of("33а-9/2026"), .kas)
        XCTAssertEqual(ProductionType.of("2-115/2026"), .civil)
        XCTAssertEqual(ProductionType.of("33-4/2026"), .civil)
    }

    func testProductionTypeUppercaseLetter() {
        // На портале встречается заглавная «А» в индексе.
        XCTAssertEqual(ProductionType.of("2А-77/2026"), .kas)
    }

    // MARK: Стороны через «⚔»

    func testPartiesShortUsesCrossedSwords() {
        let p = CaseParties(plaintiffs: ["Новожилова Е. В."], defendants: ["ООО «Северлес»"])
        XCTAssertEqual(MovementDerivation.partiesShort(p), "Новожилова Е. В. ⚔ ООО «Северлес»")
    }

    // MARK: Сортировка таблицы

    private func tracked(_ number: String, last: Date? = nil, next: Date? = nil) -> TrackedCase {
        TrackedCase(recordKey: "court/" + number, caseNumber: number, collections: [],
                    stage: .first, stageTag: "1-я инст.", subject: "—", court: "Сыктывкарский городской суд",
                    partiesShort: "Иванов А. А. ⚔ ООО «Ромашка»", statusText: "В производстве",
                    statusChip: .blue, last: "—", next: "—", nextChip: .gray,
                    isNew: false, steps: [], newDot: false,
                    lastEventDate: last, nextEventDate: next)
    }

    func testSortByNumberIsNumeric() {
        let rows = [tracked("2-10/2026"), tracked("2-9/2026"), tracked("2-100/2026")]
        let sorted = AppRouter.sorted(rows, by: .number).map(\.caseNumber)
        XCTAssertEqual(sorted, ["2-9/2026", "2-10/2026", "2-100/2026"])
    }

    func testSortByActivityFreshFirst() {
        let d1 = DateUtil.parse("01.04.2026")!, d2 = DateUtil.parse("20.04.2026")!
        let rows = [tracked("2-1/2026", last: d1), tracked("2-2/2026", last: d2),
                    tracked("2-3/2026", last: nil)]
        let sorted = AppRouter.sorted(rows, by: .activity).map(\.caseNumber)
        XCTAssertEqual(sorted, ["2-2/2026", "2-1/2026", "2-3/2026"])   // nil — в конец
    }

    func testSortByNextEventNearestFirst() {
        let d1 = DateUtil.parse("10.05.2026")!, d2 = DateUtil.parse("03.05.2026")!
        let rows = [tracked("2-1/2026", next: d1), tracked("2-2/2026", next: d2),
                    tracked("2-3/2026", next: nil)]
        let sorted = AppRouter.sorted(rows, by: .nextEvent).map(\.caseNumber)
        XCTAssertEqual(sorted, ["2-2/2026", "2-1/2026", "2-3/2026"])   // без события — в конец
    }

    // MARK: Живой фильтр

    func testQueryMatchesNumberPartiesCollectionsCourt() {
        var c = tracked("2-115/2026")
        c.collections = ["Новожилова"]
        XCTAssertTrue(AppRouter.matches(c, query: "2-115"))
        XCTAssertTrue(AppRouter.matches(c, query: "ромашка"))       // стороны, регистр
        XCTAssertTrue(AppRouter.matches(c, query: "новожилова"))    // подборка
        XCTAssertTrue(AppRouter.matches(c, query: "сыктывкарский"))  // суд
        XCTAssertFalse(AppRouter.matches(c, query: "петров"))
    }
}
