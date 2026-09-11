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

    @MainActor
    func testPreviousRegistrationProjectionPreservesEventsAndLeavesMaterialsSeparate() {
        let historicalSession = CaseSession(
            date: "01.09.2026", time: "09:00", room: nil,
            event: "Регистрация заявления", result: nil)
        let historical = CaseInstance(
            level: .first, court: "Районный суд", caseNumber: "9а-10/2026",
            judge: nil, domain: "court.sudrf.ru", foundByUID: false,
            result: nil, sessions: [historicalSession],
            note: "Предыдущая регистрация")
        let current = CaseInstance(
            level: .first, court: "Районный суд", caseNumber: "3а-10/2026",
            judge: nil, domain: "court.sudrf.ru", foundByUID: false,
            result: nil, sessions: [CaseSession(
                date: "02.09.2026", event: "Принято к производству")])
        let material = CaseInstance(
            level: .material, court: "Районный суд", caseNumber: "13а-10/2026",
            judge: nil, domain: "court.sudrf.ru", foundByUID: false,
            result: nil, sessions: [], note: "Предыдущая регистрация")
        let movement = CaseMovement(
            uid: "11RS0001-01-2026-000010-11", caseNumber: current.caseNumber,
            inForce: false, instances: [historical, current, material],
            complaints: [:], acts: [])

        XCTAssertEqual(CaseMovementView.activeInstances(in: movement), [current])
        XCTAssertEqual(CaseMovementView.previousRegistrationInstances(in: movement),
                       [historical, material])
        XCTAssertEqual(CaseMovementView.previousRegistrationInstances(in: movement)
            .first?.sessions, [historicalSession])
        XCTAssertTrue(CaseMovementView.materialInstances(in: movement).isEmpty)
    }

    func testHistoricalMaterialSourceUsesRegistrationLabel() {
        let date = Date(timeIntervalSince1970: 1_725_000_000)
        let feed = FeedEntry(
            id: "historical", dayHead: nil, date: date, time: "10:00",
            recordKey: "case", caseNumber: "3а-10/2026", client: "Доверитель",
            kind: .movement, text: "Регистрация", actID: nil, isUnread: false,
            instanceCaseNumber: "9а-10/2026", instanceLevel: .material,
            previousRegistrationNumber: "9а-10/2026")
        let hearing = TrackedHearing(
            recordKey: "case", date: date, time: "10:00",
            caseNumber: "3а-10/2026", parties: "—", court: "Суд", room: "",
            dateLabel: "1 сентября", instanceCaseNumber: "9а-10/2026",
            instanceLevel: .material,
            previousRegistrationNumber: "9а-10/2026")
        let genuineMaterial = FeedEntry(
            id: "material", dayHead: nil, date: date, time: "11:00",
            recordKey: "case", caseNumber: "3а-10/2026", client: "Доверитель",
            kind: .movement, text: "Материал", actID: nil, isUnread: false,
            instanceCaseNumber: "13а-10/2026", instanceLevel: .material)

        XCTAssertEqual(feed.secondaryLabel, "Предыдущая регистрация № 9а-10/2026")
        XCTAssertEqual(feed.notificationSubtitle,
                       "3а-10/2026 · Предыдущая регистрация № 9а-10/2026")
        XCTAssertEqual(hearing.secondaryLabel,
                       "Предыдущая регистрация № 9а-10/2026")
        XCTAssertEqual(genuineMaterial.secondaryLabel, "Материал № 13а-10/2026")
        XCTAssertEqual(genuineMaterial.notificationSubtitle,
                       "3а-10/2026 · Материал № 13а-10/2026")
    }
}
