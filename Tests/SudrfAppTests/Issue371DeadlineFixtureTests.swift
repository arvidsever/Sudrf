import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class Issue371DeadlineFixtureTests: XCTestCase {
    private func fixture() throws -> CaseMovement {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "issue371_movement", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(CaseMovement.self, from: Data(contentsOf: url))
    }

    private func context() -> MovementContext {
        MovementContext(
            branchRaw: "general", region: "Республика Коми",
            searchDomain: "uwsud--komi.sudrf.ru",
            displayDomain: "uwsud.komi.sudrf.ru",
            courtTitle: "Усть-Вымский районный суд",
            courtLevelRaw: "district", courtCode: "11", cartotekaId: "g1",
            cartotekaLevelRaw: "district",
            caseNumber: "2-441/2026 ~ М-300/2026")
    }

    func testMotivatedAppealDeterminationProducesOctoberCassationDeadline() throws {
        let snapshot = MovementDerivation.snapshot(
            from: try fixture(), context: context(), today: DateUtil.parse("26.09.2026")!)
        let deadline = try XCTUnwrap(snapshot.deadlines.first(where: {
            $0.provenance?.ruleID == "GPK-CASSATION-CSOY"
        }))

        XCTAssertEqual(deadline.date, DateUtil.parse("13.10.2026"))
        XCTAssertEqual(deadline.provenance?.trigger.dateRaw, "13.07.2026")
        XCTAssertEqual(deadline.status, .proposed)
        XCTAssertTrue(deadline.isActive)
        XCTAssertEqual(snapshot.deadlineAssessments?.first(where: {
            $0.ruleID == "GPK-CASSATION-CSOY"
        })?.status, .applicable)
        XCTAssertNotEqual(snapshot.stageRaw, CaseStageKind.cassation.rawValue)
    }

    func testMissingMotivatedAppealDeterminationExplainsAbsentDeadline() throws {
        var movement = try fixture()
        let appealIndex = try XCTUnwrap(movement.instances.firstIndex(where: { $0.level == .appeal }))
        movement.instances[appealIndex].sessions.removeAll {
            $0.event == "Составлено мотивированное апелляционное определение в окончательной форме"
        }

        let snapshot = MovementDerivation.snapshot(
            from: movement, context: context(), today: DateUtil.parse("26.09.2026")!)
        XCTAssertFalse(snapshot.deadlines.contains(where: { $0.kind == "cassation" }))
        let assessment = try XCTUnwrap(snapshot.deadlineAssessments?.first(where: {
            $0.ruleID == "GPK-CASSATION-CSOY"
        }))
        XCTAssertEqual(assessment.status, .insufficientEvidence)
        XCTAssertTrue(assessment.missingEvidenceRaw.contains(
            DeadlineEvidenceRequirement.motivatedAppealDetermination.rawValue))
    }
}
