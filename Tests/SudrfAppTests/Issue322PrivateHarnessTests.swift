// © 2026 Воробьёв Виктор Викторович. SPDX-License-Identifier: CC-BY-NC-ND-4.0
import Foundation
import XCTest
@testable import SudrfKit
@testable import CaptchaSolver
@testable import SudrfApp

/// First isolation gate only. No live requests, AppRouter or background timers.
@MainActor
final class Issue322PrivateHarnessTests: XCTestCase {
    func testDiagnosticOverrideWritesOnlyPrivateDirectory() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousDirectory = SearchDiagnostics.setDirForTesting(root)
        let previousEnabled = SearchDiagnostics.setEnabledForTesting(true)
        defer {
            SearchDiagnostics.setDirForTesting(previousDirectory)
            SearchDiagnostics.setEnabledForTesting(previousEnabled)
        }
        let bytes = Data("synthetic #322 diagnostic".utf8)
        SearchDiagnostics.dumpVariant(data: bytes, host: "issue322.invalid")
        let files = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), bytes)
    }

    func testPrivatePipelineConstructionDoesNotSendRequests() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ru.sudrf.tests.issue322.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = CaptchaTokenStore()
        let client = SudrfClient(sessionFactory: { delegate in
            let configuration = Self.configuration()
            return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }, variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: tokens)
        let moscowSession = URLSession(configuration: Self.configuration())
        defer { moscowSession.invalidateAndCancel() }
        let moscow = MosGorSudClient(session: moscowSession)
        let resolver = CaseOriginResolver(client: client,
            districtResolver: DistrictCourtResolver(client: client, cacheURL: nil),
            magistrateResolver: MagistrateCourtResolver(client: client, cacheURL: nil),
            regularProvider: client, magistrateProvider: RejectUnusedCard(), moscowProvider: moscow)
        let settings = CaptchaSettings(defaults: defaults)
        let solver = CaptchaSolver(log: CaptchaSolverLog(fileURL: nil,
            failuresDir: nil, diagnosticsDir: nil))
        let container = try SudrfModelContainerFactory.make(inMemory: false,
            storeURL: root.appendingPathComponent("fixture.store"))
        let store = try TrackedStore(container: container, prepared: true)
        let repair = TrackedCaseRepairCoordinator(store: store, client: client,
            originResolver: resolver, defaults: defaults, captchaSolver: solver,
            captchaSettings: settings, captchaStore: tokens)
        let center = RefreshCenter(store: store, client: client, captchaSolver: solver,
            captchaSettings: settings, captchaTokenStore: tokens,
            serviceBuilder: { context in
                MovementService(client: client, higherCourtDomains: [],
                    higherCourtTargets: [], knownCards: context.knownCards ?? [],
                    baseInstanceLevel: context.baseInstanceLevel, mosgorsud: moscow,
                    judicialUID: context.judicialUID, branch: context.branch,
                    transferCourts: { _ in throw URLError(.unsupportedURL) })
            }, treasuryDiscover: { _, _, _ in throw URLError(.unsupportedURL) },
            vsrfProvider: RejectUnusedVS(), fsspAutoModelEnabled: false,
            fsspDiscover: { _ in throw URLError(.unsupportedURL) })
        center.repairBeforeRefresh = { key, force in
            try await repair.repairIfNeeded(key: key, forceAttempt: force).effectiveKey
        }
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(center.refreshing.isEmpty)
        XCTAssertTrue(settings.isEffectivelyEnabled)
    }

    nonisolated private static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.protocolClasses = [RejectNetwork.self]
        return config
    }

    private func privateRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue322-private-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return root
    }
}

private final class RejectNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("#322 constructor gate attempted an unexpected request")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}

private struct RejectUnusedCard: CaseProviding {
    func search(court: Court, cartoteka: Cartoteka, field: SearchField,
                value: String) async throws -> [CaseSearchResult] {
        throw URLError(.unsupportedURL)
    }
    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard { throw URLError(.unsupportedURL) }
    func fetchCard(url: URL) async throws -> CaseCard { throw URLError(.unsupportedURL) }
}
private struct RejectUnusedVS: VSRFProviding {
    func search(uniqueNumber: String?, oldCaseNumber: String?, keywords: String?) async throws -> VSRFSearchResults {
        throw URLError(.unsupportedURL)
    }
    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard {
        throw URLError(.unsupportedURL)
    }
}
