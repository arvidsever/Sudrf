import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class TrackedStoreIdentityTests: XCTestCase {
    private let oldUID = "11RS0001-01-2025-011255-03"
    private let newUID = "11RS0001-01-2026-011256-04"

    private func context(number: String, cardID: String, caseUID: String = "link-1",
                         judicialUID: String? = nil, domain: String = "court--komi.sudrf.ru",
                         courtCode: String = "11RS0001", cartoteka: String = "g1")
        -> MovementContext {
        var value = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: domain, displayDomain: SudrfHost.alternate(domain) ?? domain,
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: courtCode, cartotekaId: cartoteka,
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number, caseID: cardID, caseUID: caseUID)
        value.judicialUID = judicialUID
        return value
    }

    private func movement(for context: MovementContext, actID: String = "act-1") -> CaseMovement {
        let instance = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.searchDomain, foundByUID: false,
            result: "Решение", sessions: [], actID: actID)
        let act = CaseAct(id: actID, title: "Решение", date: "01.08.2026",
                          courtShort: context.courtTitle, instanceLevel: .first)
        return CaseMovement(uid: context.judicialUID ?? "", caseNumber: context.caseNumber,
                            inForce: false, instances: [instance], complaints: [:], acts: [act],
                            actBodies: [actID: "Текст акта"])
    }

    func testSameSourceCardRenumberingKeepsPersistentKeyActsCollectionsAndDeepLinks() async throws {
        let store = TrackedStore(inMemory: true)
        let original = context(number: "8Г-123/2026", cardID: "native-card", judicialUID: oldUID)
        let first = store.reconcileAndUpsert(
            context: original, snapshot: nil, movement: movement(for: original),
            collections: ["Подборка"])
        let persistentKey = first.key
        let logicalCaseID = try XCTUnwrap(first.logicalCaseID)
        let oldActID = try XCTUnwrap(store.courtActID(caseKey: persistentKey, sourceActID: "act-1"))

        var renumbered = original
        renumbered.caseNumber = "88-123/2026"
        let refreshed = store.reconcileAndUpsert(
            context: renumbered, snapshot: nil, movement: movement(for: renumbered),
            collections: ["Подборка"])

        XCTAssertTrue(refreshed === first)
        XCTAssertEqual(refreshed.key, persistentKey)
        XCTAssertEqual(refreshed.logicalCaseID, logicalCaseID)
        XCTAssertEqual(refreshed.caseNumber, renumbered.caseNumber)
        XCTAssertEqual(refreshed.collectionNames, ["Подборка"])
        XCTAssertTrue(refreshed.legacyKeyAliases.contains(renumbered.key))
        XCTAssertTrue(store.record(forLocator: original.key) === refreshed)
        XCTAssertTrue(store.record(forLocator: renumbered.key) === refreshed)
        XCTAssertEqual(store.courtActID(caseKey: persistentKey, sourceActID: "act-1"), oldActID)
        XCTAssertEqual(store.route(for: .caseRecord(key: original.key)),
                       .caseRecord(key: persistentKey, staleAct: false))
        XCTAssertEqual(store.route(for: .courtAct(caseKey: original.key, sourceActID: "act-1")),
                       .courtAct(caseKey: persistentKey, sourceActID: "act-1"))

        let state = TrackedCaseIdentity.state(for: refreshed)
        XCTAssertEqual(state.cards.count, 1)
        XCTAssertEqual(Set(state.numberHistory.map(\.rawValue)),
                       Set([original.caseNumber, renumbered.caseNumber]))
        let catalog = CaseCatalog(container: store.container)
        let catalogCase = try await catalog.caseSnapshot(id: persistentKey)
        XCTAssertEqual(catalogCase?.id, persistentKey,
                       "Spotlight continues to index the immutable persistent locator")
    }

    func testMatchingValidUIDAcrossDifferentCardsCreatesOneLogicalDossierAndUsesUIDHistory() throws {
        let store = TrackedStore(inMemory: true)
        let first = context(number: "2-100/2026", cardID: "first-card", judicialUID: oldUID)
        let appeal = context(number: "33-200/2026", cardID: "appeal-card", judicialUID: oldUID,
                             domain: "vs--komi.sudrf.ru", courtCode: "11VS0001", cartoteka: "g2")

        let trackedFirst = store.reconcileAndUpsert(context: first, snapshot: nil, collections: ["A"])
        let trackedAppeal = store.reconcileAndUpsert(context: appeal, snapshot: nil, collections: ["B"])

        XCTAssertTrue(trackedFirst === trackedAppeal)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.records(forJudicialUID: "11 rs 0001-01-2025-011255-03").count, 1)
        XCTAssertEqual(TrackedCaseIdentity.state(for: trackedFirst).cards.count, 2)
        XCTAssertEqual(trackedFirst.collectionNames, ["A", "B"])
        XCTAssertTrue(store.record(forLocator: appeal.key) === trackedFirst)
    }

    func testOfficialPredecessorCanAddSequentialUIDWithoutChangingDossier() throws {
        let store = TrackedStore(inMemory: true)
        let previous = context(number: "2-100/2025", cardID: "previous-card", judicialUID: oldUID)
        let existing = store.reconcileAndUpsert(context: previous, snapshot: nil, collections: [])
        let previousObservation = try XCTUnwrap(TrackedCaseIdentity.observation(context: previous))

        let replacement = context(number: "2-101/2026", cardID: "replacement-card", judicialUID: newUID)
        let base = try XCTUnwrap(TrackedCaseIdentity.observation(context: replacement))
        let relation = OfficialCardRelation(
            kind: .predecessor, relatedCard: previousObservation.cardIdentity,
            provenance: base.provenance)
        let replacementObservation = SourceCardObservation(
            cardIdentity: base.cardIdentity, caseUID: base.caseUID,
            caseNumber: base.caseNumber, judicialUID: base.judicialUID,
            officialRelations: [relation], outcome: .usableSnapshot,
            provenance: base.provenance)

        let linked = store.reconcileAndUpsert(
            context: replacement, snapshot: nil, collections: [],
            identityObservation: replacementObservation)

        XCTAssertTrue(linked === existing)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(Set(TrackedCaseIdentity.state(for: linked).judicialUIDs),
                       Set([TrackedStore.normalizedUID(oldUID), TrackedStore.normalizedUID(newUID)]))
    }

    func testPartialUIDAndCaseUIDNeverLinkDistinctCards() throws {
        let store = TrackedStore(inMemory: true)
        let first = context(number: "2-100/2026", cardID: "first-card", caseUID: "same-link",
                            judicialUID: "11RS0001-01")
        let second = context(number: "2-101/2026", cardID: "second-card", caseUID: "same-link",
                             judicialUID: "11RS0001-01")

        _ = store.reconcileAndUpsert(context: first, snapshot: nil, collections: [])
        _ = store.reconcileAndUpsert(context: second, snapshot: nil, collections: [])

        XCTAssertEqual(store.all().count, 2)
        XCTAssertTrue(store.records(forJudicialUID: "11RS0001-01").isEmpty)
    }

    func testRepeatedReconciliationIsIdempotentAndDoesNotAdvanceRefreshTime() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-100/2026", cardID: "same-card", judicialUID: oldUID)
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let attempt = SourceAttempt(
            kind: .usableSnapshot,
            provenance: SourceProvenance(operation: .movement, sourceFamily: "sudrf",
                                         host: value.searchDomain, observedAt: observedAt))
        let observation = try XCTUnwrap(TrackedCaseIdentity.observation(
            context: value, attempt: attempt, outcome: .usableSnapshot))

        let first = store.reconcileAndUpsert(
            context: value, snapshot: nil, movement: movement(for: value), collections: [],
            identityObservation: observation, movementFetchedAt: observedAt)
        let initialState = try JSONDecoder().decode(
            LogicalCaseState.self, from: XCTUnwrap(first.identityStateData))
        let initialRefresh = first.movementFetchedAt
        store.failNextSaveForTesting = true
        XCTAssertEqual(store.reconcileStoredIdentity(), IdentityReconciliationSummary())
        XCTAssertTrue(store.failNextSaveForTesting,
                      "an already canonical graph must not invoke saveContext")
        XCTAssertEqual(store.reconcileStoredIdentity(), IdentityReconciliationSummary())
        XCTAssertTrue(store.failNextSaveForTesting,
                      "reconciliation must remain idempotent on the next launch")

        let persisted = try XCTUnwrap(store.record(forKey: first.key))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(persisted.movementFetchedAt, initialRefresh)
        XCTAssertEqual(try JSONDecoder().decode(
            LogicalCaseState.self, from: XCTUnwrap(persisted.identityStateData)), initialState)
    }

    func testCanonicalReconciliationSkipsAllRecordsWithoutSaving() throws {
        let store = TrackedStore(inMemory: true)
        for index in 0..<215 {
            let uid = "11RS0001-01-2026-\(String(format: "%06d", index + 1))-10"
            let value = context(number: "2-\(index + 1)/2026", cardID: "card-\(index)",
                                judicialUID: uid)
            _ = store.reconcileAndUpsert(context: value, snapshot: nil, collections: [])
        }

        store.failNextSaveForTesting = true
        let summary = store.reconcileStoredIdentity()

        XCTAssertEqual(summary, IdentityReconciliationSummary())
        XCTAssertTrue(store.failNextSaveForTesting,
                      "a canonical 215-record store must not start a save transaction")
        XCTAssertEqual(store.all().count, 215)
    }

    func testRepeatedPreparationAndProjectionAreNoOps() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-100/2026", cardID: "same-card", judicialUID: oldUID)
        let record = store.reconcileAndUpsert(
            context: value, snapshot: nil, movement: movement(for: value), collections: [])

        XCTAssertFalse(store.container.mainContext.hasChanges)
        XCTAssertFalse(try TrackedStorePreparation.prepare(
            context: store.container.mainContext))
        XCTAssertFalse(store.container.mainContext.hasChanges)

        store.failNextSaveForTesting = true
        XCTAssertTrue(store.save(projection: .cases([record.key])))
        XCTAssertTrue(store.failNextSaveForTesting,
                      "an unchanged court-act projection must not invoke saveContext")
    }

    func testAtomicMergeSaveFailureRollsBackWithoutSecondUpsertSave() throws {
        let store = TrackedStore(inMemory: true)
        let first = context(number: "2-100/2026", cardID: "first-card", judicialUID: oldUID)
        let appeal = context(number: "33-200/2026", cardID: "appeal-card", judicialUID: oldUID,
                             domain: "vs--komi.sudrf.ru", courtCode: "11VS0001", cartoteka: "g2")
        let firstObservation = try XCTUnwrap(TrackedCaseIdentity.observation(context: first))
        let appealObservation = try XCTUnwrap(TrackedCaseIdentity.observation(context: appeal))
        let firstState = LogicalCaseState(observation: firstObservation)
        let appealState = LogicalCaseState(observation: appealObservation)
        let firstRecord = TrackedCaseRecord(
            key: first.key, collections: ["Existing"], caseNumber: first.caseNumber,
            courtTitle: first.courtTitle, displayDomain: first.displayDomain,
            contextData: try JSONEncoder().encode(first), snapshotData: nil)
        firstRecord.logicalCaseID = firstState.logicalCaseID
        firstRecord.identityStateData = try JSONEncoder().encode(firstState)
        firstRecord.judicialUID = TrackedStore.normalizedUID(oldUID)
        let appealRecord = TrackedCaseRecord(
            key: appeal.key, collections: ["Appeal"], caseNumber: appeal.caseNumber,
            courtTitle: appeal.courtTitle, displayDomain: appeal.displayDomain,
            contextData: try JSONEncoder().encode(appeal), snapshotData: nil)
        appealRecord.logicalCaseID = appealState.logicalCaseID
        appealRecord.identityStateData = try JSONEncoder().encode(appealState)
        appealRecord.judicialUID = TrackedStore.normalizedUID(oldUID)
        store.container.mainContext.insert(firstRecord)
        store.container.mainContext.insert(appealRecord)
        try store.container.mainContext.save()

        store.failNextSaveForTesting = true
        let returned = store.reconcileAndUpsert(
            context: appeal, snapshot: nil, collections: ["Must not persist"],
            identityObservation: appealObservation)

        XCTAssertEqual(returned.key, first.key)
        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(store.record(forKey: first.key)?.collectionNames, ["Existing"])
        XCTAssertEqual(store.record(forKey: appeal.key)?.collectionNames, ["Appeal"])
        XCTAssertEqual(TrackedCaseIdentity.state(for: try XCTUnwrap(store.record(forKey: first.key))).cards.count,
                       1)
    }
}
