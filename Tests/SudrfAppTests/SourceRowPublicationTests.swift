// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import XCTest
import SwiftData
import CaptchaSolver
import Foundation
@testable import SudrfKit
@testable import SudrfApp

private actor Source179Movement: MovementProviding {
    var value: CaseMovement
    init(_ value: CaseMovement) { self.value = value }
    func set(_ value: CaseMovement) { self.value = value }
    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement { value }
}
private struct Source179UnusedVSRF: VSRFProviding {
    func search(uniqueNumber: String?, oldCaseNumber: String?, keywords: String?) async throws -> VSRFSearchResults {
        XCTFail("Unexpected source lookup"); throw CancellationError()
    }
    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard {
        XCTFail("Unexpected source card lookup"); throw CancellationError()
    }
}

@MainActor
final class SourceRowPublicationTests: XCTestCase {
    private func context() -> MovementContext {
        MovementContext(branchRaw: CourtBranch.general.rawValue, region: "Тест",
            searchDomain: "test--region.sudrf.ru", displayDomain: "test--region.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "00RS0001", cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-179/2026", caseID: "source-179")
    }
    private func movement(root: [String], other: [String]? = nil,
                          rootKind: SourceOutcomeKind = .usableSnapshot,
                          otherKind: SourceOutcomeKind = .usableSnapshot,
                          date: String = "01.10.2026",
                          otherLevel: CaseInstance.Level = .cassation) throws -> CaseMovement {
        let ctx = context()
        let rootInstance = CaseInstance(level: .first, court: ctx.courtTitle,
            caseNumber: ctx.caseNumber, judge: "Судья A", domain: ctx.searchDomain,
            foundByUID: false, result: nil,
            sessions: root.map { CaseSession(date: date, event: $0) })
        let rootID = try XCTUnwrap(CaseEventSourceAdmission.nativeCardIdentity(for: rootInstance, context: ctx))
        var instances = [rootInstance]
        var coverage = [MovementCourtCoverage(sourceFamily: rootID.sourceFamily,
            courtKey: rootID.courtKey, kind: rootKind, loadedCardIdentities: [rootID])]
        if let other {
            let instance = CaseInstance(level: otherLevel, court: "Другой суд",
                caseNumber: "88-179/2026", judge: "Судья C", domain: "vsrf.ru",
                foundByUID: true, result: nil,
                sessions: other.map { CaseSession(date: date, event: $0) },
                sourceURL: URL(string: "https://vsrf.ru/lk/practice/cases/other-179"))
            let native = try XCTUnwrap(CaseEventSourceAdmission.nativeCardIdentity(for: instance, context: ctx))
            instances.append(instance)
            coverage.append(MovementCourtCoverage(sourceFamily: native.sourceFamily,
                courtKey: native.courtKey, kind: otherKind, loadedCardIdentities: [native]))
        }
        return CaseMovement(uid: "", caseNumber: ctx.caseNumber, inForce: false,
            instances: instances, complaints: [:], acts: [],
            incompleteHigherCourtDomains: rootKind == .usableSnapshot ? nil : [ctx.searchDomain],
            sourceRefreshCoverage: coverage)
    }
    private func refresh(_ store: TrackedStore, key: String, movement: CaseMovement,
                         defaults: UserDefaults) async {
        let center = RefreshCenter(store: store, client: TestNetworkGuard.sudrfClient(),
            captchaSettings: CaptchaSettings(defaults: defaults), captchaTokenStore: CaptchaTokenStore(),
            serviceBuilder: { _ in Source179Movement(movement) },
            treasuryDiscover: { _, _, _ in XCTFail("Unexpected treasury request"); throw CancellationError() },
            vsrfProvider: Source179UnusedVSRF(), fsspAutoModelEnabled: false,
            fsspDiscover: { _ in XCTFail("Unexpected FSSP request"); throw CancellationError() })
        let result = await center.refresh(key: key, manually: true)?.value
        XCTAssertNotNil(result)
    }
    private func fixture(_ body: @MainActor (URL, UserDefaults) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-179-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "Sudrf.Source179.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(directory.appendingPathComponent("fixture.store"), defaults)
    }
    private func makeRouter(container: ModelContainer, defaults: UserDefaults,
                            suite: String, directory: URL,
                            provider: Source179Movement,
                            notifications: @escaping @MainActor ([FeedEntry]) -> Void)
        throws -> (AppRouter, TrackedStore, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Source179NoNetwork.self]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config)
        let vsrf = Source179UnusedVSRF()
        let moscow = MosGorSudClient(session: session, minInterval: 0)
        var capturedStore: TrackedStore?
        let router = try AppRouter(captchaSettings: CaptchaSettings(defaults: defaults),
            modelContainer: container,
            captchaCorpus: CorpusStore(baseDir: directory.appendingPathComponent("corpus")),
            refreshCenterFactory: { store, client in
                capturedStore = store
                return RefreshCenter(store: store, client: client,
                    captchaSettings: CaptchaSettings(defaults: defaults),
                    captchaTokenStore: CaptchaTokenStore(),
                    serviceBuilder: { _ in provider },
                    treasuryDiscover: { document, number, court in
                        XCTFail("unexpected Treasury request"); throw CancellationError()
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
                writer: Source179NoSpotlight(), manifestStore: SpotlightManifestStore(suiteName: suite),
                preferenceStore: SpotlightPreferenceStore(suiteName: suite)) },
            currentEntityActivityPublisher: { _ in },
            feedNotificationPublisher: notifications,
            feedBadgePublisher: { _ in }, notificationOpenInstaller: { _ in }, intentInstaller: { _ in },
            captchaSolverFactory: { _ in nil },
            repairCoordinatorFactory: { store, client in TrackedCaseRepairCoordinator(
                store: store, client: client, originResolver: Source179NoOrigin(), defaults: defaults,
                anchorCardFetcher: { _ in XCTFail("unexpected repair request"); throw CancellationError() }) })
        return (router, try XCTUnwrap(capturedStore), session)
    }

    private func publications(_ store: TrackedStore, key: String) -> [CaseEvent] {
        store.record(forKey: key)?.eventJournal?.events.filter { $0.kind == .sourceRowPublished && $0.evidence.sourceRowBinding?.notificationEligible == true } ?? []
    }

    func testActualRouterExactMaterialDuplicatesKeepHistoryAndShareDisplayMarks() async throws {
        try await fixture { url, defaults in
            defaults.set(false, forKey: SpotlightPreferenceStore.key)
            defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            var value = try movement(root: [], other: ["Точная строка"], otherLevel: .material)
            value.instances[1].sessions.append(try XCTUnwrap(value.instances[1].sessions.first))
            let record = try store.upsert(context: context(),
                snapshot: MovementDerivation.snapshot(from: value, context: context()), movement: value, collections: [])
            let (router, routerStore, session) = try makeRouter(container: container, defaults: defaults,
                suite: "Sudrf.Source179.Duplicate.\(UUID())", directory: url.deletingLastPathComponent(),
                provider: Source179Movement(value), notifications: { _ in XCTFail("Initial duplicate alert") })
            defer { session.invalidateAndCancel() }
            let rows = router.feed.filter { $0.text == "Точная строка" }
            XCTAssertEqual(rows.count, 1)
            let entry = try XCTUnwrap(rows.first)
            let originals = try XCTUnwrap(record.eventJournal).events.filter {
                $0.evidence.legacyFeedHistory?.text == "Точная строка"
            }
            XCTAssertEqual(originals.count, 2, "Raw multiplicity stays archived")
            var state = try XCTUnwrap(record.eventJournal?.feedState)
            state.readEventIDs.insert(entry.id)
            state.knownEventIDs.subtract(originals.map(\.id))
            state.knownEventIDs.insert(try XCTUnwrap(originals.first { $0.id != entry.id }?.id))
            try routerStore.commit { try routerStore.appendCaseEvents([], to: record, feedState: state) }
            router.refreshCenter.onRefreshed?(record.key, value, [:])
            XCTAssertTrue(Set(originals.map(\.id)).isSubset(of: record.eventJournal?.feedState?.knownEventIDs ?? []),
                "One familiar member suppresses the duplicate display alert and mirrors the group")
            XCTAssertTrue(router.feed.first { $0.id == entry.id }?.isUnread == true, "Group read requires all members")
            router.openFeedEntry(try XCTUnwrap(router.feed.first { $0.id == entry.id }))
            XCTAssertTrue(Set(originals.map(\.id)).isSubset(of: record.eventJournal?.feedState?.readEventIDs ?? []))
            XCTAssertFalse(router.feed.first { $0.id == entry.id }?.isUnread ?? true)
            XCTAssertFalse(router.cases.first?.isNew ?? true)
            let reopened = try TrackedStore(container: SudrfModelContainerFactory.make(inMemory: false, storeURL: url), prepared: true)
            XCTAssertEqual(reopened.record(forKey: record.key)?.eventJournal?.events, record.eventJournal?.events)
            XCTAssertTrue(Set(originals.map(\.id)).isSubset(of: reopened.record(forKey: record.key)?.eventJournal?.feedState?.readEventIDs ?? []))
        }
    }

    func testAllUnmigratedMergeRetainsOneTimeOriginalFlatMarks() async throws {
        try await fixture { url, defaults in
            defaults.set(false, forKey: SpotlightPreferenceStore.key)
            defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let value = try movement(root: ["Исходная A"])
            let first = try store.upsert(context: context(),
                snapshot: MovementDerivation.snapshot(from: value, context: context()), movement: value, collections: [])
            var secondContext = context(); secondContext.caseNumber = "2-180/2026"; secondContext.caseID = "source-180"
            var secondValue = try movement(root: ["Исходная B"])
            secondValue.caseNumber = secondContext.caseNumber
            secondValue.instances[0].caseNumber = secondContext.caseNumber
            let second = try store.upsert(context: secondContext,
                snapshot: MovementDerivation.snapshot(from: secondValue, context: secondContext), movement: secondValue, collections: [])
            let original = try XCTUnwrap(second.eventJournal?.events.first { $0.evidence.legacyFeedHistory != nil })
            let flatID = try XCTUnwrap(original.evidence.legacyFeedHistory?.legacyID)
            defaults.set([flatID], forKey: "overviewReadFeedIDs.v1")
            XCTAssertNil(first.eventJournal?.feedState); XCTAssertNil(second.eventJournal?.feedState)
            _ = try TrackedCaseRepairCoordinator.atomicMerge(store: store, survivor: first,
                duplicates: [second], canonicalContext: context(), canonicalCard: nil)
            XCTAssertNil(first.eventJournal?.feedState, "Pre-cutover merge must leave original flat input available")
            let (router, _, session) = try makeRouter(container: container, defaults: defaults,
                suite: "Sudrf.Source179.AllNil.\(UUID())", directory: url.deletingLastPathComponent(),
                provider: Source179Movement(value), notifications: { _ in XCTFail("Historical notification") })
            defer { session.invalidateAndCancel() }
            XCTAssertFalse(router.feed.first { $0.id == original.id }?.isUnread ?? true)
            XCTAssertTrue(first.eventJournal?.feedState?.readEventIDs.contains(original.id) == true)
        }
    }

    func testActualRouterMergeBootstrapsReadIncomingWithoutAuthorityReceiptReplay() async throws {
        for incomingSeen in [false, true] {
            try await fixture { url, defaults in
                defaults.set(false, forKey: SpotlightPreferenceStore.key)
                defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let seed = try TrackedStore(container: container, prepared: true)
                let firstMovement = try movement(root: ["Непрочитанная A"])
                let first = try seed.upsert(context: context(),
                    snapshot: MovementDerivation.snapshot(from: firstMovement, context: context()), movement: firstMovement, collections: [])
                let (router, store, session) = try makeRouter(container: container, defaults: defaults,
                    suite: "Sudrf.Source179.NilMerge.\(UUID())", directory: url.deletingLastPathComponent(),
                    provider: Source179Movement(firstMovement), notifications: { _ in XCTFail("Incoming historical alert") })
                defer { session.invalidateAndCancel() }
                var incomingContext = context(); incomingContext.caseNumber = "2-180/2026"; incomingContext.caseID = "source-180"
                var incomingMovement = try movement(root: ["Прочитанная B"])
                incomingMovement.caseNumber = incomingContext.caseNumber
                incomingMovement.instances[0].caseNumber = incomingContext.caseNumber
                let incoming = try store.upsert(context: incomingContext,
                    snapshot: MovementDerivation.snapshot(from: incomingMovement, context: incomingContext), movement: incomingMovement, collections: [])
                let treasury = CaseEvent.make(kind: .treasuryRSSPublished, occurrence: ["nil-incoming-treasury"],
                    observedAt: DateUtil.today, evidence: .init(rssGUID: "own-incoming-guid"))
                try store.commit { try store.appendCaseEvents([treasury], to: incoming) }
                incoming.seenAt = incomingSeen ? DateUtil.today : nil; try store.save()
                var firstState = try XCTUnwrap(first.eventJournal?.feedState)
                let firstID = try XCTUnwrap(first.eventJournal?.events.first?.id)
                firstState.receipts = [.init(originRecordKey: first.key,
                    originalReadIDs: [firstID], originalKnownIDs: [firstID])]
                firstState.readEventIDs.remove(firstID)
                let originalReceipts = firstState.receipts
                try store.commit { try store.appendCaseEvents([], to: first, feedState: firstState) }
                XCTAssertNil(incoming.eventJournal?.feedState)
                let readID = try XCTUnwrap(incoming.eventJournal?.events.first { $0.evidence.legacyFeedHistory != nil }?.id)
                let remaps = try TrackedCaseRepairCoordinator.atomicMerge(store: store,
                    survivor: first, duplicates: [incoming], canonicalContext: context(), canonicalCard: nil)
                router.refreshCenter.onRefreshed?(first.key, try XCTUnwrap(first.movement), remaps)
                XCTAssertEqual(router.feed.first { $0.id == readID }?.isUnread, !incomingSeen)
                XCTAssertEqual(first.eventJournal?.feedState?.readEventIDs.contains(readID), incomingSeen)
                XCTAssertFalse(first.eventJournal?.feedState?.readEventIDs.contains(treasury.id) ?? true)
                XCTAssertFalse(first.eventJournal?.feedState?.readEventIDs.contains(firstID) ?? true)
                XCTAssertTrue(originalReceipts.allSatisfy { first.eventJournal?.feedState?.receipts.contains($0) == true })
                XCTAssertTrue(router.feed.first { $0.text == "Непрочитанная A" }?.isUnread == true)
                let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
                XCTAssertEqual(reopened.record(forKey: first.key)?.eventJournal?.feedState?.readEventIDs.contains(readID), incomingSeen)
        }
        }
    }

    func testActualRouterJournalMaterialActOpensItsOwnPublishedSourceAndBody() async throws {
        try await fixture { url, defaults in
            defaults.set(false, forKey: SpotlightPreferenceStore.key)
            defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let seed = try TrackedStore(container: container, prepared: true)
            var value = try movement(root: [], other: [], otherLevel: .material)
            let actURL = try XCTUnwrap(URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/34000179"))
            let act = CaseAct(id: "own-material-act-179", title: "Определение", date: "01.10.2026",
                courtShort: "Другой суд", instanceLevel: .material,
                sourceFileURL: actURL, productionNumber: value.instances[1].caseNumber)
            let decoyURL = try XCTUnwrap(URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/34000180"))
            let decoy = CaseAct(id: "base-act-decoy-179", title: "Решение", date: "02.10.2026",
                courtShort: context().courtTitle, instanceLevel: .first,
                sourceFileURL: decoyURL, productionNumber: context().caseNumber)
            value.instances[0].actIDs = [decoy.id]
            value.instances[1].actIDs = [act.id]
            value.acts = [decoy, act]
            value.actBodies = [decoy.id: "Другой текст основного производства",
                act.id: "Сохранённый текст собственного материала"]
            let owner = value.instances[1]
            let record = try seed.upsert(context: context(),
                snapshot: MovementDerivation.snapshot(from: value, context: context()), movement: value, collections: [])
            let (router, store, session) = try makeRouter(container: container, defaults: defaults,
                suite: "Sudrf.Source179.ActNavigation.\(UUID())", directory: url.deletingLastPathComponent(),
                provider: Source179Movement(value), notifications: { _ in XCTFail("Historical act alert") })
            defer { session.invalidateAndCancel() }
            let entry = try XCTUnwrap(router.feed.first { $0.actID == act.id })
            XCTAssertEqual(entry.sourceCardID, CaseSnapshotSourceIdentity.sourceCardID(for: owner, context: context()))
            XCTAssertEqual(entry.sourceInstanceID, owner.id)
            router.openFeedEntry(entry, preferAct: true)
            XCTAssertEqual(router.focusedMaterialInstanceID, owner.id)
            let selected = try XCTUnwrap(CourtActPresentation.row(for: try XCTUnwrap(router.selectedActID),
                in: try XCTUnwrap(router.liveMovement)))
            XCTAssertEqual(selected.sourceIDs, [act.id])
            XCTAssertFalse(selected.sourceIDs.contains(decoy.id))
            XCTAssertNotEqual(router.selectedActText, value.actBodies[decoy.id])
            XCTAssertNotEqual(selected.sourceFileURL, decoyURL)
            XCTAssertEqual(selected.sourceFileURL, actURL)
            XCTAssertEqual(router.selectedActText, value.actBodies[act.id])
            XCTAssertEqual(router.liveMovement?.instances.first { $0.id == owner.id }?.sourceURL, owner.sourceURL)
            XCTAssertTrue(store.record(forKey: record.key)?.eventJournal?.feedState?.readEventIDs.contains(entry.id) == true)
            XCTAssertFalse(router.feed.first { $0.id == entry.id }?.isUnread ?? true)
            let reopened = try TrackedStore(container: SudrfModelContainerFactory.make(inMemory: false, storeURL: url), prepared: true)
            XCTAssertTrue(reopened.record(forKey: record.key)?.eventJournal?.feedState?.readEventIDs.contains(entry.id) == true)
        }
    }

    func testActualRouterJournalMaterialRowOpensItsOwnExactSource() async throws {
        try await fixture { url, defaults in
            defaults.set(false, forKey: SpotlightPreferenceStore.key)
            defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let seed = try TrackedStore(container: container, prepared: true)
            let value = try movement(root: [], other: [], otherLevel: .material)
            let owner = value.instances[1]
            let record = try seed.upsert(context: context(),
                snapshot: MovementDerivation.snapshot(from: value, context: context()), movement: value, collections: [])
            let source = try XCTUnwrap(CaseSnapshotSourceIdentity.sourceCardID(for: owner, context: context()))
            let event = CaseEvent.make(kind: .instanceDiscovered, occurrence: ["own-material", source],
                observedAt: DateUtil.today, evidence: .init(sourceCardID: source,
                    instanceLevelRaw: owner.level.rawValue, caseNumber: owner.caseNumber))
            try seed.commit { try seed.appendCaseEvents([event], to: record) }
            let (router, store, session) = try makeRouter(container: container, defaults: defaults,
                suite: "Sudrf.Source179.Navigation.\(UUID())", directory: url.deletingLastPathComponent(),
                provider: Source179Movement(value), notifications: { _ in XCTFail("Initial semantic notification") })
            defer { session.invalidateAndCancel() }
            let entry = try XCTUnwrap(router.feed.first { $0.text.hasPrefix("Новое производство:") })
            XCTAssertEqual(entry.sourceCardID, source)
            XCTAssertEqual(entry.sourceInstanceID, owner.id)
            router.openFeedEntry(entry)
            XCTAssertEqual(router.focusedMaterialInstanceID, owner.id)
            XCTAssertEqual(router.liveMovement?.instances.first { $0.id == owner.id }?.sourceURL, owner.sourceURL)
            XCTAssertEqual(router.openedCase, record.caseNumber)
            XCTAssertTrue(store.record(forKey: record.key)?.eventJournal?.feedState?.readEventIDs.contains(entry.id) == true)
            XCTAssertFalse(router.feed.first { $0.id == entry.id }?.isUnread ?? true)
        }
    }

    func testActualRouterMergedAuthorityNotifierRollbackAndRestart() async throws {
        try await fixture { url, defaults in
            defaults.set(false, forKey: SpotlightPreferenceStore.key)
            defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let seed = try TrackedStore(container: container, prepared: true)
            let firstMovement = try movement(root: ["Старая строка A"])
            let first = try seed.upsert(context: context(),
                snapshot: MovementDerivation.snapshot(from: firstMovement, context: context()),
                movement: firstMovement, collections: ["Первая"])
            var secondContext = context(); secondContext.caseNumber = "2-180/2026"; secondContext.caseID = "source-180"
            var secondMovement = try movement(root: ["Старая строка B"])
            secondMovement.caseNumber = secondContext.caseNumber
            secondMovement.instances[0].caseNumber = secondContext.caseNumber
            let second = try seed.upsert(context: secondContext,
                snapshot: MovementDerivation.snapshot(from: secondMovement, context: secondContext),
                movement: secondMovement, collections: ["Вторая"])
            let firstKey = first.key, secondKey = second.key
            var batches = [[FeedEntry]]()
            let provider = Source179Movement(firstMovement)
            let (router, store, session) = try makeRouter(container: container, defaults: defaults,
                suite: "Sudrf.Source179.Merge.\(UUID())", directory: url.deletingLastPathComponent(),
                provider: provider, notifications: { batches.append($0) })
            defer { session.invalidateAndCancel() }
            router.markAllFeedRead()
            let originals = [first.eventJournalData, second.eventJournalData]
            let read = try XCTUnwrap(first.eventJournal?.feedState).readEventIDs
                .union(try XCTUnwrap(second.eventJournal?.feedState).readEventIDs)
            store.failNextSaveForTesting = true
            XCTAssertThrowsError(try TrackedCaseRepairCoordinator.atomicMerge(store: store,
                survivor: first, duplicates: [second], canonicalContext: context(), canonicalCard: nil))
            XCTAssertEqual([first.eventJournalData, second.eventJournalData], originals)
            XCTAssertEqual(store.all().count, 2)
            XCTAssertFalse(container.mainContext.hasChanges)
            let remaps = try TrackedCaseRepairCoordinator.atomicMerge(store: store,
                survivor: first, duplicates: [second], canonicalContext: context(), canonicalCard: nil)
            XCTAssertEqual(remaps[secondKey], firstKey)
            router.refreshCenter.onRefreshed?(firstKey, try XCTUnwrap(first.movement), remaps)
            XCTAssertTrue(batches.isEmpty, "Merging known history does not emit a new notification")
            XCTAssertTrue(router.feed.allSatisfy { !$0.isUnread })
            XCTAssertEqual(first.eventJournal?.feedState?.readEventIDs, read)
            XCTAssertEqual(first.eventJournal?.feedState?.receipts.count, 2)
            XCTAssertEqual(Set(router.feed.map(\.text)), ["Старая строка A", "Старая строка B"])
            let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let (reopened, persisted, reopenedSession) = try makeRouter(container: reopenedContainer, defaults: defaults,
                suite: "Sudrf.Source179.MergeRestart.\(UUID())", directory: url.deletingLastPathComponent(),
                provider: provider, notifications: { batches.append($0) })
            defer { reopenedSession.invalidateAndCancel() }
            XCTAssertEqual(persisted.all().count, 1)
            XCTAssertTrue(reopened.feed.allSatisfy { !$0.isUnread })
            XCTAssertTrue(batches.isEmpty)
            XCTAssertEqual(persisted.record(forKey: firstKey)?.eventJournal?.feedState?.readEventIDs, read)
        }
    }

    func testActualRouterPendingMaterialAdmissionAndReadResetAcrossRestart() async throws {
        for resetRead in [false, true] {
            try await fixture { url, defaults in
                defaults.set(false, forKey: SpotlightPreferenceStore.key)
                defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
                let complete = try movement(root: [], other: ["Принято"], otherLevel: .material)
                var snapshot = MovementDerivation.snapshot(from: complete, context: context())
                for index in snapshot.sessions.indices { snapshot.sessions[index].sourceCardID = nil }
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let seed = try TrackedStore(container: container, prepared: true)
                let key = try seed.upsert(context: context(), snapshot: snapshot, movement: complete, collections: []).key
                let base = AppRouter.feedID(recordKey: key, date: try XCTUnwrap(DateUtil.parse("01.10.2026")),
                    time: "—", text: "Принято")
                defaults.set([base], forKey: "overviewReadFeedIDs.v1")
                defaults.set([base], forKey: "notifiedFeedIDs.v1")
                let partial = try movement(root: [], other: ["Принято"], otherKind: .partial, otherLevel: .material)
                let provider = Source179Movement(partial)
                let suite = "Sudrf.Source179.Material.\(UUID())"
                let (router, store, session) = try makeRouter(container: container, defaults: defaults,
                    suite: suite, directory: url.deletingLastPathComponent(),
                    provider: provider, notifications: { _ in XCTFail("Historical material alert") })
                defer { session.invalidateAndCancel() }
                let record = try XCTUnwrap(store.record(forKey: key))
                XCTAssertEqual(record.eventJournal?.feedState?.materialMigrationState.pendingUnresolvedCounts[base], 1)
                let oldArchive = record.eventJournal?.events.filter {
                    $0.kind == .legacyFeedImported
                        && $0.evidence.legacyFeedHistory?.legacyID == base
                } ?? []
                XCTAssertEqual(oldArchive.count, 1)
                @MainActor func assertSingleMaterialRow(in current: AppRouter, stage: String) -> FeedEntry? {
                    let rows = current.feed.filter { $0.recordKey == key && $0.text == "Принято" }
                    XCTAssertEqual(rows.count, 1, "\(stage): a material must have one feed row")
                    return rows.first
                }
                _ = assertSingleMaterialRow(in: router, stage: "Before partial refresh")
                if resetRead {
                    var state = try XCTUnwrap(record.eventJournal?.feedState)
                    state.readEventIDs.removeAll()
                    try store.commit { try store.appendCaseEvents([], to: record, feedState: state) }
                }
                await router.refreshCenter.refresh(key: key, manually: true)?.value
                let partialRow = assertSingleMaterialRow(in: router, stage: "After partial refresh")
                XCTAssertEqual(partialRow?.isUnread, resetRead)
                XCTAssertFalse(record.eventJournal?.events.contains { $0.kind == .sourceRowPublished } ?? true)
                XCTAssertEqual(record.eventJournal?.events.filter {
                    $0.kind == .legacyFeedImported && $0.evidence.legacyFeedHistory?.legacyID == base
                }, oldArchive, "Partial refresh must preserve the immutable original archive")
                await provider.set(complete)
                await router.refreshCenter.refresh(key: key, manually: true)?.value
                let publicationEvents = record.eventJournal?.events.filter { $0.kind == .sourceRowPublished } ?? []
                XCTAssertEqual(publicationEvents.count, 1)
                let publication = try XCTUnwrap(publicationEvents.first)
                let freshSourceID = try XCTUnwrap(CaseSnapshotSourceIdentity.sourceCardID(
                    for: try XCTUnwrap(complete.instances.first { $0.level == .material }), context: context()))
                XCTAssertEqual(publication.evidence.sourceCardID, freshSourceID)
                XCTAssertEqual(publication.evidence.sourceRowBinding?.sourceCardID, freshSourceID)
                XCTAssertEqual(record.eventJournal?.feedState?.readEventIDs.contains(publication.id), !resetRead)
                XCTAssertTrue(record.eventJournal?.feedState?.materialMigrationState.consumedLegacyIDs.contains(base) == true)
                let fullRow = assertSingleMaterialRow(in: router, stage: "After full refresh")
                XCTAssertEqual(fullRow?.sourceCardID, freshSourceID)
                XCTAssertEqual(fullRow?.isUnread, resetRead)
                let fullState = try XCTUnwrap(record.eventJournal?.feedState)
                XCTAssertTrue(fullState.knownEventIDs.contains(publication.id))
                XCTAssertEqual(record.eventJournal?.events.filter {
                    $0.kind == .legacyFeedImported && $0.evidence.legacyFeedHistory?.legacyID == base
                }, oldArchive, "Full refresh must preserve the immutable original archive")
                let readAfterFull = fullState.readEventIDs
                let knownAfterFull = fullState.knownEventIDs
                let bytes = record.eventJournalData
                await router.refreshCenter.refresh(key: key, manually: true)?.value
                XCTAssertEqual(record.eventJournalData, bytes)
                _ = assertSingleMaterialRow(in: router, stage: "After repeat full refresh")
                XCTAssertEqual(record.eventJournal?.feedState?.readEventIDs, readAfterFull)
                XCTAssertEqual(record.eventJournal?.feedState?.knownEventIDs, knownAfterFull)
                XCTAssertEqual(record.eventJournal?.events.filter {
                    $0.kind == .legacyFeedImported && $0.evidence.legacyFeedHistory?.legacyID == base
                }, oldArchive, "Repeated refresh must preserve the immutable original archive")

                let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let (reopened, persisted, reopenedSession) = try makeRouter(container: reopenedContainer,
                    defaults: defaults, suite: suite, directory: url.deletingLastPathComponent(),
                    provider: Source179Movement(complete),
                    notifications: { _ in XCTFail("Restart must not replay a historical material alert") })
                defer { reopenedSession.invalidateAndCancel() }
                let reopenedRecord = try XCTUnwrap(persisted.record(forKey: key))
                let reopenedRow = assertSingleMaterialRow(in: reopened, stage: "After restart")
                XCTAssertEqual(reopenedRow?.sourceCardID, freshSourceID)
                XCTAssertEqual(reopenedRow?.isUnread, resetRead)
                XCTAssertEqual(reopenedRecord.eventJournal?.feedState?.readEventIDs, readAfterFull)
                XCTAssertEqual(reopenedRecord.eventJournal?.feedState?.knownEventIDs, knownAfterFull)
                var cleared = try XCTUnwrap(reopenedRecord.eventJournal?.feedState)
                cleared.readEventIDs.remove(publication.id)
                try persisted.commit { try persisted.appendCaseEvents([], to: reopenedRecord, feedState: cleared) }
                await reopened.refreshCenter.refresh(key: key, manually: true)?.value
                XCTAssertTrue(assertSingleMaterialRow(in: reopened, stage: "After fresh read reset")?.isUnread == true)
                XCTAssertTrue(reopened.cases.first { $0.recordKey == key }?.isNew == true)
                let resetContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let (resetRouter, _, resetSession) = try makeRouter(container: resetContainer,
                    defaults: defaults, suite: suite, directory: url.deletingLastPathComponent(),
                    provider: Source179Movement(complete),
                    notifications: { _ in XCTFail("Read reset must not replay a historical alert") })
                defer { resetSession.invalidateAndCancel() }
                let resetRow = try XCTUnwrap(assertSingleMaterialRow(in: resetRouter, stage: "Fresh read reset after restart"))
                XCTAssertTrue(resetRow.isUnread)
                resetRouter.openFeedEntry(resetRow)
                XCTAssertFalse(resetRouter.cases.first { $0.recordKey == key }?.isNew ?? true,
                    "Reading the current publication clears its badge despite immutable unread original")
                XCTAssertEqual(reopenedRecord.eventJournal?.events.filter {
                    $0.kind == .legacyFeedImported && $0.evidence.legacyFeedHistory?.legacyID == base
                }, oldArchive, "Restart must preserve the immutable original archive")
            }
        }
    }

    func testActualRouterCaseBadgeKeepsUnreadHistoryOutsideFeedWindow() async throws {
        try await fixture { url, defaults in
            defaults.set(false, forKey: SpotlightPreferenceStore.key)
            defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
            let old = try movement(root: ["История вне окна"], date: "01.01.2026")
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let key = try store.upsert(context: context(),
                snapshot: MovementDerivation.snapshot(from: old, context: context()),
                movement: old, collections: []).key
            let (router, _, session) = try makeRouter(container: container, defaults: defaults,
                suite: "Sudrf.Source179.OldWindow.\(UUID())", directory: url.deletingLastPathComponent(),
                provider: Source179Movement(old), notifications: { _ in XCTFail("Historical alert") })
            defer { session.invalidateAndCancel() }
            XCTAssertTrue(router.feed.isEmpty)
            XCTAssertEqual(router.newBadge, 1)
            XCTAssertTrue(router.cases.first { $0.recordKey == key }?.isNew == true)
            XCTAssertTrue(router.cases.first { $0.recordKey == key }?.newDot == true)
        }
    }

    func testActualRouterFeedAdmissionNotifierAndDurableReadAcrossRestart() async throws {
        try await fixture { url, defaults in
            let suite = "Sudrf.Source179.Router.\(UUID())"
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(false, forKey: SpotlightPreferenceStore.key)
            defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
            let initial = try movement(root: ["Историческая строка A"])
            var key = ""
            do {
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let store = try TrackedStore(container: container, prepared: true)
                key = try store.upsert(context: context(),
                    snapshot: MovementDerivation.snapshot(from: initial, context: context()),
                    movement: initial, collections: []).key
            }
            let historicalID = AppRouter.feedID(recordKey: key,
                date: try XCTUnwrap(DateUtil.parse("01.10.2026")), time: "—", text: "Историческая строка A")
            defaults.set([historicalID], forKey: "overviewReadFeedIDs.v1")
            defaults.set([historicalID], forKey: "notifiedFeedIDs.v1")
            let provider = Source179Movement(initial)
            var batches = [[FeedEntry]]()
            do {
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let (router, store, session) = try makeRouter(container: container, defaults: defaults,
                    suite: suite, directory: url.deletingLastPathComponent(), provider: provider,
                    notifications: { batches.append($0) })
                defer { session.invalidateAndCancel() }
                XCTAssertTrue(batches.isEmpty)
                XCTAssertFalse(router.cases.first { $0.recordKey == key }?.isNew ?? true)
                XCTAssertFalse(router.cases.first { $0.recordKey == key }?.newDot ?? true)
                XCTAssertEqual(router.newBadge, 0)
                await router.refreshCenter.refresh(key: key, manually: true)?.value
                XCTAssertTrue(batches.isEmpty)
                await provider.set(try movement(root: ["Историческая строка A", "Новая строка B"], rootKind: .partial))
                await router.refreshCenter.refresh(key: key, manually: true)?.value
                XCTAssertTrue(batches.isEmpty)
                XCTAssertFalse(router.feed.contains { $0.text == "Новая строка B" })
                XCTAssertEqual(router.newBadge, 0)
                await provider.set(try movement(root: ["Историческая строка A", "Новая строка B"]))
                await router.refreshCenter.refresh(key: key, manually: true)?.value
                XCTAssertEqual(batches.count, 1)
                XCTAssertEqual(batches.first?.map(\.text), ["Новая строка B"])
                let eventID = try XCTUnwrap(router.feed.first { $0.text == "Новая строка B" }?.id)
                router.markAllFeedRead()
                XCTAssertFalse(router.cases.first { $0.recordKey == key }?.isNew ?? true)
                XCTAssertFalse(router.cases.first { $0.recordKey == key }?.newDot ?? true)
                XCTAssertEqual(router.newBadge, 0)
                XCTAssertTrue(store.record(forKey: key)?.eventJournal?.feedState?.readEventIDs.contains(eventID) == true)
            }
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let (router, _, session) = try makeRouter(container: container, defaults: defaults,
                suite: suite, directory: url.deletingLastPathComponent(), provider: provider,
                notifications: { batches.append($0) })
            defer { session.invalidateAndCancel() }
            XCTAssertEqual(router.feed.first { $0.text == "Новая строка B" }?.isUnread, false)
            await router.refreshCenter.refresh(key: key, manually: true)?.value
            XCTAssertEqual(batches.count, 1)
        }
    }

    func testFreshPartialRowsWaitForAdmissionThenPublishOnceAcrossRestart() async throws {
        try await fixture { url, defaults in
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let initial = try movement(root: ["Историческая строка A"])
            let record = try store.upsert(context: context(),
                snapshot: MovementDerivation.snapshot(from: initial, context: context()),
                movement: initial, collections: [])
            let key = record.key
            await refresh(store, key: key, movement: initial, defaults: defaults)
            XCTAssertEqual(publications(store, key: key).count, 0)
            XCTAssertEqual(record.eventJournal?.events.filter { $0.kind == .legacyFeedImported }.count, 1)
            let partial = try movement(root: ["Историческая строка A", "Новая опубликованная строка B"], rootKind: .partial)
            await refresh(store, key: key, movement: partial, defaults: defaults)
            XCTAssertEqual(publications(store, key: key).count, 0)
            XCTAssertTrue(record.snapshot?.sessions.contains { $0.event == "Новая опубликованная строка B" } == true)
            let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
            let complete = try movement(root: ["Историческая строка A", "Новая опубликованная строка B"])
            await refresh(reopened, key: key, movement: complete, defaults: defaults)
            let event = try XCTUnwrap(publications(reopened, key: key).first)
            XCTAssertEqual(publications(reopened, key: key).count, 1)
            XCTAssertEqual(event.evidence.legacyFeedHistory?.text, "Новая опубликованная строка B")
            XCTAssertNotNil(event.evidence.sourceRowBinding)
            let originalBytes = reopened.record(forKey: key)?.eventJournalData
            await refresh(reopened, key: key, movement: complete, defaults: defaults)
            XCTAssertEqual(publications(reopened, key: key), [event])
            XCTAssertEqual(reopened.record(forKey: key)?.eventJournalData, originalBytes)
            let third = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let final = try TrackedStore(container: third, prepared: true)
            XCTAssertEqual(publications(final, key: key), [event])
        }
    }

    func testRealRescheduleCommitsExactBindingAndSurvivesRowsDisappearing() async throws {
        try await fixture { url, defaults in
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.upsert(context: context(), snapshot: nil, collections: [])
            try store.commit {
                try store.ensureLegacyFeedHistory(for: record)
                try store.appendCaseEvents([], to: record, feedState: JournalFeedState.initial(
                    recordKey: record.key, journal: try store.requiredEventJournal(for: record),
                    legacyReadIDs: [], legacyKnownIDs: []))
            }
            var initial = try movement(root: ["Судебное заседание"])
            initial.instances[0].sessions[0].time = "10:00"
            await refresh(store, key: record.key, movement: initial, defaults: defaults)
            var rescheduled = initial
            rescheduled.instances[0].sessions[0].result = "Заседание отложено"
            rescheduled.instances[0].sessions.append(CaseSession(date: "02.10.2026",
                time: "11:00", event: "Судебное заседание"))
            await refresh(store, key: record.key, movement: rescheduled, defaults: defaults)
            let journal = try store.requiredEventJournal(for: record)
            let event = try XCTUnwrap(journal.events.first { $0.kind == .hearingRescheduled })
            let binding = try XCTUnwrap(journal.feedState?.bindings.first { $0.eventID == event.id })
            XCTAssertEqual(binding.historyEventIDs.count, 2)
            XCTAssertEqual(binding.legacyIDs.count, 2)
            let input = LegacyFeedRecordInput(recordKey: record.key, caseNumber: record.caseNumber,
                client: record.courtTitle, unreadByCase: true, snapshot: record.snapshot,
                movement: record.movement, context: record.context, enforcementRecords: [])
            let rows = JournalFeedProjection.entries(record: input, journal: journal,
                today: try XCTUnwrap(DateUtil.parse("10.10.2026")))
            XCTAssertEqual(rows.filter { $0.id == event.id }.count, 1)
            XCTAssertFalse(rows.contains { binding.historyEventIDs.contains($0.id) })
            await refresh(store, key: record.key, movement: try movement(root: []), defaults: defaults)
            let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
            let saved = try XCTUnwrap(reopened.record(forKey: record.key))
            XCTAssertEqual(saved.eventJournal?.feedState?.bindings.first { $0.eventID == event.id }, binding)
            let vanished = LegacyFeedRecordInput(recordKey: saved.key, caseNumber: saved.caseNumber,
                client: saved.courtTitle, unreadByCase: true, snapshot: saved.snapshot,
                movement: saved.movement, context: saved.context, enforcementRecords: [])
            let durable = JournalFeedProjection.entries(record: vanished,
                journal: try reopened.requiredEventJournal(for: saved),
                today: try XCTUnwrap(DateUtil.parse("10.10.2026")))
            XCTAssertEqual(durable.first { $0.id == event.id }?.text, rows.first { $0.id == event.id }?.text)
            XCTAssertEqual(durable.first { $0.id == event.id }?.date, rows.first { $0.id == event.id }?.date)
        }
    }

    func testExactHostRepairContinuityKeepsAbsentPublicationIdentityAfterRestart() async throws {
        try await fixture { url, defaults in
            let uid = "11RS0001-01-2026-000179-11"
            var originalContext = context()
            originalContext.judicialUID = uid
            originalContext.receiptDate = "01.09.2026"
            originalContext.caseUID = "source-179-guid"
            func source(_ host: String, rows: [String], found: Bool, receipt: String) -> CaseInstance {
                CaseInstance(level: .first, court: host, caseNumber: originalContext.caseNumber,
                    judge: "Судья A", domain: host, foundByUID: found, result: nil,
                    sessions: rows.map { CaseSession(date: "01.10.2026", event: $0) },
                    sourceURL: URL(string: "https://\(host)/modules.php?name=sud_delo&name_op=case&srv_num=1&delo_id=1540005&new=0&case_id=source-179&case_uid=source-179-guid"),
                    sourceEvidence: .init(receiptDate: receipt, judicialUID: uid,
                        cartotekaID: "g1", sourceCourtLevel: .district, sourceBranch: .general))
            }
            func response(_ instances: [CaseInstance], admitted: CaseInstance) throws -> CaseMovement {
                let identity = try XCTUnwrap(CaseEventSourceAdmission.nativeCardIdentity(
                    for: admitted, context: originalContext))
                return CaseMovement(uid: uid, caseNumber: originalContext.caseNumber, inForce: false,
                    instances: instances, complaints: [:], acts: [],
                    sourceRefreshCoverage: [MovementCourtCoverage(sourceFamily: identity.sourceFamily,
                        courtKey: identity.courtKey, kind: .usableSnapshot, loadedCardIdentities: [identity])])
            }
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.upsert(context: originalContext, snapshot: nil, collections: [])
            let first = source(originalContext.searchDomain, rows: ["A"], found: false, receipt: "01.09.2026")
            await refresh(store, key: record.key, movement: try response([first], admitted: first), defaults: defaults)
            let withB = source(originalContext.searchDomain, rows: ["A", "B"], found: false, receipt: "01.09.2026")
            await refresh(store, key: record.key, movement: try response([withB], admitted: withB), defaults: defaults)
            let original = try XCTUnwrap(publications(store, key: record.key).first)
            let absent = source(originalContext.searchDomain, rows: ["A"], found: false, receipt: "01.09.2026")
            await refresh(store, key: record.key, movement: try response([absent], admitted: absent), defaults: defaults)
            let canonical = source("canonical--region.sudrf.ru", rows: ["A"], found: true, receipt: "02.09.2026")
            // The native identity is proven by the same register/card/UID, with
            // a later published registration and exact canonical card URL.
            var repaired = try response([absent, canonical], admitted: canonical)
            let cart = try XCTUnwrap(originalContext.cartoteka)
            let native = try XCTUnwrap(SourceNativeCardLocator.sudrf(url: try XCTUnwrap(canonical.sourceURL), cartoteka: cart)).identity
            repaired.sourceRefreshCoverage = [MovementCourtCoverage(sourceFamily: native.sourceFamily,
                courtKey: native.courtKey, kind: .usableSnapshot, loadedCardIdentities: [native])]
            await refresh(store, key: record.key, movement: repaired, defaults: defaults)
            let survivor = try XCTUnwrap(store.all().first)
            XCTAssertEqual(survivor.context?.searchDomain, canonical.domain)
            XCTAssertFalse(survivor.eventJournal?.sourceRowContinuities?.isEmpty ?? true)
            let survivorKey = survivor.key
            let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
            let returned = source(canonical.domain, rows: ["A", "B"], found: true, receipt: "02.09.2026")
            var final = try response([returned], admitted: returned)
            final.sourceRefreshCoverage = repaired.sourceRefreshCoverage
            await refresh(reopened, key: survivorKey, movement: final, defaults: defaults)
            XCTAssertEqual(publications(reopened, key: survivorKey), [original])
        }
    }

    func testPublishedBindingsSurviveDisappearanceAndMutableJudgeMetadata() async throws {
        try await fixture { url, defaults in
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.upsert(context: context(), snapshot: nil, collections: [])
            await refresh(store, key: record.key, movement: try movement(root: ["A"]), defaults: defaults)
            let quiet = record.eventJournal?.events.filter {
                $0.kind == .sourceRowPublished && $0.evidence.sourceRowBinding?.notificationEligible == false
            } ?? []
            XCTAssertEqual(quiet.compactMap { $0.evidence.legacyFeedHistory?.text }, ["A"])
            let added = try movement(root: ["A", "B"])
            await refresh(store, key: record.key, movement: added, defaults: defaults)
            let accepted = publications(store, key: record.key)
            XCTAssertEqual(accepted.count, 1)
            await refresh(store, key: record.key, movement: try movement(root: ["A"]), defaults: defaults)
            var revised = added
            revised.instances[0].judge = "Судья после публикации"
            await refresh(store, key: record.key, movement: revised, defaults: defaults)
            XCTAssertEqual(publications(store, key: record.key), accepted)
            XCTAssertTrue(record.eventJournal?.events.contains { $0.id == quiet.first?.id } == true)
            if case .session(let original)? = accepted.first?.evidence.legacyFeedHistory?.source {
                XCTAssertEqual(original.judge, "Судья A")
            } else { XCTFail("Expected immutable original session") }
        }
    }

    func testEqualLegacyRowIDsFromIndependentCourtsKeepBothExactBindings() async throws {
        try await fixture { url, defaults in
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.upsert(context: context(), snapshot: nil, collections: [])
            await refresh(store, key: record.key, movement: try movement(root: ["A"], other: ["C"]), defaults: defaults)
            let fresh = try movement(root: ["A", "Одинаковый опубликованный текст"],
                                     other: ["C", "Одинаковый опубликованный текст"])
            await refresh(store, key: record.key, movement: fresh, defaults: defaults)
            let accepted = publications(store, key: record.key)
            XCTAssertEqual(accepted.count, 2)
            XCTAssertEqual(Set(accepted.map(\.id)).count, 2)
            XCTAssertEqual(Set(accepted.compactMap { $0.evidence.legacyFeedHistory?.legacyID }).count, 1)
            XCTAssertEqual(Set(accepted.compactMap { $0.evidence.sourceRowBinding?.nativeCardID }).count, 2)
            let legacyID = try XCTUnwrap(accepted.first?.evidence.legacyFeedHistory?.legacyID)
            let input = LegacyFeedRecordInput(recordKey: record.key, caseNumber: record.caseNumber,
                client: record.courtTitle, unreadByCase: true, snapshot: record.snapshot,
                movement: record.movement, context: record.context, enforcementRecords: [])
            let oldRenderer = LegacyFeedProjection.project(records: [input],
                today: try XCTUnwrap(DateUtil.parse("10.10.2026")), readIDs: [legacyID],
                knownIDs: [legacyID], migrationState: MaterialFeedMigrationState())
            let oldMarkedRows = oldRenderer.entries.filter { $0.id == legacyID }
            XCTAssertEqual(oldMarkedRows.count, 2)
            XCTAssertTrue(oldMarkedRows.allSatisfy { !$0.isUnread })
            let migrated = JournalFeedState.initial(recordKey: record.key,
                journal: try store.requiredEventJournal(for: record),
                legacyReadIDs: [legacyID], legacyKnownIDs: [legacyID])
            XCTAssertTrue(Set(accepted.map(\.id)).isSubset(of: migrated.readEventIDs))
            XCTAssertTrue(Set(accepted.map(\.id)).isSubset(of: migrated.knownEventIDs))
            try store.commit {
                try store.ensureLegacyFeedHistory(for: record)
                try store.appendCaseEvents([], to: record, feedState: migrated)
            }
            let markedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let markedStore = try TrackedStore(container: markedContainer, prepared: true)
            let savedMarks = try XCTUnwrap(markedStore.record(forKey: record.key)?.eventJournal?.feedState)
            XCTAssertEqual(savedMarks.readEventIDs, migrated.readEventIDs)
            XCTAssertEqual(savedMarks.knownEventIDs, migrated.knownEventIDs)
            await refresh(store, key: record.key, movement: fresh, defaults: defaults)
            XCTAssertEqual(publications(store, key: record.key), accepted)
        }
    }

    func testFailedPublicationAppendRestoresSourceAndBaselineThenRetryPublishes() async throws {
        try await fixture { url, defaults in
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.upsert(context: context(), snapshot: nil, collections: [])
            await refresh(store, key: record.key, movement: try movement(root: ["A"]), defaults: defaults)
            let originalJournal = record.eventJournalData
            let originalSnapshot = record.snapshotData
            let fresh = try movement(root: ["A", "B"])
            store.failNextJournalAppendForTesting = true
            await refresh(store, key: record.key, movement: fresh, defaults: defaults)
            XCTAssertEqual(record.eventJournalData, originalJournal)
            XCTAssertEqual(record.snapshotData, originalSnapshot)
            XCTAssertEqual(publications(store, key: record.key).count, 0)
            XCTAssertFalse(container.mainContext.hasChanges)
            let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
            XCTAssertEqual(reopened.record(forKey: record.key)?.eventJournalData, originalJournal)
            await refresh(reopened, key: record.key, movement: fresh, defaults: defaults)
            XCTAssertEqual(publications(reopened, key: record.key).count, 1)
        }
    }

    func testConfirmedOtherCourtPublishesWhileRootIsPartialAndMultiplicitySurvives() async throws {
        try await fixture { url, defaults in
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let initial = try movement(root: ["A"], other: ["C"])
            let record = try store.upsert(context: context(), snapshot: nil, collections: [])
            await refresh(store, key: record.key, movement: initial, defaults: defaults)
            let mixed = try movement(root: ["A", "B"], other: ["C", "D", "D"], rootKind: .partial)
            await refresh(store, key: record.key, movement: mixed, defaults: defaults)
            let accepted = publications(store, key: record.key)
            XCTAssertEqual(accepted.count, 2)
            XCTAssertEqual(accepted.compactMap { $0.evidence.legacyFeedHistory?.text }, ["D", "D"])
            XCTAssertEqual(Set(accepted.compactMap { $0.evidence.sourceRowBinding?.ordinal }), [0, 1])
            XCTAssertEqual(Set(accepted.map(\.id)).count, 2)
            await refresh(store, key: record.key, movement: mixed, defaults: defaults)
            XCTAssertEqual(publications(store, key: record.key), accepted)
            let complete = try movement(root: ["A", "B"], other: ["C", "D", "D"])
            await refresh(store, key: record.key, movement: complete, defaults: defaults)
            XCTAssertEqual(publications(store, key: record.key).count, 3)
            XCTAssertEqual(publications(store, key: record.key).filter {
                $0.evidence.legacyFeedHistory?.text == "B"
            }.count, 1)
        }
    }
}

private struct Source179NoOrigin: CaseOriginResolving {
    func resolve(anchorContext: MovementContext, anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        XCTFail("unexpected origin lookup")
        throw CancellationError()
    }
}

private actor Source179NoSpotlight: SpotlightIndexWriting {
    func index(cases: [CaseEntity], acts: [CourtActEntity]) async throws { XCTFail("unexpected indexing") }
    func delete(caseIDs: [String], actIDs: [String]) async throws { XCTFail("unexpected index deletion") }
    func deleteAll() async throws { XCTFail("unexpected index deletion") }
}

private final class Source179NoNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Unexpected network request in private journal runtime fixture")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
