// Build-only native QA: actual sheet, synthetic providers, private storage, no publication.
import AppKit
import SwiftData
import SwiftUI
@testable import CaptchaSolver
@testable import SudrfKit

extension Notification.Name {
    static let sudrfImportCases = Notification.Name("sudrfImportCases")
    static let sudrfSpotlightPreferenceChanged = Notification.Name("sudrfSpotlightPreferenceChanged")
}

private enum Issue339QAError: Error { case unexpectedLocator, missingTarget, disabledSource }

enum Issue339QAFixtures {
    static let cardURL = URL(string: "http://vos.spb.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=958679833&case_uid=976b38ad-eb63-425e-93d5-b15fa7df355d&delo_id=1502001&case_type=0&new=0&srv_num=1")!
    static let client: SudrfClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return SudrfClient(session: URLSession(configuration: configuration), minInterval: 0,
                           variantStore: WorkingVariantStore(cacheURL: nil),
                           captchaStore: CaptchaTokenStore())
    }()
    static let resolver = DirectCaseLinkResolver(
        fetchCard: { requested in
            guard (try? SudrfCaseCardLink(url: requested)) == (try? SudrfCaseCardLink(url: cardURL)) else {
                throw Issue339QAError.unexpectedLocator
            }
            let card = CaseCard(rawText: "", actText: nil, judge: "<скрыто>",
                                result: "Направлено по подведомственности",
                                uid: "78RS0001-01-2026-002203-86", caseNumber: "12-538/2026",
                                category: "Дело об административном правонарушении",
                                receiptDate: "11.03.2026", decisionDate: "16.07.2026")
            return SudrfCaseCardFetchResult(card: card, responseURL: cardURL)
        },
        districtCourts: { subject in
            guard subject == "78" else { throw Issue339QAError.disabledSource }
            return [DistrictCourt(title: "Василеостровский районный суд города Санкт-Петербурга",
                                  domain: "vos.spb.sudrf.ru", code: "78RS0001",
                                  regionCode: "spb", kind: .district, portalSubject: "78")]
        })

    static func sequence(_ context: MovementContext) throws -> [CaseMovement] {
        guard let subject = context.higherCourtTargets?.first(where: { $0.courtLevel == .subject }),
              let cassation = context.higherCourtTargets?.first(where: { $0.courtLevel == .cassation }),
              let subjectTitle = subject.courtTitle, let cassationTitle = cassation.courtTitle else {
            throw Issue339QAError.missingTarget
        }
        let base = CaseInstance(level: .first, court: context.courtTitle,
                                caseNumber: context.caseNumber, judge: context.judge,
                                domain: context.searchDomain, foundByUID: false,
                                result: context.resultText, sessions: [])
        let subjectStub = CaseInstance(level: .appeal, court: subjectTitle, caseNumber: "—", judge: nil,
                                      domain: subject.domain, foundByUID: false, result: nil, sessions: [],
                                      captchaFormURL: URL(string: "https://\(subject.domain)/modules.php?name=sud_delo")!)
        let cassationStub = CaseInstance(level: .cassation, court: cassationTitle, caseNumber: "—", judge: nil,
                                        domain: cassation.domain, foundByUID: false, result: nil, sessions: [],
                                        captchaFormURL: URL(string: "https://\(cassation.domain)/modules.php?name=sud_delo")!)
        let loaded = CaseInstance(level: .appeal, court: subjectTitle, caseNumber: "12-538/2026", judge: nil,
                                  domain: subject.domain, foundByUID: true, result: "Решение", sessions: [],
                                  sourceURL: URL(string: "https://\(subject.domain)/modules.php?name=sud_delo&name_op=case&case_id=123456789&case_uid=11111111-2222-4333-8444-555555555555&delo_id=1502001&case_type=0&new=0&srv_num=1")!)
        let uid = context.judicialUID ?? ""
        return [
            CaseMovement(uid: uid, caseNumber: context.caseNumber, inForce: false,
                         instances: [base, subjectStub, cassationStub], complaints: [:], acts: [],
                         incompleteHigherCourtDomains: [subject.domain, cassation.domain]),
            CaseMovement(uid: uid, caseNumber: context.caseNumber, inForce: false,
                         instances: [base, loaded, cassationStub], complaints: [:], acts: [],
                         incompleteHigherCourtDomains: [cassation.domain]),
            CaseMovement(uid: uid, caseNumber: context.caseNumber, inForce: false,
                         instances: [base, loaded], complaints: [:], acts: [],
                         honestZeroDomains: [cassation.domain])
        ]
    }
}

private actor Issue339QAMovement: MovementProviding {
    private let snapshots: [CaseMovement]
    private var calls = 0
    private var solvedHosts: [String] = []
    init(_ snapshots: [CaseMovement]) { self.snapshots = snapshots }
    func movement(for base: CaseSearchResult, court: Court, cartoteka: Cartoteka) async throws -> CaseMovement {
        let result = snapshots[min(calls, snapshots.count - 1)]
        calls += 1
        return result
    }
    func solve(_ host: String) throws {
        guard let expected = snapshots[0].instances.compactMap(\.captchaFormURL).map(\.host)
            .compactMap({ $0 }).dropFirst(solvedHosts.count).first,
              host == expected else { throw Issue339QAError.disabledSource }
        solvedHosts.append(host)
    }
}

private struct Issue339QAEmptyOCR: CaptchaSolvingProvider {
    func solve(pngData: Data, kind: CaptchaKind, host: String?) async throws -> CaptchaAttempt { .empty }
}
private actor Issue339QASpotlightWriter: SpotlightIndexWriting {
    func index(cases: [CaseEntity], acts: [CourtActEntity]) async throws {}
    func delete(caseIDs: [String], actIDs: [String]) async throws {}
    func deleteAll() async throws {}
}

@MainActor
private struct Issue339QAView: View {
    @ObservedObject var router: AppRouter
    @State private var showSheet = true
    @State private var expanded = Set<String>()
    var body: some View {
        Group {
            if let movement = router.liveMovement {
                CaseMovementView(movement: movement, expanded: $expanded,
                                 onBack: { router.closeCase() },
                                 sourceURL: Issue339QAFixtures.cardURL,
                                 isTracked: true, isRefreshing: router.loadingMovement,
                                 refreshNote: router.refreshNote)
            } else {
                ProgressView().opacity(router.loadingMovement ? 1 : 0)
            }
        }
        .frame(minWidth: 900, minHeight: 680)
        .sheet(isPresented: $showSheet) { DirectCaseLinkSheet().environmentObject(router) }
    }
}

@MainActor
private final class Issue339QADelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var router: AppRouter?
    private var defaults: UserDefaults?
    private var suiteName: String?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await prepareWindow() }
    }
    private func prepareWindow() async {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("issue-339-native-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let suiteName = "ru.sudrf.qa.issue339.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            self.defaults = defaults; self.suiteName = suiteName
            defaults.set(false, forKey: SpotlightPreferenceStore.key)
            defaults.set(true, forKey: SpotlightPreferenceStore.onboardingKey)
            let settings = CaptchaSettings(defaults: defaults)
            settings.autoSolveEnabled = true
            let logger = CaptchaSolverLog(fileURL: root.appendingPathComponent("solver.log"),
                                          failuresDir: root.appendingPathComponent("failures"),
                                          diagnosticsDir: root.appendingPathComponent("diagnostics"))
            let solver = CaptchaSolver(provider: Issue339QAEmptyOCR(), log: logger)
            let resolution = try await Issue339QAFixtures.resolver.resolve(Issue339QAFixtures.cardURL.absoluteString)
            let snapshots = try Issue339QAFixtures.sequence(resolution.context)
            assert(snapshots.count == 3 && snapshots[0].instances.filter { $0.captchaFormURL != nil }.count == 2)
            let service = Issue339QAMovement(snapshots)
            let tokenStore = CaptchaTokenStore()
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: root.appendingPathComponent("test.store"))
            let router = try AppRouter(
                captchaSettings: settings, modelContainer: container, modelContainerIsPrepared: true,
                captchaCorpus: CorpusStore(baseDir: root.appendingPathComponent("corpus")),
                configuredCaptchaSolver: solver,
                refreshCenterFactory: { store, client in
                    RefreshCenter(store: store, client: client, captchaSolver: solver, captchaSettings: settings,
                                  autoSolve: { url, _, _, _ in
                                      guard let host = url.host else { return .init(token: nil, png: nil) }
                                      do { try await service.solve(host) } catch { return .init(token: nil, png: nil) }
                                      return .init(token: CaptchaToken(value: "12345", id: host), png: nil)
                                  }, captchaTokenStore: tokenStore, serviceBuilder: { _ in service },
                                  treasuryDiscover: { _, _, _ in throw Issue339QAError.disabledSource },
                                  fsspAutoModelEnabled: false,
                                  fsspDiscover: { _ in .error("disabled in native QA") })
                },
                selectedPublishedAct: PublishedActSelection(cache: ActFileCache(directory: root.appendingPathComponent("acts")),
                                                           fetch: { _, _ in throw Issue339QAError.disabledSource }),
                trackedStoreProjectionSynchronizer: { _, _ in }, userDefaults: defaults,
                spotlightIndexerFactory: { catalog in
                    SpotlightIndexer(catalog: catalog, writer: Issue339QASpotlightWriter(),
                                     manifestStore: SpotlightManifestStore(suiteName: suiteName),
                                     preferenceStore: SpotlightPreferenceStore(defaults: defaults))
                }, currentEntityActivityPublisher: { _ in }, feedNotificationPublisher: { _ in })
            router.refreshCenter.repairBeforeRefresh = nil
            router.refreshCenter.recoverCard = nil
            self.router = router
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 760),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "СудРФ #339 — синтетическая QA-сборка"
            window.contentView = NSHostingView(rootView: Issue339QAView(router: router))
            self.window = window
            window.makeKeyAndOrderFront(nil)
        } catch { assertionFailure("native QA preparation failed: \(error)"); NSApp.terminate(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct Issue339QABoot {
    @MainActor static func main() {
        precondition(Bundle.main.bundleIdentifier == "ru.sudrf.qa.issue339")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Issue339QADelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
