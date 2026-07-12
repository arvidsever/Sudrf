import XCTest
import Foundation
@testable import SudrfKit

/// Вклейка карточки из окна капчи (CaseMovement.replacingCaptchaStub) — общая
/// логика SearchModel и AppRouter. Раньше жила двумя копиями, и копия поиска
/// теряла категорию и стороны; тест закрепляет их сохранение.
final class CaptchaStubReplacementTests: XCTestCase {

    private let domain = "vs--komi.sudrf.ru"

    private func movementWithStub() -> CaseMovement {
        let first = CaseInstance(
            level: .first, court: "Сыктывкарский городской суд", caseNumber: "2-100/2026",
            judge: "Иванова И. И.", domain: "syktsud.komi.sudrf.ru", foundByUID: false,
            result: "Иск удовлетворён",
            sessions: [CaseSession(date: "10.03.2026", event: "Судебное заседание",
                                   result: "иск удовлетворён")])
        let stub = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "—",
            judge: nil, domain: domain, foundByUID: false,
            result: nil, sessions: [],
            captchaFormURL: URL(string: "https://\(domain)/modules.php?name=sud_delo"))
        return CaseMovement(
            uid: "11RS0001-01-2026-000100-11", caseNumber: "2-100/2026", inForce: false,
            instances: [first, stub], complaints: [:], acts: [], actBodies: [:],
            category: "Трудовые споры",
            parties: CaseParties(plaintiffs: ["Петров П. П."], defendants: ["ООО «Ромашка»"]))
    }

    private func appealCard() -> CaseCard {
        CaseCard(rawText: "", actText: "АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ …",
                 sessions: [CaseSession(date: "20.05.2026", event: "Судебное заседание",
                                        result: "решение оставлено без изменения")],
                 judge: "Сидорова С. С.", result: "Решение оставлено без изменения",
                 caseNumber: "33-200/2026", receiptDate: "01.05.2026",
                 acts: [CaseActText(id: "doc1", kind: "Определения",
                                    label: "Судебный акт #1 (Определения)",
                                    body: "АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ …")])
    }

    func testStubReplacedAndMetadataPreserved() {
        let mv = movementWithStub()
        let out = mv.replacingCaptchaStub(domain: domain, courtTitle: "ВС Коми",
                                          level: .appeal, card: appealCard())

        // Заглушка ушла, реальная инстанция встала.
        XCTAssertFalse(out.instances.contains { $0.captchaFormURL != nil })
        let appeal = out.instances.first { $0.level == .appeal }
        XCTAssertEqual(appeal?.caseNumber, "33-200/2026")
        XCTAssertEqual(appeal?.judge, "Сидорова С. С.")
        XCTAssertEqual(appeal?.foundByUID, true)

        // Акт добавлен и привязан.
        XCTAssertEqual(out.acts.count, 1)
        XCTAssertEqual(appeal?.actID, out.acts.first?.id)
        XCTAssertEqual(out.actBodies[out.acts.first?.id ?? ""], "АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ …")

        // Регресс: категория и стороны НЕ теряются (как терялись в копии поиска).
        XCTAssertEqual(out.category, mv.category)
        XCTAssertEqual(out.parties, mv.parties)
        XCTAssertEqual(out.uid, mv.uid)
        XCTAssertEqual(out.complaints, mv.complaints)
    }

    func testCardWithoutActAddsInstanceWithoutAct() {
        let card = CaseCard(rawText: "", actText: nil,
                            sessions: [], judge: nil, result: nil,
                            caseNumber: "33-300/2026")
        let out = movementWithStub().replacingCaptchaStub(domain: domain, courtTitle: "ВС Коми",
                                                          level: .appeal, card: card)
        XCTAssertTrue(out.acts.isEmpty)
        XCTAssertNil(out.instances.first { $0.level == .appeal }?.actID)
    }

    func testCaptchaActPrefersDecisionDate() {
        let card = CaseCard(rawText: "", actText: "акт", sessions: [], judge: nil, result: nil,
                            caseNumber: "33-300/2026", receiptDate: "01.01.2026", decisionDate: "02.02.2026",
                            acts: [CaseActText(id: "doc1", kind: "Определение", label: "Акт", body: "акт")])
        let out = movementWithStub().replacingCaptchaStub(domain: domain, courtTitle: "ВС Коми", level: .appeal, card: card)
        XCTAssertEqual(out.acts.first?.date, "02.02.2026")
    }
}
