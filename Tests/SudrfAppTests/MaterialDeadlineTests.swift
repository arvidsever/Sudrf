import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class MaterialDeadlineTests: XCTestCase {
    private func context(number: String, cartoteka: String) -> MovementContext {
        MovementContext(branchRaw: "general", region: "Республика Коми",
                        searchDomain: "syktsud--komi.sudrf.ru",
                        displayDomain: "syktsud.komi.sudrf.ru",
                        courtTitle: "Сыктывкарский городской суд",
                        courtLevelRaw: "district", courtCode: "11RS0001",
                        cartotekaId: cartoteka, cartotekaLevelRaw: "district",
                        caseNumber: number)
    }

    private func movement(number: String, extra: [CaseInstance] = []) -> CaseMovement {
        let first = CaseInstance(
            level: .first, court: "Сыктывкарский городской суд", caseNumber: number,
            judge: nil, domain: "syktsud.komi.sudrf.ru", foundByUID: false,
            result: "Производство по делу ПРЕКРАЩЕНО",
            sessions: [CaseSession(date: "01.04.2026", event: "Судебное заседание",
                                   result: "Производство по делу ПРЕКРАЩЕНО"),
                       CaseSession(date: "01.04.2026",
                                   event: "Изготовлено мотивированное решение в окончательной форме")])
        return CaseMovement(uid: "11RS0001-01-2026-000100-11", caseNumber: number,
                            inForce: false, instances: [first] + extra,
                            complaints: [:], acts: [], category: "Общие вопросы")
    }

    func testStandaloneMaterialsDoNotReceiveMainCaseDeadlineBindings() throws {
        for (number, cartoteka) in [("13-100/2026", "m"), ("13а-100/2026", "m"),
                                   ("3/12-100/2026", "m"), ("15-100/2026", "adm")] {
            let context = context(number: number, cartoteka: cartoteka)
            let movement = movement(number: number)
            let classification = MaterialProductionContext.resolve(context: context, movement: movement)
            XCTAssertTrue(classification.isMaterial, number)
            XCTAssertNotNil(classification.production, number)
            let evaluated = DeadlineRuleEngine.evaluate(
                registry: try LegalDeadlineRegistry.load(), movement: movement,
                context: .init(movementContext: context),
                timeline: CaseLifecycleResolver.timeline(in: movement, production: classification.production),
                today: DateUtil.parse("01.05.2026")!)
            XCTAssertTrue(evaluated.deadlines.isEmpty, number)
            XCTAssertTrue(evaluated.assessments.isEmpty, number)
            XCTAssertEqual(CaseLifecycleResolver.resolve(
                movement: movement, production: classification.production, deadlines: [],
                deadlineAssessments: evaluated.assessments,
                today: DateUtil.parse("01.05.2026")!).stage, .done, number)
            XCTAssertTrue(DeadlineRuleEngine.unavailable(context: .init(movementContext: context))
                .assessments.isEmpty, number)
        }
    }

    func testNestedMaterialDoesNotChangeMainCaseDeadlineEvaluation() throws {
        let number = "2-100/2026"
        let context = context(number: number, cartoteka: "g1")
        let plain = movement(number: number)
        let material = CaseInstance(
            level: .material, court: "Другой суд", caseNumber: "13а-200/2026",
            judge: nil, domain: "other.sudrf.ru", foundByUID: true,
            result: "Производство по делу ПРЕКРАЩЕНО",
            sessions: [CaseSession(date: "15.04.2026", event: "Судебное заседание",
                                   result: "Производство по делу ПРЕКРАЩЕНО")])
        let nested = movement(number: number, extra: [material])
        func evaluate(_ movement: CaseMovement) throws -> DeadlineRuleEngine.Evaluation {
            DeadlineRuleEngine.evaluate(
                registry: try LegalDeadlineRegistry.load(), movement: movement,
                context: .init(movementContext: context),
                timeline: CaseLifecycleResolver.timeline(in: movement, production: .civil),
                today: DateUtil.parse("01.05.2026")!)
        }
        let expected = try evaluate(plain)
        let actual = try evaluate(nested)
        XCTAssertFalse(expected.deadlines.isEmpty, "Regression must exercise a real main-case deadline")
        XCTAssertEqual(actual.assessments, expected.assessments)
        XCTAssertEqual(actual.deadlines, expected.deadlines)
    }
}
