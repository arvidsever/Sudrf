import CryptoKit
import Foundation
import SwiftData
import XCTest
import SudrfKit
import CaptchaSolver
@testable import SudrfApp

@MainActor
final class PublishedActSelectionTests: XCTestCase {
    private let sourceURL = URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/34000001")!
    private let caseNumber = "3-ИКАД25-3-А2"

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

    private actor OfflineMovementProvider: MovementProviding {
        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            throw CancellationError()
        }
    }

    func testScanOnlyPDFIsCachedAndReopenedWithoutFetchingAgain() async throws {
        let data = try pdfData()
        let file = publishedFile(data: data, text: "")
        let cache = try fileCache()
        let fetcher = FetchStub(file: file)
        let first = PublishedActSelection(cache: cache) { url, number in
            try await fetcher.fetch(url: url, productionNumber: number)
        }
        let act = publishedAct()
        let firstApply = ApplyRecorder()
        first.select(caseKey: "case", selectedActID: act.id, sourceAct: act,
                     existingText: nil) { _, _, id, result in
            firstApply.ids.append(id)
            XCTAssertEqual(result.data, data)
        }

        await wait { !first.isLoading && first.fileURL != nil }
        XCTAssertNil(first.error)
        XCTAssertNil(first.text, "A scanned act has bytes but no fabricated text.")
        XCTAssertEqual(first.data, data)
        XCTAssertEqual(first.provenance, file.provenance)
        XCTAssertEqual(firstApply.ids, [act.id])
        let firstFetchCount = await fetcher.count
        XCTAssertEqual(firstFetchCount, 1)

        let second = PublishedActSelection(cache: cache) { url, number in
            try await fetcher.fetch(url: url, productionNumber: number)
        }
        var cachedAct = act
        cachedAct.fileProvenance = file.provenance
        let secondApply = ApplyRecorder()
        second.select(caseKey: "case", selectedActID: act.id, sourceAct: cachedAct,
                      existingText: nil) { _, _, id, _ in secondApply.ids.append(id) }

        await wait { !second.isLoading && second.fileURL != nil }
        XCTAssertEqual(second.data, data)
        XCTAssertNil(second.text)
        XCTAssertEqual(secondApply.ids, [act.id])
        let secondFetchCount = await fetcher.count
        XCTAssertEqual(secondFetchCount, 1, "Verified cached bytes avoid another network request.")
    }

    func testRetryAfterDownloadFailureLoadsAndAppliesPDF() async throws {
        let data = try pdfData()
        let file = publishedFile(data: data, text: "Текст судебного акта")
        let cache = try fileCache()
        let fetcher = RetryFetchStub(file: file)
        let selection = PublishedActSelection(cache: cache) { url, number in
            try await fetcher.fetch(url: url, productionNumber: number)
        }
        let applied = ApplyRecorder()
        let act = publishedAct()
        selection.select(caseKey: "case", selectedActID: act.id, sourceAct: act,
                         existingText: nil) { _, _, id, _ in applied.ids.append(id) }

        await wait { !selection.isLoading && selection.error != nil }
        XCTAssertNil(selection.data)
        XCTAssertTrue(applied.ids.isEmpty)

        selection.retry()
        await wait { !selection.isLoading && selection.data != nil }
        XCTAssertNil(selection.error)
        XCTAssertEqual(selection.text, "Текст судебного акта")
        XCTAssertEqual(selection.data, data)
        XCTAssertEqual(applied.ids, [act.id])
        let fetchCount = await fetcher.count
        XCTAssertEqual(fetchCount, 2)
    }

    func testLateResultForPreviousSelectionCannotReplaceNewSelection() async throws {
        let firstData = try pdfData()
        let secondData = firstData + Data("\n% second valid PDF payload\n".utf8)
        let firstFile = publishedFile(data: firstData, text: "Первый акт", url: sourceURL)
        let secondURL = URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/34000002")!
        let secondFile = publishedFile(data: secondData, text: "Второй акт", url: secondURL)
        let cache = try fileCache()
        let fetcher = DelayedFetchStub(firstURL: sourceURL, first: firstFile,
                                       secondURL: secondURL, second: secondFile)
        let selection = PublishedActSelection(cache: cache) { url, _ in
            try await fetcher.fetch(url: url)
        }
        let applied = ApplyRecorder()
        let firstAct = publishedAct(id: "first", url: sourceURL)
        let secondAct = publishedAct(id: "second", url: secondURL)

        selection.select(caseKey: "case", selectedActID: firstAct.id, sourceAct: firstAct,
                         existingText: nil) { _, _, id, _ in applied.ids.append(id) }
        await wait { await fetcher.isWaitingForFirst }
        selection.select(caseKey: "case", selectedActID: secondAct.id, sourceAct: secondAct,
                         existingText: nil) { _, _, id, _ in applied.ids.append(id) }

        await wait { !selection.isLoading && selection.data == secondData }
        await wait { await fetcher.didReturnFirst }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(selection.selectedActID, secondAct.id)
        XCTAssertEqual(selection.data, secondData)
        XCTAssertEqual(selection.text, "Второй акт")
        XCTAssertEqual(applied.ids, [secondAct.id])
    }

    func testSearchMovementAppliesPublishedFileAndUpdatesMemoryCache() async throws {
        let data = try pdfData()
        let file = publishedFile(data: data, text: "Текст опубликованного определения")
        let cache = try fileCache()
        let fetcher = FetchStub(file: file)
        let selection = PublishedActSelection(cache: cache) { url, number in
            try await fetcher.fetch(url: url, productionNumber: number)
        }
        let model = SearchModel(selectedPublishedAct: selection)
        let court = SearchModel.CourtOption(
            domain: "leninsky.orb.sudrf.ru", title: "Ленинский районный суд",
            level: .district)
        let result = CaseSearchResult(caseNumber: "2-41/2026")
        let act = publishedAct(number: result.caseNumber)
        let movement = CaseMovement(
            uid: "", caseNumber: result.caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .first, court: court.title, caseNumber: result.caseNumber,
                judge: nil, domain: court.domain, foundByUID: false, result: nil,
                sessions: [], actID: act.id)],
            complaints: [:], acts: [act])
        let cacheKey = MovementContext.identityKey(displayDomain: court.domain,
                                                   courtCode: nil,
                                                   caseNumber: result.caseNumber)
        MovementMemoryCache.shared.put(cacheKey, movement)
        defer { MovementMemoryCache.shared.remove(cacheKey) }

        model.tier = .district
        model.courts = [court]
        model.selectedCourtID = court.id
        model.cartotekaId = "g1"
        model.results = [result]
        await model.openMovement(result)

        await wait { !selection.isLoading && model.movement?.actBodies[act.id] != nil }
        XCTAssertEqual(model.selectedActID, act.id)
        XCTAssertEqual(model.movement?.actBodies[act.id], file.text)
        XCTAssertEqual(model.movement?.acts.first?.fileProvenance, file.provenance)
        XCTAssertEqual(MovementMemoryCache.shared.get(cacheKey)?.movement.actBodies[act.id], file.text)
        let fetchCount = await fetcher.count
        XCTAssertEqual(fetchCount, 1)
    }

    func testSearchMovementLeavesMosGorSudActsOutsideVSRFLoader() async throws {
        let fetcher = FetchStub(file: publishedFile(data: try pdfData(), text: "unused"))
        let selection = PublishedActSelection(cache: try fileCache()) { url, number in
            try await fetcher.fetch(url: url, productionNumber: number)
        }
        let model = SearchModel(selectedPublishedAct: selection)
        let court = SearchModel.CourtOption(
            domain: MosGorSudEndpoint.host, title: "Мосгорсуд", level: .district)
        let result = CaseSearchResult(caseNumber: "2-41/2026")
        let mgsURL = URL(string: "https://mos-gorsud.ru/mgs/cases/docs/content/123")!
        let act = CaseAct(id: "mgs", title: "Решение", date: "15.10.2025",
                          courtShort: "Мосгорсуд", instanceLevel: .first,
                          sourceFileURL: mgsURL, productionNumber: result.caseNumber)
        let movement = CaseMovement(
            uid: "", caseNumber: result.caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .first, court: court.title, caseNumber: result.caseNumber,
                judge: nil, domain: court.domain, foundByUID: false, result: nil,
                sessions: [], actID: act.id)],
            complaints: [:], acts: [act])
        let cacheKey = MovementContext.identityKey(displayDomain: court.domain,
                                                   courtCode: nil,
                                                   caseNumber: result.caseNumber)
        MovementMemoryCache.shared.put(cacheKey, movement)
        defer { MovementMemoryCache.shared.remove(cacheKey) }

        model.tier = .district
        model.courts = [court]
        model.selectedCourtID = court.id
        model.cartotekaId = "g1"
        model.results = [result]
        await model.openMovement(result)

        let fetchCount = await fetcher.count
        XCTAssertEqual(fetchCount, 0)
        XCTAssertNil(selection.selectedActID)
        XCTAssertEqual(model.movement?.acts.first?.sourceFileURL, mgsURL)
    }

    func testTrackedMovementAppliesFileWithoutChangingEventJournal() async throws {
        let data = try pdfData()
        let file = publishedFile(data: data, text: "Текст опубликованного решения")
        let cache = try fileCache()
        let fetcher = SuspendedFetchStub(file: file)
        let selection = PublishedActSelection(cache: cache) { url, number in
            try await fetcher.fetch(url: url, productionNumber: number)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("published-act-router-profile-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru", displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001", cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-41/2026", caseID: "test-case", caseUID: "test-uid")
        let act = publishedAct(number: context.caseNumber)
        let movement = CaseMovement(
            uid: "test-uid", caseNumber: context.caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
                judge: nil, domain: context.searchDomain, foundByUID: true, result: nil,
                sessions: [], actID: act.id)],
            complaints: [:], acts: [act])
        let record = try store.upsert(
            context: context,
            snapshot: MovementDerivation.snapshot(from: movement, context: context),
            movement: movement, collections: [])
        let suite = "Sudrf.PublishedActSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let router = try makePrivateRouter(container: container, directory: directory,
                                           defaults: defaults, suite: suite,
                                           selectedAct: selection)

        router.openCase(key: record.key)
        await wait { await fetcher.hasStarted }
        let journalBeforeFileApply = try XCTUnwrap(store.record(forKey: record.key)?.eventJournal)
        let semanticBaselineBeforeFileApply = journalBeforeFileApply.semanticBaselines
        await fetcher.release()
        await wait { !selection.isLoading && router.liveMovement?.actBodies[act.id] != nil }

        XCTAssertEqual(router.selectedActID, act.id)
        XCTAssertEqual(router.liveMovement?.actBodies[act.id], file.text)
        XCTAssertEqual(router.liveMovement?.acts.first?.fileProvenance, file.provenance)
        XCTAssertEqual(store.record(forKey: record.key)?.movement?.actBodies[act.id], file.text)
        let journalAfterFileApply = try XCTUnwrap(store.record(forKey: record.key)?.eventJournal)
        XCTAssertEqual(journalAfterFileApply, journalBeforeFileApply,
                       "Applying the file must not alter the journal captured after router setup and case opening.")
        XCTAssertEqual(journalAfterFileApply.events.map(\.id), journalBeforeFileApply.events.map(\.id))
        XCTAssertEqual(journalAfterFileApply.semanticBaselines, semanticBaselineBeforeFileApply)
        let fetchCount = await fetcher.count
        XCTAssertEqual(fetchCount, 1)
    }

    @MainActor
    private func makePrivateRouter(container: ModelContainer, directory: URL,
                                   defaults: UserDefaults, suite: String,
                                   selectedAct: PublishedActSelection) throws -> AppRouter {
        let client = TestNetworkGuard.sudrfClient()
        let tokens = CaptchaTokenStore()
        let settings = CaptchaSettings(defaults: defaults)
        let vsrf = OfflineVSRFProvider()
        let moscow = OfflineMosGorSudProvider()
        return try AppRouter(
            captchaSettings: settings,
            modelContainer: container,
            modelContainerIsPrepared: true,
            captchaCorpus: CorpusStore(baseDir: directory.appendingPathComponent("captcha")),
            refreshCenterFactory: { store, privateClient in
                RefreshCenter(store: store, client: privateClient,
                    captchaSettings: settings, captchaTokenStore: tokens,
                    serviceBuilder: { _ in OfflineMovementProvider() },
                    treasuryDiscover: { _, _, _ in throw CancellationError() },
                    vsrfProvider: vsrf, mosGorSudProvider: moscow,
                    moscowMagistrateProvider: privateClient,
                    fsspAutoModelEnabled: false,
                    fsspDiscover: { _ in throw CancellationError() },
                    initialTimerDelay: .seconds(3_600), timerInterval: .seconds(3_600),
                    walkDiagnostics: .disabled)
            },
            importVSRFProvider: vsrf,
            importMosGorSudProvider: moscow,
            selectedPublishedAct: selectedAct,
            summaryConfigurationProvider: { throw CancellationError() },
            userDefaults: defaults,
            client: client,
            captchaTokenStore: tokens,
            directCaseLinkResolverFactory: { _ in DirectCaseLinkResolver(
                fetchCard: { _ in throw CancellationError() },
                districtCourts: { _ in throw CancellationError() }) },
            spotlightIndexerFactory: { catalog in
                SpotlightIndexer(catalog: catalog, writer: NoopSpotlightWriter(),
                    manifestStore: SpotlightManifestStore(suiteName: suite),
                    preferenceStore: SpotlightPreferenceStore(suiteName: suite))
            },
            currentEntityActivityPublisher: { _ in },
            feedNotificationPublisher: { _ in },
            feedBadgePublisher: { _ in },
            notificationOpenInstaller: { _ in },
            intentInstaller: { _ in },
            captchaSolverFactory: { _ in nil },
            repairCoordinatorFactory: { store, privateClient in
                let district = DistrictCourtResolver(client: privateClient, cacheURL: nil)
                let magistrate = MagistrateCourtResolver(
                    client: privateClient, cacheURL: nil, moscowDirectoryClient: nil)
                let origin = CaseOriginResolver(client: privateClient,
                    districtResolver: district, magistrateResolver: magistrate,
                    regularProvider: privateClient, magistrateProvider: privateClient,
                    moscowProvider: OfflineMoscowOriginProvider())
                return TrackedCaseRepairCoordinator(store: store, client: privateClient,
                    originResolver: origin, defaults: defaults,
                    anchorCardResolver: { _ in throw CancellationError() })
            })
    }

    func testPublishedActSurvivesStoreAndAppRestartOffline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("published-act-restart-\(UUID().uuidString)",
                                    isDirectory: true)
        let storeDirectory = directory.appendingPathComponent("store", isDirectory: true)
        let pdfDirectory = directory.appendingPathComponent("pdf-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pdfDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = storeDirectory.appendingPathComponent("case.store")
        let data = try pdfData()
        let file = publishedFile(data: data, text: "Текст сохранённого опубликованного решения")
        let fetcher = FetchStub(file: file)
        let original = try await seedAndLoadTrackedFile(
            storeURL: storeURL, pdfDirectory: pdfDirectory, file: file, fetcher: fetcher)
        let originalFetchCount = await fetcher.count
        XCTAssertEqual(originalFetchCount, 1)

        let restartedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let restartedStore = try TrackedStore(container: restartedContainer, prepared: true)
        let persisted = try XCTUnwrap(restartedStore.record(forKey: original.key))
        XCTAssertEqual(persisted.logicalCaseID, original.logicalCaseID)
        XCTAssertEqual(persisted.collectionNames, original.collections)
        XCTAssertEqual(persisted.eventJournal, original.journal)
        XCTAssertEqual(persisted.eventJournal?.events.map(\.id), original.journal.events.map(\.id))
        XCTAssertTrue(persisted.movement?.acts.contains { $0.id == original.actID } == true)
        XCTAssertEqual(persisted.movement?.actBodies[original.actID], file.text)
        XCTAssertEqual(persisted.movement?.acts.first { $0.id == original.actID }?.fileProvenance,
                       file.provenance)

        let restartedSelection = PublishedActSelection(
            cache: ActFileCache(directory: pdfDirectory)) { url, number in
                try await fetcher.fetch(url: url, productionNumber: number)
            }
        let restartedRouter = try AppRouter(
            modelContainer: restartedContainer, modelContainerIsPrepared: true,
            selectedPublishedAct: restartedSelection)
        restartedRouter.openCase(key: original.key)
        await wait {
            !restartedSelection.isLoading && restartedSelection.data == data
                && restartedSelection.fileURL != nil
        }

        XCTAssertEqual(persisted.key, original.key)
        XCTAssertEqual(restartedRouter.selectedActID, original.actID)
        XCTAssertEqual(restartedRouter.selectedPublishedAct.text, file.text)
        XCTAssertEqual(restartedRouter.selectedPublishedAct.provenance, file.provenance)
        XCTAssertEqual(restartedRouter.selectedPublishedAct.data, data)
        XCTAssertEqual(restartedRouter.liveMovement?.actBodies[original.actID], file.text)
        let restartedFetchCount = await fetcher.count
        XCTAssertEqual(restartedFetchCount, 1, "The separate PDF cache serves the restart offline.")
    }

    private func publishedAct(id: String = "published", number: String? = nil,
                              url: URL? = nil) -> CaseAct {
        CaseAct(id: id, title: "Определение", date: "15.10.2025", courtShort: "ВС РФ",
                instanceLevel: .vsCassation, sourceFileURL: url ?? sourceURL,
                productionNumber: number ?? caseNumber)
    }

    private func publishedFile(data: Data, text: String, url: URL? = nil) -> PublishedActFile {
        let url = url ?? sourceURL
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let provenance = PublishedActProvenance(
            sourceURL: url, finalURL: url, format: .pdf, contentType: "application/pdf",
            contentHash: hash, byteCount: data.count,
            fetchedAt: Date(timeIntervalSince1970: 1_759_000_000), extractorVersion: 1)
        return PublishedActFile(text: text, provenance: provenance, data: data)
    }

    private func pdfData() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "valid", withExtension: "pdf",
            subdirectory: "Fixtures/published-act"))
        return try Data(contentsOf: url)
    }

    private func fileCache() throws -> ActFileCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("published-act-selection-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ActFileCache(directory: directory)
    }

    private func seedAndLoadTrackedFile(storeURL: URL, pdfDirectory: URL,
                                        file: PublishedActFile,
                                        fetcher: FetchStub) async throws -> RestartEvidence {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru", displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001", cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-42/2026", caseID: "restart-case", caseUID: "restart-uid")
        let act = publishedAct(number: context.caseNumber)
        let movement = CaseMovement(
            uid: context.caseUID ?? "", caseNumber: context.caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
                judge: nil, domain: context.searchDomain, foundByUID: true, result: nil,
                sessions: [], actID: act.id)],
            complaints: [:], acts: [act])
        let record = try store.upsert(
            context: context,
            snapshot: MovementDerivation.snapshot(from: movement, context: context),
            movement: movement, collections: ["Коллекция для проверки рестарта"])
        let event = CaseEvent.make(
            kind: .hearingScheduled, occurrence: [record.key, "before-restart"],
            observedAt: Date(timeIntervalSince1970: 1_759_000_000),
            evidence: CaseEventEvidence(caseNumber: context.caseNumber, dateRaw: "20.10.2025"))
        var journal = try XCTUnwrap(record.eventJournal)
        journal.events = [event]
        try store.commit(projection: { _ in .none }) {
            record.eventJournal = journal
        }

        let selection = PublishedActSelection(cache: ActFileCache(directory: pdfDirectory)) {
            url, number in try await fetcher.fetch(url: url, productionNumber: number)
        }
        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true,
            selectedPublishedAct: selection)
        router.openCase(key: record.key)
        await wait {
            !selection.isLoading && selection.data == file.data
                && router.liveMovement?.actBodies[act.id] == file.text
        }

        let saved = try XCTUnwrap(store.record(forKey: record.key))
        return RestartEvidence(
            key: saved.key, logicalCaseID: try XCTUnwrap(saved.logicalCaseID),
            actID: act.id, collections: saved.collectionNames,
            journal: try XCTUnwrap(saved.eventJournal))
    }

    private func wait(_ predicate: @MainActor () async -> Bool) async {
        for _ in 0..<400 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for published act selection")
    }
}

private struct RestartEvidence {
    let key: String
    let logicalCaseID: UUID
    let actID: String
    let collections: [String]
    let journal: CaseEventJournal
}

@MainActor
private final class ApplyRecorder {
    var ids: [String] = []
}

private actor FetchStub {
    private let file: PublishedActFile
    private(set) var count = 0

    init(file: PublishedActFile) { self.file = file }

    func fetch(url: URL, productionNumber: String?) async throws -> PublishedActFile {
        count += 1
        return file
    }
}

private actor SuspendedFetchStub {
    private let file: PublishedActFile
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    private(set) var hasStarted = false

    init(file: PublishedActFile) { self.file = file }

    func fetch(url: URL, productionNumber: String?) async throws -> PublishedActFile {
        count += 1
        hasStarted = true
        await withCheckedContinuation { continuation = $0 }
        return file
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RetryFetchStub {
    private let file: PublishedActFile
    private(set) var count = 0

    init(file: PublishedActFile) { self.file = file }

    func fetch(url: URL, productionNumber: String?) async throws -> PublishedActFile {
        count += 1
        if count == 1 { throw URLError(.timedOut) }
        return file
    }
}

private actor DelayedFetchStub {
    private let firstURL: URL
    private let first: PublishedActFile
    private let secondURL: URL
    private let second: PublishedActFile
    private(set) var isWaitingForFirst = false
    private(set) var didReturnFirst = false

    init(firstURL: URL, first: PublishedActFile, secondURL: URL, second: PublishedActFile) {
        self.firstURL = firstURL
        self.first = first
        self.secondURL = secondURL
        self.second = second
    }

    func fetch(url: URL) async throws -> PublishedActFile {
        if url == firstURL {
            isWaitingForFirst = true
            try? await Task.sleep(nanoseconds: 30_000_000)
            didReturnFirst = true
            return first
        }
        guard url == secondURL else { throw URLError(.badURL) }
        return second
    }
}
