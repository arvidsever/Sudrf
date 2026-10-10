import AppKit
import SwiftUI
import Foundation
@testable import SudrfKit
@testable import SudrfApp
@testable import CaptchaSolver

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
@MainActor private final class CSVDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var router: AppRouter?
    var pending: CheckedContinuation<CaseCard, Never>?
    var activeContext: MovementContext?
    var client: SudrfClient!
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @objc func finishCard() {
        guard let ctx = activeContext else { return }
        activeContext = nil
        pending?.resume(returning: CaseCard(rawText: "", actText: nil, caseNumber: ctx.caseNumber)); pending = nil
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let root = URL(fileURLWithPath: "/private/tmp/sudrf-250-native-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let suite = "Sudrf.QA250." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
            defaults.set(false, forKey: SpotlightPreferenceStore.key)
            let settings = CaptchaSettings(defaults: defaults)
            settings.autoSolveEnabled = false
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CSVRejectNetwork.self]
            config.httpCookieStorage = nil; config.urlCache = nil
            let session = URLSession(configuration: config)
            let tokens = CaptchaTokenStore()
            client = SudrfClient(session: session, minInterval: 0,
                variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: tokens)
            let (router, store) = try makeRouter(defaults: defaults, suite: suite, root: root, tokens: tokens, fetch: { ctx in
                self.activeContext = ctx
                return await withCheckedContinuation { self.pending = $0 }
            })
            self.router = router
            let movement = CaseMovement(uid: "synthetic", caseNumber: "33-1/2026", inForce: false,
                instances: [CaseInstance(level: .appeal, court: "Тестовый областной суд", caseNumber: "33-1/2026",
                    judge: nil, domain: "test--region.sudrf.ru", foundByUID: false, result: "Синтетическая карточка QA",
                    sessions: [])], complaints: [:], acts: [])
            let a = try store.upsert(context: context("33-1/2026"), snapshot: nil, movement: movement, collections: ["QA250"])
            let b = try store.upsert(context: context("33-2/2026"), snapshot: nil, collections: ["QA250"])
            let row = ImportedRow(number: a.caseNumber, court: a.courtTitle, parties: "", urlString: a.key)
            var summary = ImportSummary(); summary.cases = 2; summary.total = 2
            router.beginCommittedImportRepair(summary: summary, rowsByKey: [a.key: [row], b.key: [row]])
            router.dismissImportSummary()
            router.section = .cases
            router.openCase(key: a.key)
            let search = SearchModel(captchaSolver: CaptchaSolver(log: CaptchaSolverLog(fileURL: nil, failuresDir: nil)),
                captchaSettings: settings, corpusStore: CorpusStore(baseDir: root.appendingPathComponent("search-corpus")),
                client: client, resolver: DistrictCourtResolver(client: client, cacheURL: nil),
                magistrateResolver: MagistrateCourtResolver(client: client, cacheURL: nil,
                    moscowDirectoryClient: MoscowMagistrateKoAPClient(session: session, minInterval: 0)),
                mosGorSudClient: MosGorSudClient(session: session, minInterval: 0),
                vsrfProvider: VSRFClient(session: session, minInterval: 0),
                moscowMagistrateClient: MoscowMagistrateKoAPClient(session: session, minInterval: 0),
                movementServiceFactory: { _, _ in MovementService(client: self.client,
                    transferCourts: { _ in throw URLError(.notConnectedToInternet) }) },
                selectedPublishedAct: PublishedActSelection(cache: ActFileCache(directory: root.appendingPathComponent("search-acts")),
                    fetch: { _, _ in throw URLError(.notConnectedToInternet) }))
            let content = OperationalRootView(router: router, searchModel: search)
                .environmentObject(router)
                .defaultAppStorage(defaults)
                .environment(\.colorScheme, .light)
                .environment(\.openURL, OpenURLAction { _ in .discarded })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Sudrf — изолированная QA250, синтетический импорт"
            window.contentView = NSHostingView(rootView: content)
            window.center(); window.makeKeyAndOrderFront(nil); self.window = window
            let menu = NSMenu(); let item = NSMenuItem(title: "QA", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let finish = submenu.addItem(withTitle: "Завершить текущую синтетическую карточку", action: #selector(finishCard), keyEquivalent: "f")
            finish.target = self
            submenu.addItem(withTitle: "Завершить QA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.submenu = submenu; menu.addItem(item); NSApp.mainMenu = menu
        } catch { exit(1) }
    }
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

    private func makeRouter(defaults: UserDefaults, suite: String, root: URL,
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
            modelContainer: SudrfModelContainerFactory.make(inMemory: true), modelContainerIsPrepared: true,
            captchaCorpus: CorpusStore(baseDir: root.appendingPathComponent("corpus")),
            refreshCenterFactory: { suppliedStore, client in
                store = suppliedStore
                return RefreshCenter(store: suppliedStore, client: client, captchaTokenStore: tokens,
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
            feedBadgePublisher: { _ in }, notificationOpenInstaller: { _ in }, intentInstaller: { _ in },
            captchaSolverFactory: { _ in nil }, repairCoordinatorFactory: { store, client in
                TrackedCaseRepairCoordinator(store: store, client: client, originResolver: originResolver,
                    defaults: defaults, anchorCardFetcher: fetch)
            })
        return (router, store!)
    }

}
@main struct CSVBoot {
    @MainActor static func main() {
        guard Bundle.main.bundleIdentifier == "ru.sudrf.qa.csv250" else { exit(2) }
        URLProtocol.registerClass(CSVRejectNetwork.self)
        let app = NSApplication.shared; _ = app.setActivationPolicy(.regular)
        let delegate = CSVDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
