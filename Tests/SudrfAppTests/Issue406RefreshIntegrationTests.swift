import Foundation
import SwiftData
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue406MovementSequence: MovementProviding {
    private let values: [CaseMovement]
    private var index = 0

    init(_ values: [CaseMovement]) { self.values = values }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        defer { index += 1 }
        return values[min(index, values.count - 1)]
    }
}

@MainActor
final class Issue406RefreshIntegrationTests: XCTestCase {
    private let today = DateUtil.parse("22.09.2026")!
    private let joinedStatus = "Присоединено к другому делу"
    private let manualKey = "issue-406-manual"
    private let manualDate = DateUtil.parse("01.01.2030")!
    private let syntheticActID = "issue-406-local-act"
    private let syntheticActText = "Синтетический текст акта для проверки сохранения карточки."

    private var syntheticAct: CaseAct {
        CaseAct(id: syntheticActID, title: "Локальный синтетический акт",
                date: "22.09.2026", courtShort: "1-я инстанция",
                instanceLevel: .first)
    }

    func testPreparationRepairsLifecycleWithoutChangingMovementOrJournal() throws {
        let entry = try XCTUnwrap(Issue406FixtureFile.load().first)
        let movement = try movementWithSyntheticAct(entry.movement)
        let store = TrackedStore(inMemory: true)
        var stale = MovementDerivation.snapshot(
            from: movement, context: entry.context, today: today)
        stale.stageRaw = CaseStageKind.first.rawValue
        stale.stageTag = CaseStageKind.first.label
        stale.statusText = "В производстве"
        stale.nextEvent = "—"
        stale.steps = ["active", "todo", "todo", "todo"]
        let record = try store.upsert(
            context: entry.context, snapshot: stale, movement: movement,
            collections: ["Регрессия #406"])
        record.movementFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        record.seenAt = Date(timeIntervalSince1970: 1_700_000_001)
        let seed = historicalJoinEvent(movement.caseNumber)
        record.eventJournal = CaseEventJournal(events: [seed])
        try store.save()

        let oldMovement = record.movementData
        let expectedActDocument = try XCTUnwrap(store.courtActDocument(
            caseKey: record.key, sourceActID: syntheticActID))
        let oldJournal = record.eventJournalData
        let oldFetchedAt = record.movementFetchedAt
        let oldSeenAt = record.seenAt
        let oldCollections = record.collectionNames
        XCTAssertTrue(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, today: today))

        let repaired = try XCTUnwrap(store.record(forKey: record.key))
        XCTAssertEqual(repaired.snapshot?.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(repaired.snapshot?.statusText, joinedStatus)
        XCTAssertEqual(repaired.snapshot?.nextEvent, joinedStatus)
        XCTAssertEqual(repaired.movementData, oldMovement)
        try assertSyntheticAct(in: store, record: repaired, key: record.key,
                               expectedDocument: expectedActDocument)
        XCTAssertEqual(repaired.eventJournalData, oldJournal)
        XCTAssertEqual(repaired.movementFetchedAt, oldFetchedAt)
        XCTAssertEqual(repaired.seenAt, oldSeenAt)
        XCTAssertEqual(repaired.collectionNames, oldCollections)
        XCTAssertFalse(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, today: today))
    }

    func testFullPartialRefreshAndRestartKeepJoinedOutcomeManualDeadlineAndHistory()
        async throws {
        let entry = try XCTUnwrap(Issue406FixtureFile.load().first)
        let fullMovement = try movementWithSyntheticAct(entry.movement)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-406-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        var stale = MovementDerivation.snapshot(
            from: fullMovement, context: entry.context, today: today)
        stale.stageRaw = CaseStageKind.first.rawValue
        stale.stageTag = CaseStageKind.first.label
        stale.statusText = "В производстве"
        stale.deadlines.append(StoredDeadline(
            kind: "custom", what: "Пользовательский срок", basis: "Тест #406",
            calLabel: "ручной", dateRef: manualDate.timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue, occurrenceKey: manualKey,
            lifecycleRaw: DeadlineLifecycle.active.rawValue))
        let record = try store.upsert(
            context: entry.context, snapshot: stale, movement: fullMovement,
            collections: ["Регрессия #406"])
        let key = record.key
        let seenAt = Date(timeIntervalSince1970: 1_700_000_001)
        record.seenAt = seenAt
        let seed = historicalJoinEvent(fullMovement.caseNumber)
        record.eventJournal = CaseEventJournal(events: [seed])
        try store.save()

        let expectedActDocument = try XCTUnwrap(store.courtActDocument(
            caseKey: key, sourceActID: syntheticActID))
        var partial = fullMovement
        partial.instances.removeAll()
        partial.acts.removeAll()
        partial.actBodies.removeAll()
        partial.incompleteHigherCourtDomains = [entry.context.searchDomain]
        let provider = Issue406MovementSequence([fullMovement, partial, fullMovement])
        let center = RefreshCenter(
            store: store, client: SudrfClient(), serviceBuilder: { _ in provider })

        let fullRefresh = await center.refresh(key: key)?.value
        XCTAssertEqual(fullRefresh?.outcome, .refreshed)
        try assertJoinedState(in: store, key: key, seed: seed, seenAt: seenAt,
                              movement: fullMovement,
                              expectedActDocument: expectedActDocument)
        let fullSnapshot = try XCTUnwrap(store.record(forKey: key)?.snapshot)
        let fullFetchedAt = try XCTUnwrap(store.record(forKey: key)?.movementFetchedAt)

        guard case .partial = await center.refresh(key: key)?.value.outcome else {
            return XCTFail("Ожидался partial refresh")
        }
        try assertJoinedState(in: store, key: key, seed: seed, seenAt: seenAt,
                              movement: fullMovement,
                              expectedActDocument: expectedActDocument)
        XCTAssertEqual(store.record(forKey: key)?.snapshot, fullSnapshot)
        XCTAssertEqual(store.record(forKey: key)?.movementFetchedAt, fullFetchedAt)

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        try assertJoinedState(in: reopened, key: key, seed: seed, seenAt: seenAt,
                              movement: fullMovement,
                              expectedActDocument: expectedActDocument)
        let reopenedCenter = RefreshCenter(
            store: reopened, client: SudrfClient(),
            serviceBuilder: { _ in Issue406MovementSequence([fullMovement]) })
        let reopenedRefresh = await reopenedCenter.refresh(key: key)?.value
        XCTAssertEqual(reopenedRefresh?.outcome, .refreshed)
        try assertJoinedState(in: reopened, key: key, seed: seed, seenAt: seenAt,
                              movement: fullMovement,
                              expectedActDocument: expectedActDocument)

        let router = try AppRouter(
            modelContainer: reopenedContainer, modelContainerIsPrepared: true)
        router.reload(today: today)
        XCTAssertEqual(router.cases.count, 1)
        XCTAssertEqual(router.cases.first?.stage, .done)
        XCTAssertEqual(router.cases.first?.statusText, joinedStatus)
    }

    private func assertJoinedState(in store: TrackedStore, key: String,
                                   seed: CaseEvent, seenAt: Date,
                                   movement: CaseMovement,
                                   expectedActDocument: ActDocument) throws {
        let record = try XCTUnwrap(store.record(forKey: key))
        let snapshot = try XCTUnwrap(record.snapshot)
        XCTAssertEqual(snapshot.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(snapshot.statusText, joinedStatus)
        XCTAssertFalse(snapshot.inForce)
        XCTAssertTrue(snapshot.deadlines.contains {
            $0.occurrenceKey == manualKey && $0.status == .confirmed
        })
        XCTAssertEqual(record.movement?.instances, movement.instances)
        try assertSyntheticAct(in: store, record: record, key: key,
                               expectedDocument: expectedActDocument)
        XCTAssertEqual(record.eventJournal?.events, [seed])
        XCTAssertEqual(record.seenAt, seenAt)
        XCTAssertEqual(record.collectionNames, ["Регрессия #406"])
    }

    private func movementWithSyntheticAct(_ source: CaseMovement) throws -> CaseMovement {
        var movement = source
        let index = try XCTUnwrap(movement.instances.firstIndex {
            $0.level == .first && $0.caseNumber == movement.caseNumber
        })
        movement.instances[index].actID = syntheticActID
        movement.instances[index].actIDs = [syntheticActID]
        movement.acts.append(syntheticAct)
        movement.actBodies[syntheticActID] = syntheticActText
        return movement
    }

    private func assertSyntheticAct(in store: TrackedStore,
                                    record: TrackedCaseRecord, key: String,
                                    expectedDocument: ActDocument) throws {
        let movement = try XCTUnwrap(record.movement)
        let act = try XCTUnwrap(movement.acts.first { $0.id == syntheticActID })
        let instance = try XCTUnwrap(movement.instances.first {
            $0.linkedActIDs.contains(syntheticActID)
        })
        let text = try XCTUnwrap(movement.actBodies[syntheticActID])
        let document = try XCTUnwrap(store.courtActDocument(
            caseKey: key, sourceActID: syntheticActID))
        XCTAssertEqual(act, syntheticAct)
        XCTAssertEqual(instance.linkedActIDs, [syntheticActID])
        XCTAssertEqual(text, syntheticActText)
        XCTAssertEqual(ActParagraphizer.sourceHash(for: text), expectedDocument.sourceHash)
        XCTAssertEqual(document.id, expectedDocument.id)
        XCTAssertEqual(document.sourceActID, expectedDocument.sourceActID)
        XCTAssertEqual(document.sourceText, expectedDocument.sourceText)
        XCTAssertEqual(document.sourceHash, expectedDocument.sourceHash)
    }

    private func historicalJoinEvent(_ caseNumber: String) -> CaseEvent {
        CaseEvent.make(
            kind: .resultChanged, occurrence: ["issue-406-history", caseNumber],
            observedAt: Date(timeIntervalSinceReferenceDate: 1),
            evidence: .init(caseNumber: caseNumber, value: "Дело присоединено к другому делу"))
    }
}
