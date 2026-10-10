import CryptoKit
import XCTest
@testable import SudrfKit
@testable import CaptchaSolver
@testable import SudrfApp

private func canonicalAcceptanceHost(_ host: String) -> String {
    let lowercased = host.lowercased()
    if lowercased == "www.vsrf.ru" { return "vsrf.ru" }
    return SudrfHost.moduleHost(lowercased)
}

private final class Issue339DenyNetworkURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

final class DirectCaseLinkLiveAcceptanceTests: XCTestCase {

    @MainActor
    func testPrivateHarnessPersistsOfflineDirectLinkWithoutNetwork() async throws {
        let isolation = Issue339TestIsolation()
        defer { isolation.removePreferences() }
        let settings = isolation.makeCaptchaSettings()
        settings.autoSolveEnabled = true
        let tokenStore = CaptchaTokenStore()
        let client = Self.makeIsolatedClient(captchaTokenStore: tokenStore, denyNetwork: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-339-offline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let previousDir = SearchDiagnostics.setDirForTesting(root)
        defer { _ = SearchDiagnostics.setDirForTesting(previousDir) }
        let previousEnabled = SearchDiagnostics.setEnabledForTesting(true)
        defer { _ = SearchDiagnostics.setEnabledForTesting(previousEnabled) }
        let solverLog = CaptchaSolverLog(
            fileURL: root.appendingPathComponent("solver.log"),
            failuresDir: root, diagnosticsDir: root)
        let solver = try isolation.makeCaptchaSolver(log: solverLog, settings: settings)
        XCTAssertTrue(solver.log === solverLog)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-339/2026", caseID: "offline-339", caseUID: "offline-guid")
        let result = try await addAndAutoRefresh(
            context: context, client: client, solver: solver,
            settings: settings, corpus: isolation.makeCaptchaCorpus(),
            observations: SolveObservations(), storeURL: root.appendingPathComponent("tracked.store"),
            isolation: isolation, captchaTokenStore: tokenStore,
            notificationReceiver: Issue339NotificationReceiver())
        XCTAssertEqual(result.persisted.recordCount, 1)
        XCTAssertEqual(result.persisted.recordKey, context.key)
        XCTAssertEqual(try coldReopen(storeURL: root.appendingPathComponent("tracked.store"),
                                      key: context.key), result.persisted)
        XCTAssertTrue(result.outcome == "partial" || result.outcome == "failed")
        let diagnosticURL = root.appendingPathComponent("refresh-outcome-diagnostic.txt")
        let diagnostic = try String(contentsOf: diagnosticURL, encoding: .utf8)
        XCTAssertFalse(diagnostic.isEmpty)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: diagnosticURL.path)[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    private struct LocatorComparison: Codable {
        let parsed: Bool
        let moduleHost: Bool
        let caseID: Bool
        let caseUID: Bool
        let deloID: Bool
        let resolvedNew: Bool
        let srvNum: Bool
        let port: Bool
        let unknownQuery: Bool
        let scheme: Bool

        var identityMatches: Bool {
            parsed && moduleHost && caseID && caseUID && deloID
                && resolvedNew && srvNum && port && unknownQuery
        }
    }

    private static func compareLocators(_ requested: URL, _ effective: URL?) -> LocatorComparison {
        let lhs = try? SudrfCaseCardLink(url: requested)
        let rhs = effective.flatMap { try? SudrfCaseCardLink(url: $0) }
        let parsed = lhs != nil && rhs != nil
        return LocatorComparison(
            parsed: parsed,
            moduleHost: parsed && lhs?.moduleHost == rhs?.moduleHost,
            caseID: parsed && lhs?.caseID == rhs?.caseID,
            caseUID: parsed && lhs?.caseUID == rhs?.caseUID,
            deloID: parsed && lhs?.deloID == rhs?.deloID,
            resolvedNew: parsed && lhs?.resolvedNew == rhs?.resolvedNew,
            srvNum: parsed && lhs?.srvNum == rhs?.srvNum,
            port: parsed && lhs?.url.port == rhs?.url.port,
            unknownQuery: parsed && unknownQuery(lhs!.url) == unknownQuery(rhs!.url),
            scheme: parsed && lhs?.url.scheme == rhs?.url.scheme)
    }

    private static func unknownQuery(_ url: URL) -> [URLQueryItem] {
        let known: Set<String> = ["name", "name_op", "case_id", "_id", "case_uid", "_uid",
                                  "delo_id", "_deloid", "new", "_new", "srv_num"]
        return (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { !known.contains($0.name.lowercased()) }
    }

    func testLocatorComparisonAcceptsCanonicalPublishedIdentity() throws {
        let base = try XCTUnwrap(URL(string: "http://vos.spb.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=123&case_uid=abc&delo_id=42&srv_num=1&case_type=0&extra=a&extra=b"))
        for new in ["", "&_new", "&_new=", "&_new=0"] {
            let effective = try XCTUnwrap(URL(string: "https://vos--spb.sudrf.ru/modules.php?srv_num=1&_deloId=42&_uid=abc&_id=123&name_op=case&name=sud_delo" + new + "&case_type=0&extra=a&extra=b"))
            let comparison = Self.compareLocators(base, effective)
            XCTAssertTrue(comparison.identityMatches)
            XCTAssertFalse(comparison.scheme)
        }
        XCTAssertTrue(Self.compareLocators(base, base).scheme)
    }

    func testLocatorComparisonRejectsChangedIdentityAndUnknownQuery() throws {
        let text = "https://vos.spb.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=123&case_uid=abc&delo_id=42&new=0&srv_num=1&case_type=0&extra=a&extra=b&id=legacy&uid=legacy"
        let base = try XCTUnwrap(URL(string: text))
        let changes = [
            text.replacingOccurrences(of: "vos.spb", with: "other.spb"),
            text.replacingOccurrences(of: "case_id=123", with: "case_id=124"),
            text.replacingOccurrences(of: "case_uid=abc", with: "case_uid=def"),
            text.replacingOccurrences(of: "delo_id=42", with: "delo_id=43"),
            text.replacingOccurrences(of: "new=0", with: "new=1"),
            text.replacingOccurrences(of: "srv_num=1", with: "srv_num=2"),
            text.replacingOccurrences(of: "sudrf.ru/", with: "sudrf.ru:8443/"),
            text.replacingOccurrences(of: "case_type=0", with: "case_type=1"),
            text.replacingOccurrences(of: "&extra=b", with: ""),
            text.replacingOccurrences(of: "extra=a&extra=b", with: "extra=b&extra=a"),
            text.replacingOccurrences(of: "id=legacy", with: "id=changed"),
            text.replacingOccurrences(of: "uid=legacy", with: "uid=changed"),
            text + "&_id=conflict",
            text.replacingOccurrences(of: "https:", with: "ftp:")
        ]
        for changed in changes {
            XCTAssertFalse(Self.compareLocators(base, try XCTUnwrap(URL(string: changed))).identityMatches)
        }
        XCTAssertFalse(Self.compareLocators(base, nil).identityMatches)
    }

    private struct SolveSnapshot: Sendable {
        let callCount: Int
        let returnedTokenCount: Int
        let milliseconds: Int
        let callsByHost: [String: Int]
        let successfulHosts: Set<String>
        let successfulSolveOrderByHost: [String: Int]
        let latestMovementProof: MovementProofSnapshot?
    }

    private struct MovementProofSnapshot: Sendable {
        let eventOrder: Int
        let freshCardHosts: Set<String>
        let verifiedEmptyHosts: Set<String>
        let unresolvedHosts: Set<String>
    }

    private actor SolveObservations {
        private var callCount = 0
        private var returnedTokenCount = 0
        private var milliseconds = 0
        private var callsByHost = [String: Int]()
        private var successfulHosts = Set<String>()
        private var successfulSolveOrderByHost = [String: Int]()
        private var eventOrder = 0
        private var latestMovementProof: MovementProofSnapshot?

        func record(host: String, returnedToken: Bool, elapsedMilliseconds: Int) {
            eventOrder += 1
            let canonicalHost = canonicalAcceptanceHost(host)
            callCount += 1
            if returnedToken { returnedTokenCount += 1 }
            milliseconds += elapsedMilliseconds
            callsByHost[canonicalHost, default: 0] += 1
            if returnedToken {
                successfulHosts.insert(canonicalHost)
                successfulSolveOrderByHost[canonicalHost] = eventOrder
            }
        }

        func recordMovement(_ movement: CaseMovement, context: MovementContext) {
            eventOrder += 1
            let admitted = CaseEventSourceAdmission.courts(in: movement, context: context)
            var freshCardHosts = Set<String>()
            var verifiedEmptyHosts = Set<String>()
            var unresolvedHosts = Set<String>()

            for coverage in movement.sourceRefreshCoverage ?? [] {
                let host = coverage.sourceFamily == "mosgorsud"
                    ? "mos-gorsud.ru" : canonicalAcceptanceHost(coverage.courtKey)
                switch coverage.kind {
                case .usableSnapshot:
                    if !coverage.loadedCardIdentities.isEmpty,
                       let cards = admitted[coverage.id], !cards.isEmpty {
                        freshCardHosts.insert(host)
                    } else {
                        unresolvedHosts.insert(host)
                    }
                case .honestZero:
                    if coverage.loadedCardIdentities.isEmpty, admitted[coverage.id] != nil {
                        verifiedEmptyHosts.insert(host)
                    } else {
                        unresolvedHosts.insert(host)
                    }
                default:
                    unresolvedHosts.insert(host)
                }
            }

            for domain in movement.incompleteHigherCourtDomains ?? [] {
                unresolvedHosts.insert(canonicalAcceptanceHost(domain))
            }
            for instance in movement.instances
                where instance.captchaFormURL != nil
                    || instance.transientError == true
                    || instance.actFileError != nil {
                unresolvedHosts.insert(canonicalAcceptanceHost(instance.domain))
            }

            latestMovementProof = MovementProofSnapshot(
                eventOrder: eventOrder,
                freshCardHosts: freshCardHosts,
                verifiedEmptyHosts: verifiedEmptyHosts,
                unresolvedHosts: unresolvedHosts)
        }

        func snapshot() -> SolveSnapshot {
            SolveSnapshot(callCount: callCount,
                          returnedTokenCount: returnedTokenCount,
                          milliseconds: milliseconds,
                          callsByHost: callsByHost,
                          successfulHosts: successfulHosts,
                          successfulSolveOrderByHost: successfulSolveOrderByHost,
                          latestMovementProof: latestMovementProof)
        }
    }

    private struct MovementInstanceSnapshot: Equatable {
        let level: String
        let domain: String
        let caseNumber: String
        let foundByUID: Bool
        let sourceURL: String?
        let hasCaptchaForm: Bool
    }

    private struct PersistedSnapshot: Equatable {
        let recordKey: String
        let recordCount: Int
        let contextDigest: String
        let locatorDigest: String
        let collections: [String]
        let seenAt: Date?
        let eventIDs: [String]
        let movementInstances: [MovementInstanceSnapshot]
        let movementFetchedAt: Date?
        let sourceAttemptKind: SourceOutcomeKind?
    }

    private struct LiveRefreshResult {
        let persisted: PersistedSnapshot
        let outcome: String
        let elapsedMilliseconds: Int
    }

    @MainActor
    func testOptInLiveDirectLinkAutoRefreshPersistsAcrossColdReopen() async throws {
        guard Bundle.main.bundleIdentifier != "ru.sudrf.app" else {
            XCTFail("live acceptance cannot run inside the production app process")
            return
        }
        guard NSApp == nil else {
            throw XCTSkip("live #339 acceptance must not update the test host's Dock badge")
        }
        guard ProcessInfo.processInfo.environment["SUDRF_ISSUE339_LIVE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("live #339 acceptance is opt-in and remains disabled by default")
        }

        let isolation = Issue339TestIsolation()
        defer { isolation.removePreferences() }
        let settings = isolation.makeCaptchaSettings()
        settings.autoSolveEnabled = true
        let captchaTokenStore = CaptchaTokenStore()
        let notificationReceiver = Issue339NotificationReceiver()

        let fileManager = FileManager.default
        let runID = UUID().uuidString.lowercased()
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("issue-339-live-\(runID)", isDirectory: true)
        let solverFailures = root.appendingPathComponent("captcha-failures", isDirectory: true)
        let solverDiagnostics = root.appendingPathComponent("captcha-candidates", isDirectory: true)
        let searchDiagnostics = root.appendingPathComponent("search-diagnostics", isDirectory: true)
        let corpusDirectory = root.appendingPathComponent("captcha-corpus", isDirectory: true)
        for directory in [root, solverFailures, solverDiagnostics,
                          searchDiagnostics, corpusDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        let previousSearchDiagnosticsDirectory = SearchDiagnostics.setDirForTesting(searchDiagnostics)
        defer { _ = SearchDiagnostics.setDirForTesting(previousSearchDiagnosticsDirectory) }
        let previousDiagnosticsEnabled = SearchDiagnostics.setEnabledForTesting(true)
        defer { _ = SearchDiagnostics.setEnabledForTesting(previousDiagnosticsEnabled) }

        let solverLog = CaptchaSolverLog(
            fileURL: root.appendingPathComponent("captcha-solve.log"),
            failuresDir: solverFailures,
            diagnosticsDir: solverDiagnostics)
        let solver = try isolation.makeCaptchaSolver(log: solverLog, settings: settings)
        let captchaCorpus = CorpusStore(baseDir: corpusDirectory)
        let observations = SolveObservations()
        let client = Self.makeIsolatedClient(captchaTokenStore: captchaTokenStore)
        await client.setMaxAttemptsForTesting(3)

        let resolver = DirectCaseLinkResolver(
            client: client,
            districtResolver: DistrictCourtResolver(client: client, cacheURL: nil))
        let resolveStartedAt = Date()
        let resolution = try await resolver.resolve(Self.issue321CardURL.absoluteString)
        let resolveMilliseconds = Self.elapsedMilliseconds(since: resolveStartedAt)
        let context = resolution.context

        let effectiveURL = context.cardURLString.flatMap(URL.init(string:))
        let comparison = Self.compareLocators(Self.issue321CardURL, effectiveURL)
        let requested = try SudrfCaseCardLink(url: Self.issue321CardURL).sanitizedURL.absoluteString
        let effective = effectiveURL.flatMap { try? SudrfCaseCardLink(url: $0) }?
            .sanitizedURL.absoluteString
        let fullDigest: (String) -> String = { value in
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        struct LocatorDiagnostic: Encodable {
            let runID: String
            let utc: String
            let requestedURL: String
            let effectiveURL: String?
            let requestedSHA256: String
            let effectiveSHA256: String?
            let comparison: LocatorComparison
        }
        let diagnostic = LocatorDiagnostic(
            runID: runID, utc: ISO8601DateFormatter().string(from: Date()),
            requestedURL: requested, effectiveURL: effective,
            requestedSHA256: fullDigest(requested), effectiveSHA256: effective.map(fullDigest),
            comparison: comparison)
        let diagnosticURL = root.appendingPathComponent("locator-comparison.json")
        let diagnosticData = try JSONEncoder().encode(diagnostic)
        guard fileManager.createFile(atPath: diagnosticURL.path, contents: diagnosticData,
                                     attributes: [.posixPermissions: 0o600]) else {
            XCTFail("could not persist private locator diagnostic")
            return
        }
        print("issue339_locator_identity_matches=\(comparison.identityMatches) "
              + "issue339_locator_scheme_matches=\(comparison.scheme) "
              + "issue339_locator_parsed=\(comparison.parsed)")
        guard comparison.identityMatches else {
            XCTFail("resolved card must retain the supplied published locator identity")
            return
        }

        let refresh = try await addAndAutoRefresh(
            context: context, client: client, solver: solver,
            settings: settings, corpus: captchaCorpus,
            observations: observations,
            storeURL: root.appendingPathComponent("tracked.store"),
            isolation: isolation, captchaTokenStore: captchaTokenStore,
            notificationReceiver: notificationReceiver)
        let reopenStartedAt = Date()
        let reopened = try coldReopen(
            storeURL: root.appendingPathComponent("tracked.store"),
            key: refresh.persisted.recordKey)
        let reopenMilliseconds = Self.elapsedMilliseconds(since: reopenStartedAt)
        XCTAssertTrue(reopened == refresh.persisted,
                      "disk cold reopen must preserve the captured record state")

        let solveSnapshot = await observations.snapshot()
        XCTAssertGreaterThan(solveSnapshot.callCount, 0,
                             "the automatic solver must be invoked")
        XCTAssertGreaterThan(solveSnapshot.returnedTokenCount, 0,
                             "the on-device solver must return a CAPTCHA token")
        let movementProof = try XCTUnwrap(solveSnapshot.latestMovementProof,
                                          "movement refresh must produce fresh coverage evidence")
        XCTAssertFalse(solveSnapshot.successfulHosts.isEmpty,
                       "a returned token must identify the host whose retry is checked")
        for host in solveSnapshot.successfulHosts {
            guard let solveOrder = solveSnapshot.successfulSolveOrderByHost[host] else {
                XCTFail("each successful host must have a recorded solve event")
                continue
            }
            XCTAssertGreaterThan(movementProof.eventOrder, solveOrder,
                                 "a movement retry must follow the successful solve")
            XCTAssertTrue(movementProof.freshCardHosts.contains(host)
                            || movementProof.verifiedEmptyHosts.contains(host),
                          "each solved host must return a confirmed card or verified empty listing")
            XCTAssertFalse(movementProof.unresolvedHosts.contains(host),
                           "a solved host must not retain a CAPTCHA or source failure")
        }
        XCTAssertTrue(refresh.outcome == "refreshed" || refresh.outcome == "partial",
                      "the automatic refresh must resume to a usable result")
        XCTAssertEqual(refresh.persisted.recordCount, 1,
                       "the direct import must persist exactly one record")
        XCTAssertGreaterThan(refresh.persisted.movementInstances.count, 0,
                             "the refresh result must persist movement")
        XCTAssertTrue(refresh.persisted.sourceAttemptKind == .usableSnapshot
                            || refresh.persisted.sourceAttemptKind == .partial,
                          "the source outcome must be persisted")

        let hostSummary = solveSnapshot.callsByHost.keys.sorted().map {
            "\($0):\(solveSnapshot.callsByHost[$0] ?? 0)"
        }.joined(separator: ",")
        print("[issue339-live] run=\(String(runID.prefix(8))) "
              + "outcome=\(refresh.outcome) records=\(refresh.persisted.recordCount) "
              + "movement_instances=\(refresh.persisted.movementInstances.count) "
              + "solver_calls=\(solveSnapshot.callCount) "
              + "tokens_returned=\(solveSnapshot.returnedTokenCount) "
              + "solver_ms=\(solveSnapshot.milliseconds) "
              + "hosts=\(hostSummary) "
              + "stages_ms=resolve:\(resolveMilliseconds),refresh:\(refresh.elapsedMilliseconds),"
              + "cold_reopen:\(reopenMilliseconds) "
              + "locator_sha256=\(refresh.persisted.locatorDigest) "
              + "identity_sha256=\(Self.digest(refresh.persisted.recordKey)) "
              + "events_sha256=\(Self.digest(refresh.persisted.eventIDs.sorted().joined(separator: "\n")))")
    }

    @MainActor
    private func addAndAutoRefresh(
        context: MovementContext,
        client: SudrfClient,
        solver: CaptchaSolver,
        settings: CaptchaSettings,
        corpus: CorpusStore,
        observations: SolveObservations,
        storeURL: URL,
        isolation: Issue339TestIsolation,
        captchaTokenStore: CaptchaTokenStore,
        notificationReceiver: Issue339NotificationReceiver
    ) async throws -> LiveRefreshResult {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        var capturedStore: TrackedStore?
        let unusedVSRF = Issue339UnusedVSRF()
        let unusedMosGorSud = Issue339UnusedMosGorSud()
        let router = try AppRouter(
            captchaSettings: settings,
            modelContainer: container,
            modelContainerIsPrepared: true,
            captchaCorpus: corpus,
            configuredCaptchaSolver: solver,
            refreshCenterFactory: { store, _ in
                capturedStore = store
                return RefreshCenter(
                    store: store,
                    client: client,
                    captchaSolver: solver,
                    captchaSettings: settings,
                    autoSolve: { formURL, _, activeSolver, autoSettings in
                        let startedAt = Date()
                        let boundedSettings = AutoCaptchaSolver.Settings(
                            maxAttempts: min(autoSettings.maxAttempts, 3),
                            minConfidence: autoSettings.minConfidence)
                        let result = await AutoCaptchaSolver.solve(
                            formURL: formURL, client: client,
                            solver: activeSolver, settings: boundedSettings)
                        let host = SudrfHost.moduleHost(formURL.host ?? "unknown")
                        await observations.record(
                            host: host, returnedToken: result.token != nil,
                            elapsedMilliseconds: Self.elapsedMilliseconds(since: startedAt))
                        return result
                    },
                    captchaTokenStore: captchaTokenStore,
                    serviceBuilder: { refreshContext in
                        Self.makeIsolatedMovementProvider(
                            context: refreshContext, client: client,
                            observations: observations)
                    },
                    treasuryDiscover: { _, _, _ in
                        EnforcementLookup(state: .error)
                    },
                    vsrfProvider: unusedVSRF,
                    mosGorSudProvider: unusedMosGorSud,
                    fsspAutoModelEnabled: false,
                    fsspDiscover: { _ in .error("disabled in issue-339 acceptance harness") })
            },
            importVSRFProvider: unusedVSRF,
            importMosGorSudProvider: unusedMosGorSud,
            selectedPublishedAct: PublishedActSelection(
                cache: ActFileCache(directory: storeURL.deletingLastPathComponent()
                    .appendingPathComponent("published-acts", isDirectory: true)),
                fetch: { _, _ in throw CancellationError() }),
            trackedStoreProjectionSynchronizer: { _, _ in },
            userDefaults: isolation.userDefaults,
            client: client,
            captchaTokenStore: captchaTokenStore,
            directCaseLinkResolverFactory: { client in
                DirectCaseLinkResolver(client: client,
                    districtResolver: DistrictCourtResolver(client: client, cacheURL: nil))
            },
            spotlightIndexerFactory: { isolation.makeSpotlightIndexer(catalog: $0) },
            currentEntityActivityPublisher: { _ in },
            feedNotificationPublisher: { notificationReceiver.receive($0) },
            feedBadgePublisher: { _ in },
            notificationOpenInstaller: { _ in },
            intentInstaller: { _ in },
            captchaSolverFactory: { _ in solver },
            repairCoordinatorFactory: { store, client in
                TrackedCaseRepairCoordinator(
                    store: store, client: client, originResolver: Issue339UnusedOrigin(),
                    defaults: isolation.userDefaults, captchaSolver: solver,
                    captchaSettings: settings,
                    anchorCardResolver: { _ in throw CancellationError() })
            })
        router.refreshCenter.repairBeforeRefresh = nil
        router.refreshCenter.recoverCard = { _ in throw CancellationError() }

        let refreshStartedAt = Date()
        let key = try XCTUnwrap(router.addDirectCaseLink(context))
        guard router.refreshCenter.isRefreshing(key) else {
            XCTFail("addDirectCaseLink must synchronously start its initial refresh")
            throw LiveAcceptanceError.autostartDidNotBegin
        }
        guard let refreshTask = router.refreshCenter.refresh(key: key) else {
            XCTFail("the initially started refresh task must remain joinable")
            throw LiveAcceptanceError.autostartTaskMissing
        }
        let execution = await refreshTask.value
        let elapsed = Self.elapsedMilliseconds(since: refreshStartedAt)
        if let diagnostic = Self.outcomeDiagnostic(execution.outcome) {
            let url = storeURL.deletingLastPathComponent()
                .appendingPathComponent("refresh-outcome-diagnostic.txt")
            guard FileManager.default.createFile(
                atPath: url.path, contents: Data(diagnostic.utf8),
                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard let record = capturedStore?.record(forKey: key) else {
            XCTFail("the direct link must persist a tracked record")
            throw LiveAcceptanceError.persistedRecordMissing
        }
        let persisted = Self.snapshot(store: try XCTUnwrap(capturedStore), record: record)
        router.closeCase()
        return LiveRefreshResult(
            persisted: persisted, outcome: Self.outcomeName(execution.outcome),
            elapsedMilliseconds: elapsed)
    }

    @MainActor
    private func coldReopen(storeURL: URL, key: String) throws -> PersistedSnapshot {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        guard let record = store.record(forKey: key) else {
            throw LiveAcceptanceError.persistedRecordMissing
        }
        return Self.snapshot(store: store, record: record)
    }

    @MainActor
    private static func snapshot(store: TrackedStore,
                                 record: TrackedCaseRecord) -> PersistedSnapshot {
        let context = record.context
        let contextMaterial = [context?.searchDomain, context?.displayDomain,
                               context?.caseNumber, context?.caseID,
                               context?.caseUID, context?.judicialUID,
                               context?.cardURLString].compactMap { $0 }.joined(separator: "\n")
        let movementInstances = record.movement?.instances.map {
            MovementInstanceSnapshot(
                level: $0.level.rawValue, domain: $0.domain,
                caseNumber: $0.caseNumber, foundByUID: $0.foundByUID,
                sourceURL: $0.sourceURL?.absoluteString,
                hasCaptchaForm: $0.captchaFormURL != nil)
        } ?? []
        return PersistedSnapshot(
            recordKey: record.key,
            recordCount: store.all().count,
            contextDigest: digest(contextMaterial),
            locatorDigest: digest(context?.cardURLString ?? ""),
            collections: record.collectionNames,
            seenAt: record.seenAt,
            eventIDs: record.eventJournal?.events.map(\.id) ?? [],
            movementInstances: movementInstances,
            movementFetchedAt: record.movementFetchedAt,
            sourceAttemptKind: record.sourceRefreshAttempt?.kind)
    }

    private static func makeIsolatedMovementProvider(
        context: MovementContext,
        client: SudrfClient,
        observations: SolveObservations
    ) -> any MovementProviding {
        let transferResolver = DistrictCourtResolver(client: client, cacheURL: nil)
        let exactTargets = context.higherCourtTargets ?? context.cartoteka.flatMap {
            MovementTargetBuilder.targets(
                branch: context.branch, courtLevel: context.courtLevel,
                baseCartoteka: $0, caseNumber: context.caseNumber,
                judicialUID: context.judicialUID, courtTitle: context.courtTitle,
                courtCode: context.courtCode, region: context.region,
                displayDomain: context.displayDomain)
        }
        let service = MovementService(
            client: client, higherCourtDomains: context.expandedHigherDomains(),
            higherCourtTargets: exactTargets, knownCards: context.knownCards ?? [],
            baseInstanceLevel: context.baseInstanceLevel,
            judicialUID: context.judicialUID, branch: context.branch,
            transferCourts: { subjectCode in
                try await transferResolver.allCourts(forSubjectCode: subjectCode)
            })
        return ObservingMovementProvider(
            service: service, context: context, observations: observations)
    }

    private static func makeIsolatedClient(
        captchaTokenStore: CaptchaTokenStore, denyNetwork: Bool = false
    ) -> SudrfClient {
        SudrfClient(
            sessionFactory: { delegate in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 45
                configuration.urlCache = nil
                configuration.httpCookieStorage = HTTPCookieStorage()
                configuration.httpShouldSetCookies = true
                configuration.httpCookieAcceptPolicy = .always
                if denyNetwork {
                    configuration.protocolClasses = [Issue339DenyNetworkURLProtocol.self]
                }
                return URLSession(configuration: configuration,
                                  delegate: delegate, delegateQueue: nil)
            },
            minInterval: 1.5,
            trustCourtCertificates: true,
            variantStore: WorkingVariantStore(cacheURL: nil),
            captchaStore: captchaTokenStore)
    }

    private struct ObservingMovementProvider: MovementProviding {
        let service: MovementService
        let context: MovementContext
        let observations: SolveObservations

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            let movement = try await service.movement(
                for: base, court: court, cartoteka: cartoteka)
            await observations.recordMovement(movement, context: context)
            return movement
        }
    }

    private static func outcomeName(_ outcome: CaseRefreshOutcome) -> String {
        switch outcome {
        case .refreshed: "refreshed"
        case .partial: "partial"
        case .cancelled: "cancelled"
        case .captchaRequired: "captcha_required"
        case .failed: "failed"
        case .notFound: "not_found"
        }
    }

    private static func outcomeDiagnostic(_ outcome: CaseRefreshOutcome) -> String? {
        switch outcome {
        case .partial(let message), .failed(let message): message
        default: nil
        }
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
    }

    private static let issue321CardURL = URL(string:
        "http://vos.spb.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=958679833&case_uid=976b38ad-eb63-425e-93d5-b15fa7df355d"
            + "&delo_id=1502001&case_type=0&new=0&srv_num=1")!

    private enum LiveAcceptanceError: Error {
        case autostartDidNotBegin
        case autostartTaskMissing
        case persistedRecordMissing
    }
}
