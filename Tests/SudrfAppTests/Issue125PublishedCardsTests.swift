import XCTest
import SudrfKit
@testable import SudrfApp

final class Issue125PublishedCardsTests: XCTestCase {
    func testPublishedCategoriesAndDatedReturnOutcomes() throws {
        for (fixture, number, host, court, level, expectedDate, expectedRule) in [
            ("issue125_9a-66-2025", "9а-66/2025", "vs.komi.sudrf.ru",
             "Верховный Суд Республики Коми", "subject", "16.12.2025", "KAS-PRIVATE-GENERAL"),
            ("issue125_9a-307-2025", "9а-307/2025", "vktsud--komi.sudrf.ru",
             "Воркутинский городской суд Республики Коми", "district", "01.07.2025", "KAS-PRIVATE-ELECTION"),
        ] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "html", subdirectory: "Fixtures"))
            let card = try CaseCardParser.parse(html: String(contentsOf: url, encoding: .utf8))
            XCTAssertTrue(card.caseNumber?.hasPrefix(number) == true)
            XCTAssertEqual(card.sessions.count, 4)
            let context = MovementContext(branchRaw: "general", region: "Республика Коми",
                searchDomain: host, displayDomain: host, courtTitle: court,
                courtLevelRaw: level, courtCode: nil, cartotekaId: "p1",
                cartotekaLevelRaw: level, caseNumber: number, judicialUID: card.uid)
            let first = CaseInstance(level: .first, court: court, caseNumber: number,
                judge: nil, domain: host, foundByUID: false, result: card.result,
                sessions: card.sessions, sourceEvidence: .init(
                    decisionDate: card.decisionDate, judicialUID: card.uid,
                    cartotekaID: "p1", category: card.category, ownProcessKind: card.processKind))
            let movement = CaseMovement(uid: card.uid ?? "", caseNumber: number, inForce: false,
                instances: [first], complaints: [:], acts: [], category: card.category)
            let result = DeadlineRuleEngine.evaluate(registry: try LegalDeadlineRegistry.load(),
                movement: movement, context: .init(movementContext: context),
                timeline: CaseLifecycleResolver.timeline(in: movement, production: .kas),
                today: DateUtil.parse(card.decisionDate!)!)
            XCTAssertEqual(result.deadlines.count, 1, number)
            XCTAssertEqual(result.deadlines.first?.what, "Частная жалоба", number)
            XCTAssertEqual(result.deadlines.first?.provenance?.ruleID, expectedRule, number)
            XCTAssertEqual(result.deadlines.first?.date, DateUtil.parse(expectedDate), number)
            XCTAssertFalse(result.deadlines.contains { $0.what == "Апелляционная жалоба" })
        }
    }
}
