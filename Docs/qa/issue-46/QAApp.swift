import AppKit
import SwiftUI
import SwiftData
import Foundation
@testable import SudrfKit
@testable import CaptchaSolver

extension Notification.Name {
    static let sudrfImportCases = Notification.Name("sudrfImportCases")
    static let sudrfSpotlightPreferenceChanged = Notification.Name("sudrfSpotlightPreferenceChanged")
}
private final class CSVRejectNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
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
@MainActor private final class QAEnvironment: ObservableObject {
    let root: URL
    let defaults: UserDefaults
    let suite = "ru.sudrf.qa.issue46.private"
    let client: SudrfClient
    let tokens = CaptchaTokenStore()
    let search: SearchModel
    private var container: ModelContainer?
    private var router: AppRouter?
    @Published var setupStatus = "Синтетическая база ещё не подготовлена"
    lazy var bootstrap: AppBootstrap = makeBootstrap()
    private func makeBootstrap() -> AppBootstrap {
        let storeURL = root.appendingPathComponent("fixture.store")
        let recoveryRoot = root.appendingPathComponent("backups")
        let suiteName = suite
        return AppBootstrap(loader: {
            try await Task.detached(priority: .userInitiated) {
                try await PersistentStoreBootstrapper(recoveryRoot: recoveryRoot)
                    .prepareProduction(storeURL: storeURL, defaultsSuiteName: suiteName)
            }.value
        }, quarantine: { _, _ in throw URLError(.unsupportedURL) }, routerFactory: { container in
            self.container = container
            let (router, _) = try self.makeRouter(container: container, defaults: self.defaults,
                suite: self.suite, root: self.root, originResolver: CSVRepairOrigin(), tokens: self.tokens,
                fetch: { _ in throw URLError(.notConnectedToInternet) })
            self.router = router
            return router
        })
    }
    init() throws {
        guard Bundle.main.bundleIdentifier == "ru.sudrf.qa.issue46" else { throw URLError(.unsupportedURL) }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        root = support.appendingPathComponent("Sudrf-QA46", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
        defaults.set(false, forKey: SpotlightPreferenceStore.key)
        let settings = CaptchaSettings(defaults: defaults)
        settings.autoSolveEnabled = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CSVRejectNetwork.self]; config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config)
        client = SudrfClient(session: session, minInterval: 0,
            variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: tokens)
        let privateClient = client
        let moscow = MoscowMagistrateKoAPClient(session: session, minInterval: 0)
        search = SearchModel(captchaSolver: CaptchaSolver(log: CaptchaSolverLog(fileURL: nil, failuresDir: nil)),
            captchaSettings: settings, corpusStore: CorpusStore(baseDir: root.appendingPathComponent("search-corpus")),
            client: client, resolver: DistrictCourtResolver(client: client, cacheURL: nil),
            magistrateResolver: MagistrateCourtResolver(client: client, cacheURL: nil, moscowDirectoryClient: moscow),
            mosGorSudClient: MosGorSudClient(session: session, minInterval: 0),
            vsrfProvider: VSRFClient(session: session, minInterval: 0), moscowMagistrateClient: moscow,
            movementServiceFactory: { _, _ in MovementService(client: privateClient,
                transferCourts: { _ in throw URLError(.notConnectedToInternet) }) },
            selectedPublishedAct: PublishedActSelection(cache: ActFileCache(directory: root.appendingPathComponent("search-acts")),
                fetch: { _, _ in throw URLError(.notConnectedToInternet) }))
    }
    func prepareFixture() {
        do {
            guard let container, let router else { throw URLError(.resourceUnavailable) }
            let store = try TrackedStore(container: container, prepared: true)
            guard store.all().isEmpty else { setupStatus = "База уже подготовлена; повторная запись запрещена"; return }
            let context = MovementContext(branchRaw: "general", region: "Тестовый регион",
                searchDomain: "test--region.sudrf.ru", displayDomain: "test--region.sudrf.ru",
                courtTitle: "Тестовый районный суд", courtLevelRaw: CourtLevel.district.rawValue,
                cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
                caseNumber: "2-46/2099", caseID: "46", caseUID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                cardURLString: "https://test--region.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=46&case_uid=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa&delo_id=1540005")
            let movement = CaseMovement(uid: "", caseNumber: context.caseNumber, inForce: false,
                instances: [CaseInstance(level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
                    judge: nil, domain: context.displayDomain, foundByUID: false, result: nil,
                    sessions: [CaseSession(date: "01.01.2099", time: "10:00", event: "Судебное заседание")])],
                complaints: [:], acts: [])
            let record = try store.upsert(context: context, snapshot: MovementDerivation.snapshot(from: movement, context: context),
                movement: movement, collections: [])
            record.movementFetchedAt = Date(); record.seenAt = Date(); record.addLegacyKeyAlias("qa46-original")
            try store.save()
            router.reload()
            let manifest = ["storePath": root.appendingPathComponent("fixture.store").path, "recordKey": record.key,
                "suite": suite, "targetCollection": "QA46 cold-start"]
            let path = root.appendingPathComponent("fixture.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            setupStatus = "Подготовлено одно синтетическое дело 2-46/2099"
            Issue46Trace.emit("fixture.explicitSetup.success")
        } catch { setupStatus = "Подготовка не выполнена"; Issue46Trace.emit("fixture.explicitSetup.failure") }
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
@MainActor private final class QADelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        // Only FeedNotifier.configure is replaced; scene activation remains normal.
        Issue46Trace.emit("delegate.didFinishLaunching")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct Issue46QAApp: App {
    @NSApplicationDelegateAdaptor(QADelegate.self) private var delegate
    @StateObject private var environment: QAEnvironment
    init() {
        guard Bundle.main.bundleIdentifier == "ru.sudrf.qa.issue46" else { exit(2) }
        URLProtocol.registerClass(CSVRejectNetwork.self)
        guard let environment = try? QAEnvironment() else { exit(3) }
        _environment = StateObject(wrappedValue: environment)
        Issue46Trace.emit("qa.app.init")
    }
    var body: some Scene {
        WindowGroup("Sudrf — QA46, собственные синтетические команды") {
            RootView(bootstrap: environment.bootstrap, searchModel: environment.search)
                .defaultAppStorage(environment.defaults)
                .buttonBorderShape(.capsule)
                .environment(\.openURL, OpenURLAction { _ in .discarded })
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandMenu("QA46") {
                Button("Подготовить синтетическую базу один раз") { environment.prepareFixture() }
                Text(environment.setupStatus)
            }
        }
    }
}
