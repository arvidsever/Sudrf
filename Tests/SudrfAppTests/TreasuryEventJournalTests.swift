// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import XCTest
import SwiftData
import CaptchaSolver
@testable import SudrfKit
@testable import SudrfApp

@MainActor
final class TreasuryEventJournalTests: XCTestCase {
    private let observed = Date(timeIntervalSince1970: 1_800_000_000)

    private func rss(_ guid: String?, text: String = "Документ принят",
                     date: Date? = nil, order: Int = 0) -> EnforcementEvent {
        EnforcementEvent(guid: guid, dateRaw: "01.10.2026", date: date,
                         text: text, sourceOrder: order)
    }

    private func source(_ events: [EnforcementEvent]) -> EnforcementRecord {
        EnforcementRecord(courtDocumentID: "writ-454", source: .treasury,
                          sourceRecordID: "synthetic-treasury-454", status: "Исполняется",
                          events: events, lastAttemptAt: observed, lastSuccessAt: observed)
    }

    private func journal(_ items: [EnforcementEvent], caseID: UUID) throws -> CaseEventJournal {
        var journal = CaseEventJournal()
        try journal.append(TreasuryEventJournal.additions(records: [source(items)],
            logicalCaseID: caseID, journal: journal))
        return journal
    }

    func testPublishedGUIDScopesIdentityToLogicalCaseAndIgnoresPresentationChanges() throws {
        let caseID = UUID()
        let original = try journal([rss("guid-1", date: observed)], caseID: caseID)
        let event = try XCTUnwrap(original.events.first)
        XCTAssertEqual(event.kind, .treasuryRSSPublished)
        XCTAssertEqual(event.evidence.rssGUID, "guid-1")
        XCTAssertEqual(event.evidence.rssPublishedAtRef, observed.timeIntervalSinceReferenceDate)
        XCTAssertEqual(event.evidence.event, "Документ принят")
        let revised = source([rss("guid-1", text: "Текст исправлен", date: .distantPast, order: 5)])
        XCTAssertTrue(TreasuryEventJournal.additions(
            records: [revised], logicalCaseID: caseID, journal: original).isEmpty)
        let separate = try journal([rss("guid-1")], caseID: UUID())
        XCTAssertNotEqual(separate.events.first?.id, event.id)
    }

    func testReorderedDuplicatesAreSilentAndMissingGUIDIsNotInvented() throws {
        let caseID = UUID()
        let first = rss("guid-1")
        let second = rss("guid-2", order: 1)
        let initial = try journal([first, second, first, rss(nil), rss("  ")], caseID: caseID)
        XCTAssertEqual(initial.events.count, 2)
        XCTAssertTrue(TreasuryEventJournal.additions(
            records: [source([second, first])], logicalCaseID: caseID, journal: initial).isEmpty)
        var bailiff = source([first])
        bailiff.source = .bailiffs
        XCTAssertTrue(TreasuryEventJournal.additions(
            records: [bailiff], logicalCaseID: caseID, journal: .init()).isEmpty)
    }

    func testProvenDossierMergeKeepsSurvivorBindingAndRetiredIDs() throws {
        let survivor = try journal([rss("guid-1")], caseID: UUID())
        let duplicate = try journal([rss("guid-1", text: "Уточнённый текст")], caseID: UUID())
        let merged = try TreasuryEventJournal.merged([survivor, duplicate], preferred: survivor)
        let result = try XCTUnwrap(merged.events.first)
        XCTAssertEqual(merged.events.count, 1)
        XCTAssertEqual(result.id, survivor.events.first?.id)
        XCTAssertEqual(result.evidence.event, survivor.events.first?.evidence.event)
        XCTAssertEqual(result.evidence.eventIDAliases, duplicate.events.map(\.id))
        XCTAssertEqual(TreasuryEventJournal.legacyFeedIDs(recordKey: "new", legacyKeys: ["old"],
                                                         event: result),
                       ["new#enforcement#guid-1", "old#enforcement#guid-1"])
        XCTAssertTrue(TreasuryEventJournal.additions(records: [source([rss("guid-1")])],
            logicalCaseID: UUID(), journal: merged).isEmpty)
        let repeated = try TreasuryEventJournal.merged([merged, duplicate], preferred: merged)
        XCTAssertEqual(repeated, merged)
    }

    func testMergePreservesCourtJournalBaselinesAndStillRejectsCourtIDConflicts() throws {
        var court = CaseEventJournal()
        court.semanticBaselines = CaseEventBaselines()
        let courtEvent = CaseEvent.make(kind: .instanceDiscovered, occurrence: ["card"],
            observedAt: observed, evidence: .init(sourceCardID: "card", caseNumber: "2-1/2026"))
        try court.append([courtEvent])
        let treasury = try journal([rss("guid-1")], caseID: UUID())
        let merged = try TreasuryEventJournal.merged([court, treasury], preferred: court)
        XCTAssertEqual(merged.semanticBaselines, court.semanticBaselines)
        XCTAssertTrue(merged.events.contains(courtEvent))
        var conflict = CaseEventJournal()
        try conflict.append([CaseEvent(id: courtEvent.id, kind: courtEvent.kind,
            observedAtRef: courtEvent.observedAtRef, evidence: .init(caseNumber: "2-OTHER/2026"))])
        XCTAssertThrowsError(try TreasuryEventJournal.merged([court, conflict], preferred: court))
    }

    private func context(_ number: String = "2-454/2026") -> MovementContext {
        MovementContext(branchRaw: CourtBranch.general.rawValue, region: "Тестовый регион",
            searchDomain: "test--region.sudrf.ru", displayDomain: "test--region.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "00RS0001", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: number, caseID: "454",
            caseUID: "synthetic-454")
    }

    private func movement() -> CaseMovement {
        var movement = CaseMovement(uid: "", caseNumber: "2-454/2026", inForce: false,
                                    instances: [], complaints: [:], acts: [])
        movement.executionDocuments = [CourtEnforcementDocument(id: "writ-454",
                                                                blankNumber: "ФС № 454")]
        return movement
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sudrf-454-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seedAndPrepare(_ directory: URL) throws -> (String, String, Date) {
        let container = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: directory.appendingPathComponent("fixture.store"))
        let store = try TrackedStore(container: container, prepared: true)
        let record = try store.upsert(context: context(), snapshot: nil,
                                      movement: movement(), collections: ["Тестовая подборка"])
        record.enforcementRecords = [source([rss("guid-old", date: observed)])]
        record.seenAt = observed
        try store.save()
        XCTAssertTrue(try TrackedStorePreparation.prepare(context: container.mainContext))
        let eventID = try XCTUnwrap(record.eventJournal?.events.first?.id)
        XCTAssertEqual(record.seenAt, observed)
        XCTAssertFalse(try TrackedStorePreparation.prepare(context: container.mainContext))
        return (record.key, eventID, observed)
    }

    func testStoredRSSBackfillReopensAndRepeatUpdatePreservesBindingAndUserState() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (key, eventID, seen) = try seedAndPrepare(directory)
        let container = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: directory.appendingPathComponent("fixture.store"))
        let store = try TrackedStore(container: container)
        let record = try XCTUnwrap(store.record(forKey: key))
        XCTAssertEqual(record.eventJournal?.events.map(\.id), [eventID])
        XCTAssertEqual(record.seenAt, seen)
        try store.applyEnforcementUpdates(forLocator: key,
            updates: [source([rss("guid-old", date: observed)])], openedKey: nil)
        XCTAssertEqual(record.eventJournal?.events.map(\.id), [eventID])
        XCTAssertEqual(record.seenAt, seen)
        XCTAssertEqual(record.collectionNames, ["Тестовая подборка"])
        try store.applyEnforcementUpdates(forLocator: key,
            updates: [source([rss("guid-old"), rss("guid-new", order: 1)])], openedKey: nil)
        XCTAssertEqual(record.eventJournal?.events.count, 2)
        XCTAssertNil(record.seenAt)
    }

    func testAtomicDossierMergePersistsGUIDBindingsAliasesAndCourtHistory() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")
        var survivorID = ""
        var retiredID = ""
        var key = ""
        var oldKey = ""
        var courtEventID = ""
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let survivor = try store.upsert(context: context(), snapshot: nil,
                                           movement: movement(), collections: ["Основная"])
            var duplicateContext = context("М-454/2026")
            duplicateContext.caseID = "duplicate-454"
            duplicateContext.caseUID = "duplicate-guid-454"
            let duplicate = try store.upsert(context: duplicateContext, snapshot: nil,
                                            movement: movement(), collections: ["Вторая"])
            try store.applyEnforcementUpdates(forLocator: survivor.key,
                updates: [source([rss("guid-shared")])], openedKey: nil)
            try store.applyEnforcementUpdates(forLocator: duplicate.key,
                updates: [source([rss("guid-shared"), rss("guid-other")])], openedKey: nil)
            survivorID = try XCTUnwrap(survivor.eventJournal?.events.first?.id)
            retiredID = try XCTUnwrap(duplicate.eventJournal?.events.first?.id)
            let courtEvent = CaseEvent.make(kind: .instanceDiscovered, occurrence: ["court-454"],
                observedAt: observed, evidence: .init(sourceCardID: "court-454"))
            courtEventID = courtEvent.id
            var original = try store.requiredEventJournal(for: survivor)
            try original.append([courtEvent])
            original.semanticBaselines = CaseEventBaselines()
            survivor.eventJournalData = try JSONEncoder().encode(original)
            var duplicateJournal = try store.requiredEventJournal(for: duplicate)
            duplicateJournal.semanticBaselines = CaseEventBaselines()
            duplicate.eventJournalData = try JSONEncoder().encode(duplicateJournal)
            try store.save()
            oldKey = duplicate.key
            _ = try TrackedCaseRepairCoordinator.atomicMerge(store: store, survivor: survivor,
                duplicates: [duplicate], canonicalContext: context(), canonicalCard: nil)
            key = survivor.key
            XCTAssertEqual(store.all().count, 1)
            XCTAssertTrue(survivor.legacyKeyAliases.contains(oldKey))
            XCTAssertTrue(try store.requiredEventJournal(for: survivor).events.contains(courtEvent))
            XCTAssertEqual(survivor.eventJournal?.semanticBaselines, original.semanticBaselines)
        }
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
        let store = try TrackedStore(container: container)
        let record = try XCTUnwrap(store.record(forKey: key))
        let journal = try store.requiredEventJournal(for: record)
        XCTAssertTrue(record.legacyKeyAliases.contains(oldKey))
        XCTAssertTrue(journal.events.contains { $0.id == courtEventID })
        XCTAssertEqual(journal.semanticBaselines, CaseEventBaselines())
        let shared = try XCTUnwrap(journal.events.first { $0.evidence.rssGUID == "guid-shared" })
        XCTAssertEqual(shared.id, survivorID)
        XCTAssertEqual(shared.evidence.eventIDAliases, [retiredID])
        XCTAssertEqual(journal.events.filter { $0.kind == .treasuryRSSPublished }.count, 2)
        XCTAssertEqual(Set(record.collectionNames), ["Основная", "Вторая"])
        try store.applyEnforcementUpdates(forLocator: key,
            updates: [source([rss("guid-other"), rss("guid-shared", text: "Уточнено")])],
            openedKey: nil)
        XCTAssertEqual(record.eventJournal, journal)
    }

    func testNativeTreasuryClientRefreshPersistsHistoryAndReplaysAfterRestart() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")
        var key = ""
        var eventIDs: [String] = []
        for pass in 0..<2 {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container)
            if pass == 0 {
                key = try store.upsert(context: context(), snapshot: nil,
                                       movement: movement(), collections: []).key
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [Treasury454URLProtocol.self]
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCache = nil
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let client = TreasuryClient(session: session, minInterval: 0,
                baseURL: URL(string: "https://treasury454.test")!, maxAttempts: 1)
            let center = RefreshCenter(store: store, client: TestNetworkGuard.sudrfClient(),
                captchaTokenStore: CaptchaTokenStore(),
                serviceBuilder: { _ in Treasury454UnusedMovement() },
                treasuryDiscover: { document, number, court in
                    try await client.discover(document: document, caseNumber: number, court: court)
                }, vsrfProvider: Treasury454UnusedVSRF(), fsspAutoModelEnabled: false,
                fsspDiscover: { _ in .notFound(.init(state: .notFound, record: nil)) })
            var callbacks: [String] = []
            center.onEnforcementRefreshed = { callbacks.append($0) }
            let task = try XCTUnwrap(center.refreshEnforcement(key: key))
            await task.value
            XCTAssertNil(center.enforcementError(forKey: key))
            XCTAssertEqual(callbacks, [key])
            let record = try XCTUnwrap(store.record(forKey: key))
            let treasury = try XCTUnwrap(record.enforcementRecords.first { $0.source == .treasury })
            XCTAssertEqual(treasury.events.map(\.guid), ["native-guid-1", "native-guid-2"])
            XCTAssertEqual(treasury.sourceURL?.host, "treasury454.test")
            let currentIDs = try store.requiredEventJournal(for: record).events.map(\.id)
            XCTAssertEqual(currentIDs.count, 2)
            if pass == 0 { eventIDs = currentIDs }
            else { XCTAssertEqual(currentIDs, eventIDs) }
        }
    }

    private func makeRouter(container: ModelContainer, defaults: UserDefaults,
                            suite: String, directory: URL,
                            notifications: @escaping @MainActor ([FeedEntry]) -> Void)
        throws -> (AppRouter, TrackedStore, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Treasury454URLProtocol.self]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config)
        let treasury = TreasuryClient(session: session, minInterval: 0,
            baseURL: URL(string: "https://treasury454.test")!, maxAttempts: 1)
        let vsrf = Treasury454UnusedVSRF()
        let moscow = MosGorSudClient(session: session, minInterval: 0)
        var capturedStore: TrackedStore?
        let router = try AppRouter(captchaSettings: CaptchaSettings(defaults: defaults),
            modelContainer: container,
            captchaCorpus: CorpusStore(baseDir: directory.appendingPathComponent("corpus")),
            refreshCenterFactory: { store, client in
                capturedStore = store
                return RefreshCenter(store: store, client: client,
                    captchaTokenStore: CaptchaTokenStore(),
                    serviceBuilder: { _ in Treasury454UnusedMovement() },
                    treasuryDiscover: { document, number, court in
                        try await treasury.discover(document: document, caseNumber: number, court: court)
                    }, vsrfProvider: vsrf, fsspAutoModelEnabled: false,
                    fsspDiscover: { _ in .notFound(.init(state: .notFound, record: nil)) })
            }, importVSRFProvider: vsrf, importMosGorSudProvider: moscow,
            selectedPublishedAct: PublishedActSelection(
                cache: ActFileCache(directory: directory.appendingPathComponent("acts")),
                fetch: { _, _ in XCTFail("unexpected act request"); throw CancellationError() }),
            summaryConfigurationProvider: { throw CancellationError() },
            userDefaults: defaults, client: TestNetworkGuard.sudrfClient(),
            captchaTokenStore: CaptchaTokenStore(),
            directCaseLinkResolverFactory: { _ in DirectCaseLinkResolver(
                fetchCard: { _ in XCTFail("unexpected direct card request"); throw CancellationError() },
                districtCourts: { _ in XCTFail("unexpected directory request"); throw CancellationError() }) },
            spotlightIndexerFactory: { catalog in SpotlightIndexer(catalog: catalog,
                writer: Treasury454NoSpotlight(), manifestStore: SpotlightManifestStore(suiteName: suite),
                preferenceStore: SpotlightPreferenceStore(suiteName: suite)) },
            currentEntityActivityPublisher: { _ in XCTFail("unexpected activity publication") },
            feedNotificationPublisher: notifications,
            feedBadgePublisher: { _ in }, notificationOpenInstaller: { _ in }, intentInstaller: { _ in },
            captchaSolverFactory: { _ in nil },
            repairCoordinatorFactory: { store, client in TrackedCaseRepairCoordinator(
                store: store, client: client, originResolver: Treasury454NoOrigin(), defaults: defaults,
                anchorCardFetcher: { _ in XCTFail("unexpected repair request"); throw CancellationError() }) })
        return (router, try XCTUnwrap(capturedStore), session)
    }

    func testActualFeedNotifierFilteringPreservesOldMarksAndFirstFetchAcrossRestartAndMerge() async throws {
        for hasOldHistory in [true, false] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("fixture.store")
            let suite = "Sudrf.Treasury454.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(false, forKey: SpotlightPreferenceStore.key)
            defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
            var key = ""
            var oldID = ""
            var persistedReadIDs = Set<String>()
            var persistedKnownIDs = Set<String>()
            do {
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let store = try TrackedStore(container: container, prepared: true)
                let record = try store.upsert(context: context(), snapshot: nil,
                                              movement: movement(), collections: ["Пользовательская"])
                key = record.key
                oldID = AppRouter.enforcementFeedID(recordKey: key, guid: "native-guid-1")
                if hasOldHistory {
                    record.enforcementRecords = [source([rss("native-guid-1", date: DateUtil.today)])]
                    defaults.set([oldID], forKey: "overviewReadFeedIDs.v1")
                    defaults.set([oldID], forKey: "notifiedFeedIDs.v1")
                }
                record.seenAt = observed
                try store.save()
            }
            var batches: [[FeedEntry]] = []
            for pass in 0..<2 {
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let (router, store, session) = try makeRouter(container: container, defaults: defaults,
                    suite: suite, directory: directory, notifications: { batches.append($0) })
                defer { session.invalidateAndCancel() }
                XCTAssertEqual(batches.count, pass == 0 ? 0 : 1)
                let beforeRefresh = try XCTUnwrap(store.record(forKey: key))
                if hasOldHistory {
                    let oldEvent = try XCTUnwrap(beforeRefresh.eventJournal?.events.first {
                        $0.kind == .treasuryRSSPublished && $0.evidence.rssGUID == "native-guid-1"
                    })
                    XCTAssertEqual(router.feed.first { $0.id == oldEvent.id }?.isUnread, false,
                                   "legacy read preference maps to the persisted RSS event identity")
                    let state = try XCTUnwrap(beforeRefresh.eventJournal?.feedState)
                    XCTAssertTrue(state.readEventIDs.contains(oldEvent.id))
                    XCTAssertTrue(state.knownEventIDs.contains(oldEvent.id))
                    let receipt = try XCTUnwrap(state.receipts.first)
                    XCTAssertTrue(receipt.originalReadIDs.contains(oldID))
                    XCTAssertTrue(receipt.originalKnownIDs.contains(oldID))
                }
                let task = try XCTUnwrap(router.refreshCenter.refreshEnforcement(key: key))
                await task.value
                XCTAssertNil(router.refreshCenter.enforcementError(forKey: key))
                let expectedGUIDs = hasOldHistory ? ["native-guid-2"] : ["native-guid-1", "native-guid-2"]
                let record = try XCTUnwrap(store.record(forKey: key))
                let expectedEventIDs = Set(try expectedGUIDs.map { guid in
                    try XCTUnwrap(record.eventJournal?.events.first {
                        $0.kind == .treasuryRSSPublished && $0.evidence.rssGUID == guid
                    }).id
                })
                XCTAssertEqual(batches.count, 1)
                XCTAssertEqual(Set(batches[0].map(\.id)), expectedEventIDs,
                               "notifier uses canonical persisted IDs selected by exact RSS GUID")
                XCTAssertEqual(record.eventJournal?.events.filter { $0.kind == .treasuryRSSPublished }.count, 2)
                XCTAssertEqual(record.collectionNames, ["Пользовательская"])
                if pass == 0 {
                    let repeatedUnread = try XCTUnwrap(router.refreshCenter.refreshEnforcement(key: key))
                    await repeatedUnread.value
                    XCTAssertEqual(batches.count, 1)
                    XCTAssertTrue(router.feed.contains { $0.isUnread })
                    router.markAllFeedRead()
                    let readState = try XCTUnwrap(store.record(forKey: key)?.eventJournal?.feedState)
                    persistedReadIDs = readState.readEventIDs
                    persistedKnownIDs = readState.knownEventIDs
                    XCTAssertEqual(persistedReadIDs, Set(try XCTUnwrap(
                        store.record(forKey: key)?.eventJournal?.events
                            .filter { $0.kind == .treasuryRSSPublished }.map(\.id))))
                    // Once imported, preferences are only a compatibility mirror; a stale
                    // snapshot must not overwrite the journal's durable read/known authority.
                    let repeated = try XCTUnwrap(router.refreshCenter.refreshEnforcement(key: key))
                    await repeated.value
                    XCTAssertEqual(batches.count, 1)
                    // Corrupt the mirrors after the current process has finished syncing them;
                    // the next router must still honor the persisted journal state.
                    defaults.set(["stale-preimport-read"], forKey: "overviewReadFeedIDs.v1")
                    defaults.set(["stale-preimport-known"], forKey: "notifiedFeedIDs.v1")
                } else {
                    let feedState = try XCTUnwrap(record.eventJournal?.feedState)
                    XCTAssertEqual(feedState.readEventIDs, persistedReadIDs,
                                   "restart uses the persisted read authority after preference corruption")
                    XCTAssertEqual(feedState.knownEventIDs, persistedKnownIDs,
                                   "restart does not replay stale known preferences")
                    XCTAssertTrue(router.feed.allSatisfy { !$0.isUnread })
                    // Exercise the existing remap callback after the real disk merge.
                    var duplicateContext = context("М-454/2026")
                    duplicateContext.caseID = "notification-merge"
                    duplicateContext.caseUID = "notification-merge-guid"
                    let duplicate = try store.upsert(context: duplicateContext, snapshot: nil,
                                                     movement: movement(), collections: [])
                    try store.applyEnforcementUpdates(forLocator: duplicate.key,
                        updates: [source([rss("native-guid-3", date: DateUtil.today)])], openedKey: nil)
                    let duplicateKey = duplicate.key
                    let duplicateEventID = try XCTUnwrap(duplicate.eventJournal?.events.first {
                        $0.kind == .treasuryRSSPublished && $0.evidence.rssGUID == "native-guid-3"
                    }).id
                    router.reload()
                    router.markAllFeedRead()
                    let duplicateState = try XCTUnwrap(duplicate.eventJournal?.feedState)
                    XCTAssertTrue(duplicateState.readEventIDs.contains(duplicateEventID))
                    XCTAssertTrue(duplicateState.knownEventIDs.contains(duplicateEventID))
                    var canonical = context("2-454-REANCHORED/2026")
                    canonical.caseID = "reanchored-454"
                    canonical.caseUID = "reanchored-guid-454"
                    let oldKey = key
                    let remaps = try TrackedCaseRepairCoordinator.atomicMerge(store: store,
                        survivor: record, duplicates: [duplicate], canonicalContext: canonical,
                        canonicalCard: nil)
                    key = record.key
                    XCTAssertEqual(key, oldKey)
                    XCTAssertEqual(record.context?.caseNumber, canonical.caseNumber)
                    XCTAssertEqual(remaps[duplicateKey], key)
                    router.refreshCenter.onRefreshed?(key, try XCTUnwrap(record.movement), remaps)
                    XCTAssertEqual(batches.count, 1)
                    XCTAssertTrue(router.feed.allSatisfy { !$0.isUnread })
                    let canonicalReadIDs = Set(try ["native-guid-1", "native-guid-2", "native-guid-3"].map { guid in
                        try XCTUnwrap(record.eventJournal?.events.first {
                            $0.kind == .treasuryRSSPublished && $0.evidence.rssGUID == guid
                        }).id
                    })
                    let mergedState = try XCTUnwrap(record.eventJournal?.feedState)
                    XCTAssertEqual(mergedState.readEventIDs, canonicalReadIDs,
                                   "merge keeps every read mark on its persisted event identity")
                    XCTAssertEqual(mergedState.knownEventIDs, canonicalReadIDs,
                                   "merge keeps known/read marks on the exact RSS event IDs")
                }
            }
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let (reopened, store, session) = try makeRouter(container: container, defaults: defaults,
                suite: suite, directory: directory, notifications: { batches.append($0) })
            defer { session.invalidateAndCancel() }
            XCTAssertEqual(store.all().count, 1)
            XCTAssertEqual(batches.count, 1)
            XCTAssertTrue(reopened.feed.allSatisfy { !$0.isUnread })
        }
    }

    func testPreparationFailureRestoresRSSAndMoscowNormalizationInMemoryAndOnDisk() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
        let store = try TrackedStore(container: container, prepared: true)
        var moscow = context()
        moscow.searchDomain = "mos-gorsud.ru"
        moscow.displayDomain = "mos-gorsud.ru"
        moscow.courtTitle = "Московский городской суд"
        moscow.cardURLString = "https://mos-gorsud.ru/mgs/services/cases/appeal-civil/details/synthetic-454"
        var sourceMovement = movement()
        sourceMovement.instances = [CaseInstance(level: .appeal,
            court: "Хамовнический районный суд", caseNumber: "33-454/2026", judge: nil,
            domain: "mos-gorsud.ru", foundByUID: false, result: nil, sessions: [],
            sourceURL: URL(string: moscow.cardURLString!))]
        XCTAssertFalse(MovementDerivation.moscowOwnCourtCorrections(
            in: sourceMovement, context: moscow).isEmpty)
        let record = try store.upsert(context: moscow, snapshot: nil,
                                      movement: sourceMovement, collections: [])
        // Seed a legacy cache directly, before either preparation repair runs.
        record.movementData = try JSONEncoder().encode(sourceMovement)
        record.enforcementRecords = [source([rss("stored-guid")])]
        record.eventJournalData = try JSONEncoder().encode(CaseEventJournal())
        record.seenAt = observed
        try store.save()
        let key = record.key
        let oldJournal = record.eventJournalData
        let oldMovement = record.movementData
        let oldSnapshot = record.snapshotData
        XCTAssertThrowsError(try TrackedStorePreparation.prepare(context: container.mainContext,
            save: { _ in
                XCTAssertNotEqual(record.movementData, oldMovement)
                XCTAssertNotEqual(record.eventJournalData, oldJournal)
                throw CancellationError()
            }))
        XCTAssertEqual(record.eventJournalData, oldJournal)
        XCTAssertEqual(record.movementData, oldMovement)
        XCTAssertEqual(record.snapshotData, oldSnapshot)
        XCTAssertEqual(record.seenAt, observed)
        let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let saved = try XCTUnwrap(reopened.record(forKey: key))
        XCTAssertEqual(saved.eventJournalData, oldJournal)
        XCTAssertEqual(saved.movementData, oldMovement)
        XCTAssertEqual(saved.snapshotData, oldSnapshot)
        XCTAssertEqual(saved.seenAt, observed)
    }

    func testJournalAppendEncodingAndSaveFailuresRollbackWholeEnforcementTransition() throws {
        for failure in 0..<3 {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let container = try SudrfModelContainerFactory.make(
                inMemory: false, storeURL: directory.appendingPathComponent("fixture.store"))
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.upsert(context: context(), snapshot: nil,
                                          movement: movement(), collections: [])
            record.seenAt = observed
            try store.save()
            let priorEnforcement = record.enforcementData
            let priorJournal = record.eventJournalData
            if failure == 0 { store.failNextJournalAppendForTesting = true }
            if failure == 1 { store.failNextJournalEncodingForTesting = true }
            if failure == 2 { store.failNextSaveForTesting = true }
            XCTAssertThrowsError(try store.applyEnforcementUpdates(forLocator: record.key,
                updates: [source([rss("new")])], openedKey: nil))
            let restored = try XCTUnwrap(store.record(forKey: record.key))
            XCTAssertEqual(restored.enforcementData, priorEnforcement)
            XCTAssertEqual(restored.eventJournalData, priorJournal)
            XCTAssertEqual(restored.seenAt, observed)
        }
    }
}

private struct Treasury454UnusedMovement: MovementProviding {
    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        XCTFail("enforcement refresh must not request court movement")
        throw CancellationError()
    }
}

private struct Treasury454UnusedVSRF: VSRFProviding {
    func search(uniqueNumber: String?, oldCaseNumber: String?,
                keywords: String?) async throws -> VSRFSearchResults {
        XCTFail("enforcement refresh must not request VS RF")
        throw CancellationError()
    }
    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard {
        XCTFail("enforcement refresh must not request VS RF card")
        throw CancellationError()
    }
}

private final class Treasury454URLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "treasury454.test" else {
            XCTFail("unexpected URL in isolated Treasury refresh")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss"
        let publishedDate = formatter.string(from: DateUtil.today)
        let content: String
        if url.path == "/roskazna/rss" {
            let history = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "documentId" } == true
            if history {
                content = """
                <rss><channel>
                <item><title>Документ принят</title><guid>native-guid-1</guid><pubDate>\(publishedDate)</pubDate></item>
                <item><title>Документ исполнен</title><guid>native-guid-2</guid><pubDate>\(publishedDate)</pubDate></item>
                </channel></rss>
                """
            } else {
                content = """
                <rss><channel><item><title>Исполнительный документ ФС № 454</title>
                <link>https://treasury454.test/roskazna/spring/document_details?documentId=454</link>
                <description><![CDATA[<b>Серия и номер исполнительного документа:</b>ФС № 454<br/><b>Номер судебного дела:</b>2-454/2026<br/><b>Наименование судебного органа:</b>Тестовый суд]]></description>
                <guid>document-454</guid></item></channel></rss>
                """
            }
        } else if url.path == "/roskazna/spring/document_details" {
            content = "<html><body>Тестовый исполнительный документ</body></html>"
        } else {
            XCTFail("unexpected Treasury fixture path")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "text/xml; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(content.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct Treasury454NoOrigin: CaseOriginResolving {
    func resolve(anchorContext: MovementContext, anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        XCTFail("unexpected origin lookup")
        throw CancellationError()
    }
}

private actor Treasury454NoSpotlight: SpotlightIndexWriting {
    func index(cases: [CaseEntity], acts: [CourtActEntity]) async throws { XCTFail("unexpected indexing") }
    func delete(caseIDs: [String], actIDs: [String]) async throws { XCTFail("unexpected index deletion") }
    func deleteAll() async throws { XCTFail("unexpected index deletion") }
}
