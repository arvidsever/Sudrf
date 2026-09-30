import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class PublishedActPresentationTests: XCTestCase {
    private let pdfURL = URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/34000001")!

    private func movement(_ acts: [CaseAct], bodies: [String: String] = [:]) -> CaseMovement {
        let instances = acts.map { act in
            CaseInstance(level: .vsCassation, court: "Верховный Суд РФ",
                         caseNumber: act.productionNumber ?? "3-ИКАД25-3-А2", judge: nil,
                         domain: "vsrf.ru", foundByUID: true, result: "Оставлено без изменения",
                         sessions: [], actID: act.id,
                         sourceURL: URL(string: "https://www.vsrf.ru/lk/practice/claims/12-36321243"))
        }
        return CaseMovement(uid: "", caseNumber: "3а-85/2025", inForce: true,
                            instances: instances, complaints: [:], acts: acts, actBodies: bodies)
    }

    private func act(_ id: String, number: String = "3-ИКАД25-3-А2") -> CaseAct {
        CaseAct(id: id, title: "Кассационное определение", date: "15.10.2025",
                courtShort: "ВС РФ", instanceLevel: .vsCassation,
                sourceFileURL: pdfURL, productionNumber: number)
    }

    func testPublishedFileVisibleBeforeTextAndAfterSavedMovementReopen() throws {
        let saved = try JSONDecoder().decode(CaseMovement.self,
            from: JSONEncoder().encode(movement([act("published")])) )
        let row = try XCTUnwrap(CourtActPresentation.rows(in: saved).first)
        XCTAssertEqual(row.id, "published")
        XCTAssertEqual(row.title, "Кассационное определение")
        XCTAssertEqual(row.date, "15.10.2025")
        XCTAssertEqual(row.stage, "кассация")
        XCTAssertEqual(row.originalURL, pdfURL)
        XCTAssertEqual(row.productionNumber, "3-ИКАД25-3-А2")
        XCTAssertEqual(row.text, "")
    }

    func testUnloadedFilesNeverMergeBecauseBothHaveEmptyText() {
        let rows = CourtActPresentation.rows(in: movement([act("one"), act("two", number: "3-ИКАД26-1-А2")]))
        XCTAssertEqual(rows.count, 2)
    }

    func testDifferentProductionsRemainDistinctEvenWithEqualReadableText() {
        let text = "КАССАЦИОННОЕ ОПРЕДЕЛЕНИЕ\nОставлено без изменения."
        let rows = CourtActPresentation.rows(in: movement(
            [act("one"), act("two", number: "3-ИКАД26-1-А2")], bodies: ["one": text, "two": text]))
        XCTAssertEqual(rows.count, 2)
    }

    func testLoadPreservesSourceIDAndOwnProduction() throws {
        let initial = movement([act("published")])
        var loaded = initial
        loaded.actBodies["published"] = "КАССАЦИОННОЕ ОПРЕДЕЛЕНИЕ\n3-ИКАД25-3-А2\nТекст акта."
        let row = try XCTUnwrap(CourtActPresentation.row(for: "published", in: loaded))
        XCTAssertEqual(row.id, CourtActPresentation.rows(in: initial).first?.id)
        XCTAssertEqual(row.productionNumber, "3-ИКАД25-3-А2")
        XCTAssertEqual(row.text, loaded.actBodies["published"])
    }

    func testUnsafeFileDoesNotCreatePublishedRow() {
        var unsafe = act("bad")
        unsafe.sourceFileURL = URL(string: "https://evil.example/document.pdf")
        XCTAssertTrue(CourtActPresentation.rows(in: movement([unsafe])).isEmpty)
    }
}
