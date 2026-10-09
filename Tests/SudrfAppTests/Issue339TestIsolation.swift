import Foundation
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
