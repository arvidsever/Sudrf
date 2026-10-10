import Foundation
import XCTest
import Synchronization
@testable import SudrfKit
@testable import SudrfApp
import CaptchaSolver

private struct CSVRepairOrigin: CaseOriginResolving {
    func resolve(anchorContext: MovementContext, anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        throw CaseOriginResolutionError.notFound
    }
}
private struct CSVResolvedOrigin: CaseOriginResolving {
    let origin: ResolvedCaseOrigin
    var unresolvedNumber: String? = nil
    func resolve(anchorContext: MovementContext, anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        if anchorContext.caseNumber == unresolvedNumber { throw CaseOriginResolutionError.notFound }
        return origin
    }
}
private actor CSVPrivateSpotlightWriter: SpotlightIndexWriting {
    func index(cases: [CaseEntity], acts: [CourtActEntity]) async throws {}
    func delete(caseIDs: [String], actIDs: [String]) async throws {}
    func deleteAll() async throws {}
}
private final class CSVRejectNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Unexpected network in isolated CSV lifecycle test")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}
private final class CSVImportCardProtocol: URLProtocol {
    static let requests = Mutex<[URL]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.httpMethod == "GET", let url = request.url, url.host == "test--region.sudrf.ru", url.path == "/modules.php",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              query.contains(where: { $0.name == "name_op" && $0.value == "sf" }) || query.contains(where: { $0.name == "case_id" && ["1", "2"].contains($0.value ?? "") }) else {
            XCTFail("Unexpected CSV fixture request: \(request.url?.absoluteString ?? "nil")"); client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        Self.requests.withLock { $0.append(url) }
        let id = query.first(where: { $0.name == "case_id" })?.value ?? ""
        let html = id.isEmpty ? "<html><form id='search-form'></form></html>" : "<html><body><h2 class='casenumber'>ДЕЛО № 33-\(id)/2026</h2><table><tr><td>Номер дела</td><td>33-\(id)/2026</td></tr></table></body></html>"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"text/html; charset=utf-8"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor private final class CSVCardBarrier {
    var calls: [String] = []
    private var anyStarted: CheckedContinuation<String, Never>?
    func waitAny() async -> String {
        if let number = pending.keys.first { return number }
        return await withCheckedContinuation { anyStarted = $0 }
    }
    private var started: [String: CheckedContinuation<Void, Never>] = [:]
    private var pending: [String: CheckedContinuation<CaseCard, Never>] = [:]
    func fetch(_ context: MovementContext) async -> CaseCard {
        calls.append(context.caseNumber)
        anyStarted?.resume(returning: context.caseNumber); anyStarted = nil
        return await withCheckedContinuation {
            pending[context.caseNumber] = $0
            started.removeValue(forKey: context.caseNumber)?.resume()
        }
    }
    func wait(_ number: String) async {
        if pending[number] != nil { return }
        await withCheckedContinuation { started[number] = $0 }
    }
    func finish(_ number: String) {
        pending.removeValue(forKey: number)?.resume(returning: CaseCard(rawText: "", actText: nil,
            caseNumber: number))
    }
}

@MainActor final class CSVBackgroundRepairTests: XCTestCase {
    private func context(_ number: String) -> MovementContext {
        var context = MovementContext(branchRaw: "general", region: "Тестовый регион",
            searchDomain: "test--region.sudrf.ru", displayDomain: "test--region.sudrf.ru",
            courtTitle: "Тестовый областной суд", courtLevelRaw: CourtLevel.subject.rawValue,
            cartotekaId: "g2", cartotekaLevelRaw: CourtLevel.subject.rawValue,
            caseNumber: number, caseID: number, caseUID: "guid-\(number)",
            cardURLString: "https://test--region.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=\(number)&case_uid=guid&delo_id=5")
        context.baseInstanceLevelRaw = CaseInstance.Level.appeal.rawValue
        return context
    }

    private func privateDefaults() throws -> (UserDefaults, String) {
        let suite = "Sudrf.CSVBackgroundRepairTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    func testCSVAtomicCommitSoftStopAndDiskReopenPreserveImportedRecords() async throws {
        let (defaults, suite) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csv250-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = root.appendingPathComponent("fixture.store")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CSVImportCardProtocol.self]; config.httpCookieStorage = nil
        config.httpShouldSetCookies = false; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        CSVImportCardProtocol.requests.withLock { $0 = [] }
        defer { CSVImportCardProtocol.requests.withLock { $0 = [] } }
        let client = SudrfClient(session: session, minInterval: 0, variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: CaptchaTokenStore())
        let barrier = CSVCardBarrier()
        var pair: (AppRouter, TrackedStore)? = try makeRouter(defaults: defaults, suite: suite, root: root,
            diskURL: disk, importClient: client, fetch: { await barrier.fetch($0) })
        let csv = "number,court,parties,url\n" + ["1", "2"].map {
            "33-\($0)/2026,Тестовый областной суд,Тестовый участник,https://test--region.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=\($0)&case_uid=00000000-0000-0000-0000-00000000000\($0)&delo_id=5"
        }.joined(separator: "\n")
        pair!.0.beginImport(csvText: csv)
        let number = await barrier.waitAny()
        XCTAssertEqual(pair!.1.all().count, 2)
        guard case .finished(let initial) = pair!.0.importState else { return XCTFail("Initial atomic import report missing") }
        XCTAssertEqual(initial.cases, 2); XCTAssertEqual(initial.cold, 0)
        XCTAssertEqual(initial.parsing, 0); XCTAssertEqual(initial.transient, 0)
        let ids = CSVImportCardProtocol.requests.withLock { urls in urls.compactMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "case_id" })?.value
        } }
        XCTAssertEqual(ids, ["1", "2"])
        XCTAssertEqual(Set(pair!.1.all().map(\.caseNumber)), Set(["33-1/2026", "33-2/2026"]))
        let first = try XCTUnwrap(pair!.1.all().first(where: { $0.caseNumber == number })).key
        pair!.0.dismissImportSummary(); XCTAssertFalse(pair!.0.importSheetPresented)
        pair!.0.showImportProgress(); XCTAssertTrue(pair!.0.importSheetPresented)
        pair!.0.stopImportRepair(); barrier.finish(number)
        await pair!.0.importRepairTask?.value
        XCTAssertEqual(barrier.calls, [number])
        XCTAssertEqual(pair!.0.completedImportKeys, [first])
        XCTAssertEqual(pair!.0.originalImportKeys.count, 2)
        let saved = pair!.1.all().map { ($0.key, $0.caseNumber, $0.collectionNames, $0.contextData, $0.movementData, $0.snapshotData, $0.eventJournalData, $0.logicalCaseID) }
        XCTAssertTrue(saved.allSatisfy { !$0.2.isEmpty })
        pair = nil
        let reopened = try TrackedStore(container: try SudrfModelContainerFactory.make(inMemory: false, storeURL: disk), prepared: true)
        XCTAssertEqual(reopened.all().count, 2)
        for expected in saved {
            let actual = try XCTUnwrap(reopened.record(forKey: expected.0))
            XCTAssertEqual(actual.caseNumber, expected.1); XCTAssertEqual(actual.collectionNames, expected.2)
            XCTAssertEqual(actual.contextData, expected.3); XCTAssertEqual(actual.movementData, expected.4)
            XCTAssertEqual(actual.snapshotData, expected.5); XCTAssertEqual(actual.eventJournalData, expected.6)
            XCTAssertEqual(actual.logicalCaseID, expected.7)
        }
    }

    func testForegroundPreflightCompletesBeforeNextBackgroundAdmission() async throws {
        let (defaults, suite) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TrackedStore(inMemory: true)
        let barrier = CSVCardBarrier()
        let a = try store.upsert(context: context("33-1/2026"), snapshot: nil, collections: [])
        let b = try store.upsert(context: context("33-2/2026"), snapshot: nil, collections: [])
        let x = try store.upsert(context: context("33-3/2026"), snapshot: nil, collections: [])
        let coordinator = TrackedCaseRepairCoordinator(store: store, client: TestNetworkGuard.sudrfClient(),
            originResolver: CSVRepairOrigin(), defaults: defaults, anchorCardFetcher: { await barrier.fetch($0) })
        let background = Task {
            _ = try await coordinator.runBackground(key: a.key)
            _ = try await coordinator.runBackground(key: b.key)
        }
        await barrier.wait(a.caseNumber)
        var interactive: Task<TrackedCaseRepairCoordinator.Outcome, Error>!
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            interactive = Task {
                started.resume()
                return try await coordinator.repairIfNeeded(key: x.key)
            }
        }
        XCTAssertEqual(coordinator.foregroundRepairDemand, 1)
        barrier.finish(a.caseNumber)
        await barrier.wait(x.caseNumber)
        XCTAssertEqual(barrier.calls, [a.caseNumber, x.caseNumber])
        barrier.finish(x.caseNumber)
        _ = try await interactive.value
        await barrier.wait(b.caseNumber)
        XCTAssertEqual(barrier.calls, [a.caseNumber, x.caseNumber, b.caseNumber])
        barrier.finish(b.caseNumber)
        try await background.value
    }

    private func makeRouter(defaults: UserDefaults, suite: String, root: URL,
                            originResolver: any CaseOriginResolving = CSVRepairOrigin(),
                            tokens: CaptchaTokenStore = CaptchaTokenStore(),
                            diskURL: URL? = nil, importClient: SudrfClient? = nil,
                            fetch: @escaping (MovementContext) async throws -> CaseCard) throws
        -> (AppRouter, TrackedStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CSVRejectNetwork.self]
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let vsrf = VSRFClient(session: session, minInterval: 0)
        let moscow = MosGorSudClient(session: session, minInterval: 0)
        let settings = CaptchaSettings(defaults: defaults)
        var store: TrackedStore!
        let router = try AppRouter(captchaSettings: settings,
            modelContainer: SudrfModelContainerFactory.make(inMemory: diskURL == nil, storeURL: diskURL), modelContainerIsPrepared: true,
            captchaCorpus: CorpusStore(baseDir: root.appendingPathComponent("corpus")),
            refreshCenterFactory: { suppliedStore, client in
                store = suppliedStore
                return RefreshCenter(store: suppliedStore, client: client, captchaTokenStore: tokens,
                    serviceBuilder: { _ in XCTFail("Unexpected refresh in CSV lifecycle"); return MovementService(client: client) },
                    treasuryDiscover: { _, _, _ in throw URLError(.unsupportedURL) }, vsrfProvider: vsrf,
                    fsspAutoModelEnabled: false, fsspDiscover: { _ in throw URLError(.unsupportedURL) })
            }, importVSRFProvider: vsrf, importMosGorSudProvider: moscow,
            selectedPublishedAct: PublishedActSelection(cache: ActFileCache(directory: root.appendingPathComponent("acts")),
                fetch: { _, _ in throw URLError(.unsupportedURL) }),
            userDefaults: defaults, client: importClient ?? TestNetworkGuard.sudrfClient(), captchaTokenStore: tokens,
            directCaseLinkResolverFactory: { _ in DirectCaseLinkResolver(fetchCard: { _ in throw URLError(.unsupportedURL) },
                districtCourts: { _ in throw URLError(.unsupportedURL) }) },
            spotlightIndexerFactory: { catalog in SpotlightIndexer(catalog: catalog,
                writer: CSVPrivateSpotlightWriter(), manifestStore: SpotlightManifestStore(suiteName: suite),
                preferenceStore: SpotlightPreferenceStore(suiteName: suite)) },
            currentEntityActivityPublisher: { _ in XCTFail("Unexpected activity publication") },
            feedNotificationPublisher: { _ in XCTFail("Unexpected notification publication") },
            feedBadgePublisher: { _ in }, notificationOpenInstaller: { _ in }, intentInstaller: { _ in },
            captchaSolverFactory: { _ in nil }, repairCoordinatorFactory: { store, client in
                TrackedCaseRepairCoordinator(store: store, client: client, originResolver: originResolver,
                    defaults: defaults, anchorCardFetcher: fetch)
            })
        return (router, try XCTUnwrap(store))
    }

    func testClosingAndReopeningReportKeepsOperationAndSoftStopFinishesOnlyCurrentCard() async throws {
        let (defaults, suite) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csv250-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = CSVCardBarrier()
        let (router, store) = try makeRouter(defaults: defaults, suite: suite, root: root,
            fetch: { await barrier.fetch($0) })
        let a = try store.upsert(context: context("33-1/2026"), snapshot: nil, collections: ["Импорт"])
        let b = try store.upsert(context: context("33-2/2026"), snapshot: nil, collections: ["Импорт"])
        let rows = [a.key: [ImportedRow(number: a.caseNumber, court: a.courtTitle, parties: "", urlString: "a")],
                    b.key: [ImportedRow(number: b.caseNumber, court: b.courtTitle, parties: "", urlString: "b")]]
        var summary = ImportSummary(); summary.cases = 2; summary.total = 2
        router.beginCommittedImportRepair(summary: summary, rowsByKey: rows)
        await barrier.wait(a.caseNumber)
        router.dismissImportSummary()
        XCTAssertFalse(router.importSheetPresented)
        XCTAssertEqual(router.importRepairProgress?.total, 2)
        router.showImportProgress()
        XCTAssertTrue(router.importSheetPresented)
        router.stopImportRepair()
        barrier.finish(a.caseNumber)
        await router.importRepairTask?.value
        XCTAssertEqual(barrier.calls, [a.caseNumber])
        XCTAssertEqual(router.completedImportKeys, [a.key])
        XCTAssertEqual(router.originalImportKeys.count, 2)
        XCTAssertEqual(store.all().count, 2)
        guard case .finished(let report) = router.importState else { return XCTFail("Saved import report missing") }
        XCTAssertEqual(report.cases, 2)
        XCTAssertTrue(report.issues.contains { $0.reason.contains("1 из 2") })
        XCTAssertTrue(report.repairEvents.contains { $0.caseKey == a.key })
        XCTAssertFalse(report.repairEvents.contains { $0.caseKey == b.key })
    }
    func testStopWhileWaitingForAnotherRepairDoesNotAdmitImportCard() async throws {
        let (defaults, suite) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TrackedStore(inMemory: true)
        let barrier = CSVCardBarrier()
        let x = try store.upsert(context: context("33-0/2026"), snapshot: nil, collections: [])
        let a = try store.upsert(context: context("33-1/2026"), snapshot: nil, collections: [])
        let coordinator = TrackedCaseRepairCoordinator(store: store, client: TestNetworkGuard.sudrfClient(),
            originResolver: CSVRepairOrigin(), defaults: defaults, anchorCardFetcher: { await barrier.fetch($0) })
        let other = Task { try await coordinator.run(keys: [x.key]) }
        await barrier.wait(x.caseNumber)
        var stopped = false
        var background: Task<CaseRepairSummary, Error>!
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            background = Task {
                waiting.resume()
                return try await coordinator.runBackground(key: a.key, admit: { !stopped })
            }
        }
        stopped = true
        barrier.finish(x.caseNumber)
        _ = try await other.value
        do { _ = try await background.value; XCTFail("Stopped admission must not run") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(barrier.calls, [x.caseNumber])
    }

    func testOriginalDenominatorIncludesMissingIneligibleAndBackoffKeys() async throws {
        let (defaults, suite) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csv250-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var fetched: [String] = []
        let (router, store) = try makeRouter(defaults: defaults, suite: suite, root: root, fetch: {
            fetched.append($0.caseNumber)
            return CaseCard(rawText: "", actText: nil, caseNumber: $0.caseNumber)
        })
        let a = try store.upsert(context: context("33-1/2026"), snapshot: nil, collections: [])
        let backoff = try store.upsert(context: context("33-2/2026"), snapshot: nil, collections: [])
        var lower = context("2-3/2026"); lower.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        let ineligible = try store.upsert(context: lower, snapshot: nil, collections: [])
        defaults.set([backoff.key: Date().addingTimeInterval(3600).timeIntervalSince1970],
            forKey: "importChainRepair.v6.nextRetry")
        let keys = [a.key, backoff.key, ineligible.key, "missing"]
        let rows = Dictionary(uniqueKeysWithValues: keys.map { ($0, [ImportedRow(number: $0,
            court: "Тестовый суд", parties: "", urlString: $0)]) })
        var summary = ImportSummary(); summary.cases = 4; summary.total = 4
        router.beginCommittedImportRepair(summary: summary, rowsByKey: rows)
        await router.importRepairTask?.value
        XCTAssertEqual(router.originalImportKeys.count, 4)
        XCTAssertEqual(router.completedImportKeys, Set(keys))
        XCTAssertEqual(fetched, [a.caseNumber])
    }

    func testLaterPersistenceFailureKeepsFirstResultAndDoesNotCountFailedRemainder() async throws {
        let (defaults, suite) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csv250-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var canonical = context("2-10/2026")
        canonical.searchDomain = "lower--region.sudrf.ru"
        canonical.courtTitle = "Тестовый городской суд"
        canonical.courtLevelRaw = CourtLevel.district.rawValue
        canonical.cartotekaLevelRaw = CourtLevel.district.rawValue
        canonical.cartotekaId = "g1"
        canonical.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        let uid = "11RS0001-01-2026-009999-11"
        let origin = ResolvedCaseOrigin(court: canonical.searchCourt, branch: .general,
            region: canonical.region, courtCode: canonical.courtCode,
            cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1")),
            result: CaseSearchResult(caseNumber: canonical.caseNumber, caseID: "lower", caseUID: "lower-guid"),
            card: CaseCard(rawText: "", actText: nil, uid: uid, caseNumber: canonical.caseNumber))
        var capturedStore: TrackedStore!
        var fetched: [String] = []
        let (router, store) = try makeRouter(defaults: defaults, suite: suite, root: root, originResolver: CSVResolvedOrigin(origin: origin), fetch: {
            fetched.append($0.caseNumber)
            if $0.caseNumber == "33-2/2026" { capturedStore.failNextSaveForTesting = true }
            return CaseCard(rawText: "", actText: nil, uid: uid, caseNumber: $0.caseNumber)
        })
        capturedStore = store
        let records = try ["33-1/2026", "33-2/2026", "33-3/2026"].map {
            try store.upsert(context: context($0), snapshot: nil, collections: ["Импорт"])
        }
        let firstKey = records[0].key
        let lastKey = records[2].key
        let rows = Dictionary(uniqueKeysWithValues: records.map { ($0.key,
            [ImportedRow(number: $0.caseNumber, court: $0.courtTitle, parties: "", urlString: $0.key)]) })
        var summary = ImportSummary(); summary.cases = 3; summary.total = 3
        router.beginCommittedImportRepair(summary: summary, rowsByKey: rows)
        await router.importRepairTask?.value
        XCTAssertEqual(fetched, ["33-1/2026", "33-2/2026"])
        XCTAssertEqual(router.completedImportKeys, [firstKey])
        XCTAssertEqual(router.originalImportKeys.count, 3)
        XCTAssertEqual(store.all().count, 3)
        guard case .finished(let report) = router.importState else { return XCTFail("Report missing") }
        XCTAssertTrue(report.repairEvents.contains { $0.caseKey == firstKey })
        XCTAssertFalse(report.repairEvents.contains { $0.caseKey == lastKey })
        XCTAssertTrue(report.issues.contains { $0.reason.contains("не завершено") })
    }

    func testRepeatedCaptchaRetryDoesNotCountOriginalAgainAndLateStoppedFormCannotRestart() async throws {
        let (defaults, suite) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csv250-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let formURL = try XCTUnwrap(URL(string: "https://test--region.sudrf.ru/captcha"))
        let barrier = CSVCardBarrier()
        let tokens = CaptchaTokenStore()
        var calls: [String] = []
        var captchaNeeded = true
        let (router, store) = try makeRouter(defaults: defaults, suite: suite, root: root, tokens: tokens, fetch: {
            calls.append($0.caseNumber)
            if $0.caseNumber == "33-1/2026", captchaNeeded { throw SudrfError.captchaRequired(formURL: formURL) }
            if $0.caseNumber == "33-2/2026" { return await barrier.fetch($0) }
            return CaseCard(rawText: "", actText: nil, caseNumber: $0.caseNumber)
        })
        let a = try store.upsert(context: context("33-1/2026"), snapshot: nil, collections: [])
        let row = ImportedRow(number: a.caseNumber, court: a.courtTitle, parties: "", urlString: a.key)
        var summary = ImportSummary(); summary.cases = 1; summary.total = 1
        router.beginCommittedImportRepair(summary: summary, rowsByKey: [a.key: [row]])
        await router.importRepairTask?.value
        guard case .finished(let initial) = router.importState else { return XCTFail("Report missing") }
        XCTAssertEqual(initial.repairEvents.filter { $0.kind == .captcha }.count, 1)
        let group = RepairCaptchaGroup(host: "test--region.sudrf.ru", requests: [RepairCaptchaRequest(
            key: a.key, caseNumber: a.caseNumber, courtTitle: a.courtTitle, formURL: formURL)])
        captchaNeeded = false
        for _ in 0..<2 {
            router.beginRepairCaptcha(group)
            let generation = try XCTUnwrap(router.captcha?.importRepairGeneration)
            router.captchaSessionUnlocked(host: group.host, originGeneration: generation)
            await router.importRepairTask?.value
        }
        XCTAssertEqual(router.completedImportKeys, [a.key])
        XCTAssertEqual(router.originalImportKeys.count, 1)
        guard case .finished(let repeated) = router.importState else { return XCTFail("Report missing") }
        XCTAssertTrue(repeated.repairEvents.filter { $0.kind == .captcha }.isEmpty)
        XCTAssertEqual(repeated.repairEvents.filter { $0.kind == .firstInstanceNotFound }.count, 1)
        // A new stopped operation has one CAPTCHA result and a different active card.
        captchaNeeded = true
        let b = try store.upsert(context: context("33-2/2026"), snapshot: nil, collections: [])
        // Explicit first operation already completed A; force a fresh retry marker for the new profile.
        defaults.removeObject(forKey: "importChainRepair.v6.unsupported")
        defaults.removeObject(forKey: "importChainRepair.v6.completed")
        defaults.removeObject(forKey: "importChainRepair.v6.nextRetry")
        router.beginCommittedImportRepair(summary: summary, rowsByKey: [a.key: [row], b.key: [row]])
        await barrier.wait(b.caseNumber)
        router.beginRepairCaptcha(group)
        let stoppedGeneration = try XCTUnwrap(router.captcha?.importRepairGeneration)
        router.stopImportRepair()
        barrier.finish(b.caseNumber)
        await router.importRepairTask?.value
        let stoppedCalls = calls
        router.captchaSessionUnlocked(host: group.host, originGeneration: stoppedGeneration)
        XCTAssertNil(router.importRepairTask)
        XCTAssertEqual(calls, stoppedCalls)
        let token = CaptchaToken(value: "synthetic", id: "synthetic")
        XCTAssertNil(router.storeCaptchaPair(host: group.host, token: token, originGeneration: stoppedGeneration))
        let ordinary = router.storeCaptchaPair(host: group.host, token: token)
        XCTAssertNotNil(ordinary)
        await ordinary?.value
        let accepted = await tokens.token(forDomain: group.host)
        XCTAssertEqual(accepted, token)
        XCTAssertEqual(calls, stoppedCalls)
        router.dismissImportSummary()
        let ordinaryCase = try store.upsert(context: context("33-9/2026"), snapshot: nil, collections: [])
        let ordinaryGroup = RepairCaptchaGroup(host: group.host, requests: [RepairCaptchaRequest(
            key: ordinaryCase.key, caseNumber: ordinaryCase.caseNumber,
            courtTitle: ordinaryCase.courtTitle, formURL: formURL)])
        router.beginRepairCaptcha(ordinaryGroup)
        XCTAssertNil(router.captcha?.importRepairGeneration)
        router.captchaSessionUnlocked(host: ordinaryGroup.host)
        await router.importRepairTask?.value
        XCTAssertTrue(router.repairSummary?.events.contains { $0.caseKey == ordinaryCase.key } == true)
        XCTAssertFalse(router.importSheetPresented)
    }

    func testStopDuringCaptchaRetryFinishesCurrentAndDoesNotAdmitNextKey() async throws {
        let (defaults, suite) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csv250-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let formURL = try XCTUnwrap(URL(string: "https://test--region.sudrf.ru/captcha"))
        let barrier = CSVCardBarrier()
        var retry = false
        var calls: [String] = []
        let (router, store) = try makeRouter(defaults: defaults, suite: suite, root: root, fetch: {
            calls.append($0.caseNumber)
            if !retry { throw SudrfError.captchaRequired(formURL: formURL) }
            return await barrier.fetch($0)
        })
        let a = try store.upsert(context: context("33-1/2026"), snapshot: nil, collections: [])
        let b = try store.upsert(context: context("33-2/2026"), snapshot: nil, collections: [])
        let row = ImportedRow(number: a.caseNumber, court: a.courtTitle, parties: "", urlString: a.key)
        var summary = ImportSummary(); summary.cases = 2; summary.total = 2
        router.beginCommittedImportRepair(summary: summary, rowsByKey: [a.key: [row], b.key: [row]])
        await router.importRepairTask?.value
        let group = RepairCaptchaGroup(host: "test--region.sudrf.ru", requests: [a, b].map {
            RepairCaptchaRequest(key: $0.key, caseNumber: $0.caseNumber, courtTitle: $0.courtTitle, formURL: formURL)
        })
        router.beginRepairCaptcha(group)
        let generation = try XCTUnwrap(router.captcha?.importRepairGeneration)
        retry = true
        router.captchaSessionUnlocked(host: group.host, originGeneration: generation)
        await barrier.wait(a.caseNumber)
        XCTAssertEqual(router.importRepairProgress?.done, 2)
        XCTAssertEqual(router.importRepairProgress?.total, 2)
        router.stopImportRepair()
        barrier.finish(a.caseNumber)
        await router.importRepairTask?.value
        XCTAssertEqual(calls, [a.caseNumber, b.caseNumber, a.caseNumber])
        XCTAssertEqual(router.completedImportKeys, [a.key, b.key])
        XCTAssertEqual(router.originalImportKeys.count, 2)
        guard case .finished(let report) = router.importState else { return XCTFail("Report missing") }
        XCTAssertEqual(report.repairEvents.filter { $0.kind == .captcha }.map(\.caseKey), [b.key])
        XCTAssertTrue(report.issues.contains { $0.reason.contains("остановлена") })
        XCTAssertNil(router.importRepairProgress)
    }

    func testOriginalAliasesMergedByFirstRepairCountOnceWithoutAnotherFetch() async throws {
        let (defaults, suite) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csv250-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "11RS0001-01-2026-009999-11"
        var canonical = context("2-10/2026")
        canonical.searchDomain = "zzz--region.sudrf.ru"
        canonical.displayDomain = canonical.searchDomain
        canonical.cardURLString = canonical.cardURLString?.replacingOccurrences(of: "test--region", with: "zzz--region")
        canonical.courtTitle = "Тестовый городской суд"
        canonical.courtLevelRaw = CourtLevel.district.rawValue
        canonical.cartotekaLevelRaw = CourtLevel.district.rawValue
        canonical.cartotekaId = "g1"
        canonical.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        canonical.judicialUID = uid
        let origin = ResolvedCaseOrigin(court: canonical.searchCourt, branch: .general,
            region: canonical.region, courtCode: canonical.courtCode,
            cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1")),
            result: CaseSearchResult(caseNumber: canonical.caseNumber, caseID: "lower", caseUID: "lower-guid"),
            card: CaseCard(rawText: "", actText: nil, uid: uid, caseNumber: canonical.caseNumber))
        var fetched: [String] = []
        var captchaNeeded = true
        let formURL = try XCTUnwrap(URL(string: "https://zzz--region.sudrf.ru/captcha"))
        let (router, store) = try makeRouter(defaults: defaults, suite: suite, root: root,
            originResolver: CSVResolvedOrigin(origin: origin, unresolvedNumber: "33-3/2026"), fetch: {
                fetched.append($0.caseNumber)
                if $0.caseNumber == "33-3/2026" {
                    if captchaNeeded { throw SudrfError.captchaRequired(formURL: formURL) }
                    return CaseCard(rawText: "", actText: nil, caseNumber: $0.caseNumber)
                }
                return CaseCard(rawText: "", actText: nil, uid: uid, caseNumber: $0.caseNumber)
            })
        var anchor = context("33-1/2026")
        anchor.searchDomain = "aaa--region.sudrf.ru"
        anchor.displayDomain = anchor.searchDomain
        anchor.cardURLString = anchor.cardURLString?.replacingOccurrences(of: "test--region", with: "aaa--region")
        let a = try store.upsert(context: anchor, snapshot: nil, collections: ["A"])
        let b = try store.upsert(context: canonical, snapshot: nil, collections: ["B"])
        var pending = context("33-3/2026")
        pending.searchDomain = canonical.searchDomain
        pending.cardURLString = pending.cardURLString?.replacingOccurrences(of: "test--region", with: "zzz--region")
        let c = try store.upsert(context: pending, snapshot: nil, collections: [])
        let originalKeys = [a.key, b.key, c.key]
        let rows = Dictionary(uniqueKeysWithValues: originalKeys.map { ($0,
            [ImportedRow(number: $0, court: "Тестовый суд", parties: "", urlString: $0)]) })
        var summary = ImportSummary(); summary.cases = 3; summary.total = 3
        router.beginCommittedImportRepair(summary: summary, rowsByKey: rows)
        await router.importRepairTask?.value
        XCTAssertEqual(fetched, [anchor.caseNumber, c.caseNumber])
        XCTAssertEqual(router.completedImportKeys, Set(originalKeys))
        XCTAssertEqual(router.originalImportKeys.count, 3)
        XCTAssertEqual(store.all().count, 2)
        guard case .finished(let report) = router.importState else { return XCTFail("Report missing") }
        XCTAssertEqual(report.stitchedExisting, 1)
        XCTAssertEqual(report.recoveredDown, 1)
        XCTAssertEqual(report.repairEvents.filter { $0.kind == .reanchored }.count, 1)
        captchaNeeded = false
        let group = RepairCaptchaGroup(host: "zzz--region.sudrf.ru", requests: [RepairCaptchaRequest(
            key: c.key, caseNumber: c.caseNumber, courtTitle: c.courtTitle, formURL: formURL)])
        for _ in 0..<2 {
            router.beginRepairCaptcha(group)
            let generation = try XCTUnwrap(router.captcha?.importRepairGeneration)
            router.captchaSessionUnlocked(host: group.host, originGeneration: generation)
            await router.importRepairTask?.value
        }
        guard case .finished(let final) = router.importState else { return XCTFail("Report missing") }
        XCTAssertEqual(final.stitchedExisting, 1)
        XCTAssertEqual(final.recoveredDown, 1)
        XCTAssertEqual(final.repairEvents.filter { $0.kind == .reanchored }.count, 1)
        XCTAssertTrue(final.repairEvents.filter { $0.kind == .captcha }.isEmpty)
        XCTAssertEqual(router.completedImportKeys, Set(originalKeys))

    }

}
