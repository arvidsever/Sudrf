import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

struct Issue414FixtureFile: Decodable {
    struct Entry: Decodable {
        var movement: CaseMovement
        var context: MovementContext
    }
    var entries: [Entry]

    static func load() throws -> [Entry] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "issue414_ezhva_appeals", withExtension: "json",
            subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).entries
    }
}

final class Issue414LifecycleTests: XCTestCase {
    private let today = DateUtil.parse("06.10.2026")!

    func testThreeCompletedChainsUseOrdinaryAppealDespiteEarlierPrivateReview() throws {
        let entries = try Issue414FixtureFile.load()
        XCTAssertEqual(entries.count, 3)
        for entry in entries {
            let movement = entry.movement
            let first = try XCTUnwrap(movement.instances.first)
            let ordinary = try XCTUnwrap(movement.instances.last)
            XCTAssertEqual(ordinary.sourceEvidence?.lowerCourt?.caseNumber, first.caseNumber)
            XCTAssertEqual(ordinary.sourceEvidence?.lowerCourt?.courtTitle, "Эжвинский районный суд")
            let resolution = CaseLifecycleResolver.resolve(
                movement: movement, production: .kas, deadlines: [], today: today)
            XCTAssertEqual(resolution.stage, .done, movement.caseNumber)
            XCTAssertEqual(resolution.currentInstance?.caseNumber, ordinary.caseNumber)
            let snapshot = MovementDerivation.snapshot(
                from: movement, context: entry.context, today: today)
            XCTAssertEqual(snapshot.stageRaw, CaseStageKind.done.rawValue, movement.caseNumber)
            XCTAssertFalse(snapshot.inForce, movement.caseNumber)
            XCTAssertTrue((snapshot.deadlineAssessments ?? []).contains {
                $0.isIndeterminate && $0.missingEvidenceRaw.contains("legalForce")
            }, "Known legalForce warning remains a separate issue")
            let presentation = MovementDerivation.lifecyclePresentation(
                from: movement, snapshot: snapshot, context: entry.context, today: today)
            XCTAssertNil(presentation.currentTier, movement.caseNumber)
        }
    }

    func testCourtTitleAllowsObservedLocalitySuffixButRejectsConflictingIdentity() {
        let short = "Эжвинский районный суд"
        let full = "Эжвинский районный суд г. Сыктывкара Республики Коми"
        let domain = "ejvasud--komi.sudrf.ru"
        XCTAssertTrue(CaseLifecycleResolver.courtTitlesAgree(short, full, domain: domain))
        XCTAssertTrue(CaseLifecycleResolver.courtTitlesAgree(full, short, domain: domain))
        for conflicting in [
            "Эжвинский районный суд г. Ухты Республики Коми",
            "Эжвинский районный суд г. Сыктывкара Республики Карелия",
            "Эжвинский городской суд г. Сыктывкара Республики Коми",
            "Сыктывкарский районный суд г. Сыктывкара Республики Коми",
        ] {
            XCTAssertFalse(CaseLifecycleResolver.courtTitlesAgree(full, conflicting, domain: domain), conflicting)
        }
    }

    func testLocalitySuffixRequiresRegionKindAndKnownDomain() {
        let short = "Эжвинский районный суд"
        for full in [
            "Эжвинский районный суд г. Сыктывкара Республики Карелия",
            "Эжвинский районный суд г. Сыктывкара области",
            "Эжвинский районный суд г. Сыктывкара",
            "Эжвинский городской суд г. Сыктывкара Республики Коми",
        ] {
            XCTAssertFalse(CaseLifecycleResolver.courtTitlesAgree(short, full, domain: "ejvasud--komi.sudrf.ru"), full)
        }
        XCTAssertTrue(CaseLifecycleResolver.courtTitlesAgree(
            "Калининский районный суд", "Калининский районный суд г. Твери Тверской области",
            domain: "kalininsky--twr.sudrf.ru"))
        XCTAssertFalse(CaseLifecycleResolver.courtTitlesAgree(
            short, "Эжвинский районный суд г. Сыктывкара Республики Коми", domain: "unknown.example.invalid"))
        XCTAssertFalse(CaseLifecycleResolver.courtTitlesAgree(
            "Судебный участок № 1", "Судебный участок № 10", domain: "ejvasud--komi.sudrf.ru"))
    }

    func testExactCaseNumberDoesNotLinkDifferentCourt() throws {
        let entry = try XCTUnwrap(Issue414FixtureFile.load().last)
        var movement = entry.movement
        let sourceIDs = movement.instances.map(\.id)
        let index = movement.instances.count - 1
        movement.instances[index].sourceEvidence?.lowerCourt?.courtTitle =
            "Сыктывкарский районный суд г. Сыктывкара Республики Коми"
        XCTAssertEqual(movement.instances[index].sourceEvidence?.lowerCourt?.caseNumber,
                       movement.instances[0].caseNumber)
        let resolution = CaseLifecycleResolver.resolve(
            movement: movement, production: .kas, deadlines: [], today: today)
        XCTAssertEqual(resolution.stage, .first)
        XCTAssertFalse(resolution.isCompleted)
        XCTAssertEqual(resolution.currentInstance?.id, movement.instances[0].id)
        XCTAssertEqual(movement.instances.map(\.id), sourceIDs)
        let snapshot = MovementDerivation.snapshot(
            from: movement, context: entry.context, today: today)
        XCTAssertEqual(snapshot.stageRaw, CaseStageKind.first.rawValue)
    }

    func testActiveOrdinaryAppealRemainsAppeal() throws {
        let entry = try XCTUnwrap(Issue414FixtureFile.load().last)
        var movement = entry.movement
        let index = movement.instances.count - 1
        movement.instances[index].result = nil
        movement.instances[index].sourceEvidence?.decisionDate = nil
        movement.instances[index].sessions = [CaseSession(
            date: "08.07.2021", event: "Жалоба принята к производству"),
            CaseSession(date: "10.07.2021", event: "Судебное заседание")]
        let resolution = CaseLifecycleResolver.resolve(
            movement: movement, production: .kas, deadlines: [], today: DateUtil.parse("09.07.2021")!)
        XCTAssertEqual(resolution.stage, .appeal)
        XCTAssertFalse(resolution.isCompleted)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, movement.instances[index].caseNumber)
    }

    func testGenuineRemandAndNewFirstRoundRemainActive() throws {
        let entry = try XCTUnwrap(Issue414FixtureFile.load().last)
        var movement = entry.movement
        let index = movement.instances.count - 1
        let remand = "Решение отменено с направлением дела на новое рассмотрение в суд первой инстанции"
        movement.instances[index].result = remand
        movement.instances[index].sessions = [CaseSession(
            date: "19.07.2021", event: "Судебное заседание", result: remand)]
        let first = try XCTUnwrap(movement.instances.first)
        let newRound = CaseInstance(
            level: .first, court: first.court, caseNumber: "2а-414/2021",
            judge: nil, domain: first.domain, foundByUID: false, result: nil,
            sessions: [CaseSession(date: "01.09.2021", event: "Административное исковое заявление принято к производству")],
            sourceEvidence: .init(receiptDate: "01.09.2021"))
        movement.instances.append(newRound)
        let resolution = CaseLifecycleResolver.resolve(
            movement: movement, production: .kas, deadlines: [], today: today)
        XCTAssertEqual(resolution.stage, .first)
        XCTAssertFalse(resolution.isCompleted)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, newRound.caseNumber)
    }
}
