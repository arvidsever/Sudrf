import Foundation
import SudrfKit
@testable import CaptchaSolver
@testable import SudrfApp

final class Issue339TestIsolation {
    let suiteName: String
    let userDefaults: UserDefaults
    private let supportDirectory: URL
    private let spotlightWriter = Issue339NoopSpotlightWriter()

    init() {
        let suiteName = "ru.sudrf.tests.issue339.\(UUID().uuidString)"
        self.suiteName = suiteName
        self.userDefaults = UserDefaults(suiteName: suiteName)!
        self.supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
    }

    @MainActor
    func makeCaptchaSettings() -> CaptchaSettings {
        CaptchaSettings(defaults: userDefaults)
    }

    func makeCaptchaCorpus() -> CorpusStore {
        CorpusStore(baseDir: supportDirectory.appendingPathComponent(
            "captcha-training", isDirectory: true))
    }

    func makeNoopCaptchaSolver() -> CaptchaSolver {
        CaptchaSolver(
            provider: Issue339NoopCaptchaProvider(), enabledKinds: [],
            log: CaptchaSolverLog(fileURL: nil, failuresDir: nil, diagnosticsDir: nil))
    }

    @MainActor
    func makeCaptchaSolver(log: CaptchaSolverLog, settings: CaptchaSettings) throws -> CaptchaSolver {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../CaptchaSolverTests/Fixtures", isDirectory: true)
            .standardizedFileURL
        let primaryURL = fixtures.appendingPathComponent("model-captcha-numeric.mlmodelc")
        let specialistURL = fixtures.appendingPathComponent(
            "model-captcha-numeric-specialist.mlmodelc")
        let primary = try CoreMLCaptchaStrategy(modelURL: primaryURL, kind: .sudrfToken)
        let specialist = try CoreMLCaptchaStrategy(modelURL: specialistURL, kind: .sudrfToken)
        var vision = VisionOCRStrategy(preprocessorHosts: settings.preprocessorHosts)
        vision.preprocessingProvider = { [weak settings] in
            settings?.preprocessorEnabled ?? false
        }
        let numeric = HighestConfidenceStrategy(first: primary, second: specialist)
        let provider = KindDispatchingStrategy(
            primary: numeric, fallback: vision,
            minPrimaryConfidence: settings.minConfidence,
            primaryAttemptIsCompatible: { CoreMLCaptchaStrategy.isCompatibleOutput($0.value) })
        return CaptchaSolver(provider: provider,
                             enabledKinds: [.sudrfToken, .kcaptcha], log: log)
    }

    func makeSpotlightIndexer(catalog: CaseCatalog) -> SpotlightIndexer {
        SpotlightIndexer(
            catalog: catalog,
            writer: spotlightWriter,
            manifestStore: SpotlightManifestStore(suiteName: suiteName),
            preferenceStore: SpotlightPreferenceStore(defaults: userDefaults))
    }

    @MainActor
    func spotlightIndexCallCount() async -> Int {
        await spotlightWriter.indexCallCount
    }

    func removePreferences() {
        userDefaults.removePersistentDomain(forName: suiteName)
        if FileManager.default.fileExists(atPath: supportDirectory.path) {
            try? FileManager.default.removeItem(at: supportDirectory)
        }
    }
}

struct Issue339UnusedVSRF: VSRFProviding {
    func search(uniqueNumber: String?, oldCaseNumber: String?,
                keywords: String?) async throws -> VSRFSearchResults { throw CancellationError() }
    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard {
        throw CancellationError()
    }
}

struct Issue339UnusedMosGorSud: MosGorSudProviding {
    func search(courtAlias: String?, uid: String?, caseNumber: String?, participant: String?,
                instance: Int, processType: MosGorSudProcessType) async throws -> [MosGorSudResult] {
        throw CancellationError()
    }
    func fetchCard(url: URL) async throws -> MosGorSudCard { throw CancellationError() }
    func fetchPublishedAct(url: URL) async throws -> PublishedActFile { throw CancellationError() }
}

struct Issue339UnusedOrigin: CaseOriginResolving {
    func resolve(anchorContext: MovementContext,
                 anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        throw CancellationError()
    }
}

private struct Issue339NoopCaptchaProvider: CaptchaSolvingProvider {
    func solve(pngData: Data, kind: CaptchaKind, host: String?) async throws -> CaptchaAttempt {
        .empty
    }
}

private actor Issue339NoopSpotlightWriter: SpotlightIndexWriting {
    private(set) var indexCallCount = 0

    func index(cases: [CaseEntity], acts: [CourtActEntity]) async throws {
        indexCallCount += 1
    }
    func delete(caseIDs: [String], actIDs: [String]) async throws {}
    func deleteAll() async throws {}
}

@MainActor
final class Issue339NotificationReceiver {
    private(set) var receivedEntryCount = 0

    func receive(_ entries: [FeedEntry]) {
        receivedEntryCount += entries.count
    }
}
