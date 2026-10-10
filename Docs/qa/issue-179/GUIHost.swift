// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
// Own offline QA host. Production entry point is excluded; never launched by build.
import AppKit
import SwiftUI
import SwiftData
@testable import SudrfKit
import CaptchaSolver

extension Notification.Name {
    static let sudrfImportCases = Notification.Name("sudrfImportCases")
    static let sudrfSpotlightPreferenceChanged = Notification.Name("sudrfSpotlightPreferenceChanged")
}
private actor Issue179Movement: MovementProviding {
    var value: CaseMovement
    init(_ value: CaseMovement) { self.value = value }
    func set(_ value: CaseMovement) { self.value = value }
    func movement(for base: CaseSearchResult, court: Court, cartoteka: Cartoteka) async throws -> CaseMovement {
        guard base.caseNumber == value.caseNumber else { throw CancellationError() }
        return value
    }
}
private struct Issue179UnusedVSRF: VSRFProviding {
    func search(uniqueNumber: String?, oldCaseNumber: String?, keywords: String?) async throws -> VSRFSearchResults { throw CancellationError() }
    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard { throw CancellationError() }
}
@MainActor private final class Issue179QADelegate: NSObject, NSApplicationDelegate {
    static let requiredBundleID = "ru.sudrf.qa.issue179"
    var window: NSWindow?
    var router: AppRouter?
    var session: URLSession?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Bundle.main.bundleIdentifier == Self.requiredBundleID else { NSApp.terminate(nil); return }
        Task { @MainActor in
            do { try await prepare() } catch { fatalError("Own QA fixture failed: \(error)") }
        }
    }
    func prepare() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("issue179-own-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = Self.requiredBundleID + ".fixture"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CancellationError() }
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: SpotlightPreferenceStore.key)
        defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        func context(_ number: String, id: String) -> MovementContext {
            MovementContext(branchRaw: "general", region: "Учебный регион",
                searchDomain: "test--region.sudrf.ru", displayDomain: "test--region.sudrf.ru",
                courtTitle: "Тестовый городской суд", courtLevelRaw: "district", courtCode: "00RS0001",
                cartotekaId: "g1", cartotekaLevelRaw: "district", caseNumber: number, caseID: id)
        }
        let today = DateUtil.today
        for material in [false, true] {
            let ctx = context(material ? "2-180/2026" : "2-179/2026", id: material ? "180" : "179")
            let owner = CaseInstance(level: material ? .material : .appeal, court: "Тестовый областной суд",
                caseNumber: material ? "13-300/2026" : "33-300/2026", judge: "Петров П.П.", domain: "komi.sudrf.ru",
                foundByUID: false, result: "Иск удовлетворён частично", sessions: [],
                sourceURL: URL(string: "https://komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=300&delo_id=1540005"))
            let movement = CaseMovement(uid: "", caseNumber: ctx.caseNumber, inForce: false,
                instances: [owner], complaints: [:], acts: [])
            let rec = try store.upsert(context: ctx, snapshot: MovementDerivation.snapshot(from: movement, context: ctx),
                movement: movement, collections: ["Учебные данные #179"])
            guard let source = CaseSnapshotSourceIdentity.sourceCardID(for: owner, context: ctx) else { throw CancellationError() }
            let kinds: [CaseEventKind] = material ? [.instanceDiscovered] : [.judgeChanged, .instanceDiscovered, .resultChanged]
            let events = kinds.map { kind in
                CaseEvent.make(kind: kind, occurrence: [source, kind.rawValue], observedAt: today,
                    evidence: .init(sourceCardID: source, instanceLevelRaw: owner.level.rawValue,
                        caseNumber: owner.caseNumber, previousValue: kind == .judgeChanged ? "Иванов И.И." : kind == .resultChanged ? "Иск удовлетворён" : nil,
                        value: kind == .judgeChanged ? "Петров П.П." : kind == .resultChanged ? "Иск удовлетворён частично" : nil))
            }
            try store.commit { try store.ensureLegacyFeedHistory(for: rec); try store.appendCaseEvents(events, to: rec) }
        }
        let hearingContext = context("2-181/2026", id: "181")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "dd.MM.yyyy"
        let oldDay = Calendar.current.date(byAdding: .day, value: -2, to: today)!
        let newDay = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let owner = CaseInstance(level: .first, court: hearingContext.courtTitle, caseNumber: hearingContext.caseNumber,
            judge: "Учебный судья", domain: hearingContext.searchDomain, foundByUID: false, result: nil,
            sessions: [CaseSession(date: formatter.string(from: oldDay), time: "10:00", event: "Судебное заседание")])
        let native = CaseEventSourceAdmission.nativeCardIdentity(for: owner, context: hearingContext)!
        var initial = CaseMovement(uid: "", caseNumber: hearingContext.caseNumber, inForce: false, instances: [owner], complaints: [:], acts: [],
            sourceRefreshCoverage: [.init(sourceFamily: native.sourceFamily, courtKey: native.courtKey, kind: .usableSnapshot, loadedCardIdentities: [native])])
        let rec = try store.upsert(context: hearingContext, snapshot: nil, collections: ["Учебные данные #179"])
        let provider = Issue179Movement(initial)
        let (router, _, session) = try makeRouter(container: container, defaults: defaults, suite: suite,
            directory: directory, provider: provider, notifications: { _ in })
        self.router = router; self.session = session
        await router.refreshCenter.refresh(key: rec.key, manually: true)?.value
        initial.instances[0].sessions[0].result = "Заседание отложено"
        initial.instances[0].sessions.append(CaseSession(date: formatter.string(from: newDay), time: "11:00", event: "Судебное заседание"))
        await provider.set(initial)
        await router.refreshCenter.refresh(key: rec.key, manually: true)?.value
        router.openFullFeed()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1500, height: 980),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Журнал #179 — собственные учебные данные"
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: OverviewView().environmentObject(router))
        self.window = window
        let menu = NSMenu()
        let app = NSMenuItem(); app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Закрыть QA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        let view = NSMenuItem(title: "QA", action: nil, keyEquivalent: ""); view.submenu = NSMenu()
        let dark = NSMenuItem(title: "Тёмный вид", action: #selector(dark), keyEquivalent: "d"); dark.target = self
        let light = NSMenuItem(title: "Светлый вид", action: #selector(light), keyEquivalent: "l"); light.target = self
        view.submenu?.addItem(dark); view.submenu?.addItem(light); menu.addItem(view)
        NSApp.mainMenu = menu; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func dark() { window?.appearance = NSAppearance(named: .darkAqua) }
    @objc func light() { window?.appearance = NSAppearance(named: .aqua) }
    private func makeRouter(container: ModelContainer, defaults: UserDefaults,
                            suite: String, directory: URL,
                            provider: Issue179Movement,
                            notifications: @escaping @MainActor ([FeedEntry]) -> Void)
        throws -> (AppRouter, TrackedStore, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Issue179NoNetwork.self]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config)
        let vsrf = Issue179UnusedVSRF()
        let moscow = MosGorSudClient(session: session, minInterval: 0)
        var capturedStore: TrackedStore?
        let router = try AppRouter(captchaSettings: CaptchaSettings(defaults: defaults),
            modelContainer: container, modelContainerIsPrepared: true,
            captchaCorpus: CorpusStore(baseDir: directory.appendingPathComponent("corpus")),
            refreshCenterFactory: { store, client in
                capturedStore = store
                return RefreshCenter(store: store, client: client,
                    captchaSettings: CaptchaSettings(defaults: defaults),
                    captchaTokenStore: CaptchaTokenStore(),
                    serviceBuilder: { _ in provider },
                    treasuryDiscover: { document, number, court in
                        fatalError("unexpected Treasury request"); throw CancellationError()
                    }, vsrfProvider: vsrf, fsspAutoModelEnabled: false,
                    fsspDiscover: { _ in throw CancellationError() })
            }, importVSRFProvider: vsrf, importMosGorSudProvider: moscow,
            selectedPublishedAct: PublishedActSelection(
                cache: ActFileCache(directory: directory.appendingPathComponent("acts")),
                fetch: { _, _ in fatalError("unexpected act request"); throw CancellationError() }),
            summaryConfigurationProvider: { throw CancellationError() },
            userDefaults: defaults, client: SudrfClient(session: session, minInterval: 0, variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: CaptchaTokenStore()),
            captchaTokenStore: CaptchaTokenStore(),
            directCaseLinkResolverFactory: { _ in DirectCaseLinkResolver(
                fetchCard: { _ in fatalError("unexpected direct card request"); throw CancellationError() },
                districtCourts: { _ in fatalError("unexpected directory request"); throw CancellationError() }) },
            spotlightIndexerFactory: { catalog in SpotlightIndexer(catalog: catalog,
                writer: Issue179NoSpotlight(), manifestStore: SpotlightManifestStore(suiteName: suite),
                preferenceStore: SpotlightPreferenceStore(suiteName: suite)) },
            currentEntityActivityPublisher: { _ in },
            feedNotificationPublisher: notifications,
            feedBadgePublisher: { _ in }, notificationOpenInstaller: { _ in }, intentInstaller: { _ in },
            captchaSolverFactory: { _ in nil },
            repairCoordinatorFactory: { store, client in TrackedCaseRepairCoordinator(
                store: store, client: client, originResolver: Issue179NoOrigin(), defaults: defaults,
                anchorCardFetcher: { _ in fatalError("unexpected repair request"); throw CancellationError() }) })
        return (router, capturedStore!, session)
    }

}
@main struct Issue179QABoot {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = Issue179QADelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
private struct Issue179NoOrigin: CaseOriginResolving {
    func resolve(anchorContext: MovementContext, anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        fatalError("unexpected origin lookup")
        throw CancellationError()
    }
}

private actor Issue179NoSpotlight: SpotlightIndexWriting {
    func index(cases: [CaseEntity], acts: [CourtActEntity]) async throws { fatalError("unexpected indexing") }
    func delete(caseIDs: [String], actIDs: [String]) async throws { fatalError("unexpected index deletion") }
    func deleteAll() async throws { fatalError("unexpected index deletion") }
}

private final class Issue179NoNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        fatalError("Unexpected network request in private journal runtime fixture")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
