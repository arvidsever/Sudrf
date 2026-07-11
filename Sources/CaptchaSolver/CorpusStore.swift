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
            self.fifoPolicy = fifoPolicy
            self.textLengthDistribution = textLengthDistribution
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
        try? fm.createDirectory(at: numeric, withIntermediateDirectories: true)
        try? fm.createDirectory(at: text, withIntermediateDirectories: true)
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
        }
    }

    /// Тестовый хук: подменить потолок для numeric kind. Используется
    /// в `CorpusStoreTests.testFIFOEvictsOldestAtCeiling` для быстрого
    /// теста (5 vs 7 элементов). В production не вызывается.
    public func _setCeilingForTesting(_ value: Int, kind: CaptchaKind) {
        switch kind {
        case .sudrfToken: manifest.numericCeiling = value
        case .kcaptcha:   manifest.textCeiling = value
        }
        scheduleManifestWrite()
    }

    public func pendingSinceLastTrain(kind: CaptchaKind) -> Int {
        switch kind {
        case .sudrfToken: return manifest.numericPendingSinceLastTrain
        case .kcaptcha:   return manifest.textPendingSinceLastTrain
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
        }
        scheduleManifestWrite()
    }

    // MARK: - Internals

    private func dir(for kind: CaptchaKind) -> URL {
        switch kind {
        case .sudrfToken: return baseDir.appendingPathComponent("solved-numeric", isDirectory: true)
        case .kcaptcha:   return baseDir.appendingPathComponent("solved-text", isDirectory: true)
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
