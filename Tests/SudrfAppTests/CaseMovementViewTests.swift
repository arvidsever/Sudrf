import XCTest
@testable import SudrfApp
import SudrfKit

final class CaseMovementViewTests: XCTestCase {
    @MainActor
    func testMaterialProjectionKeepsPublishedMovementAndSourceState() {
        let session = CaseSession(
            date: "02.09.2026", time: "10:30", room: "Зал № 1",
            event: "Судебное заседание", result: "Удовлетворено")
        let material = CaseInstance(
            level: .material, court: "Районный суд", caseNumber: "13-1/2026",
            judge: "Иванов И.И.", domain: "court.sudrf.ru", foundByUID: true,
            result: "Удовлетворено", sessions: [session],
            note: "Движение временно недоступно")
        let base = CaseInstance(
            level: .first, court: "Районный суд", caseNumber: "2-1/2026",
            judge: nil, domain: "court.sudrf.ru", foundByUID: false,
            result: nil, sessions: [])
        let movement = CaseMovement(
            uid: "11RS0001-01-2026-000001-11", caseNumber: "2-1/2026",
            inForce: false, instances: [base, material], complaints: [:], acts: [])

        let projected = CaseMovementView.materialInstances(in: movement)

        XCTAssertEqual(projected, [material])
        XCTAssertEqual(projected.first?.sessions, [session])
        XCTAssertEqual(projected.first?.note, "Движение временно недоступно")
    }
}
