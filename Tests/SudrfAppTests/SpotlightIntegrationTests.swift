import CoreSpotlight
import SudrfKit
import XCTest
@testable import SudrfApp

private actor RecordingSpotlightWriter: SpotlightIndexWriting {
    struct State: Sendable {
        var indexedCaseIDs: [String] = []
        var indexedActIDs: [String] = []
        var deletedCaseIDs: [String] = []
        var deletedActIDs: [String] = []
        var deleteAllCount = 0
        var currentCaseIDs = Set<String>()
        var currentActIDs = Set<String>()
        var indexedActUIDs: [String] = []
    }

    private var state = State()

    func index(cases: [CaseEntity], acts: [CourtActEntity]) {
        state.indexedCaseIDs += cases.map(\.id)
        state.indexedActIDs += acts.map(\.id)
        state.indexedActUIDs += acts.map { $0.document.judicialUID ?? "" }
        state.currentCaseIDs.formUnion(cases.map(\.id))
        state.currentActIDs.formUnion(acts.map(\.id))
    }

    func delete(caseIDs: [String], actIDs: [String]) {
        state.deletedCaseIDs += caseIDs
        state.deletedActIDs += actIDs
        state.currentCaseIDs.subtract(caseIDs)
        state.currentActIDs.subtract(actIDs)
    }

    func deleteAll() {
        state.deleteAllCount += 1
        state.currentCaseIDs.removeAll()
        state.currentActIDs.removeAll()
    }

    func snapshot() -> State { state }
}

private actor ControlledSpotlightWriter: SpotlightIndexWriting {
    private let failuresBeforeSuccess: Int
    private let failingAttempts: Set<Int>
    private var indexAttempts = 0
    private var indexedCaseFingerprints: [String: String] = [:]
    private var attemptedCaseIDs: [[String]] = []
    private var attemptedActIDs: [[String]] = []
    private var pausedAttempt: Int?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(failuresBeforeSuccess: Int = 1, failingAttempts: Set<Int> = []) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.failingAttempts = failingAttempts
    }

    func index(cases: [CaseEntity], acts: [CourtActEntity]) async throws {
        indexAttempts += 1
        attemptedCaseIDs.append(cases.map(\.id).sorted())
        attemptedActIDs.append(acts.map(\.id).sorted())
        if pausedAttempt == indexAttempts {
            await withCheckedContinuation { releaseContinuation = $0 }
            pausedAttempt = nil
        }
        guard indexAttempts > failuresBeforeSuccess, !failingAttempts.contains(indexAttempts) else {
            throw NSError(domain: "SpotlightIntegrationTests", code: 1)
        }
        indexedCaseFingerprints.merge(
            Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0.fingerprint) }),
            uniquingKeysWith: { _, new in new })
    }

    func delete(caseIDs: [String], actIDs: [String]) {}

    func deleteAll() { indexedCaseFingerprints.removeAll() }

    func pauseIndexAttempt(_ count: Int) {
        pausedAttempt = count
    }

    func waitUntilIndexAttemptStarts(_ count: Int, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while indexAttempts < count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return indexAttempts >= count
    }

    func releaseIndexAttempt() {
        pausedAttempt = nil
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitForIndexAttempts(_ count: Int, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if indexAttempts >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return indexAttempts >= count
    }

    func snapshot() -> (Int, [String: String], [[String]], [[String]]) {
        (indexAttempts, indexedCaseFingerprints, attemptedCaseIDs, attemptedActIDs)
    }
}

private actor DelayedSpotlightWriter: SpotlightIndexWriting {
    private var currentCaseIDs = Set<String>()
    private var currentActIDs = Set<String>()
    private var indexStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var deleteAllCount = 0

    func index(cases: [CaseEntity], acts: [CourtActEntity]) async {
        indexStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        currentCaseIDs.formUnion(cases.map(\.id))
        currentActIDs.formUnion(acts.map(\.id))
    }

    func delete(caseIDs: [String], actIDs: [String]) {
        currentCaseIDs.subtract(caseIDs)
        currentActIDs.subtract(actIDs)
    }

    func deleteAll() {
        deleteAllCount += 1
        currentCaseIDs.removeAll()
        currentActIDs.removeAll()
    }

    func waitUntilIndexStarts() async {
        guard !indexStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseIndex() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func snapshot() -> (Set<String>, Set<String>, Int) {
        (currentCaseIDs, currentActIDs, deleteAllCount)
    }
}

final class SpotlightIntegrationTests: XCTestCase {
    private static func waitForManifest(
        _ manifest: SpotlightManifestStore,
        caseID: String,
        fingerprint: String,
        timeout: Duration
    ) async -> SpotlightManifest {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var saved = await manifest.load()
        while saved.cases[caseID] != fingerprint, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            saved = await manifest.load()
        }
        return saved
    }

    private static func waitForActManifest(
        _ manifest: SpotlightManifestStore,
        actID: String,
        fingerprint: String,
        timeout: Duration
    ) async -> SpotlightManifest {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var saved = await manifest.load()
        while saved.acts[actID]?.fingerprint != fingerprint, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            saved = await manifest.load()
        }
        return saved
    }

    func testAppIdentityKeepsDebugLinksAndKeychainSeparate() throws {
        let productionID = "ru.sudrf.app"
        let debugID = AppIdentity.debugBundleIdentifier

        XCTAssertNotEqual(productionID, debugID)
        XCTAssertFalse(AppIdentity.isDebug(bundleIdentifier: productionID))
        XCTAssertTrue(AppIdentity.isDebug(bundleIdentifier: debugID))
        XCTAssertEqual(AppIdentity.urlScheme(bundleIdentifier: productionID), "sudrf")
        XCTAssertEqual(AppIdentity.urlScheme(bundleIdentifier: debugID), "sudrf-debug")
        XCTAssertEqual(AppIdentity.keychainService(bundleIdentifier: productionID),
                       "ru.sudrf.app.ai-provider-key")
        XCTAssertNotEqual(AppIdentity.keychainService(bundleIdentifier: productionID),
                          AppIdentity.keychainService(bundleIdentifier: debugID))
        let link = SudrfDeepLink.caseRecord(key: "debug/key")
        let debugURL = try XCTUnwrap(link.url(bundleIdentifier: debugID))
        XCTAssertEqual(debugURL.scheme, "sudrf-debug")
        XCTAssertEqual(SudrfDeepLink(url: debugURL, bundleIdentifier: debugID), link)
        XCTAssertNil(SudrfDeepLink(url: debugURL, bundleIdentifier: productionID))
    }

    @MainActor
    func testScheduledSpotlightFailureKeepsManifestAndRetriesLatestSnapshot() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        _ = try store.upsert(context: context, snapshot: nil,
                             movement: makeMovement(text: "Первый снимок."), collections: [])

        let suite = "SpotlightRetryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let manifest = SpotlightManifestStore(suiteName: suite, key: "manifest")
        let writer = ControlledSpotlightWriter()
        let indexer = SpotlightIndexer(
            catalog: CaseCatalog(container: store.container), writer: writer,
            manifestStore: manifest,
            preferenceStore: SpotlightPreferenceStore(suiteName: suite))

        await indexer.scheduleSynchronization(scope: .full)
        let firstAttemptStarted = await writer.waitForIndexAttempts(1, timeout: .seconds(2))
        XCTAssertTrue(firstAttemptStarted)
        let beforeRetry = await manifest.load()
        XCTAssertEqual(beforeRetry, SpotlightManifest())

        _ = try store.upsert(context: context, snapshot: nil,
                             movement: makeMovement(text: "Обновлённый снимок."), collections: [])
        await indexer.scheduleSynchronization(scope: .cases([context.key]))
        let retryStarted = await writer.waitForIndexAttempts(2, timeout: .seconds(10))
        XCTAssertTrue(retryStarted)
        let catalog = CaseCatalog(container: store.container)
        let currentSnapshot = try await catalog.caseSnapshot(id: context.key)
        let savedSnapshot = try XCTUnwrap(currentSnapshot)
        let expectedFingerprint = CaseEntity(snapshot: savedSnapshot).fingerprint
        let savedManifest = await Self.waitForManifest(
            manifest, caseID: context.key, fingerprint: expectedFingerprint, timeout: .seconds(2))
        let writerState = await writer.snapshot()
        XCTAssertEqual(writerState.0, 2)
        XCTAssertEqual(writerState.1[context.key], expectedFingerprint)
        XCTAssertEqual(savedManifest.cases[context.key], expectedFingerprint)
    }

    @MainActor
    func testPersistentScheduledFailureStopsRetriesAndExplicitRecoveryDrainsConcurrentUpdate() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        _ = try store.upsert(context: context, snapshot: nil,
                             movement: makeMovement(text: "Снимок."), collections: [])

        let suite = "SpotlightRetryLimitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let manifest = SpotlightManifestStore(suiteName: suite, key: "manifest")
        let writer = ControlledSpotlightWriter(failuresBeforeSuccess: 3)
        let indexer = SpotlightIndexer(
            catalog: CaseCatalog(container: store.container), writer: writer,
            manifestStore: manifest,
            preferenceStore: SpotlightPreferenceStore(suiteName: suite))

        await indexer.scheduleSynchronization(scope: .full)
        let boundedAttemptsStarted = await writer.waitForIndexAttempts(3, timeout: .seconds(40))
        XCTAssertTrue(boundedAttemptsStarted)
        await indexer.scheduleSynchronization(scope: .full)
        try await Task.sleep(for: .milliseconds(350))

        let state = await writer.snapshot()
        let savedManifest = await manifest.load()
        XCTAssertEqual(state.0, 3)
        XCTAssertTrue(state.1.isEmpty)
        XCTAssertEqual(savedManifest, SpotlightManifest())

        await writer.pauseIndexAttempt(4)
        let recovery = Task { try await indexer.setEnabled(true, revision: 1) }
        let recoveryAttemptStarted = await writer.waitUntilIndexAttemptStarts(4, timeout: .seconds(3))
        XCTAssertTrue(recoveryAttemptStarted)
        _ = try store.upsert(context: context, snapshot: nil,
                             movement: makeMovement(text: "Обновлённый во время recovery снимок."),
                             collections: [])
        await indexer.scheduleSynchronization(scope: .cases([context.key]))
        await writer.releaseIndexAttempt()
        try await recovery.value

        let pendingUpdateStarted = await writer.waitForIndexAttempts(5, timeout: .seconds(3))
        XCTAssertTrue(pendingUpdateStarted)
        let latestSnapshotValue = try await CaseCatalog(container: store.container)
            .caseSnapshot(id: context.key)
        let latestSnapshot = try XCTUnwrap(latestSnapshotValue)
        let latestFingerprint = CaseEntity(snapshot: latestSnapshot).fingerprint
        let recoveredManifest = await Self.waitForManifest(
            manifest, caseID: context.key, fingerprint: latestFingerprint, timeout: .seconds(2))
        let recoveredWriterState = await writer.snapshot()
        XCTAssertEqual(recoveredWriterState.0, 5)
        XCTAssertEqual(recoveredWriterState.1[context.key], latestFingerprint)
        XCTAssertEqual(recoveredManifest.cases[context.key], latestFingerprint)
    }

    @MainActor
    func testFullRecoveryKeepsQueuedScheduledScopeAfterItsFirstWriteFails()
        async throws {
        let store = TrackedStore(inMemory: true)
        let first = makeContext()
        var second = first
        second.displayDomain = "second.msk.sudrf.ru"
        second.searchDomain = "second--msk.sudrf.ru"
        second.caseNumber = "2-2/2026"
        _ = try store.upsert(context: first, snapshot: nil,
                             movement: makeMovement(text: "Первая исходная карточка."), collections: [])
        _ = try store.upsert(context: second, snapshot: nil,
                             movement: makeMovement(text: "Вторая исходная карточка."), collections: [])

        let suite = "SpotlightRecoveryQueueTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let manifest = SpotlightManifestStore(suiteName: suite, key: "manifest")
        let writer = ControlledSpotlightWriter(failuresBeforeSuccess: 0, failingAttempts: [2])
        let indexer = SpotlightIndexer(
            catalog: CaseCatalog(container: store.container), writer: writer,
            manifestStore: manifest,
            preferenceStore: SpotlightPreferenceStore(suiteName: suite))

        await writer.pauseIndexAttempt(1)
        let fullSync = Task { try await indexer.setEnabled(true, revision: 1) }
        let fullWriteStarted = await writer.waitUntilIndexAttemptStarts(1, timeout: .seconds(3))
        XCTAssertTrue(fullWriteStarted)

        _ = try store.upsert(context: first, snapshot: nil,
                             movement: makeMovement(text: "Первая изменённая карточка."), collections: [])
        await indexer.scheduleSynchronization(scope: .cases([first.key]))
        try await Task.sleep(for: .milliseconds(750))

        _ = try store.upsert(context: second, snapshot: nil,
                             movement: makeMovement(text: "Вторая изменённая карточка."), collections: [])
        await indexer.scheduleSynchronization(scope: .cases([second.key]))
        await writer.releaseIndexAttempt()
        try await fullSync.value

        let retriedBothCases = await writer.waitForIndexAttempts(3, timeout: .seconds(8))
        XCTAssertTrue(retriedBothCases)
        let catalog = CaseCatalog(container: store.container)
        let firstActDocuments = try await catalog.acts(caseKey: first.key)
        let secondActDocuments = try await catalog.acts(caseKey: second.key)
        let firstAct = CourtActEntity(document: try XCTUnwrap(firstActDocuments.first).document)
        let secondAct = CourtActEntity(document: try XCTUnwrap(secondActDocuments.first).document)
        let firstManifest = await Self.waitForActManifest(
            manifest, actID: firstAct.id, fingerprint: firstAct.fingerprint, timeout: .seconds(2))
        let secondManifest = await Self.waitForActManifest(
            manifest, actID: secondAct.id, fingerprint: secondAct.fingerprint, timeout: .seconds(2))
        let state = await writer.snapshot()
        XCTAssertEqual(state.0, 3)
        XCTAssertEqual(state.2[1], [])
        XCTAssertEqual(state.3[1], [firstAct.id])
        XCTAssertEqual(state.3[2], [firstAct.id, secondAct.id].sorted())
        XCTAssertEqual(Set(state.1.keys), [first.key, second.key])
        XCTAssertEqual(firstManifest.acts[firstAct.id]?.fingerprint, firstAct.fingerprint)
        XCTAssertEqual(secondManifest.acts[secondAct.id]?.fingerprint, secondAct.fingerprint)
    }

    func testCourtActFingerprintIncludesParagraphizerVersion() {
        let current = ActDocument(
            caseKey: "court/2-1/2026", sourceActID: "act-1", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Тестовый суд", instanceLevel: .first,
            kind: "Решение", date: "01.07.2026", sourceText: "Текст акта.")
        let legacy = ActDocument(
            id: current.id, caseKey: current.caseKey, sourceActID: current.sourceActID,
            caseNumber: current.caseNumber, judicialUID: current.judicialUID, court: current.court,
            instanceLevel: current.instanceLevel, kind: current.kind, date: current.date,
            sourceText: current.sourceText, sourceHash: current.sourceHash,
            paragraphizerVersion: 1, paragraphs: current.paragraphs)

        XCTAssertNotEqual(CourtActEntity(document: current).fingerprint,
                          CourtActEntity(document: legacy).fingerprint)
    }

    @MainActor
    func testLegacyHeadingTextIsNormalizedAndInvalidatesSpotlightIndex() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        let source = "ЗАОЧНОЕРЕШЕНИЕ\nИменем Российской Федерации\nСуд рассмотрел дело."
        _ = try store.upsert(context: context, snapshot: nil,
                             movement: makeMovement(text: source), collections: [])
        let catalog = CaseCatalog(container: store.container)
        let records = try await catalog.acts()
        let document = try XCTUnwrap(records.first?.document)
        let entity = CourtActEntity(document: document)
        let oldFingerprint = ActParagraphizer.sourceHash(for: [
            document.sourceHash, document.caseNumber, document.judicialUID,
            document.court, document.kind, document.date,
            String(document.paragraphizerVersion),
        ].compactMap { $0 }.joined(separator: "\n"))

        XCTAssertEqual(entity.attributeSet.textContent,
                       "ЗАОЧНОЕ РЕШЕНИЕ\nИменем Российской Федерации\nСуд рассмотрел дело.")
        XCTAssertNotEqual(entity.fingerprint, oldFingerprint)
        XCTAssertEqual(document.id, "\(context.key)#act-1")
        XCTAssertEqual(document.sourceText, source)
        XCTAssertEqual(document.sourceHash, ActParagraphizer.sourceHash(for: source))
        XCTAssertEqual(document.paragraphizerVersion, ActParagraphizer.currentVersion)
        XCTAssertEqual(document.paragraphs.first?.text, "ЗАОЧНОЕРЕШЕНИЕ")

        let suite = "SpotlightHeadingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manifest = SpotlightManifestStore(suiteName: suite, key: "manifest")
        await manifest.save(SpotlightManifest(acts: [
            document.id: SpotlightActManifestEntry(
                fingerprint: oldFingerprint, caseKey: document.caseKey),
        ]))
        let writer = RecordingSpotlightWriter()
        let indexer = SpotlightIndexer(
            catalog: catalog, writer: writer, manifestStore: manifest,
            preferenceStore: SpotlightPreferenceStore(suiteName: suite))

        try await indexer.synchronize()

        var state = await writer.snapshot()
        XCTAssertEqual(state.indexedActIDs, [document.id])

        try await indexer.synchronize()
        state = await writer.snapshot()
        XCTAssertEqual(state.indexedActIDs, [document.id])
        let savedManifest = await manifest.load()
        XCTAssertEqual(savedManifest.acts[document.id]?.fingerprint, entity.fingerprint)
    }

    func testDeepLinksRoundTripReservedCharacters() throws {
        let links: [SudrfDeepLink] = [
            .caseRecord(key: "court.example/2-1/2026 # 7"),
            .courtAct(caseKey: "court.example/2-1/2026", sourceActID: "act?id=1&x=2"),
        ]
        for link in links {
            XCTAssertEqual(SudrfDeepLink(url: try XCTUnwrap(link.url)), link)
        }
        XCTAssertNil(SudrfDeepLink(url: try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertNil(SudrfDeepLink(url: try XCTUnwrap(
            URL(string: "sudrf://case?id=first&id=second"))))
        XCTAssertNil(SudrfDeepLink(url: try XCTUnwrap(
            URL(string: "sudrf://act?case=one&act=a&act=b"))))
    }

    @MainActor
    func testStaleActDeepLinkFallsBackToExistingCase() throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        _ = try store.upsert(context: context, snapshot: nil, movement: nil, collections: [])
        let route = store.route(for: .courtAct(
            caseKey: context.key, sourceActID: "missing-act"))
        XCTAssertEqual(route, .caseRecord(key: context.key, staleAct: true))
    }

    @MainActor
    func testIncrementalInsertUpdateDeleteAndRebuild() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        let original = makeMovement(text: "Исходный текст акта.")
        _ = try store.upsert(context: context, snapshot: nil, movement: original,
                     collections: ["Доверитель"])

        let catalog = CaseCatalog(container: store.container)
        let writer = RecordingSpotlightWriter()
        let suite = "SpotlightIntegrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manifest = SpotlightManifestStore(suiteName: suite, key: "manifest")
        let preference = SpotlightPreferenceStore(suiteName: suite)
        let indexer = SpotlightIndexer(catalog: catalog, writer: writer,
                                       manifestStore: manifest,
                                       preferenceStore: preference)

        try await indexer.synchronize()
        var state = await writer.snapshot()
        XCTAssertEqual(state.indexedCaseIDs, [context.key])
        XCTAssertEqual(state.indexedActIDs, ["\(context.key)#act-1"])

        try await indexer.synchronize()
        state = await writer.snapshot()
        XCTAssertEqual(state.indexedCaseIDs.count, 1)
        XCTAssertEqual(state.indexedActIDs.count, 1)

        _ = try store.upsert(context: context, snapshot: nil,
                     movement: makeMovement(text: "Изменённый текст акта."),
                     collections: ["Доверитель"])
        try await indexer.synchronize()
        state = await writer.snapshot()
        XCTAssertEqual(state.indexedCaseIDs.count, 1)
        XCTAssertEqual(state.indexedActIDs.count, 2)

        var metadataOnlyContext = context
        metadataOnlyContext.judicialUID = "77RS0001-01-2026-999999-10"
        _ = try store.upsert(context: metadataOnlyContext, snapshot: nil, movement: nil,
                     collections: ["Доверитель"])
        try await indexer.synchronize()
        state = await writer.snapshot()
        XCTAssertEqual(state.indexedActIDs.count, 3)
        XCTAssertEqual(state.indexedActUIDs.last,
                       TrackedStore.normalizedUID(metadataOnlyContext.judicialUID ?? ""))

        try store.remove(key: context.key)
        try await indexer.synchronize()
        state = await writer.snapshot()
        XCTAssertEqual(state.deletedCaseIDs, [context.key])
        XCTAssertEqual(state.deletedActIDs, ["\(context.key)#act-1"])

        try await indexer.rebuild()
        state = await writer.snapshot()
        XCTAssertEqual(state.deleteAllCount, 1)

        try await indexer.setEnabled(false, revision: 1)
        state = await writer.snapshot()
        XCTAssertEqual(state.deleteAllCount, 2)
        _ = try store.upsert(context: context, snapshot: nil, movement: original,
                     collections: ["Доверитель"])
        try await indexer.synchronize()
        let disabledState = await writer.snapshot()
        XCTAssertEqual(disabledState.indexedCaseIDs.count, state.indexedCaseIDs.count)
    }

    @MainActor
    func testEntityContainsLocalSearchMetadataAndDeepLink() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        _ = try store.upsert(context: context, snapshot: nil,
                     movement: makeMovement(text: "Мотивировка и резолютивная часть."),
                     collections: ["Доверитель"])
        let catalog = CaseCatalog(container: store.container)

        let catalogCases = try await catalog.cases()
        let catalogActs = try await catalog.acts()
        let caseEntity = try XCTUnwrap(catalogCases.first.map(CaseEntity.init))
        let actEntity = try XCTUnwrap(catalogActs.first.map {
            CourtActEntity(document: $0.document)
        })

        XCTAssertTrue(caseEntity.attributeSet.textContent?.contains("Истец") == true)
        XCTAssertEqual(SudrfDeepLink(url: try XCTUnwrap(caseEntity.attributeSet.contentURL)),
                       .caseRecord(key: context.key))
        XCTAssertTrue(actEntity.attributeSet.textContent?.contains("Мотивировка") == true)
        XCTAssertEqual(SudrfDeepLink(url: try XCTUnwrap(actEntity.attributeSet.contentURL)),
                       .courtAct(caseKey: context.key, sourceActID: "act-1"))

        let caseItem = SystemSpotlightWriter.searchableItem(for: caseEntity)
        let actItem = SystemSpotlightWriter.searchableItem(for: actEntity)
        XCTAssertEqual(caseItem.expirationDate, Date.distantFuture)
        XCTAssertEqual(actItem.expirationDate, Date.distantFuture)

        let item = CSSearchableItem(uniqueIdentifier: caseEntity.id,
                                    domainIdentifier: caseEntity.attributeSet.domainIdentifier,
                                    attributeSet: caseEntity.attributeSet)
        let hit = try XCTUnwrap(SpotlightSearchSession.hit(from: item))
        XCTAssertEqual(hit.id, context.key)
        XCTAssertEqual(hit.url, caseEntity.attributeSet.contentURL)
        XCTAssertEqual(hit.title, caseEntity.attributeSet.title)
        XCTAssertFalse(hit.isCourtAct)
    }

    @MainActor
    func testCaseEntityQueryResolvesMergedRecordAlias() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        let record = try store.upsert(context: context, snapshot: nil, collections: [])
        let oldIdentifier = "legacy/source/card"
        record.addLegacyKeyAlias(oldIdentifier)
        try store.save()

        let catalog = CaseCatalog(container: store.container)
        await CaseCatalogRegistry.shared.install(catalog)
        let entities = try await CaseEntityQuery().entities(for: [oldIdentifier])

        XCTAssertEqual(entities.map(\.id), [record.key])
        XCTAssertEqual(entities.first?.caseNumber, record.caseNumber)
    }

    @MainActor
    func testSearchRequestsEveryAttributeUsedToBuildHits() {
        XCTAssertEqual(Set(SpotlightSearchSession.makeQueryContext().fetchAttributes), [
            "title",
            "displayName",
            "contentDescription",
            "contentURL",
        ])
    }

    @MainActor
    func testDisableWaitsForInflightIndexAndLeavesIndexAndManifestEmpty() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        _ = try store.upsert(context: context, snapshot: nil,
                     movement: makeMovement(text: "Текст для гонки индекса."),
                     collections: [])
        let catalog = CaseCatalog(container: store.container)
        let writer = DelayedSpotlightWriter()
        let suite = "SpotlightRaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manifest = SpotlightManifestStore(suiteName: suite, key: "manifest")
        let preference = SpotlightPreferenceStore(suiteName: suite)
        let indexer = SpotlightIndexer(catalog: catalog, writer: writer,
                                       manifestStore: manifest,
                                       preferenceStore: preference)

        let synchronization = Task { try await indexer.synchronize() }
        await writer.waitUntilIndexStarts()
        let disabling = Task { try await indexer.setEnabled(false, revision: 1) }
        for _ in 0..<100 where preference.isEnabled() { await Task.yield() }
        XCTAssertFalse(preference.isEnabled())
        await writer.releaseIndex()
        try await synchronization.value
        try await disabling.value

        let state = await writer.snapshot()
        XCTAssertTrue(state.0.isEmpty)
        XCTAssertTrue(state.1.isEmpty)
        XCTAssertGreaterThanOrEqual(state.2, 1)
        let savedManifest = await manifest.load()
        XCTAssertEqual(savedManifest, SpotlightManifest())
    }

    @MainActor
    func testStaleSpotlightPreferenceRevisionCannotOverrideLatestToggle() async throws {
        let store = TrackedStore(inMemory: true)
        let suite = "SpotlightRevisionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = SpotlightPreferenceStore(suiteName: suite)
        let indexer = SpotlightIndexer(
            catalog: CaseCatalog(container: store.container),
            writer: RecordingSpotlightWriter(),
            manifestStore: SpotlightManifestStore(suiteName: suite, key: "manifest"),
            preferenceStore: preference)

        try await indexer.setEnabled(true, revision: 2)
        try await indexer.setEnabled(false, revision: 1)
        XCTAssertTrue(preference.isEnabled())
    }

    @MainActor
    func testCaseScopedSynchronizationDoesNotReindexUnrelatedCase() async throws {
        let store = TrackedStore(inMemory: true)
        let first = makeContext()
        var second = first
        second.displayDomain = "second.msk.sudrf.ru"
        second.searchDomain = "second--msk.sudrf.ru"
        second.caseNumber = "2-2/2026"
        _ = try store.upsert(context: first, snapshot: nil,
                     movement: makeMovement(text: "Первый акт."), collections: [])
        _ = try store.upsert(context: second, snapshot: nil,
                     movement: makeMovement(text: "Второй акт."), collections: [])
        let writer = RecordingSpotlightWriter()
        let suite = "SpotlightScopedTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let indexer = SpotlightIndexer(
            catalog: CaseCatalog(container: store.container), writer: writer,
            manifestStore: SpotlightManifestStore(suiteName: suite, key: "manifest"),
            preferenceStore: SpotlightPreferenceStore(suiteName: suite))

        try await indexer.synchronize()
        var state = await writer.snapshot()
        XCTAssertEqual(state.indexedActIDs.count, 2)

        _ = try store.upsert(context: first, snapshot: nil,
                     movement: makeMovement(text: "Первый акт изменён."), collections: [])
        try await indexer.synchronize(scope: .cases([first.key]))
        state = await writer.snapshot()
        XCTAssertEqual(state.indexedActIDs.count, 3)
        XCTAssertEqual(state.indexedCaseIDs.count, 2)
    }

    @MainActor
    func testCaseScopedSynchronizationDeletesOnlyUntrackedCaseAndActs() async throws {
        let store = TrackedStore(inMemory: true)
        let first = makeContext()
        var second = first
        second.displayDomain = "second.msk.sudrf.ru"
        second.searchDomain = "second--msk.sudrf.ru"
        second.caseNumber = "2-2/2026"
        _ = try store.upsert(context: first, snapshot: nil,
                     movement: makeMovement(text: "Первый акт."), collections: [])
        _ = try store.upsert(context: second, snapshot: nil,
                     movement: makeMovement(text: "Второй акт."), collections: [])
        let writer = RecordingSpotlightWriter()
        let suite = "SpotlightUntrackTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let indexer = SpotlightIndexer(
            catalog: CaseCatalog(container: store.container), writer: writer,
            manifestStore: SpotlightManifestStore(suiteName: suite, key: "manifest"),
            preferenceStore: SpotlightPreferenceStore(suiteName: suite))

        try await indexer.synchronize()
        try store.remove(key: first.key)
        try await indexer.synchronize(scope: .cases([first.key]))

        let state = await writer.snapshot()
        XCTAssertEqual(state.indexedCaseIDs.count, 2,
                       "соседнее дело не должно переиндексироваться")
        XCTAssertEqual(state.indexedActIDs.count, 2,
                       "акты соседнего дела не должны переиндексироваться")
        XCTAssertEqual(state.deletedCaseIDs, [first.key])
        XCTAssertEqual(state.deletedActIDs, ["\(first.key)#act-1"])
        XCTAssertEqual(state.currentCaseIDs, [second.key])
        XCTAssertEqual(state.currentActIDs, ["\(second.key)#act-1"])
    }

    @MainActor
    func testLegacyManifestForcesPurgeAndFullRebuild() async throws {
        struct LegacyManifest: Codable {
            let cases: [String: String]
            let acts: [String: String]
        }
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        _ = try store.upsert(context: context, snapshot: nil,
                     movement: makeMovement(text: "Актуальный акт."), collections: [])
        let suite = "SpotlightLegacyManifestTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(LegacyManifest(
            cases: ["stale": "old"], acts: ["stale#act": "old"])),
            forKey: "manifest")
        let writer = RecordingSpotlightWriter()
        let manifest = SpotlightManifestStore(suiteName: suite, key: "manifest")
        let indexer = SpotlightIndexer(
            catalog: CaseCatalog(container: store.container), writer: writer,
            manifestStore: manifest,
            preferenceStore: SpotlightPreferenceStore(suiteName: suite))

        try await indexer.synchronize(scope: .cases([context.key]))

        let state = await writer.snapshot()
        XCTAssertEqual(state.deleteAllCount, 1)
        XCTAssertEqual(state.currentCaseIDs, [context.key])
        XCTAssertEqual(state.currentActIDs, ["\(context.key)#act-1"])
        let saved = await manifest.loadSnapshot()
        XCTAssertFalse(saved.requiresFullRebuild)
    }

    @MainActor
    func testVersionFourManifestForcesExpirationPolicyReindex() async throws {
        struct Envelope: Codable {
            let version: Int
            let manifest: SpotlightManifest
        }
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        _ = try store.upsert(context: context, snapshot: nil,
                     movement: makeMovement(text: "Актуальный акт."), collections: [])
        let suite = "SpotlightVersionFourManifestTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(Envelope(
            version: 4,
            manifest: SpotlightManifest(
                cases: [context.key: "unchanged"],
                acts: ["\(context.key)#act-1": SpotlightActManifestEntry(
                    fingerprint: "unchanged", caseKey: context.key)]))),
            forKey: "manifest")
        let writer = RecordingSpotlightWriter()
        let manifest = SpotlightManifestStore(suiteName: suite, key: "manifest")
        let indexer = SpotlightIndexer(
            catalog: CaseCatalog(container: store.container), writer: writer,
            manifestStore: manifest,
            preferenceStore: SpotlightPreferenceStore(suiteName: suite))

        try await indexer.synchronize()

        let state = await writer.snapshot()
        XCTAssertEqual(state.deleteAllCount, 1)
        XCTAssertEqual(state.indexedCaseIDs, [context.key])
        XCTAssertEqual(state.indexedActIDs, ["\(context.key)#act-1"])
        let saved = await manifest.loadSnapshot()
        XCTAssertFalse(saved.requiresFullRebuild)
    }

    @MainActor
    func testFastOffThenOnLeavesSpotlightPopulated() async throws {
        let fixture = try makeToggleFixture()
        let off = Task { try await fixture.indexer.setEnabled(false, revision: 1) }
        let on = Task { try await fixture.indexer.setEnabled(true, revision: 2) }
        try await off.value
        try await on.value

        XCTAssertTrue(fixture.preference.isEnabled())
        let state = await fixture.writer.snapshot()
        XCTAssertEqual(state.currentCaseIDs, Set([fixture.caseKey]))
        XCTAssertEqual(state.currentActIDs, Set(["\(fixture.caseKey)#act-1"]))
    }

    @MainActor
    func testFastOnThenOffLeavesSpotlightEmpty() async throws {
        let fixture = try makeToggleFixture()
        fixture.preference.setEnabled(false)
        let on = Task { try await fixture.indexer.setEnabled(true, revision: 1) }
        let off = Task { try await fixture.indexer.setEnabled(false, revision: 2) }
        try await on.value
        try await off.value

        XCTAssertFalse(fixture.preference.isEnabled())
        let state = await fixture.writer.snapshot()
        XCTAssertTrue(state.currentCaseIDs.isEmpty)
        XCTAssertTrue(state.currentActIDs.isEmpty)
        let savedManifest = await fixture.manifest.load()
        XCTAssertEqual(savedManifest, SpotlightManifest())
    }

    @MainActor
    private func makeToggleFixture() throws -> (
        indexer: SpotlightIndexer,
        writer: RecordingSpotlightWriter,
        preference: SpotlightPreferenceStore,
        manifest: SpotlightManifestStore,
        caseKey: String
    ) {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        _ = try store.upsert(context: context, snapshot: nil,
                     movement: makeMovement(text: "Текст для быстрых переключений."),
                     collections: [])
        let suite = "SpotlightToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let writer = RecordingSpotlightWriter()
        let preference = SpotlightPreferenceStore(suiteName: suite)
        let manifest = SpotlightManifestStore(suiteName: suite, key: "manifest")
        let indexer = SpotlightIndexer(
            catalog: CaseCatalog(container: store.container), writer: writer,
            manifestStore: manifest, preferenceStore: preference)
        return (indexer, writer, preference, manifest, context.key)
    }

    private func makeContext() -> MovementContext {
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court--msk.sudrf.ru", displayDomain: "court.msk.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-1/2026")
        context.judicialUID = "77RS0001-01-2026-000001-10"
        return context
    }

    private func makeMovement(text: String) -> CaseMovement {
        let act = CaseAct(id: "act-1", title: "Решение", date: "01.07.2026",
                          courtShort: "1-я инстанция", instanceLevel: .first)
        let instance = CaseInstance(
            level: .first, court: "Тестовый суд", caseNumber: "2-1/2026",
            judge: "Иванова И.И.", domain: "court.msk.sudrf.ru",
            foundByUID: false, result: "Иск удовлетворён",
            sessions: [CaseSession(date: "01.07.2026", event: "Рассмотрение",
                                   result: "Иск удовлетворён")], actID: act.id)
        return CaseMovement(
            uid: "77RS0001-01-2026-000001-10", caseNumber: "2-1/2026",
            inForce: false, instances: [instance], complaints: [:], acts: [act],
            actBodies: [act.id: text], category: "Споры о договоре",
            parties: CaseParties(plaintiffs: ["Истец"], defendants: ["Ответчик"]))
    }
}
