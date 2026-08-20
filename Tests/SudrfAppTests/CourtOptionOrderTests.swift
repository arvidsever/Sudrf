import XCTest
import SudrfKit
@testable import SudrfApp

/// Регресс #97: нумерованные суды (КСОЮ, апелляционные ОСЮ) сортировались
/// лексикографически по названию, из-за чего «Восьмой» вставал перед «Вторым»,
/// а «Девятый» — перед «Первым».
@MainActor
final class CourtOptionOrderTests: XCTestCase {

    private func option(_ title: String, number: Int? = nil,
                        level: CourtLevel = .cassation) -> SearchModel.CourtOption {
        SearchModel.CourtOption(domain: "\(number.map(String.init) ?? title).sudrf.ru",
                                title: title, level: level, number: number)
    }

    func testCassationCourtsFollowTheirNumberNotTheAlphabet() {
        let ordered = SearchModel.ordered(CourtDirectory.cassationCourts.map {
            option($0.title, number: $0.number)
        })

        XCTAssertEqual(ordered.map(\.number), Array(1...9))
        XCTAssertEqual(ordered.first?.title, "Первый кассационный суд")
        XCTAssertEqual(ordered.last?.title, "Девятый кассационный суд")
    }

    func testAppealCourtsFollowTheirNumberNotTheAlphabet() {
        let ordered = SearchModel.ordered(CourtDirectory.appealCourts.map {
            option($0.title, number: $0.number, level: .appeal)
        })

        XCTAssertEqual(ordered.map(\.number), Array(1...5))
        XCTAssertEqual(ordered.map(\.title), [
            "Первый апелляционный суд", "Второй апелляционный суд",
            "Третий апелляционный суд", "Четвертый апелляционный суд",
            "Пятый апелляционный суд"
        ])
    }

    /// Звенья без номеров (суды субъектов, районные) сортируются по названию —
    /// поведение до #97 не меняется.
    func testUnnumberedCourtsStayAlphabetical() {
        let ordered = SearchModel.ordered([
            option("Сыктывкарский городской суд", level: .district),
            option("Абаканский городской суд", level: .district),
            option("Ленинский районный суд", level: .district)
        ])

        XCTAssertEqual(ordered.map(\.title), [
            "Абаканский городской суд", "Ленинский районный суд", "Сыктывкарский городской суд"
        ])
    }

    /// Смешанный список не должен «терять» суд без номера: такие идут после
    /// нумерованных, а между собой — по названию.
    func testUnnumberedCourtsSortAfterNumberedOnes() {
        let ordered = SearchModel.ordered([
            option("Апелляционный военный суд", level: .appeal),
            option("Второй апелляционный суд", number: 2, level: .appeal),
            option("Первый апелляционный суд", number: 1, level: .appeal)
        ])

        XCTAssertEqual(ordered.map(\.title), [
            "Первый апелляционный суд", "Второй апелляционный суд", "Апелляционный военный суд"
        ])
    }
}
