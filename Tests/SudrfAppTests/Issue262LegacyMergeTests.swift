import Foundation
import SwiftData
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue262LegacyMovementSequence: MovementProviding {
    private let values: [CaseMovement]
    private var index = 0

    init(_ values: [CaseMovement]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        defer { index += 1 }
        return values[min(index, values.count - 1)]
    }
}

@MainActor
final class Issue262LegacyMergeTests: XCTestCase {
    private let judicialUID = "11RS0001-01-2026-000262-11"
    private let host = "syktsud--komi.sudrf.ru"
    private var retainedCenters: [RefreshCenter] = []

    func testMergeKeepsConfirmedAndPendingFactsWhileLegacyCardSeedsSilentlyAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-262-legacy-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")

        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let rootContext = context(number: "2-262/2026", cardID: "legacy-root-card")
        let legacyContext = context(number: "2-263/2026", cardID: "legacy-cached-card")
        let legacyNativeID = try identity("legacy-cached-card").id
        let rootRecord = try store.upsert(
            context: rootContext, snapshot: nil, collections: ["Регрессия #262"])

        let rootBaseline = try movement(rootJudge: "Судья A0")
        let baselineResult = await center(store: store, movements: [rootBaseline])
            .refresh(key: rootRecord.key)?.value
        XCTAssertEqual(baselineResult?.outcome, .refreshed)

        let pendingRoot = try movement(rootJudge: "Судья A1", coverageKind: .partial)
        let partialResult = await center(store: store, movements: [pendingRoot])
            .refresh(key: rootRecord.key)?.value
        guard let partialResult, case .partial = partialResult.outcome else {
            return XCTFail("partial root refresh should leave A1 pending")
        }
        XCTAssertEqual(rootRecord.movement?.instances.first?.judge, "Судья A1")
        XCTAssertEqual(rootRecord.eventJournal?.semanticBaselines?.courts.values
            .flatMap(\.instances).compactMap(\.judge), ["Судья A0"])
        XCTAssertTrue(rootRecord.eventJournal?.events.isEmpty == true)

        var legacyCache = try movement(rootJudge: nil, legacyJudge: "Судья B0",
                                       includeCoverage: false)
        legacyCache.caseNumber = legacyContext.caseNumber
        let legacyRecord = try insertLegacyRecord(
            store: store, context: legacyContext,
            snapshot: MovementDerivation.snapshot(from: legacyCache, context: legacyContext),
            movement: legacyCache)
        XCTAssertNotEqual(rootRecord.key, legacyRecord.key)
        XCTAssertEqual(store.all().count, 2,
                       "the legacy cache must remain a separate record until the explicit merge")
        XCTAssertEqual(legacyRecord.context?.caseID, legacyContext.caseID)
        XCTAssertEqual(legacyRecord.movement?.caseNumber, legacyContext.caseNumber)
        XCTAssertNil(legacyRecord.eventJournal?.semanticBaselines,
                     "the duplicate is a legacy cache with no confirmed semantic baseline")

        _ = try TrackedCaseRepairCoordinator.atomicMerge(
            store: store, survivor: rootRecord, duplicates: [legacyRecord],
            canonicalContext: rootContext, canonicalCard: nil)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(rootRecord.movement?.instances.compactMap(\.judge).sorted(),
                       ["Судья A1", "Судья B0"])
        XCTAssertEqual(rootRecord.eventJournal?.semanticBaselines?.courts.values
            .flatMap(\.instances).compactMap(\.judge), ["Судья A0"])
        XCTAssertEqual(rootRecord.eventJournal?.semanticBaselines?.unprocessedCardIDs,
                       Set([legacyNativeID]))

        let reopened = try TrackedStore(container: SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL), prepared: true)
        let saved = try XCTUnwrap(reopened.record(forKey: rootRecord.key))
        XCTAssertEqual(saved.eventJournal?.semanticBaselines?.courts.values
            .flatMap(\.instances).compactMap(\.judge), ["Судья A0"])
        XCTAssertEqual(saved.eventJournal?.semanticBaselines?.unprocessedCardIDs,
                       Set([legacyNativeID]), "the legacy-card marker must survive disk reopen")
        XCTAssertTrue(saved.eventJournal?.events.isEmpty == true)
        XCTAssertEqual(saved.movement?.instances.compactMap(\.judge).sorted(),
                       ["Судья A1", "Судья B0"])

        let completeWithLegacyBaseline = try movement(rootJudge: "Судья A1",
                                                      legacyJudge: "Судья B0")
        let refreshCenter = center(store: reopened,
                                   movements: [completeWithLegacyBaseline,
                                               completeWithLegacyBaseline,
                                               try movement(rootJudge: "Судья A1",
                                                            legacyJudge: "Судья B1")])
        let firstConfirmation = await refreshCenter.refresh(key: saved.key)?.value
        XCTAssertEqual(firstConfirmation?.outcome, .refreshed)
        var events = try XCTUnwrap(reopened.record(forKey: saved.key)?.eventJournal?.events)
        XCTAssertEqual(events.map(\.kind), [.judgeChanged],
                       "A's pending change is emitted; B's legacy first confirmation stays quiet")
        XCTAssertEqual(events.first?.evidence.previousValue, "Судья A0")
        XCTAssertEqual(events.first?.evidence.value, "Судья A1")
        let seeded = try XCTUnwrap(reopened.record(forKey: saved.key)?.eventJournal?
            .semanticBaselines?.courts.values.first)
        XCTAssertEqual(seeded.cards.count, 2)
        XCTAssertEqual(Set(seeded.instances.compactMap(\.judge)), ["Судья A1", "Судья B0"])
        XCTAssertFalse(reopened.record(forKey: saved.key)?.eventJournal?
            .semanticBaselines?.unprocessedCardIDs?.contains(legacyNativeID) == true)

        let repeatedConfirmation = await refreshCenter.refresh(key: saved.key)?.value
        XCTAssertEqual(repeatedConfirmation?.outcome, .refreshed)
        XCTAssertEqual(reopened.record(forKey: saved.key)?.eventJournal?.events, events,
                       "repeating A1/B0 must not duplicate the pending A transition")

        let changedLegacy = await refreshCenter.refresh(key: saved.key)?.value
        XCTAssertEqual(changedLegacy?.outcome, .refreshed)
        events = try XCTUnwrap(reopened.record(forKey: saved.key)?.eventJournal?.events)
        let changes = events.filter { $0.kind == .judgeChanged }
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(Set(changes.compactMap(\.evidence.previousValue)), ["Судья A0", "Судья B0"])
        XCTAssertEqual(Set(changes.compactMap(\.evidence.value)), ["Судья A1", "Судья B1"])
        XCTAssertFalse(events.contains { $0.kind == .instanceDiscovered })
    }

    func testSnapshotOnlyLegacyMergeReseedsAmbiguousCourtWithoutHistoricalEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-262-snapshot-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")

        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let rootContext = context(number: "2-262/2026", cardID: "legacy-root-card")
        let rootRecord = try store.upsert(
            context: rootContext, snapshot: nil, collections: ["Регрессия #262"])

        let baselineA = try movement(rootJudge: "Судья A0")
        let baselineResult = await center(store: store, movements: [baselineA])
            .refresh(key: rootRecord.key)?.value
        XCTAssertEqual(baselineResult?.outcome, .refreshed)
        let changedA = try movement(rootJudge: "Судья A1")
        let changedResult = await center(store: store, movements: [changedA])
            .refresh(key: rootRecord.key)?.value
        XCTAssertEqual(changedResult?.outcome, .refreshed)
        let existingEvents = try XCTUnwrap(semanticJournalEvents(rootRecord.eventJournal))
        XCTAssertEqual(existingEvents.map(\.kind), [.judgeChanged])
        XCTAssertEqual(existingEvents.first?.evidence.previousValue, "Судья A0")
        XCTAssertEqual(existingEvents.first?.evidence.value, "Судья A1")

        var legacyContext = context(number: "2-263/2026", cardID: "snapshot-legacy-card")
        legacyContext.cardURLString = nil
        var oldMovement = try movement(rootJudge: nil, legacyJudge: "Судья B legacy",
                                       includeCoverage: false)
        oldMovement.caseNumber = legacyContext.caseNumber
        oldMovement.instances[0].caseNumber = legacyContext.caseNumber
        oldMovement.instances[0].sourceURL = nil
        oldMovement.instances[0].sessions = [CaseSession(
            date: "01.07.2019", event: "Судебное заседание", result: "Старый результат")]
        var oldSnapshot = MovementDerivation.snapshot(
            from: oldMovement, context: legacyContext)
        oldSnapshot.semanticProjectionVersion = nil
        oldSnapshot.instanceObservations = nil
        oldSnapshot.actObservations = nil
        oldSnapshot.complaintObservations = nil
        oldSnapshot.sessions = oldSnapshot.sessions.map { session in
            var legacySession = session
            legacySession.sourceCardID = nil
            return legacySession
        }
        oldSnapshot.actsFingerprint = ["legacy-act-fingerprint"]

        let legacyRecord = try insertLegacyRecord(
            store: store, context: legacyContext,
            snapshot: oldSnapshot, movement: nil)
        XCTAssertNil(legacyRecord.movement)
        XCTAssertNil(legacyRecord.snapshot?.semanticProjectionVersion)
        XCTAssertNil(legacyRecord.snapshot?.instanceObservations)
        XCTAssertNil(legacyRecord.snapshot?.actObservations)
        XCTAssertNil(legacyRecord.snapshot?.complaintObservations)
        XCTAssertEqual(legacyRecord.snapshot?.sessions.count, 1)
        XCTAssertNil(legacyRecord.snapshot?.sessions.first?.sourceCardID)
        XCTAssertEqual(legacyRecord.snapshot?.actsFingerprint, ["legacy-act-fingerprint"])
        XCTAssertEqual(store.all().count, 2)

        _ = try TrackedCaseRepairCoordinator.atomicMerge(
            store: store, survivor: rootRecord, duplicates: [legacyRecord],
            canonicalContext: rootContext, canonicalCard: nil)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(semanticJournalEvents(rootRecord.eventJournal), existingEvents)
        let mergedBaselines = try XCTUnwrap(rootRecord.eventJournal?.semanticBaselines)
        let rootIdentity = try contextIdentity(rootContext)
        let rootScope = rootIdentity.sourceFamily + "|" + rootIdentity.courtKey
        XCTAssertNil(mergedBaselines.courts[rootScope],
                     "snapshot-only legacy data makes this court ambiguous")
        XCTAssertTrue(mergedBaselines.conflictingCourts.contains(rootScope))

        let reopened = try TrackedStore(container: SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL), prepared: true)
        let saved = try XCTUnwrap(reopened.record(forKey: rootRecord.key))
        XCTAssertEqual(semanticJournalEvents(saved.eventJournal), existingEvents)

        let fresh = try movement(rootJudge: "Судья A1", legacyJudge: "Судья B legacy")
        let refreshed = await center(store: reopened, movements: [fresh])
            .refresh(key: saved.key)?.value
        XCTAssertEqual(refreshed?.outcome, .refreshed)
        XCTAssertEqual(semanticJournalEvents(reopened.record(forKey: saved.key)?.eventJournal), existingEvents,
                       "the first fresh observation seeds B without replaying legacy display facts")
        let seeded = try XCTUnwrap(reopened.record(forKey: saved.key)?.eventJournal?
            .semanticBaselines?.courts[rootScope])
        XCTAssertEqual(seeded.cards.count, 2)
        XCTAssertEqual(Set(seeded.instances.compactMap(\.judge)), ["Судья A1", "Судья B legacy"])
        XCTAssertFalse(reopened.record(forKey: saved.key)?.eventJournal?
            .semanticBaselines?.conflictingCourts.contains(rootScope) == true)
    }

    func testMovementLegacyCardWithoutURLUsesOriginalContextForExactMarker() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-262-no-url-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")

        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let rootContext = context(number: "2-262/2026", cardID: "legacy-root-card")
        let rootRecord = try store.upsert(
            context: rootContext, snapshot: nil, collections: [])
        let baseline = try movement(rootJudge: "Судья A0")
        let baselineResult = await center(store: store, movements: [baseline])
            .refresh(key: rootRecord.key)?.value
        XCTAssertEqual(baselineResult?.outcome, .refreshed)

        var legacyContext = context(number: rootContext.caseNumber,
                                    cardID: "no-url-legacy-card")
        legacyContext.cardURLString = nil
        let legacyNative = try contextIdentity(legacyContext)
        let legacyMovement = CaseMovement(
            uid: judicialUID, caseNumber: rootContext.caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .first, court: rootContext.courtTitle,
                caseNumber: rootContext.caseNumber, judge: "Судья B0",
                domain: host, foundByUID: true, result: "Иск удовлетворён",
                sessions: [], sourceURL: nil)],
            complaints: [:], acts: [])
        let legacyRecord = try insertLegacyRecord(
            store: store, context: legacyContext,
            snapshot: nil, movement: legacyMovement)
        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(legacyRecord.context?.caseID, legacyContext.caseID)
        XCTAssertEqual(legacyRecord.movement?.caseNumber, rootContext.caseNumber)

        _ = try TrackedCaseRepairCoordinator.atomicMerge(
            store: store, survivor: rootRecord, duplicates: [legacyRecord],
            canonicalContext: rootContext, canonicalCard: nil)
        let baselines = try XCTUnwrap(rootRecord.eventJournal?.semanticBaselines)
        let rootNative = try contextIdentity(rootContext)
        let rootScope = rootNative.sourceFamily + "|" + rootNative.courtKey
        XCTAssertEqual(baselines.unprocessedCardIDs, Set([legacyNative.id]))
        XCTAssertFalse(baselines.unprocessedCardIDs?.contains(rootNative.id) == true)
        XCTAssertEqual(baselines.courts[rootScope]?.instances.first?.judge, "Судья A0")
        XCTAssertFalse(baselines.conflictingCourts.contains(rootScope))
    }

    private func context(number: String, cardID: String) -> MovementContext {
        let url = cardURL(cardID)
        var value = MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Республика Коми",
            searchDomain: host,
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001",
            cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number,
            caseID: cardID,
            caseUID: "url-\(cardID)",
            judicialUID: judicialUID)
        value.cardURLString = url.absoluteString
        return value
    }

    private func cardURL(_ cardID: String) -> URL {
        URL(string: "https://\(host)/modules.php?name=sud_delo&name_op=case"
            + "&case_id=\(cardID)&case_uid=url-\(cardID)"
            + "&delo_id=1540005&new=0&srv_num=1")!
    }

    private func identity(_ cardID: String) throws -> SourceNativeCardIdentity {
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        return try XCTUnwrap(SourceNativeCardLocator.sudrf(
            url: cardURL(cardID), cartoteka: cart)).identity
    }

    private func contextIdentity(_ context: MovementContext) throws -> SourceNativeCardIdentity {
        try XCTUnwrap(SourceNativeCardLocator.sudrf(
            court: context.searchCourt,
            cartoteka: try XCTUnwrap(context.cartoteka),
            caseID: try XCTUnwrap(context.caseID))).identity
    }

    private func insertLegacyRecord(
        store: TrackedStore,
        context: MovementContext,
        snapshot: CaseSnapshot?,
        movement: CaseMovement?
    ) throws -> TrackedCaseRecord {
        let record = TrackedCaseRecord(
            key: "legacy-fixture-\(UUID().uuidString)", collections: [],
            caseNumber: context.caseNumber, courtTitle: context.courtTitle,
            displayDomain: context.displayDomain,
            contextData: try JSONEncoder().encode(context), snapshotData: nil)
        record.judicialUID = context.judicialUID.map(TrackedStore.normalizedUID)
        record.snapshot = snapshot
        record.movement = movement
        if movement != nil { record.movementFetchedAt = .now }
        store.container.mainContext.insert(record)
        try store.save()
        return record
    }

    private func movement(rootJudge: String?, legacyJudge: String? = nil,
                          coverageKind: SourceOutcomeKind = .usableSnapshot,
                          includeCoverage: Bool = true) throws -> CaseMovement {
        let rootContext = context(number: "2-262/2026", cardID: "legacy-root-card")
        let rootURL = cardURL("legacy-root-card")
        let legacyURL = cardURL("legacy-cached-card")
        var instances: [CaseInstance] = []
        if let rootJudge {
            instances.append(CaseInstance(
                level: .first, court: rootContext.courtTitle,
                caseNumber: rootContext.caseNumber, judge: rootJudge,
                domain: host, foundByUID: false, result: "Иск удовлетворён",
                sessions: [], sourceURL: rootURL))
        }
        if let legacyJudge {
            instances.append(CaseInstance(
                level: .first, court: rootContext.courtTitle,
                caseNumber: "2-263/2026", judge: legacyJudge,
                domain: host, foundByUID: true, result: "Иск удовлетворён",
                sessions: [], sourceURL: legacyURL))
        }
        let loaded = try [rootJudge == nil ? nil : identity("legacy-root-card"),
                          legacyJudge == nil ? nil : identity("legacy-cached-card")]
            .compactMap { $0 }
        let coverage = MovementCourtCoverage(
            sourceFamily: "sudrf", courtKey: loaded.first?.courtKey ?? host, kind: coverageKind,
            loadedCardIdentities: loaded)
        return CaseMovement(
            uid: judicialUID, caseNumber: rootContext.caseNumber, inForce: false,
            instances: instances, complaints: [:], acts: [],
            incompleteHigherCourtDomains: coverageKind == .partial ? [host] : nil,
            sourceRefreshCoverage: includeCoverage && !loaded.isEmpty ? [coverage] : nil)
    }

    private func center(store: TrackedStore, movements: [CaseMovement]) -> RefreshCenter {
        let sequence = Issue262LegacyMovementSequence(movements)
        let center = RefreshCenter(store: store, client: SudrfClient(), serviceBuilder: { _ in
            sequence
        })
        retainedCenters.append(center)
        return center
    }
}
