import Foundation

/// Ищет скомпилированную CoreML-модель для числовой sudrf captcha.
/// Порядок поиска:
///   1. `~/Library/Application Support/Sudrf/model-captcha-numeric.mlmodelc/`
///      — позволяет пользователю переопределить модель без перебилда.
///   2. `Bundle.main.url(forResource: "model-captcha-numeric",
///      withExtension: "mlmodelc")` — модель, зашитая в app bundle.
/// Возвращает `nil`, если ни там, ни там модель не найдена —
/// `CoreMLCaptchaStrategy` не инициализируется, и солвер работает
/// на `VisionOCRStrategy` (текущее поведение до v0.38.8).
public enum CoreMLModelDiscovery {

    public static let numericModelName = "model-captcha-numeric"
    public static let fsspModelName = "model-captcha-fssp"
    public static let fsspEligibilityName = "model-captcha-fssp-eligibility"

    public static func discoverURL() -> URL? {
        discoverURL(named: numericModelName)
    }

    /// FSSP is intentionally fail-closed: merely placing a model on disk is
    /// not enough. The adjacent eligibility report must prove the corpus,
    /// fixture and held-out thresholds from the integration plan.
    public static func discoverEligibleFSSPURL() -> URL? {
        let locations = candidateLocations(named: fsspModelName)
        for modelURL in locations {
            if eligibleFSSPURL(modelURL: modelURL) != nil { return modelURL }
        }
        return nil
    }

    static func eligibleFSSPURL(modelURL: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
        let reportURL = modelURL.deletingLastPathComponent()
            .appendingPathComponent("\(fsspEligibilityName).json")
        guard let data = try? Data(contentsOf: reportURL),
              let report = try? JSONDecoder().decode(FSSPModelEligibility.self, from: data),
              report.isEligible else { return nil }
        return modelURL
    }

    private static func discoverURL(named name: String) -> URL? {
        candidateLocations(named: name).first
    }

    private static func candidateLocations(named name: String) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(support
                .appendingPathComponent("Sudrf", isDirectory: true)
                .appendingPathComponent("\(name).mlmodelc", isDirectory: true))
        }
        if let bundled = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            urls.append(bundled)
        }
        return urls.filter { fm.fileExists(atPath: $0.path) }
    }
}

/// Machine-readable output of the FSSP training/evaluation pipeline.
/// The release SHA manifest protects the files in delivery; this report is
/// the runtime switch that keeps an unqualified model disabled.
public struct FSSPModelEligibility: Codable, Sendable, Equatable {
    public let version: Int
    public let modelName: String
    public let split: String
    public let uniqueCorpusCount: Int
    public let regressionFixtureCount: Int
    public let heldOutStringAccuracy: Double
    public let acceptedAt090Count: Int
    public let acceptedAt090Accuracy: Double

    public init(version: Int = 1,
                modelName: String = CoreMLModelDiscovery.fsspModelName,
                split: String = "sha256-80-20",
                uniqueCorpusCount: Int,
                regressionFixtureCount: Int,
                heldOutStringAccuracy: Double,
                acceptedAt090Count: Int,
                acceptedAt090Accuracy: Double) {
        self.version = version
        self.modelName = modelName
        self.split = split
        self.uniqueCorpusCount = uniqueCorpusCount
        self.regressionFixtureCount = regressionFixtureCount
        self.heldOutStringAccuracy = heldOutStringAccuracy
        self.acceptedAt090Count = acceptedAt090Count
        self.acceptedAt090Accuracy = acceptedAt090Accuracy
    }

    public var isEligible: Bool {
        version == 1
            && modelName == CoreMLModelDiscovery.fsspModelName
            && split == "sha256-80-20"
            && uniqueCorpusCount >= 2_000
            && regressionFixtureCount >= 30
            && heldOutStringAccuracy.isFinite
            && heldOutStringAccuracy >= 0.97
            && heldOutStringAccuracy <= 1
            && acceptedAt090Count > 0
            && acceptedAt090Accuracy.isFinite
            && acceptedAt090Accuracy >= 0.99
            && acceptedAt090Accuracy <= 1
    }
}
