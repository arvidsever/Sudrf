import Foundation

/// Ищет скомпилированную CoreML-модель для числовой sudrf CAPTCHA.
/// Порядок поиска:
///   1. `~/Library/Application Support/Sudrf/model-captcha-numeric.mlmodelc/`;
///   2. модель из app bundle.
/// Возвращает `nil`, если модели нет, оставляя существующий Vision fallback.
public enum CoreMLModelDiscovery {

    public static let numericModelName = "model-captcha-numeric"
    public static let fsspModelName = "model-captcha-fssp"
    public static let fsspEligibilityName = "model-captcha-fssp-eligibility"
    /// Bootstrap artifacts are deliberately not part of production model
    /// discovery. The lab may load this path explicitly while collecting
    /// data, but the ordinary app only searches `fsspModelName` below.
    public static let fsspBootstrapModelName = "model-captcha-fssp-bootstrap"
    public static let fsspBootstrapReportName = "model-captcha-fssp-bootstrap-report"
    public static let fsspSplit = "sha256-mod10-v2"
    public static let fsspArchitectureVersion = "fssp-shared-cnn-v2"

    public static func discoverURL() -> URL? {
        discoverURL(named: numericModelName)
    }

    /// FSSP is intentionally fail-closed: merely placing a model on disk is
    /// not enough. The adjacent eligibility report must prove the production
    /// corpus, fixture and independent-exam thresholds.
    public static func discoverEligibleFSSPURL() -> URL? {
        for modelURL in candidateLocations(named: fsspModelName) {
            if eligibleFSSPURL(modelURL: modelURL) != nil { return modelURL }
        }
        return nil
    }

    static func eligibleFSSPURL(modelURL: URL) -> URL? {
        guard modelURL.lastPathComponent == "\(fsspModelName).mlmodelc",
              FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
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

/// Machine-readable proof that a production FSSP model passed the independent
/// examination. Schema v1 is intentionally not decodable as this type.
public struct FSSPModelEligibility: Codable, Sendable, Equatable {
    public let version: Int
    public let modelName: String
    public let split: String
    public let uniqueCorpusCount: Int
    public let regressionFixtureCount: Int
    public let trainCount: Int
    public let trainStringAccuracy: Double
    public let trainDigitAccuracy: Double
    public let validationCount: Int
    public let validationStringAccuracy: Double
    public let validationDigitAccuracy: Double
    public let examCount: Int
    public let examStringAccuracy: Double
    public let examDigitAccuracy: Double
    public let acceptedAt090Count: Int
    public let acceptedAt090Accuracy: Double
    public let trainedAt: String
    public let preprocessorVersion: String
    public let architectureVersion: String
    public let coreMLParityPassed: Bool
    public let coreMLMaxLogitDifference: Double

    public init(
        version: Int = 2,
        modelName: String = CoreMLModelDiscovery.fsspModelName,
        split: String = CoreMLModelDiscovery.fsspSplit,
        uniqueCorpusCount: Int,
        regressionFixtureCount: Int,
        trainCount: Int,
        trainStringAccuracy: Double,
        trainDigitAccuracy: Double,
        validationCount: Int,
        validationStringAccuracy: Double,
        validationDigitAccuracy: Double,
        examCount: Int,
        examStringAccuracy: Double,
        examDigitAccuracy: Double,
        acceptedAt090Count: Int,
        acceptedAt090Accuracy: Double,
        trainedAt: String,
        preprocessorVersion: String = FSSPPreprocessor.version,
        architectureVersion: String = CoreMLModelDiscovery.fsspArchitectureVersion,
        coreMLParityPassed: Bool,
        coreMLMaxLogitDifference: Double
    ) {
        self.version = version
        self.modelName = modelName
        self.split = split
        self.uniqueCorpusCount = uniqueCorpusCount
        self.regressionFixtureCount = regressionFixtureCount
        self.trainCount = trainCount
        self.trainStringAccuracy = trainStringAccuracy
        self.trainDigitAccuracy = trainDigitAccuracy
        self.validationCount = validationCount
        self.validationStringAccuracy = validationStringAccuracy
        self.validationDigitAccuracy = validationDigitAccuracy
        self.examCount = examCount
        self.examStringAccuracy = examStringAccuracy
        self.examDigitAccuracy = examDigitAccuracy
        self.acceptedAt090Count = acceptedAt090Count
        self.acceptedAt090Accuracy = acceptedAt090Accuracy
        self.trainedAt = trainedAt
        self.preprocessorVersion = preprocessorVersion
        self.architectureVersion = architectureVersion
        self.coreMLParityPassed = coreMLParityPassed
        self.coreMLMaxLogitDifference = coreMLMaxLogitDifference
    }

    public var isEligible: Bool {
        hasCurrentFSSPContract(
            version: version,
            split: split,
            preprocessorVersion: preprocessorVersion,
            architectureVersion: architectureVersion,
            coreMLParityPassed: coreMLParityPassed,
            coreMLMaxLogitDifference: coreMLMaxLogitDifference,
            trainedAt: trainedAt
        )
            && modelName == CoreMLModelDiscovery.fsspModelName
            && uniqueCorpusCount >= 2_000
            && regressionFixtureCount >= 30
            && hasValidEvaluation(
                count: trainCount, stringAccuracy: trainStringAccuracy, digitAccuracy: trainDigitAccuracy)
            && hasValidEvaluation(
                count: validationCount, stringAccuracy: validationStringAccuracy,
                digitAccuracy: validationDigitAccuracy)
            && hasValidEvaluation(
                count: examCount, stringAccuracy: examStringAccuracy, digitAccuracy: examDigitAccuracy)
            && examStringAccuracy >= 0.97
            && acceptedAt090Count >= 100
            && acceptedAt090Count <= examCount
            && isProbability(acceptedAt090Accuracy)
            && acceptedAt090Accuracy >= 0.99
    }
}

/// Report written next to the lab-only bootstrap model. It stays separate from
/// `FSSPModelEligibility`: a lab model can never be discovered by production.
public struct FSSPBootstrapReport: Codable, Sendable, Equatable {
    public static let reportFileName =
        "\(CoreMLModelDiscovery.fsspBootstrapReportName).json"

    public let version: Int
    public let modelName: String
    public let split: String
    public let uniqueCorpusCount: Int
    public let trainCount: Int
    public let trainStringAccuracy: Double
    public let trainDigitAccuracy: Double
    public let validationCount: Int
    public let validationStringAccuracy: Double
    public let validationDigitAccuracy: Double
    public let examCount: Int
    public let examStringAccuracy: Double
    public let examDigitAccuracy: Double
    public let acceptedAt050Count: Int
    public let acceptedAt050Accuracy: Double
    public let trainedAt: String
    public let preprocessorVersion: String
    public let architectureVersion: String
    public let coreMLParityPassed: Bool
    public let coreMLMaxLogitDifference: Double

    public init(
        version: Int = 2,
        modelName: String = CoreMLModelDiscovery.fsspBootstrapModelName,
        split: String = CoreMLModelDiscovery.fsspSplit,
        uniqueCorpusCount: Int,
        trainCount: Int,
        trainStringAccuracy: Double,
        trainDigitAccuracy: Double,
        validationCount: Int,
        validationStringAccuracy: Double,
        validationDigitAccuracy: Double,
        examCount: Int,
        examStringAccuracy: Double,
        examDigitAccuracy: Double,
        acceptedAt050Count: Int,
        acceptedAt050Accuracy: Double,
        trainedAt: String,
        preprocessorVersion: String = FSSPPreprocessor.version,
        architectureVersion: String = CoreMLModelDiscovery.fsspArchitectureVersion,
        coreMLParityPassed: Bool,
        coreMLMaxLogitDifference: Double
    ) {
        self.version = version
        self.modelName = modelName
        self.split = split
        self.uniqueCorpusCount = uniqueCorpusCount
        self.trainCount = trainCount
        self.trainStringAccuracy = trainStringAccuracy
        self.trainDigitAccuracy = trainDigitAccuracy
        self.validationCount = validationCount
        self.validationStringAccuracy = validationStringAccuracy
        self.validationDigitAccuracy = validationDigitAccuracy
        self.examCount = examCount
        self.examStringAccuracy = examStringAccuracy
        self.examDigitAccuracy = examDigitAccuracy
        self.acceptedAt050Count = acceptedAt050Count
        self.acceptedAt050Accuracy = acceptedAt050Accuracy
        self.trainedAt = trainedAt
        self.preprocessorVersion = preprocessorVersion
        self.architectureVersion = architectureVersion
        self.coreMLParityPassed = coreMLParityPassed
        self.coreMLMaxLogitDifference = coreMLMaxLogitDifference
    }

    public var isCurrentContract: Bool {
        hasCurrentFSSPContract(
            version: version,
            split: split,
            preprocessorVersion: preprocessorVersion,
            architectureVersion: architectureVersion,
            coreMLParityPassed: coreMLParityPassed,
            coreMLMaxLogitDifference: coreMLMaxLogitDifference,
            trainedAt: trainedAt
        )
            && modelName == CoreMLModelDiscovery.fsspBootstrapModelName
            && uniqueCorpusCount >= 200
            && hasValidEvaluation(
                count: trainCount, stringAccuracy: trainStringAccuracy, digitAccuracy: trainDigitAccuracy)
            && hasValidEvaluation(
                count: validationCount, stringAccuracy: validationStringAccuracy,
                digitAccuracy: validationDigitAccuracy)
            && hasValidEvaluation(
                count: examCount, stringAccuracy: examStringAccuracy, digitAccuracy: examDigitAccuracy)
    }

    /// Suggest only after the model proves itself on images not used while
    /// learning. This is deliberately lower than production's final gate.
    public var isRecognitionEligible: Bool {
        isCurrentContract
            && examCount >= 30
            && examStringAccuracy >= 0.50
    }

    public var isAutoCollectionEligible: Bool {
        isRecognitionEligible
            && acceptedAt050Count >= 10
            && acceptedAt050Count <= examCount
            && isProbability(acceptedAt050Accuracy)
            && acceptedAt050Accuracy >= 0.50
    }
}

private func hasCurrentFSSPContract(
    version: Int,
    split: String,
    preprocessorVersion: String,
    architectureVersion: String,
    coreMLParityPassed: Bool,
    coreMLMaxLogitDifference: Double,
    trainedAt: String
) -> Bool {
    version == 2
        && split == CoreMLModelDiscovery.fsspSplit
        && preprocessorVersion == FSSPPreprocessor.version
        && architectureVersion == CoreMLModelDiscovery.fsspArchitectureVersion
        && coreMLParityPassed
        && coreMLMaxLogitDifference.isFinite
        && coreMLMaxLogitDifference >= 0
        && coreMLMaxLogitDifference <= 0.001
        && isISO8601Timestamp(trainedAt)
}

private func hasValidEvaluation(count: Int,
                                stringAccuracy: Double,
                                digitAccuracy: Double) -> Bool {
    count > 0 && isProbability(stringAccuracy) && isProbability(digitAccuracy)
}

private func isProbability(_ value: Double) -> Bool {
    value.isFinite && value >= 0 && value <= 1
}

private func isISO8601Timestamp(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) != nil
}
