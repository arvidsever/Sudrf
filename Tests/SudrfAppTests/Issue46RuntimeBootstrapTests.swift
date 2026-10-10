import Foundation
import SwiftData
import XCTest
@testable import SudrfKit
@testable import SudrfApp
@testable import CaptchaSolver

private final class CSVRejectNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Unexpected network in private bootstrap profile")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
private struct CSVRepairOrigin: CaseOriginResolving {
    func resolve(anchorContext: MovementContext, anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        throw CaseOriginResolutionError.notFound
    }
}
private actor CSVPrivateSpotlightWriter: SpotlightIndexWriting {
    func index(cases: [CaseEntity], acts: [CourtActEntity]) async throws {}
    func delete(caseIDs: [String], actIDs: [String]) async throws {}
    func deleteAll() async throws {}
}
private actor Issue46LoaderGate {
    private var entered = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true; observer?.resume(); observer = nil
        await withCheckedContinuation { pending = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
@MainActor final class Issue46RuntimeBootstrapTests: XCTestCase {
    private var client: SudrfClient!
    func testPreparedContainerFactoryInstallsActualRuntimeAndStartsCatalogWithoutPreinstall() async throws {
        let suite = "Sudrf.Issue46.Runtime." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
        defaults.set(false, forKey: SpotlightPreferenceStore.key)
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("issue46-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CSVRejectNetwork.self]; config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let tokens = CaptchaTokenStore()
        client = SudrfClient(session: session, minInterval: 0,
            variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: tokens)
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let seed = try TrackedStore(container: container, prepared: true)
        let ctx = MovementContext(branchRaw: "general", region: "Тестовый регион",
            searchDomain: "test--region.sudrf.ru", displayDomain: "test--region.sudrf.ru",
            courtTitle: "Тестовый районный суд", courtLevelRaw: CourtLevel.district.rawValue,
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-46/2099", caseID: "46", caseUID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            cardURLString: "https://test--region.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=46&case_uid=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa&delo_id=1540005")
        let movement = CaseMovement(uid: "", caseNumber: ctx.caseNumber, inForce: false,
            instances: [CaseInstance(level: .first, court: ctx.courtTitle, caseNumber: ctx.caseNumber,
                judge: nil, domain: ctx.displayDomain, foundByUID: false, result: nil,
                sessions: [CaseSession(date: "01.01.2099", time: "10:00", event: "Судебное заседание")])],
            complaints: [:], acts: [])
        let record = try seed.upsert(context: ctx, snapshot: MovementDerivation.snapshot(from: movement, context: ctx),
                movement: movement, collections: [])
        record.movementFetchedAt = Date(); record.seenAt = Date(); try seed.save()
        let key = record.key
        let gate = Issue46LoaderGate()
        var factoryCalls = 0
        var suppliedStore: TrackedStore?
        let bootstrap = AppBootstrap(loader: { await gate.wait(); return container },
            quarantine: { _, _ in throw URLError(.unsupportedURL) }, routerFactory: { prepared in
                factoryCalls += 1
                XCTAssertTrue(prepared === container)
                let (router, store) = try self.makeRouter(container: prepared, defaults: defaults,
                    suite: suite, root: root, tokens: tokens,
                    fetch: { _ in XCTFail("First-instance fixture must not enter repair"); throw URLError(.notConnectedToInternet) })
                suppliedStore = store
                return router
            })
        let start = Task { await bootstrap.start() }
        await gate.waitUntilEntered()
        XCTAssertEqual(factoryCalls, 0)
        if case .loading = bootstrap.state {} else { XCTFail("Loader must remain pending") }
        await gate.release(); await start.value
        guard case .ready(let router) = bootstrap.state else { return XCTFail("Bootstrap missing ready") }
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(try SudrfIntentRuntime.shared.requireRouter() === router)
        XCTAssertTrue(router.intentUpcomingHearings().contains(ctx.caseNumber))
        XCTAssertTrue(try router.intentAddCase(key: key, collection: "QA46 test"))
        XCTAssertTrue(suppliedStore?.record(forKey: key)?.collectionNames.contains("QA46 test") == true)
        await bootstrap.start()
        XCTAssertEqual(factoryCalls, 1, "Repeated root.task does not create a second router/container")
        var installed = false
        for _ in 0..<20 {
            let entities = try await CaseCatalogRegistry.shared.caseEntities(for: [key])
            if entities.map(\.id) == [key] { installed = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(installed, "Normal asynchronous background path eventually installs catalog")
        // This is an in-process bootstrap contract, not an OS cold-start oracle.
    }

    func testRouterFactoryFailurePublishesFailureWithoutReadyOrSecondAttempt() async throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        var calls = 0
        let bootstrap = AppBootstrap(loader: { container },
            quarantine: { _, _ in throw URLError(.unsupportedURL) }, routerFactory: { _ in
                calls += 1; throw URLError(.cannotOpenFile)
            })
        await bootstrap.start()
        guard case .failed = bootstrap.state else { return XCTFail("Expected private factory failure") }
        await bootstrap.start()
        XCTAssertEqual(calls, 1)
    }
    private func makeRouter(container: ModelContainer, defaults: UserDefaults, suite: String, root: URL,
                            originResolver: any CaseOriginResolving = CSVRepairOrigin(),
                            tokens: CaptchaTokenStore = CaptchaTokenStore(),
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
            modelContainer: container, modelContainerIsPrepared: true,
            captchaCorpus: CorpusStore(baseDir: root.appendingPathComponent("corpus")),
            refreshCenterFactory: { suppliedStore, client in
                store = suppliedStore
                return RefreshCenter(store: suppliedStore, client: client, captchaSettings: settings, captchaTokenStore: tokens,
                    serviceBuilder: { _ in return MovementService(client: client, transferCourts: { _ in throw URLError(.notConnectedToInternet) }) },
                    treasuryDiscover: { _, _, _ in throw URLError(.unsupportedURL) }, vsrfProvider: vsrf,
                    fsspAutoModelEnabled: false, fsspDiscover: { _ in throw URLError(.unsupportedURL) })
            }, importVSRFProvider: vsrf, importMosGorSudProvider: moscow,
            selectedPublishedAct: PublishedActSelection(cache: ActFileCache(directory: root.appendingPathComponent("acts")),
                fetch: { _, _ in throw URLError(.unsupportedURL) }),
            userDefaults: defaults, client: client, captchaTokenStore: tokens,
            directCaseLinkResolverFactory: { _ in DirectCaseLinkResolver(fetchCard: { _ in throw URLError(.unsupportedURL) },
                districtCourts: { _ in throw URLError(.unsupportedURL) }) },
            spotlightIndexerFactory: { catalog in SpotlightIndexer(catalog: catalog,
                writer: CSVPrivateSpotlightWriter(), manifestStore: SpotlightManifestStore(suiteName: suite),
                preferenceStore: SpotlightPreferenceStore(suiteName: suite)) },
            currentEntityActivityPublisher: { _ in  },
            feedNotificationPublisher: { _ in  },
            feedBadgePublisher: { _ in }, notificationOpenInstaller: { _ in }, intentInstaller: { SudrfIntentRuntime.shared.install($0) },
            captchaSolverFactory: { _ in nil }, repairCoordinatorFactory: { store, client in
                TrackedCaseRepairCoordinator(store: store, client: client, originResolver: originResolver,
                    defaults: defaults, anchorCardFetcher: fetch)
            })
        return (router, store!)
    }

}
