import XCTest
import SudrfKit
import SwiftData
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

    private func movement(for context: MovementContext, actID: String = "act-1",
                          sourceURL: URL? = nil,
                          previousRegistration: PreviousRegistrationReference? = nil)
        -> CaseMovement {
        let instance = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.searchDomain, foundByUID: false,
            result: "Решение", sessions: [], actID: actID,
            sourceURL: sourceURL, previousRegistration: previousRegistration)
        let act = CaseAct(id: actID, title: "Решение", date: "01.08.2026",
                          courtShort: context.courtTitle, instanceLevel: .first)
        return CaseMovement(uid: context.judicialUID ?? "", caseNumber: context.caseNumber,
                            inForce: false, instances: [instance], complaints: [:], acts: [act],
                            actBodies: [actID: "Текст акта"])
    }

    private func sourceURL(for context: MovementContext) -> URL {
        let cartoteka = CartotekaRegistry.find(
            level: context.cartotekaLevel, id: context.cartotekaId)!
        var components = URLComponents()
        components.scheme = "https"
        components.host = context.searchDomain
        components.path = "/modules.php"
        components.queryItems = [
            URLQueryItem(name: "name", value: "sud_delo"),
            URLQueryItem(name: "name_op", value: "case"),
            URLQueryItem(name: "vnkod", value: context.courtCode),
            URLQueryItem(name: "srv_num", value: "2"),
            URLQueryItem(name: "delo_id", value: cartoteka.deloID),
            URLQueryItem(name: "new", value: cartoteka.new),
            URLQueryItem(name: "case_id", value: context.caseID),
            URLQueryItem(name: "case_uid", value: context.caseUID)
        ]
        return components.url!
    }

    func testSameSourceCardRenumberingKeepsPersistentKeyActsCollectionsAndDeepLinks() async throws {
        let store = TrackedStore(inMemory: true)
        let original = context(number: "8Г-123/2026", cardID: "native-card", judicialUID: oldUID)
        let first = try store.reconcileAndUpsert(
            context: original, snapshot: nil, movement: movement(for: original),
            collections: ["Подборка"])
        let persistentKey = first.key
        let logicalCaseID = try XCTUnwrap(first.logicalCaseID)
        let oldActID = try XCTUnwrap(store.courtActID(caseKey: persistentKey, sourceActID: "act-1"))

        var renumbered = original
        renumbered.caseNumber = "88-123/2026"
        let refreshed = try store.reconcileAndUpsert(
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

        let trackedFirst = try store.reconcileAndUpsert(context: first, snapshot: nil, collections: ["A"])
        let trackedAppeal = try store.reconcileAndUpsert(context: appeal, snapshot: nil, collections: ["B"])

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
        let existing = try store.reconcileAndUpsert(context: previous, snapshot: nil, collections: [])
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

        let linked = try store.reconcileAndUpsert(
            context: replacement, snapshot: nil, collections: [],
            identityObservation: replacementObservation)

        XCTAssertTrue(linked === existing)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(Set(TrackedCaseIdentity.state(for: linked).judicialUIDs),
                       Set([TrackedStore.normalizedUID(oldUID), TrackedStore.normalizedUID(newUID)]))
    }

    func testMovementPredecessorLinksSequentialUIDsRegardlessOfTrackingOrder() throws {
        let previous = context(number: "2-100/2025", cardID: "previous-card",
                               caseUID: "previous-link", judicialUID: oldUID)
        let replacement = context(number: "2-101/2026", cardID: "replacement-card",
                                  caseUID: "replacement-link", judicialUID: newUID)
        let previousURL = sourceURL(for: previous)
        let replacementURL = sourceURL(for: replacement)
        let replacementMovement = movement(
            for: replacement, sourceURL: replacementURL,
            previousRegistration: PreviousRegistrationReference(
                caseNumber: previous.caseNumber, url: previousURL))
        var validatedReplacementMovement = replacementMovement
        validatedReplacementMovement.instances.append(CaseInstance(
            level: .first, court: previous.courtTitle, caseNumber: previous.caseNumber,
            judge: nil, domain: previous.searchDomain, foundByUID: true,
            result: "Решение", sessions: [], sourceURL: previousURL))
        let attempt = SourceAttempt(
            kind: .usableSnapshot,
            provenance: SourceProvenance(
                operation: .movement, sourceFamily: "sudrf",
                host: replacement.searchDomain,
                observedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let replacementObservation = try XCTUnwrap(TrackedCaseIdentity.observation(
            context: replacement, movement: validatedReplacementMovement, attempt: attempt))
        let previousObservation = try XCTUnwrap(TrackedCaseIdentity.observation(context: previous))
        let relation = try XCTUnwrap(replacementObservation.officialRelations.first)

        XCTAssertEqual(relation.kind, .predecessor)
        XCTAssertEqual(relation.relatedCard, previousObservation.cardIdentity)
        XCTAssertEqual(relation.provenance, attempt.provenance)

        for previousFirst in [true, false] {
            let store = TrackedStore(inMemory: true)
            if previousFirst {
                _ = try store.reconcileAndUpsert(
                    context: previous, snapshot: nil,
                    movement: movement(for: previous, sourceURL: previousURL), collections: [])
                _ = try store.reconcileAndUpsert(
                    context: replacement, snapshot: nil, movement: replacementMovement,
                    collections: [], identityObservation: replacementObservation)
            } else {
                _ = try store.reconcileAndUpsert(
                    context: replacement, snapshot: nil, movement: replacementMovement,
                    collections: [], identityObservation: replacementObservation)
                _ = try store.reconcileAndUpsert(
                    context: previous, snapshot: nil,
                    movement: movement(for: previous, sourceURL: previousURL), collections: [])
            }

            let oldRecord = try XCTUnwrap(store.record(forLocator: previous.key))
            let newRecord = try XCTUnwrap(store.record(forLocator: replacement.key))
            XCTAssertTrue(oldRecord === newRecord, "tracking order: \(previousFirst)")
            XCTAssertEqual(store.all().count, 1, "tracking order: \(previousFirst)")
            XCTAssertEqual(TrackedCaseIdentity.state(for: oldRecord).cards.count, 2)
            XCTAssertEqual(Set(TrackedCaseIdentity.state(for: oldRecord).judicialUIDs),
                           Set([TrackedStore.normalizedUID(oldUID),
                                TrackedStore.normalizedUID(newUID)]))
        }
    }

    func testMovementPredecessorMustBelongToRefreshedSourceCard() throws {
        let previous = context(number: "2-100/2025", cardID: "previous-card",
                               caseUID: "previous-link", judicialUID: oldUID)
        let replacement = context(number: "2-101/2026", cardID: "replacement-card",
                                  caseUID: "replacement-link", judicialUID: newUID)
        let unrelated = context(number: "2-102/2026", cardID: "unrelated-card",
                                caseUID: "unrelated-link", judicialUID: newUID)
        var currentMovement = movement(for: replacement, sourceURL: sourceURL(for: replacement))
        currentMovement.instances.append(CaseInstance(
            level: .first, court: unrelated.courtTitle, caseNumber: unrelated.caseNumber,
            judge: nil, domain: unrelated.searchDomain, foundByUID: true,
            result: nil, sessions: [], sourceURL: sourceURL(for: unrelated),
            previousRegistration: PreviousRegistrationReference(
                caseNumber: previous.caseNumber, url: sourceURL(for: previous))))

        let observation = try XCTUnwrap(TrackedCaseIdentity.observation(
            context: replacement, movement: currentMovement))

        XCTAssertTrue(observation.officialRelations.isEmpty)
    }

    func testUnloadedOrMismatchedPredecessorNeverCreatesIdentityRelation() throws {
        let previous = context(number: "2-100/2025", cardID: "previous-card",
                               caseUID: "previous-link", judicialUID: oldUID)
        let replacement = context(number: "2-101/2026", cardID: "replacement-card",
                                  caseUID: "replacement-link", judicialUID: newUID)
        let reference = PreviousRegistrationReference(
            caseNumber: previous.caseNumber, url: sourceURL(for: previous))
        let unvalidated = movement(
            for: replacement, sourceURL: sourceURL(for: replacement),
            previousRegistration: reference)
        XCTAssertTrue(try XCTUnwrap(TrackedCaseIdentity.observation(
            context: replacement, movement: unvalidated)).officialRelations.isEmpty)

        var mismatched = unvalidated
        mismatched.instances.append(CaseInstance(
            level: .first, court: previous.courtTitle, caseNumber: "2-999/2025",
            judge: nil, domain: previous.searchDomain, foundByUID: true,
            result: nil, sessions: [], sourceURL: sourceURL(for: previous)))
        XCTAssertTrue(try XCTUnwrap(TrackedCaseIdentity.observation(
            context: replacement, movement: mismatched)).officialRelations.isEmpty)
    }

    func testStartupReconciliationUsesValidatedPredecessorFromStoredMovement() throws {
        let store = TrackedStore(inMemory: true)
        let previous = context(number: "2-100/2025", cardID: "previous-card",
                               caseUID: "previous-link", judicialUID: oldUID)
        let replacement = context(number: "2-101/2026", cardID: "replacement-card",
                                  caseUID: "replacement-link", judicialUID: newUID)
        let previousURL = sourceURL(for: previous)
        let replacementURL = sourceURL(for: replacement)
        _ = try store.reconcileAndUpsert(
            context: previous, snapshot: nil,
            movement: movement(for: previous, sourceURL: previousURL), collections: [])
        let replacementRecord = try store.reconcileAndUpsert(
            context: replacement, snapshot: nil,
            movement: movement(for: replacement, sourceURL: replacementURL), collections: [])
        XCTAssertEqual(store.all().count, 2)

        var linkedMovement = movement(
            for: replacement, sourceURL: replacementURL,
            previousRegistration: PreviousRegistrationReference(
                caseNumber: previous.caseNumber, url: previousURL))
        linkedMovement.instances.append(CaseInstance(
            level: .first, court: previous.courtTitle, caseNumber: previous.caseNumber,
            judge: nil, domain: previous.searchDomain, foundByUID: true,
            result: "Решение", sessions: [], sourceURL: previousURL))
        replacementRecord.movement = linkedMovement

        let summary = try store.reconcileStoredIdentity()

        XCTAssertEqual(summary.merged, 1)
        XCTAssertEqual(store.all().count, 1)
    }

    func testPartialUIDAndCaseUIDNeverLinkDistinctCards() throws {
        let store = TrackedStore(inMemory: true)
        let first = context(number: "2-100/2026", cardID: "first-card", caseUID: "same-link",
                            judicialUID: "11RS0001-01")
        let second = context(number: "2-101/2026", cardID: "second-card", caseUID: "same-link",
                             judicialUID: "11RS0001-01")

        _ = try store.reconcileAndUpsert(context: first, snapshot: nil, collections: [])
        _ = try store.reconcileAndUpsert(context: second, snapshot: nil, collections: [])

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

        let first = try store.reconcileAndUpsert(
            context: value, snapshot: nil, movement: movement(for: value), collections: [],
            identityObservation: observation, movementFetchedAt: observedAt)
        let initialState = try JSONDecoder().decode(
            LogicalCaseState.self, from: XCTUnwrap(first.identityStateData))
        let initialRefresh = first.movementFetchedAt
        store.failNextSaveForTesting = true
        XCTAssertEqual(try store.reconcileStoredIdentity(), IdentityReconciliationSummary())
        XCTAssertTrue(store.failNextSaveForTesting,
                      "an already canonical graph must not invoke saveContext")
        XCTAssertEqual(try store.reconcileStoredIdentity(), IdentityReconciliationSummary())
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
            _ = try store.reconcileAndUpsert(context: value, snapshot: nil, collections: [])
        }

        store.failNextSaveForTesting = true
        let summary = try store.reconcileStoredIdentity()

        XCTAssertEqual(summary, IdentityReconciliationSummary())
        XCTAssertTrue(store.failNextSaveForTesting,
                      "a canonical 215-record store must not start a save transaction")
        XCTAssertEqual(store.all().count, 215)
    }

    func testRepeatedPreparationAndProjectionAreNoOps() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-100/2026", cardID: "same-card", judicialUID: oldUID)
        let record = try store.reconcileAndUpsert(
            context: value, snapshot: nil, movement: movement(for: value), collections: [])

        XCTAssertFalse(store.container.mainContext.hasChanges)
        XCTAssertFalse(try TrackedStorePreparation.prepare(
            context: store.container.mainContext))
        XCTAssertFalse(store.container.mainContext.hasChanges)

        store.failNextSaveForTesting = true
        try store.save(projection: .cases([record.key]))
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
        XCTAssertThrowsError(try store.reconcileAndUpsert(
            context: appeal, snapshot: nil, collections: ["Must not persist"],
            identityObservation: appealObservation
        )) { error in
            guard case .contextSave = error as? TrackedStoreCommitError else {
                return XCTFail("Expected context-save failure, got \(error)")
            }
        }

        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(store.record(forKey: first.key)?.collectionNames, ["Existing"])
        XCTAssertEqual(store.record(forKey: appeal.key)?.collectionNames, ["Appeal"])
        XCTAssertEqual(TrackedCaseIdentity.state(for: try XCTUnwrap(store.record(forKey: first.key))).cards.count,
                       1)
    }

    func testProjectionSynchronizationFailureRollsBackTrackedChanges() throws {
        struct ProjectionFailure: LocalizedError {
            var errorDescription: String? { "forced projection failure" }
        }

        var failNextProjection = false
        let store = TrackedStore(inMemory: true) { context, scope in
            if failNextProjection { throw ProjectionFailure() }
            try CourtActProjectionSynchronizer.synchronize(context: context, scope: scope)
        }
        let original = context(number: "2-100/2026", cardID: "source-card", judicialUID: oldUID)
        let tracked = try store.reconcileAndUpsert(
            context: original, snapshot: nil, movement: movement(for: original),
            collections: ["Existing"])
        let originalActs = tracked.movement?.acts

        var updated = original
        updated.caseNumber = "2-101/2026"
        failNextProjection = true
        XCTAssertThrowsError(try store.reconcileAndUpsert(
            context: updated, snapshot: nil, movement: movement(for: updated, actID: "act-2"),
            collections: ["Must not persist"]
        )) { error in
            guard case .projectionSynchronization = error as? TrackedStoreCommitError else {
                return XCTFail("Expected projection failure, got \(error)")
            }
        }

        let persisted = try XCTUnwrap(store.record(forKey: tracked.key))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(persisted.caseNumber, original.caseNumber)
        XCTAssertEqual(persisted.collectionNames, ["Existing"])
        XCTAssertEqual(persisted.movement?.acts, originalActs)
    }

    func testStartupIdentityReconciliationPropagatesCommitFailureWithoutMerging() throws {
        struct ProjectionFailure: LocalizedError {
            var errorDescription: String? { "forced startup projection failure" }
        }

        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let first = context(number: "2-100/2026", cardID: "first-card", judicialUID: oldUID)
        let appeal = context(
            number: "33-200/2026", cardID: "appeal-card", judicialUID: oldUID,
            domain: "vs--komi.sudrf.ru", courtCode: "11VS0001", cartoteka: "g2")
        func legacyRecord(_ value: MovementContext, collections: [String]) throws -> TrackedCaseRecord {
            TrackedCaseRecord(
                key: value.key, collections: collections, caseNumber: value.caseNumber,
                courtTitle: value.courtTitle, displayDomain: value.displayDomain,
                contextData: try JSONEncoder().encode(value), snapshotData: nil)
        }
        let firstRecord = try legacyRecord(first, collections: ["First"])
        let appealRecord = try legacyRecord(appeal, collections: ["Appeal"])
        container.mainContext.insert(firstRecord)
        container.mainContext.insert(appealRecord)
        try container.mainContext.save()

        XCTAssertThrowsError(try TrackedStore(
            container: container, prepared: true,
            projectionSynchronizer: { _, _ in throw ProjectionFailure() }
        )) { error in
            guard case .projectionSynchronization = error as? TrackedStoreCommitError else {
                return XCTFail("Expected projection failure, got \(error)")
            }
        }

        let records = try container.mainContext.fetch(FetchDescriptor<TrackedCaseRecord>())
        XCTAssertEqual(Set(records.map(\.key)), Set([first.key, appeal.key]))
        XCTAssertEqual(records.first { $0.key == first.key }?.collectionNames, ["First"])
        XCTAssertEqual(records.first { $0.key == appeal.key }?.collectionNames, ["Appeal"])
    }
}
