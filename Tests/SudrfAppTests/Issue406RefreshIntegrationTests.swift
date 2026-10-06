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

    func testPreparationRepairsLifecycleWithoutChangingMovementOrJournal() throws {
        let entry = try XCTUnwrap(Issue406FixtureFile.load().first)
        let store = TrackedStore(inMemory: true)
        var stale = MovementDerivation.snapshot(
            from: entry.movement, context: entry.context, today: today)
        stale.stageRaw = CaseStageKind.first.rawValue
        stale.stageTag = CaseStageKind.first.label
        stale.statusText = "В производстве"
        stale.nextEvent = "—"
        stale.steps = ["active", "todo", "todo", "todo"]
        let record = try store.upsert(
            context: entry.context, snapshot: stale, movement: entry.movement,
            collections: ["Регрессия #406"])
        record.movementFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        record.seenAt = Date(timeIntervalSince1970: 1_700_000_001)
        let seed = historicalJoinEvent(entry.movement.caseNumber)
        record.eventJournal = CaseEventJournal(events: [seed])
        try store.save()

        let oldMovement = record.movementData
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-406-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        var stale = MovementDerivation.snapshot(
            from: entry.movement, context: entry.context, today: today)
        stale.stageRaw = CaseStageKind.first.rawValue
        stale.stageTag = CaseStageKind.first.label
        stale.statusText = "В производстве"
        stale.deadlines.append(StoredDeadline(
            kind: "custom", what: "Пользовательский срок", basis: "Тест #406",
            calLabel: "ручной", dateRef: manualDate.timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue, occurrenceKey: manualKey,
            lifecycleRaw: DeadlineLifecycle.active.rawValue))
        let record = try store.upsert(
            context: entry.context, snapshot: stale, movement: entry.movement,
            collections: ["Регрессия #406"])
        let key = record.key
        let seenAt = Date(timeIntervalSince1970: 1_700_000_001)
        record.seenAt = seenAt
        let seed = historicalJoinEvent(entry.movement.caseNumber)
        record.eventJournal = CaseEventJournal(events: [seed])
        try store.save()

        var partial = entry.movement
        partial.instances.removeAll()
        partial.incompleteHigherCourtDomains = [entry.context.searchDomain]
        let provider = Issue406MovementSequence([entry.movement, partial, entry.movement])
        let center = RefreshCenter(
            store: store, client: SudrfClient(), serviceBuilder: { _ in provider })

        let fullRefresh = await center.refresh(key: key)?.value
        XCTAssertEqual(fullRefresh?.outcome, .refreshed)
        try assertJoinedState(in: store, key: key, seed: seed, seenAt: seenAt,
                              movement: entry.movement)
        let fullSnapshot = try XCTUnwrap(store.record(forKey: key)?.snapshot)
        let fullFetchedAt = try XCTUnwrap(store.record(forKey: key)?.movementFetchedAt)

        guard case .partial = await center.refresh(key: key)?.value.outcome else {
            return XCTFail("Ожидался partial refresh")
        }
        try assertJoinedState(in: store, key: key, seed: seed, seenAt: seenAt,
                              movement: entry.movement)
        XCTAssertEqual(store.record(forKey: key)?.snapshot, fullSnapshot)
        XCTAssertEqual(store.record(forKey: key)?.movementFetchedAt, fullFetchedAt)

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        try assertJoinedState(in: reopened, key: key, seed: seed, seenAt: seenAt,
                              movement: entry.movement)
        let reopenedCenter = RefreshCenter(
            store: reopened, client: SudrfClient(),
            serviceBuilder: { _ in Issue406MovementSequence([entry.movement]) })
        let reopenedRefresh = await reopenedCenter.refresh(key: key)?.value
        XCTAssertEqual(reopenedRefresh?.outcome, .refreshed)
        try assertJoinedState(in: reopened, key: key, seed: seed, seenAt: seenAt,
                              movement: entry.movement)

        let router = try AppRouter(
            modelContainer: reopenedContainer, modelContainerIsPrepared: true)
        router.reload(today: today)
        XCTAssertEqual(router.cases.count, 1)
        XCTAssertEqual(router.cases.first?.stage, .done)
        XCTAssertEqual(router.cases.first?.statusText, joinedStatus)
    }

    private func assertJoinedState(in store: TrackedStore, key: String,
                                   seed: CaseEvent, seenAt: Date,
                                   movement: CaseMovement) throws {
        let record = try XCTUnwrap(store.record(forKey: key))
        let snapshot = try XCTUnwrap(record.snapshot)
        XCTAssertEqual(snapshot.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(snapshot.statusText, joinedStatus)
        XCTAssertFalse(snapshot.inForce)
        XCTAssertTrue(snapshot.deadlines.contains {
            $0.occurrenceKey == manualKey && $0.status == .confirmed
        })
        XCTAssertEqual(record.movement?.instances, movement.instances)
        XCTAssertEqual(record.eventJournal?.events, [seed])
        XCTAssertEqual(record.seenAt, seenAt)
        XCTAssertEqual(record.collectionNames, ["Регрессия #406"])
    }

    private func historicalJoinEvent(_ caseNumber: String) -> CaseEvent {
        CaseEvent.make(
            kind: .resultChanged, occurrence: ["issue-406-history", caseNumber],
            observedAt: Date(timeIntervalSinceReferenceDate: 1),
            evidence: .init(caseNumber: caseNumber, value: "Дело присоединено к другому делу"))
    }
}
