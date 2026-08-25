import CryptoKit
import Foundation

/// Хранилище корпуса captcha-изображений, на которых солвер учится.
///
/// v0.38.9: dual-corpus bootstrap. Каждый успешно решённый captcha
/// (если сервер реально вернул результаты, а не captcha-rejection)
/// копируется в `solved-<kind>/<code>_<host>_<ts>_<uuid>.png`.
/// При превышении потолка (5000 на kind) — FIFO-eviction по mtime.
///
/// Структура:
/// ```
/// ~/Library/Application Support/Sudrf/captcha-training/
///   solved-numeric/      # .sudrfToken, ceiling 5000
///   solved-text/         # .kcaptcha, ceiling 5000
///   pending/             # friend's 17 unsolved, не трогаем
///   manifest.json        # единый источник правды
/// ```
///
/// Manifest обновляется дебаунсом (1 запись в секунду). На
/// большом потоке это держит IO разумным.
public actor CorpusStore {

    public static let shared = CorpusStore()

    public struct Manifest: Codable, Sendable, Equatable {
        public var version: Int
        public var numericCeiling: Int
        public var textCeiling: Int
        public var numericLastTrainedAt: Date?
        public var numericLastTrainedCount: Int
        public var numericPendingSinceLastTrain: Int
        public var textLastTrainedAt: Date?
        public var textLastTrainedCount: Int
        public var textPendingSinceLastTrain: Int
        public var fsspCeiling: Int
        public var fsspLastTrainedAt: Date?
        public var fsspLastTrainedCount: Int
        public var fsspPendingSinceLastTrain: Int
        public var fifoPolicy: String
        public var textLengthDistribution: [Int: Int]

        public init(version: Int = 1,
                    numericCeiling: Int = 5000,
                    textCeiling: Int = 5000,
                    numericLastTrainedAt: Date? = nil,
                    numericLastTrainedCount: Int = 0,
                    numericPendingSinceLastTrain: Int = 0,
                    textLastTrainedAt: Date? = nil,
                    textLastTrainedCount: Int = 0,
                    textPendingSinceLastTrain: Int = 0,
                    fsspCeiling: Int = 5000,
                    fsspLastTrainedAt: Date? = nil,
                    fsspLastTrainedCount: Int = 0,
                    fsspPendingSinceLastTrain: Int = 0,
                    fifoPolicy: String = "oldestFirst",
                    textLengthDistribution: [Int: Int] = [:]) {
            self.version = version
            self.numericCeiling = numericCeiling
            self.textCeiling = textCeiling
            self.numericLastTrainedAt = numericLastTrainedAt
            self.numericLastTrainedCount = numericLastTrainedCount
            self.numericPendingSinceLastTrain = numericPendingSinceLastTrain
            self.textLastTrainedAt = textLastTrainedAt
            self.textLastTrainedCount = textLastTrainedCount
            self.textPendingSinceLastTrain = textPendingSinceLastTrain
            self.fsspCeiling = fsspCeiling
            self.fsspLastTrainedAt = fsspLastTrainedAt
            self.fsspLastTrainedCount = fsspLastTrainedCount
            self.fsspPendingSinceLastTrain = fsspPendingSinceLastTrain
            self.fifoPolicy = fifoPolicy
            self.textLengthDistribution = textLengthDistribution
        }

        private enum CodingKeys: String, CodingKey {
            case version, numericCeiling, textCeiling
            case numericLastTrainedAt, numericLastTrainedCount, numericPendingSinceLastTrain
            case textLastTrainedAt, textLastTrainedCount, textPendingSinceLastTrain
            case fsspCeiling, fsspLastTrainedAt, fsspLastTrainedCount, fsspPendingSinceLastTrain
            case fifoPolicy, textLengthDistribution
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            numericCeiling = try c.decodeIfPresent(Int.self, forKey: .numericCeiling) ?? 5000
            textCeiling = try c.decodeIfPresent(Int.self, forKey: .textCeiling) ?? 5000
            numericLastTrainedAt = try c.decodeIfPresent(Date.self, forKey: .numericLastTrainedAt)
            numericLastTrainedCount = try c.decodeIfPresent(Int.self, forKey: .numericLastTrainedCount) ?? 0
            numericPendingSinceLastTrain = try c.decodeIfPresent(Int.self, forKey: .numericPendingSinceLastTrain) ?? 0
            textLastTrainedAt = try c.decodeIfPresent(Date.self, forKey: .textLastTrainedAt)
            textLastTrainedCount = try c.decodeIfPresent(Int.self, forKey: .textLastTrainedCount) ?? 0
            textPendingSinceLastTrain = try c.decodeIfPresent(Int.self, forKey: .textPendingSinceLastTrain) ?? 0
            fsspCeiling = try c.decodeIfPresent(Int.self, forKey: .fsspCeiling) ?? 5000
            fsspLastTrainedAt = try c.decodeIfPresent(Date.self, forKey: .fsspLastTrainedAt)
            fsspLastTrainedCount = try c.decodeIfPresent(Int.self, forKey: .fsspLastTrainedCount) ?? 0
            fsspPendingSinceLastTrain = try c.decodeIfPresent(Int.self, forKey: .fsspPendingSinceLastTrain) ?? 0
            fifoPolicy = try c.decodeIfPresent(String.self, forKey: .fifoPolicy) ?? "oldestFirst"
            textLengthDistribution = try c.decodeIfPresent([Int: Int].self, forKey: .textLengthDistribution) ?? [:]
        }
    }

    public let baseDir: URL
    public internal(set) var manifest: Manifest

    private let fm = FileManager.default
    private let isoFormatter: ISO8601DateFormatter
    private let dateFormatter: DateFormatter
    private var pendingManifestWrite: Task<Void, Never>?

    public init(baseDir: URL? = nil) {
        if let baseDir {
            self.baseDir = baseDir
        } else if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            self.baseDir = support
                .appendingPathComponent("Sudrf", isDirectory: true)
                .appendingPathComponent("captcha-training", isDirectory: true)
        } else {
            // Fallback: tmp dir. Production никогда сюда не попадёт
            // (на macOS Application Support всегда есть).
            self.baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Sudrf-captcha-training", isDirectory: true)
        }
        try? fm.createDirectory(at: self.baseDir, withIntermediateDirectories: true)
        let numeric = self.baseDir.appendingPathComponent("solved-numeric", isDirectory: true)
        let text = self.baseDir.appendingPathComponent("solved-text", isDirectory: true)
        let fssp = self.baseDir.appendingPathComponent("solved-fssp", isDirectory: true)
        try? fm.createDirectory(at: numeric, withIntermediateDirectories: true)
        try? fm.createDirectory(at: text, withIntermediateDirectories: true)
        try? fm.createDirectory(at: fssp, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        self.isoFormatter = iso
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        df.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = df
        // Load manifest.json or start with default.
        let manifestURL = self.baseDir.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: manifestURL),
           let loaded = try? decoder.decode(Manifest.self, from: data) {
            self.manifest = loaded
        } else {
            self.manifest = Manifest()
        }
    }

    // MARK: - Add / evict

    /// Добавляет PNG в `solved-<kind>/<code>_<host>_<ts>_<uuid>.png`.
    /// Если размер корпуса превысил потолок — удаляет самые старые
    /// (по mtime), пока не вернётся в лимит. Возвращает URL
    /// нового файла или `nil`, если запись не удалась.
    @discardableResult
    public func add(png: Data, code: String, host: String, kind: CaptchaKind) -> URL? {
        let dir = self.dir(for: kind)
        if kind == .fsspDigits || kind == .sudrfToken {
            guard !png.isEmpty else { return nil }
            if kind == .fsspDigits {
                guard code.utf8.count == 5,
                      code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            }
            let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            let url = dir.appendingPathComponent("\(code)_\(digest).png")
            if fm.fileExists(atPath: url.path) { return url }
            // The split key is the image hash, so one PNG may exist only
            // once even if a later manual entry supplies a conflicting code.
            // Keep the first confirmed label and let neither a typo nor a
            // duplicate leak across training and independent-exam sets.
            if let names = try? fm.contentsOfDirectory(atPath: dir.path),
               names.contains(where: { $0.hasSuffix("_\(digest).png") }) {
                return nil
            }
            do { try png.write(to: url, options: .atomic) } catch { return nil }
            switch kind {
            case .sudrfToken:
                manifest.numericPendingSinceLastTrain += 1
            case .fsspDigits:
                manifest.version = max(manifest.version, 2)
                manifest.fsspPendingSinceLastTrain += 1
            case .kcaptcha:
                break
            }
            evictIfNeeded(kind: kind)
            scheduleManifestWrite()
            return url
        }
        let safeHost = host.replacingOccurrences(of: "/", with: "_")
                            .replacingOccurrences(of: ":", with: "")
        let ts = dateFormatter.string(from: Date())
        let uuid = UUID().uuidString.prefix(8)
        let name = "\(code)_\(safeHost)_\(ts)_\(uuid).png"
        let url = dir.appendingPathComponent(name)
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        // Update manifest.
        switch kind {
        case .sudrfToken: manifest.numericPendingSinceLastTrain += 1
        case .kcaptcha:
            manifest.textPendingSinceLastTrain += 1
            manifest.textLengthDistribution[code.count, default: 0] += 1
        case .fsspDigits:
            break
        }
        evictIfNeeded(kind: kind)
        scheduleManifestWrite()
        return url
    }

    /// Удаляет самые старые файлы в `solved-<kind>/`, пока
    /// `count > ceiling`. Возвращает число удалённых.
    @discardableResult
    public func evictIfNeeded(kind: CaptchaKind) -> Int {
        let dir = self.dir(for: kind)
        let ceiling = ceiling(for: kind)
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch { return 0 }
        let pngs = entries.filter { $0.pathExtension.lowercased() == "png" }
        guard pngs.count > ceiling else { return 0 }
        let sorted = pngs.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        let toDelete = sorted.prefix(pngs.count - ceiling)
        var n = 0
        for u in toDelete {
            if (try? fm.removeItem(at: u)) != nil { n += 1 }
        }
        return n
    }

    public func currentCount(kind: CaptchaKind) -> Int {
        let dir = self.dir(for: kind)
        let entries = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { $0.pathExtension.lowercased() == "png" }.count
    }

    public func ceiling(for kind: CaptchaKind) -> Int {
        switch kind {
        case .sudrfToken: return manifest.numericCeiling
        case .kcaptcha:   return manifest.textCeiling
        case .fsspDigits: return manifest.fsspCeiling
        }
    }

    /// Тестовый хук: подменить потолок для numeric kind. Используется
    /// в `CorpusStoreTests.testFIFOEvictsOldestAtCeiling` для быстрого
    /// теста (5 vs 7 элементов). В production не вызывается.
    public func _setCeilingForTesting(_ value: Int, kind: CaptchaKind) {
        switch kind {
        case .sudrfToken: manifest.numericCeiling = value
        case .kcaptcha:   manifest.textCeiling = value
        case .fsspDigits: manifest.fsspCeiling = value
        }
        scheduleManifestWrite()
    }

    public func pendingSinceLastTrain(kind: CaptchaKind) -> Int {
        switch kind {
        case .sudrfToken: return manifest.numericPendingSinceLastTrain
        case .kcaptcha:   return manifest.textPendingSinceLastTrain
        case .fsspDigits: return manifest.fsspPendingSinceLastTrain
        }
    }

    /// Вызывается после retrain. Сбрасывает pendingSinceLastTrain
    /// и обновляет дату/число последнего тренировочного снапшота.
    public func markTrained(kind: CaptchaKind, count: Int) {
        switch kind {
        case .sudrfToken:
            manifest.numericLastTrainedAt = Date()
            manifest.numericLastTrainedCount = count
            manifest.numericPendingSinceLastTrain = 0
        case .kcaptcha:
            manifest.textLastTrainedAt = Date()
            manifest.textLastTrainedCount = count
            manifest.textPendingSinceLastTrain = 0
        case .fsspDigits:
            manifest.fsspLastTrainedAt = Date()
            manifest.fsspLastTrainedCount = count
            manifest.fsspPendingSinceLastTrain = 0
        }
        scheduleManifestWrite()
    }

    // MARK: - Internals

    private func dir(for kind: CaptchaKind) -> URL {
        switch kind {
        case .sudrfToken: return baseDir.appendingPathComponent("solved-numeric", isDirectory: true)
        case .kcaptcha:   return baseDir.appendingPathComponent("solved-text", isDirectory: true)
        case .fsspDigits: return baseDir.appendingPathComponent("solved-fssp", isDirectory: true)
        }
    }

    /// Дебаунс: реальная запись manifest.json происходит через 1с
    /// после последнего изменения. На горячем пути (несколько add'ов
    /// подряд) это держит IO разумным.
    private func scheduleManifestWrite() {
        pendingManifestWrite?.cancel()
        pendingManifestWrite = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            await self?.flushManifest()
        }
    }

    public func flushManifest() {
        let url = baseDir.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(manifest),
           let _ = try? data.write(to: url, options: .atomic) {
            // success
        }
    }
}
