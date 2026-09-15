import Foundation
import XCTest
import SwiftData
import SudrfKit
@testable import SudrfApp

@MainActor
final class MaterialStorePreparationTests: XCTestCase {
    private enum SaveError: Error { case forced }
    private let today = DateUtil.parse("01.09.2026")!

    private func insertStaleMaterial(in store: TrackedStore) throws -> TrackedCaseRecord {
        let uid = "11RS0001-01-2026-000100-11"
        let url = URL(string: "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=100&delo_id=1610001&srv_num=1")!
        let context = MovementContext(
            branchRaw: "general", region: "Республика Коми", searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru", courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: "district", courtCode: "11RS0001", cartotekaId: "m",
            cartotekaLevelRaw: "district", caseNumber: "15-100/2026", caseID: "100",
            cardURLString: url.absoluteString, judicialUID: uid)
        let material = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber, judge: nil,
            domain: context.searchDomain, foundByUID: false, result: nil, sessions: [], sourceURL: url,
            sourceEvidence: .init(judicialUID: uid, cartotekaID: "m", sourceCourtLevel: .district,
                                   sourceBranch: .general))
        let main = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: "5-200/2026", judge: nil,
            domain: context.searchDomain, foundByUID: true, result: nil, sessions: [],
            sourceURL: URL(string: "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=200&delo_id=1500001&srv_num=1"),
            sourceEvidence: .init(judicialUID: uid, cartotekaID: "adm", sourceCourtLevel: .district,
                                   sourceBranch: .general))
        var parties = CaseParties(kind: .civil)
        parties.add(role: "Защитник", name: "Петров Пётр Петрович")
        parties.add(role: "Привлекаемое лицо", name: "Иванов Иван Иванович",
                    articles: "ч. 1 ст. 12.8 КоАП РФ")
        // add(role:) upgrades the process today. Reproduce an old serialized
        // default explicitly after adding its retained raw role items.
        parties.kind = .civil
        let movement = CaseMovement(uid: uid, caseNumber: context.caseNumber, inForce: false,
                                    instances: [material, main], complaints: [:], acts: [], parties: parties)
        var snapshot = MovementDerivation.snapshot(from: movement, context: context, today: today)
        snapshot.partiesShort = "Петров Пётр Петрович · Защитник"
        snapshot.leadCharges = "устаревшие статьи"
        snapshot.secondPartyLine = PartiesSecondLine(name: "Иванов Иван Иванович",
                                                     articles: "ч. 1 ст. 12.8 КоАП РФ", more: nil)
        snapshot.deadlines = [StoredDeadline(
            kind: "appeal", what: "Пользовательский срок", basis: "Установлено пользователем",
            calLabel: "срок", dateRef: DateUtil.parse("20.10.2026")!.timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue, occurrenceKey: "manual-material")]
        // Seed a coherent existing manual-deadline projection so preparation
        // need only repair parties, rather than also repair this test fixture.
        let presentation = MovementDerivation.lifecyclePresentation(
            from: movement, snapshot: snapshot, context: context, today: today)
        snapshot.nextEvent = presentation.nextEvent
        snapshot.nextChipRaw = presentation.nextChip.rawValue
        return try store.reconcileAndUpsert(
            context: context, snapshot: snapshot, movement: movement, collections: ["Материалы"],
            movementFetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testCachedMaterialPartyRepairPreservesOtherStateAndIsIdempotent() throws {
        let store = TrackedStore(inMemory: true)
        let record = try insertStaleMaterial(in: store)
        let before = try XCTUnwrap(record.snapshot)
        let movement = record.movementData
        let fetched = record.movementFetchedAt
        let identity = record.identityStateData
        let journal = record.eventJournalData
        let logicalID = record.logicalCaseID
        let key = record.key

        XCTAssertTrue(try TrackedStorePreparation.prepare(context: store.container.mainContext, today: today))
        var expected = before
        expected.partiesShort = "Иванов Иван Иванович"
        expected.leadCharges = "ч. 1 ст. 12.8 КоАП РФ"
        expected.secondPartyLine = nil
        XCTAssertEqual(record.snapshot, expected)
        XCTAssertEqual(record.movementData, movement)
        XCTAssertEqual(record.movement?.parties.kind, .civil, "Source parser value remains unchanged")
        XCTAssertEqual(record.movementFetchedAt, fetched)
        XCTAssertEqual(record.identityStateData, identity)
        XCTAssertEqual(record.eventJournalData, journal)
        XCTAssertEqual(record.logicalCaseID, logicalID)
        XCTAssertEqual(record.key, key)
        XCTAssertEqual(record.collectionNames, ["Материалы"])
        XCTAssertFalse(try TrackedStorePreparation.prepare(context: store.container.mainContext, today: today))
        XCTAssertFalse(store.container.mainContext.hasChanges)
    }

    func testFailedMaterialPartyRepairRollsBackSnapshotAndPersistentState() throws {
        let store = TrackedStore(inMemory: true)
        let record = try insertStaleMaterial(in: store)
        let key = record.key
        let snapshot = record.snapshotData
        let movement = record.movementData
        let fetched = record.movementFetchedAt
        let identity = record.identityStateData
        let journal = record.eventJournalData

        XCTAssertThrowsError(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, today: today,
            save: { _ in throw SaveError.forced }))
        let restored = try XCTUnwrap(store.record(forKey: key))
        XCTAssertEqual(restored.snapshotData, snapshot)
        XCTAssertEqual(restored.movementData, movement)
        XCTAssertEqual(restored.movementFetchedAt, fetched)
        XCTAssertEqual(restored.identityStateData, identity)
        XCTAssertEqual(restored.eventJournalData, journal)
        XCTAssertEqual(restored.collectionNames, ["Материалы"])
        XCTAssertFalse(store.container.mainContext.hasChanges)
    }
}
