import XCTest
import Combine
import SwiftData
import SudrfKit
import CaptchaSolver
@testable import SudrfApp

@MainActor
final class CaseOpeningSeenStateTests: XCTestCase {
    private static let readIDsKey = "overviewReadFeedIDs.v1"
    private static let knownIDsKey = "notifiedFeedIDs.v1"
    private static let consumedMaterialIDsKey = "materialFeedConsumedLegacyIDs.v1"
    private static let pendingMaterialCountsKey = "materialFeedPendingCounts.v1"
    private static let collectionsKey = "myCollections"
    private var defaultsSuite: String!
    private var testDefaults: UserDefaults!
    private var testDirectory: URL!
    private var captchaSettings: CaptchaSettings!
    private var captchaTokenStore: CaptchaTokenStore!

    private actor NoopSpotlightWriter: SpotlightIndexWriting {
        func index(cases: [CaseEntity], acts: [CourtActEntity]) async throws {}
        func delete(caseIDs: [String], actIDs: [String]) async throws {}
        func deleteAll() async throws {}
    }

    private actor OfflineVSRFProvider: VSRFProviding {
        func search(uniqueNumber: String?, oldCaseNumber: String?,
                    keywords: String?) async throws -> VSRFSearchResults {
            throw URLError(.notConnectedToInternet)
        }
        func fetchCard(productionID: String,
                       section: VSRFCardSection) async throws -> VSRFCard {
            throw URLError(.notConnectedToInternet)
        }
    }

    private actor OfflineMosGorSudProvider: MosGorSudProviding {
        func search(courtAlias: String?, uid: String?, caseNumber: String?,
                    participant: String?, instance: Int,
                    processType: MosGorSudProcessType) async throws -> [MosGorSudResult] {
            throw URLError(.notConnectedToInternet)
        }
        func fetchCard(url: URL) async throws -> MosGorSudCard {
            throw URLError(.notConnectedToInternet)
        }
        func fetchPublishedAct(url: URL) async throws -> PublishedActFile {
            throw URLError(.notConnectedToInternet)
        }
    }

    private actor OfflineMoscowOriginProvider: MoscowOriginProviding {
        func search(courtAlias: String?, uid: String?, caseNumber: String?,
                    participant: String?, instance: Int,
                    processType: MosGorSudProcessType) async throws -> [MosGorSudResult] {
            throw URLError(.notConnectedToInternet)
        }
        func fetchCard(url: URL) async throws -> MosGorSudCard {
            throw URLError(.notConnectedToInternet)
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuite = "Sudrf.CaseOpeningSeenStateTests.\(UUID().uuidString)"
        testDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("case-opening-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        captchaSettings = CaptchaSettings(defaults: testDefaults)
        captchaTokenStore = CaptchaTokenStore()
    }

    override func tearDown() async throws {
        testDefaults.removePersistentDomain(forName: defaultsSuite)
        if let testDirectory { try? FileManager.default.removeItem(at: testDirectory) }
        try await super.tearDown()
    }

    private actor FixedMovement: MovementProviding {
        let value: CaseMovement
        init(_ value: CaseMovement) { self.value = value }

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            value
        }
    }

    private func isolateFeedDefaults() -> () -> Void {
        testDefaults.removePersistentDomain(forName: defaultsSuite)
        return {}
    }

    private func makeRouter(
        container: ModelContainer,
        refreshCenterFactory: (@MainActor (TrackedStore, SudrfClient) -> RefreshCenter)? = nil
    ) throws -> AppRouter {
        let defaults = try XCTUnwrap(testDefaults)
        let directory = try XCTUnwrap(testDirectory)
        let settings = try XCTUnwrap(captchaSettings)
        let tokens = try XCTUnwrap(captchaTokenStore)
        let client = TestNetworkGuard.sudrfClient()
        let factory = refreshCenterFactory ?? { store, privateClient in
            self.makeRefreshCenter(store: store, client: privateClient)
        }
        return try AppRouter(
            captchaSettings: settings,
            modelContainer: container,
            modelContainerIsPrepared: true,
            captchaCorpus: CorpusStore(baseDir: directory.appendingPathComponent("captcha")),
            refreshCenterFactory: factory,
            importVSRFProvider: OfflineVSRFProvider(),
            importMosGorSudProvider: OfflineMosGorSudProvider(),
            selectedPublishedAct: PublishedActSelection(
                cache: ActFileCache(directory: directory.appendingPathComponent("acts")),
                fetch: { _, _ in throw CancellationError() }),
            summaryConfigurationProvider: { throw CancellationError() },
            userDefaults: defaults,
            client: client,
            captchaTokenStore: tokens,
            directCaseLinkResolverFactory: { _ in DirectCaseLinkResolver(
                fetchCard: { _ in throw CancellationError() },
                districtCourts: { _ in throw CancellationError() }) },
            spotlightIndexerFactory: { catalog in
                SpotlightIndexer(catalog: catalog, writer: NoopSpotlightWriter(),
                    manifestStore: SpotlightManifestStore(suiteName: defaultsSuite),
                    preferenceStore: SpotlightPreferenceStore(suiteName: defaultsSuite))
            },
            currentEntityActivityPublisher: { _ in },
            feedNotificationPublisher: { _ in },
            feedBadgePublisher: { _ in },
            notificationOpenInstaller: { _ in },
            intentInstaller: { _ in },
            captchaSolverFactory: { _ in nil },
            repairCoordinatorFactory: { store, privateClient in
                let districtResolver = DistrictCourtResolver(client: privateClient, cacheURL: nil)
                let magistrateResolver = MagistrateCourtResolver(
                    client: privateClient, cacheURL: nil, moscowDirectoryClient: nil)
                let originResolver = CaseOriginResolver(
                    client: privateClient, districtResolver: districtResolver,
                    magistrateResolver: magistrateResolver,
                    regularProvider: privateClient, magistrateProvider: privateClient,
                    moscowProvider: OfflineMoscowOriginProvider())
                return TrackedCaseRepairCoordinator(
                    store: store, client: privateClient,
                    originResolver: originResolver,
                    defaults: defaults,
                    anchorCardResolver: { _ in throw CancellationError() })
            })
    }

    private func makeRefreshCenter(
        store: TrackedStore, client: SudrfClient,
        movementProvider: (any MovementProviding)? = nil
    ) -> RefreshCenter {
        let settings = captchaSettings!
        let tokens = captchaTokenStore!
        return RefreshCenter(
            store: store, client: client,
            captchaSettings: settings, captchaTokenStore: tokens,
            serviceBuilder: movementProvider.map { provider in { _ in provider } },
            treasuryDiscover: { _, _, _ in throw CancellationError() },
            vsrfProvider: OfflineVSRFProvider(),
            mosGorSudProvider: OfflineMosGorSudProvider(),
            moscowMagistrateProvider: client,
            fsspAutoModelEnabled: false,
            fsspDiscover: { _ in throw CancellationError() },
            initialTimerDelay: .seconds(3_600), timerInterval: .seconds(3_600),
            walkDiagnostics: .disabled)
    }

    private func context(_ number: String) -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number)
    }

    private func date(_ offset: Int) -> Date {
        DateUtil.addDays(DateUtil.today, offset)
    }

    private func dateText(_ offset: Int) -> String {
        let parts = DateUtil.cal.dateComponents([.day, .month, .year], from: date(offset))
        return String(format: "%02d.%02d.%04d", parts.day!, parts.month!, parts.year!)
    }

    private func movement(for context: MovementContext,
                          withMaterial: Bool = false,
                          actID: String? = nil) -> CaseMovement {
        var instances = [CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.displayDomain, foundByUID: false, result: nil,
            sessions: [
                CaseSession(date: dateText(-1), time: "10:00",
                            event: "Судебное заседание"),
                CaseSession(date: dateText(2), time: "12:00",
                            event: "Судебное заседание"),
            ])]
        if withMaterial {
            instances.append(CaseInstance(
                level: .material, court: context.courtTitle,
                caseNumber: "13-1/2026", judge: nil, domain: context.displayDomain,
                foundByUID: true, result: nil,
                sessions: [CaseSession(date: dateText(-1), time: "11:00",
                                       event: "Поступление материала")]))
        }
        let acts = actID.map {
            [CaseAct(id: $0, title: "Определение", date: dateText(-1),
                     courtShort: "СГС", instanceLevel: .first)]
        } ?? []
        return CaseMovement(uid: "uid-\(context.caseNumber)",
                            caseNumber: context.caseNumber, inForce: false,
                            instances: instances, complaints: [:], acts: acts)
    }

    private func record(_ context: MovementContext,
                        withMaterial: Bool = false,
                        actID: String? = nil) throws -> TrackedCaseRecord {
        let movement = movement(for: context, withMaterial: withMaterial, actID: actID)
        var snapshot = MovementDerivation.snapshot(from: movement, context: context)
        snapshot.deadlines.append(StoredDeadline(
            kind: "opening-test", what: "Контрольный срок", basis: "тест",
            calLabel: "контроль", dateRef: date(3).timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue,
            occurrenceKey: "opening-\(context.caseNumber)"))
        let record = TrackedCaseRecord(
            key: context.key, collections: ["Тест"], caseNumber: context.caseNumber,
            courtTitle: context.courtTitle, displayDomain: context.displayDomain,
            contextData: try JSONEncoder().encode(context),
            snapshotData: try JSONEncoder().encode(snapshot))
        record.movement = movement
        record.movementFetchedAt = Date()
        return record
    }

    private func container(with records: [TrackedCaseRecord]) throws -> ModelContainer {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        for record in records { container.mainContext.insert(record) }
        try container.mainContext.save()
        return container
    }

    func testOpeningUsesCurrentDayCacheAndOnlyMarksCanonicalCaseAndNormalFeedRead() throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let first = try record(context("2-385/2026"))
        first.legacyKeyAliases = ["old-display-key"]
        let other = try record(context("2-386/2026"))
        let container = try container(with: [first, other])
        let router = try makeRouter(container: container)

        var hearingPublications = 0
        var calendarPublications = 0
        var deadlinePublications = 0
        var inactiveDeadlinePublications = 0
        let hearingSubscription = router.$hearings.sink { _ in hearingPublications += 1 }
        let calendarSubscription = router.$calendarHearings.sink { _ in calendarPublications += 1 }
        let deadlineSubscription = router.$deadlines.sink { _ in deadlinePublications += 1 }
        let inactiveDeadlineSubscription = router.$inactiveDeadlines.sink {
            _ in inactiveDeadlinePublications += 1
        }
        hearingPublications = 0
        calendarPublications = 0
        deadlinePublications = 0
        inactiveDeadlinePublications = 0

        let firstNormalIDs = Set(router.feed.filter {
            $0.recordKey == first.key && $0.kind != .enforcement
        }.map(\.id))
        XCTAssertFalse(firstNormalIDs.isEmpty)
        XCTAssertTrue(router.feed.filter { firstNormalIDs.contains($0.id) }.allSatisfy(\.isUnread))

        router.openCase(key: "old-display-key")

        XCTAssertEqual(router.openedCase, first.caseNumber)
        XCTAssertEqual(try TrackedStore(container: container, prepared: true)
            .record(forKey: first.key)?.seenAt, first.seenAt)
        XCTAssertNotNil(first.seenAt)
        XCTAssertFalse(router.cases.first { $0.recordKey == first.key }?.isNew ?? true)
        XCTAssertFalse(router.cases.first { $0.recordKey == first.key }?.newDot ?? true)
        XCTAssertTrue(router.cases.first { $0.recordKey == other.key }?.isNew ?? false)
        XCTAssertTrue(router.feed.filter { firstNormalIDs.contains($0.id) }.allSatisfy { !$0.isUnread })
        XCTAssertTrue(router.feed.filter { $0.recordKey == other.key && $0.kind != .enforcement }
            .allSatisfy(\.isUnread))
        let firstReadIDs = Set(try XCTUnwrap(
            TrackedStore(container: container, prepared: true).record(forKey: first.key)?
                .eventJournal?.feedState?.readEventIDs))
        XCTAssertTrue(firstNormalIDs.isSubset(of: firstReadIDs))
        XCTAssertTrue(firstReadIDs.isDisjoint(with: Set(router.feed.filter {
            $0.recordKey == other.key
        }.map(\.id))), "opening one case must not mark another case's feed entries read")
        XCTAssertEqual(hearingPublications, 0)
        XCTAssertEqual(calendarPublications, 0)
        XCTAssertEqual(deadlinePublications, 0)
        XCTAssertEqual(inactiveDeadlinePublications, 0)

        let seenAt = try XCTUnwrap(first.seenAt)
        router.openCase(key: first.key)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(first.seenAt), seenAt)
        XCTAssertEqual(hearingPublications, 0)
        XCTAssertEqual(calendarPublications, 0)
        XCTAssertEqual(deadlinePublications, 0)

        func projection(_ router: AppRouter) -> [String] {
            [
                "\(router.newBadge)|\(router.unreadFeedCount)",
                router.cases.map { "\($0.recordKey)|\($0.isNew)|\($0.newDot)" }.joined(separator: ";"),
                router.feed.map { "\($0.id)|\($0.kind.rawValue)|\($0.isUnread)" }.joined(separator: ";"),
                router.hearings.map(\.id).joined(separator: ";"),
                router.calendarHearings.map(\.id).joined(separator: ";"),
                router.deadlines.map(\.id).joined(separator: ";"),
                router.stageCounts.map { "\($0.0.rawValue)|\($0.1)" }.joined(separator: ";"),
                router.tierCounts.map { "\(String(describing: $0.0))|\($0.1)" }.joined(separator: ";"),
            ]
        }
        let fastPathProjection = projection(router)
        router.reload()
        XCTAssertEqual(projection(router), fastPathProjection,
                       "same-day seen updates must match the full reload projection")
        _ = hearingSubscription
        _ = calendarSubscription
        _ = deadlineSubscription
        _ = inactiveDeadlineSubscription
    }

    func testOpeningMaterialAndActFeedEntriesKeepsExplicitActSelection() throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let context = context("2-387/2026")
        let record = try record(context, withMaterial: true, actID: "opening-act")
        let container = try container(with: [record])
        let router = try makeRouter(container: container)
        let material = try XCTUnwrap(router.feed.first {
            $0.recordKey == record.key && $0.instanceLevel == .material
        })
        XCTAssertTrue(material.isUnread)

        router.openFeedEntry(material)

        XCTAssertEqual(router.openedCase, record.caseNumber)
        XCTAssertFalse(try XCTUnwrap(router.feed.first { $0.id == material.id }).isUnread)
        XCTAssertTrue(router.feed.filter { $0.recordKey == record.key && $0.kind != .enforcement }
            .allSatisfy { !$0.isUnread })

        let act = try XCTUnwrap(router.feed.first { $0.actID == "opening-act" })
        router.closeCase()
        router.openFeedEntry(act, preferAct: true)

        XCTAssertEqual(router.selectedActID, "opening-act")
        XCTAssertFalse(try XCTUnwrap(router.feed.first { $0.id == act.id }).isUnread)
        XCTAssertTrue(try XCTUnwrap(record.eventJournal?.feedState?.readEventIDs).contains(act.id))
    }

    func testOpeningCaseLeavesEnforcementUnreadUntilItsEntryIsOpened() throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let record = try record(context("2-388/2026"))
        let updates = [EnforcementRecord(
            courtDocumentID: "writ-388", source: .treasury, status: "Исполняется",
            events: [
                EnforcementEvent(guid: "rss-388-a", date: date(-1), text: "Первое событие", sourceOrder: 0),
                EnforcementEvent(guid: "rss-388-b", date: date(-2), text: "Второе событие", sourceOrder: 1),
            ])]
        let container = try container(with: [record])
        let store = try TrackedStore(container: container, prepared: true)
        _ = try store.applyEnforcementUpdates(forLocator: record.key, updates: updates, openedKey: nil)
        let router = try makeRouter(container: container)
        let enforcement = router.feed.filter {
            $0.recordKey == record.key && $0.kind == .enforcement
        }
        XCTAssertEqual(enforcement.count, 2)

        router.openCase(key: record.key)

        XCTAssertTrue(router.feed.filter { $0.kind == .enforcement }.allSatisfy(\.isUnread))
        let enforcementIDs = Set(try XCTUnwrap(record.eventJournal?.events
            .filter { $0.kind == .treasuryRSSPublished }.map(\.id)))
        XCTAssertEqual(enforcementIDs.count, 2)
        XCTAssertTrue(enforcementIDs.isDisjoint(with:
            try XCTUnwrap(record.eventJournal?.feedState?.readEventIDs)))

        let chosen = try XCTUnwrap(enforcement.first)
        router.openFeedEntry(chosen)
        XCTAssertFalse(try XCTUnwrap(router.feed.first { $0.id == chosen.id }).isUnread)
        XCTAssertEqual(router.feed.filter {
            $0.recordKey == record.key && $0.kind == .enforcement && $0.id != chosen.id
        }.count, 1)
        XCTAssertTrue(router.feed.first {
            $0.recordKey == record.key && $0.kind == .enforcement && $0.id != chosen.id
        }?.isUnread ?? false)
        let readIDs = try XCTUnwrap(record.eventJournal?.feedState?.readEventIDs)
        XCTAssertTrue(readIDs.contains(chosen.id))
        XCTAssertEqual(readIDs.intersection(enforcementIDs), [chosen.id])
    }

    func testFailedSeenSaveRollsBackRecordAndPublishedUnreadState() throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let record = try record(context("2-389/2026"))
        let priorSeenAt: Date? = nil
        record.seenAt = priorSeenAt
        let container = try container(with: [record])
        var capturedStore: TrackedStore?
        let router = try makeRouter(container: container,
            refreshCenterFactory: { store, client in
                capturedStore = store
                return self.makeRefreshCenter(store: store, client: client)
            })
        capturedStore?.failNextSaveForTesting = true

        router.openCase(key: record.key)

        XCTAssertEqual(capturedStore?.record(forKey: record.key)?.seenAt, priorSeenAt)
        XCTAssertEqual(router.persistenceError, "Изменения не сохранены. Повторите попытку.")
        XCTAssertTrue(router.cases.first?.isNew == true)
        XCTAssertTrue(router.cases.first?.newDot == true)
        XCTAssertTrue(router.feed.filter { $0.recordKey == record.key && $0.kind != .enforcement }
            .allSatisfy(\.isUnread))
        XCTAssertFalse(capturedStore?.failNextSaveForTesting ?? true)
    }

    func testSeenAtSurvivesReopeningPersistentStoreAndRouter() throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("case-opening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let context = context("2-390/2026")
        let record = try record(context)
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        container.mainContext.insert(record)
        try container.mainContext.save()
        let router = try makeRouter(container: container)

        router.openCase(key: record.key)
        let savedSeenAt = try XCTUnwrap(record.seenAt)

        let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let reopenedStore = try TrackedStore(container: reopenedContainer, prepared: true)
        XCTAssertEqual(reopenedStore.record(forKey: record.key)?.seenAt, savedSeenAt)
        let reopenedRouter = try makeRouter(container: reopenedContainer)
        XCTAssertFalse(reopenedRouter.cases.first?.isNew ?? true)
    }

    func testOpeningAfterPreviousDayCacheFallsBackToFullReload() throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let record = try record(context("2-391/2026"))
        let container = try container(with: [record])
        let router = try makeRouter(container: container)
        router.reload(today: DateUtil.addDays(DateUtil.today, -1))
        var calendarPublications = 0
        let subscription = router.$calendarHearings.sink { _ in calendarPublications += 1 }
        let beforeOpen = calendarPublications

        router.openCase(key: record.key)

        XCTAssertGreaterThan(calendarPublications, beforeOpen,
                             "previous-day cache must trigger the ordinary full reload")
        XCTAssertNotNil(record.seenAt)
        let afterFallback = calendarPublications
        router.openCase(key: record.key)
        XCTAssertEqual(calendarPublications, afterFallback,
                       "a second open on the current day must use the warm cache")
        _ = subscription
    }

    func testRefreshWithNewEventClearsSeenAndReturnsFeedEntryToUnread() async throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        var context = context("2-392/2026")
        context.caseID = "seen-state-refresh-card"
        let record = try record(context)
        record.seenAt = Date(timeIntervalSince1970: 1_700_000_100)
        var updated = try XCTUnwrap(record.movement)
        updated.instances[0].sessions.append(CaseSession(
            date: dateText(0), time: "14:30", event: "Поступление нового документа"))
        let cartoteka = try XCTUnwrap(context.cartoteka)
        let nativeCaseID = try XCTUnwrap(context.caseID)
        let native = try XCTUnwrap(SourceNativeCardLocator.sudrf(
            court: context.searchCourt, cartoteka: cartoteka, caseID: nativeCaseID))
        updated.sourceRefreshCoverage = [MovementCourtCoverage(
            sourceFamily: native.sourceFamily, courtKey: native.courtKey,
            kind: .usableSnapshot, loadedCardIdentities: [native.identity])]
        let container = try container(with: [record])
        let provider = FixedMovement(updated)
        let router = try makeRouter(container: container,
            refreshCenterFactory: { store, client in
                self.makeRefreshCenter(store: store, client: client,
                                       movementProvider: provider)
            })
        router.refreshCenter.repairBeforeRefresh = { key, _ in key }
        // Avoid UNUserNotificationCenter in xctest; project persisted state explicitly below.
        router.refreshCenter.onRefreshed = nil
        router.openCase(key: record.key)
        router.closeCase()

        let execution = await router.refreshCenter.refresh(key: record.key, manually: true)?.value

        XCTAssertEqual(execution?.outcome, .refreshed)
        XCTAssertNil(record.seenAt)
        router.reload(notifyNew: false, changedCaseKeys: [record.key])
        let addedRow = try XCTUnwrap(router.feed.first {
            $0.recordKey == record.key && $0.text == "Поступление нового документа"
        })
        XCTAssertTrue(addedRow.isUnread)
        let journal = try XCTUnwrap(record.eventJournal)
        let publications = try XCTUnwrap(assertSourceRowPublications(journal))
        let publication = try XCTUnwrap(publications.first {
            $0.evidence.legacyFeedHistory?.text == "Поступление нового документа"
        })
        let binding = try XCTUnwrap(publication.evidence.sourceRowBinding)
        let history = try XCTUnwrap(publication.evidence.legacyFeedHistory)
        XCTAssertEqual(binding.nativeCardID, native.id)
        XCTAssertEqual(binding.sourceCardID, history.sourceCardID)
        XCTAssertEqual(history.sourceCardID, CaseSnapshotSourceIdentity.sourceCardID(
            for: updated.instances[0], context: context))
        XCTAssertEqual(publication.evidence.sourceCardID, binding.sourceCardID)
    }

    func testLifecycleCacheIsCurrentOnlyForPreparedDay() {
        let today = DateUtil.today
        var cache = CaseLifecyclePresentationCache()

        XCTAssertFalse(cache.isCurrent(for: today))
        cache.prepare(for: today, changedCaseKeys: nil)
        XCTAssertTrue(cache.isCurrent(for: today))
        XCTAssertFalse(cache.isCurrent(for: DateUtil.addDays(today, 1)))
    }
}
