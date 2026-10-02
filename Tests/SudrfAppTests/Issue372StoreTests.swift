import XCTest
import SwiftData
import SudrfKit
@testable import SudrfApp

@MainActor
final class Issue372StoreTests: XCTestCase {
    private let today = DateUtil.parse("02.10.2026")!

    private func fixture() -> (MovementContext, CaseMovement) {
        let context = MovementContext(branchRaw: "general", region: "Проверочный регион",
            searchDomain: "qa.sudrf.ru", displayDomain: "qa.sudrf.ru",
            courtTitle: "Проверочный районный суд", courtLevelRaw: "district", courtCode: "00RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: "district", caseNumber: "2-372/2026",
            caseID: "qa372", caseUID: "qa372-card")
        let first = CaseInstance(level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.searchDomain, foundByUID: false,
            result: "Иск удовлетворён", sessions: [
                CaseSession(date: "03.09.2026", event: "Судебное заседание", result: "Иск удовлетворён"),
                CaseSession(date: "04.09.2026", event: "Изготовлено мотивированное решение в окончательной форме")])
        let movement = CaseMovement(uid: "00RS0001-01-2026-000372-11", caseNumber: context.caseNumber,
            inForce: false, instances: [first], complaints: [:], acts: [], category: "Споры из договоров")
        return (context, movement)
    }

    func testPreparationRefreshesAssessmentsWithoutActiveTermsAndDoesNotAdmitNewDeadline() throws {
        for history in [false, true] {
            for partial in [false, true] {
                let store = TrackedStore(inMemory: true)
                let (context, movement) = fixture()
                let fresh = MovementDerivation.snapshot(from: movement, context: context, today: today)
                var old = fresh
                old.deadlines = history ? fresh.deadlines.map { deadline in
                    var historical = deadline
                    historical.lifecycleRaw = DeadlineLifecycle.superseded.rawValue
                    historical.statusRaw = DeadlineStatus.confirmed.rawValue
                    return historical
                } : []
                old.deadlineAssessments = [DeadlineRuleAssessment(ruleID: "KAS-CASSATION-KSOYU",
                    kind: "cassation", statusRaw: DeadlineAssessmentStatus.needsLegalReview.rawValue)]
                let record = try store.reconcileAndUpsert(context: context, snapshot: old,
                    movement: movement, collections: ["Проверка #372"], movementFetchedAt: partial ? nil : today)
                // Seed the legacy stored snapshot after the normal upsert derivation.
                record.snapshot = old
                try store.save()
                let journal = record.eventJournal
                let seenAt = record.seenAt
                let fetchedAt = record.movementFetchedAt
                for _ in 0..<2 {
                    _ = try TrackedStorePreparation.prepare(context: store.container.mainContext, today: today)
                    let current = try XCTUnwrap(store.record(forKey: record.key)?.snapshot)
                    XCTAssertEqual(current.deadlineAssessments, fresh.deadlineAssessments)
                    XCTAssertEqual(current.deadlines, old.deadlines)
                    XCTAssertFalse(current.deadlines.contains(where: \.isActive))
                    XCTAssertEqual(record.movement, movement)
                    XCTAssertEqual(record.eventJournal, journal)
                    XCTAssertEqual(record.seenAt, seenAt)
                    XCTAssertEqual(record.movementFetchedAt, fetchedAt)
                    XCTAssertEqual(record.collectionNames, ["Проверка #372"])
                }
            }
        }
    }

    func testPreparedAssessmentsSurviveDiskReopenWithoutCreatingNewTerms() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("issue372-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("qa.store")
        let (context, movement) = fixture()
        let fresh = MovementDerivation.snapshot(from: movement, context: context, today: today)
        var key = ""
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            var old = fresh
            old.deadlines = []
            old.deadlineAssessments = [DeadlineRuleAssessment(ruleID: "legacy-warning",
                statusRaw: DeadlineAssessmentStatus.insufficientEvidence.rawValue)]
            let record = try store.reconcileAndUpsert(context: context, snapshot: old,
                movement: movement, collections: ["Проверка #372"], movementFetchedAt: today)
            record.snapshot = old; key = record.key
            try store.save()
            _ = try TrackedStorePreparation.prepare(context: container.mainContext, today: today)
        }
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            _ = try TrackedStorePreparation.prepare(context: container.mainContext, today: today)
            let snapshot = try XCTUnwrap(store.record(forKey: key)?.snapshot)
            XCTAssertEqual(snapshot.deadlineAssessments, fresh.deadlineAssessments)
            XCTAssertTrue(snapshot.deadlines.isEmpty)
        }
    }
}
