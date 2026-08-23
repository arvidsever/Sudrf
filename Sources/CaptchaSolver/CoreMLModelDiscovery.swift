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
    /// Bootstrap artifacts are deliberately not part of production model
    /// discovery. The lab may load this path explicitly while collecting
    /// data, but the ordinary app only searches `fsspModelName` below.
    public static let fsspBootstrapModelName = "model-captcha-fssp-bootstrap"
    public static let fsspBootstrapReportName = "model-captcha-fssp-bootstrap-report"

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
        guard modelURL.lastPathComponent == "\(fsspModelName).mlmodelc" else {
            return nil
        }
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
                split: String = "sha256-mod5-v1",
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
            && split == "sha256-mod5-v1"
            && uniqueCorpusCount >= 2_000
            && regressionFixtureCount >= 30
            && heldOutStringAccuracy.isFinite
            && heldOutStringAccuracy >= 0.97
            && heldOutStringAccuracy <= 1
            && acceptedAt090Count >= 100
            && acceptedAt090Accuracy.isFinite
            && acceptedAt090Accuracy >= 0.99
            && acceptedAt090Accuracy <= 1
    }
}

/// Report written next to the lab-only bootstrap model. It is intentionally
/// a separate type from `FSSPModelEligibility`: the bootstrap gate is much
/// smaller and must never be accepted by production discovery.
public struct FSSPBootstrapReport: Codable, Sendable, Equatable {
    public static let reportFileName =
        "\(CoreMLModelDiscovery.fsspBootstrapReportName).json"

    public let version: Int
    public let modelName: String
    public let split: String
    public let uniqueCorpusCount: Int
    public let heldOutCount: Int
    public let heldOutStringAccuracy: Double
    public let acceptedAt098Count: Int
    public let acceptedAt098Accuracy: Double
    public let trainedAt: Date
    public let preprocessorVersion: String

    public init(
        version: Int = 1,
        modelName: String = CoreMLModelDiscovery.fsspBootstrapModelName,
        split: String = "sha256-mod5-v1",
        uniqueCorpusCount: Int,
        heldOutCount: Int,
        heldOutStringAccuracy: Double,
        acceptedAt098Count: Int,
        acceptedAt098Accuracy: Double,
        trainedAt: Date = Date(),
        preprocessorVersion: String = FSSPPreprocessor.version
    ) {
        self.version = version
        self.modelName = modelName
        self.split = split
        self.uniqueCorpusCount = uniqueCorpusCount
        self.heldOutCount = heldOutCount
        self.heldOutStringAccuracy = heldOutStringAccuracy
        self.acceptedAt098Count = acceptedAt098Count
        self.acceptedAt098Accuracy = acceptedAt098Accuracy
        self.trainedAt = trainedAt
        self.preprocessorVersion = preprocessorVersion
    }

    public var isAutoCollectionEligible: Bool {
        version == 1
            && modelName == CoreMLModelDiscovery.fsspBootstrapModelName
            && split == "sha256-mod5-v1"
            && uniqueCorpusCount >= 200
            && heldOutCount >= 30
            && heldOutStringAccuracy.isFinite
            && heldOutStringAccuracy >= 0.80
            && heldOutStringAccuracy <= 1
            && acceptedAt098Count >= 10
            && acceptedAt098Accuracy.isFinite
            && acceptedAt098Accuracy >= 1.0
            && acceptedAt098Accuracy <= 1
            && preprocessorVersion == FSSPPreprocessor.version
    }

    // Python writes an ISO-8601 string so the report remains readable outside
    // Swift. Keep decoding strict enough to reject malformed timestamps while
    // still allowing the normal `JSONDecoder()` used by callers.
    private enum CodingKeys: String, CodingKey {
        case version, modelName, split, uniqueCorpusCount, heldOutCount
        case heldOutStringAccuracy, acceptedAt098Count, acceptedAt098Accuracy
        case trainedAt, preprocessorVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        modelName = try c.decode(String.self, forKey: .modelName)
        split = try c.decode(String.self, forKey: .split)
        uniqueCorpusCount = try c.decode(Int.self, forKey: .uniqueCorpusCount)
        heldOutCount = try c.decode(Int.self, forKey: .heldOutCount)
        heldOutStringAccuracy = try c.decode(Double.self, forKey: .heldOutStringAccuracy)
        acceptedAt098Count = try c.decode(Int.self, forKey: .acceptedAt098Count)
        acceptedAt098Accuracy = try c.decode(Double.self, forKey: .acceptedAt098Accuracy)
        preprocessorVersion = try c.decode(String.self, forKey: .preprocessorVersion)

        if let value = try? c.decode(Date.self, forKey: .trainedAt) {
            trainedAt = value
            return
        }
        let value = try c.decode(String.self, forKey: .trainedAt)
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value)
        }()
        guard let date else {
            throw DecodingError.dataCorruptedError(
                forKey: .trainedAt,
                in: c,
                debugDescription: "trainedAt is not ISO-8601"
            )
        }
        trainedAt = date
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(modelName, forKey: .modelName)
        try c.encode(split, forKey: .split)
        try c.encode(uniqueCorpusCount, forKey: .uniqueCorpusCount)
        try c.encode(heldOutCount, forKey: .heldOutCount)
        try c.encode(heldOutStringAccuracy, forKey: .heldOutStringAccuracy)
        try c.encode(acceptedAt098Count, forKey: .acceptedAt098Count)
        try c.encode(acceptedAt098Accuracy, forKey: .acceptedAt098Accuracy)
        try c.encode(ISO8601DateFormatter().string(from: trainedAt), forKey: .trainedAt)
        try c.encode(preprocessorVersion, forKey: .preprocessorVersion)
    }
}
