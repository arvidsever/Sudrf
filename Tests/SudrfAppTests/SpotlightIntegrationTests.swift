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
        store.upsert(context: context, snapshot: nil, movement: nil, collections: [])
        let route = store.route(for: .courtAct(
            caseKey: context.key, sourceActID: "missing-act"))
        XCTAssertEqual(route, .caseRecord(key: context.key, staleAct: true))
    }

    @MainActor
    func testIncrementalInsertUpdateDeleteAndRebuild() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        let original = makeMovement(text: "Исходный текст акта.")
        store.upsert(context: context, snapshot: nil, movement: original,
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

        store.upsert(context: context, snapshot: nil,
                     movement: makeMovement(text: "Изменённый текст акта."),
                     collections: ["Доверитель"])
        try await indexer.synchronize()
        state = await writer.snapshot()
        XCTAssertEqual(state.indexedCaseIDs.count, 1)
        XCTAssertEqual(state.indexedActIDs.count, 2)

        var metadataOnlyContext = context
        metadataOnlyContext.judicialUID = "77RS0001-01-2026-999999-10"
        store.upsert(context: metadataOnlyContext, snapshot: nil, movement: nil,
                     collections: ["Доверитель"])
        try await indexer.synchronize()
        state = await writer.snapshot()
        XCTAssertEqual(state.indexedActIDs.count, 3)
        XCTAssertEqual(state.indexedActUIDs.last,
                       TrackedStore.normalizedUID(metadataOnlyContext.judicialUID ?? ""))

        store.remove(key: context.key)
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
        store.upsert(context: context, snapshot: nil, movement: original,
                     collections: ["Доверитель"])
        try await indexer.synchronize()
        let disabledState = await writer.snapshot()
        XCTAssertEqual(disabledState.indexedCaseIDs.count, state.indexedCaseIDs.count)
    }

    @MainActor
    func testEntityContainsLocalSearchMetadataAndDeepLink() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        store.upsert(context: context, snapshot: nil,
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
    }

    @MainActor
    func testDisableWaitsForInflightIndexAndLeavesIndexAndManifestEmpty() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        store.upsert(context: context, snapshot: nil,
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
        store.upsert(context: context, snapshot: nil,
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
