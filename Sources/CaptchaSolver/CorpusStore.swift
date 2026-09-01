import CryptoKit
import Foundation

/// Хранилище корпуса captcha-изображений, на которых солвер учится.
///
/// v0.38.9: dual-corpus bootstrap. Каждый успешно решённый captcha
/// (если сервер реально вернул результаты, а не captcha-rejection)
/// копируется в `solved-<kind>/`.
/// При превышении потолка (5000 на kind) — FIFO-eviction по mtime.
///
/// Структура:
/// ```
/// ~/Library/Application Support/Sudrf/captcha-training/
///   solved-numeric/      # .sudrfToken, ceiling 5000
///   solved-text/         # legacy .kcaptcha samples (not trusted for #164)
///   solved-kcaptcha-verified/ # confirmed .kcaptcha PNGs, keyed by SHA-256
///   kcaptcha-verified-index.json # SHA-256 → code + hosts
///   pending/             # friend's 17 unsolved, не трогаем
///   manifest.json        # единый источник правды
/// ```
///
/// Manifest обновляется дебаунсом (1 запись в секунду). На
/// большом потоке это держит IO разумным.
public actor CorpusStore {

    public static let shared = CorpusStore()

    /// Result of recording a confirmed kcaptcha sample.
    ///
    /// A duplicate can still add a previously unseen host to the index; it
    /// never creates a second image. A conflicting label is rejected so one
    /// image cannot enter training with ambiguous ground truth.
    public enum AddResult: Sendable, Equatable {
        case stored(URL)
        case duplicate(URL)
        case conflict
        case invalid
    }

    /// Metadata for one hash-keyed, confirmed kcaptcha image.
    public struct VerifiedKCaptchaMetadata: Codable, Sendable, Equatable {
        public let digest: String
        public let code: String
        public let hosts: [String]

        public init(digest: String, code: String, hosts: [String]) {
            self.digest = digest
            self.code = code
            self.hosts = hosts
        }
    }

    private struct VerifiedKCaptchaIndexEntry: Codable, Sendable, Equatable {
        var code: String
        var hosts: [String]
    }

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
    /// Directory containing only phase-1 confirmed kcaptcha images.
    public let verifiedKCaptchaDirectory: URL
    /// JSON index for `verifiedKCaptchaDirectory`.
    public let verifiedKCaptchaIndexURL: URL
    public internal(set) var manifest: Manifest

    private let fm = FileManager.default
    private var pendingManifestWrite: Task<Void, Never>?
    private var verifiedKCaptchaIndex: [String: VerifiedKCaptchaIndexEntry]
    private var verifiedKCaptchaIndexIsValid: Bool

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
        let verifiedKCaptcha = self.baseDir.appendingPathComponent(
            "solved-kcaptcha-verified", isDirectory: true)
        try? fm.createDirectory(at: verifiedKCaptcha, withIntermediateDirectories: true)
        self.verifiedKCaptchaDirectory = verifiedKCaptcha
        self.verifiedKCaptchaIndexURL = self.baseDir.appendingPathComponent(
            "kcaptcha-verified-index.json")
        if let data = try? Data(contentsOf: self.verifiedKCaptchaIndexURL),
           let loaded = try? JSONDecoder().decode(
               [String: VerifiedKCaptchaIndexEntry].self, from: data) {
            self.verifiedKCaptchaIndex = loaded
            self.verifiedKCaptchaIndexIsValid = true
        } else if fm.fileExists(atPath: self.verifiedKCaptchaIndexURL.path) {
            // A damaged index must not be guessed or merged with legacy
            // files: callers stay fail-closed until the index is repaired.
            self.verifiedKCaptchaIndex = [:]
            self.verifiedKCaptchaIndexIsValid = false
        } else {
            self.verifiedKCaptchaIndex = [:]
            self.verifiedKCaptchaIndexIsValid = true
        }
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

    /// Добавляет PNG в `solved-<kind>/`.
    /// Если размер корпуса превысил потолок — удаляет самые старые
    /// (по mtime), пока не вернётся в лимит. Возвращает URL
    /// нового файла или `nil`, если запись не удалась.
    @discardableResult
    public func add(png: Data, code: String, host: String, kind: CaptchaKind) -> URL? {
        let dir = self.dir(for: kind)
        switch kind {
        case .kcaptcha:
            switch addVerifiedKCaptcha(png: png, code: code, host: host) {
            case .stored(let url), .duplicate(let url): return url
            case .conflict, .invalid: return nil
            }
        case .fsspDigits, .sudrfToken:
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
    }

    /// Records a confirmed `.kcaptcha` sample in the phase-1 corpus.
    /// Images are keyed only by SHA-256; the sidecar index retains the code
    /// and every host that confirmed that image.
    @discardableResult
    public func addVerifiedKCaptcha(png: Data, code: String, host: String) -> AddResult {
        let canonicalHost = host.lowercased()
        guard verifiedKCaptchaIndexIsValid,
              isValidTextSample(png: png, code: code, host: canonicalHost) else {
            return .invalid
        }

        let imageDigest = digest(of: png)
        let imageURL = verifiedKCaptchaDirectory.appendingPathComponent("\(imageDigest).png")

        if var entry = verifiedKCaptchaIndex[imageDigest] {
            guard entry.code == code else { return .conflict }
            guard entry.hosts.allSatisfy({ !$0.isEmpty }),
                  fm.fileExists(atPath: imageURL.path),
                  let storedData = try? Data(contentsOf: imageURL),
                  digest(of: storedData) == imageDigest else {
                return .invalid
            }
            if !entry.hosts.contains(canonicalHost) {
                let previous = entry
                entry.hosts.append(canonicalHost)
                entry.hosts = Array(Set(entry.hosts)).sorted()
                verifiedKCaptchaIndex[imageDigest] = entry
                guard writeVerifiedKCaptchaIndex() else {
                    verifiedKCaptchaIndex[imageDigest] = previous
                    return .invalid
                }
            }
            return .duplicate(imageURL)
        }

        // An unindexed file under the hash name is not safe to overwrite.
        guard !fm.fileExists(atPath: imageURL.path) else { return .invalid }
        do {
            try png.write(to: imageURL, options: .atomic)
        } catch {
            return .invalid
        }

        verifiedKCaptchaIndex[imageDigest] = VerifiedKCaptchaIndexEntry(
            code: code, hosts: [canonicalHost])
        guard writeVerifiedKCaptchaIndex() else {
            verifiedKCaptchaIndex.removeValue(forKey: imageDigest)
            try? fm.removeItem(at: imageURL)
            return .invalid
        }

        manifest.textPendingSinceLastTrain += 1
        manifest.textLengthDistribution[code.count, default: 0] += 1
        _ = evictIfNeeded(kind: .kcaptcha)
        scheduleManifestWrite()
        return .stored(imageURL)
    }

    /// Returns the confirmed kcaptcha metadata in stable digest order.
    public func verifiedKCaptchaMetadata() -> [VerifiedKCaptchaMetadata] {
        verifiedKCaptchaIndex.keys.sorted().compactMap { digest in
            let imageURL = verifiedKCaptchaDirectory.appendingPathComponent("\(digest).png")
            guard let entry = verifiedKCaptchaIndex[digest],
                  let imageData = try? Data(contentsOf: imageURL),
                  self.digest(of: imageData) == digest else { return nil }
            return VerifiedKCaptchaMetadata(
                digest: digest, code: entry.code, hosts: entry.hosts.sorted())
        }
    }

    private func isValidTextSample(png: Data, code: String, host: String) -> Bool {
        guard !png.isEmpty,
              !code.isEmpty,
              code.count <= 12,
              code.allSatisfy({ $0.isLetter || $0.isNumber }),
              !host.isEmpty,
              !host.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return false
        }
        return true
    }

    private func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Удаляет самые старые файлы в `solved-<kind>/`, пока
    /// `count > ceiling`. Возвращает число удалённых.
    @discardableResult
    public func evictIfNeeded(kind: CaptchaKind) -> Int {
        if kind == .kcaptcha {
            return evictVerifiedKCaptchaIfNeeded()
        }
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
        if kind == .kcaptcha {
            guard verifiedKCaptchaIndexIsValid else { return 0 }
            return verifiedKCaptchaIndex.keys.reduce(into: 0) { count, digest in
                let url = verifiedKCaptchaDirectory.appendingPathComponent("\(digest).png")
                if fm.fileExists(atPath: url.path) { count += 1 }
            }
        }
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
        case .kcaptcha:   return verifiedKCaptchaDirectory
        case .fsspDigits: return baseDir.appendingPathComponent("solved-fssp", isDirectory: true)
        }
    }

    private func writeVerifiedKCaptchaIndex() -> Bool {
        guard verifiedKCaptchaIndexIsValid else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(verifiedKCaptchaIndex) else {
            return false
        }
        do {
            try data.write(to: verifiedKCaptchaIndexURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func evictVerifiedKCaptchaIfNeeded() -> Int {
        guard verifiedKCaptchaIndexIsValid else { return 0 }
        let indexedFiles: [(digest: String, url: URL)] = verifiedKCaptchaIndex.keys.compactMap { digest in
            let url = verifiedKCaptchaDirectory.appendingPathComponent("\(digest).png")
            return fm.fileExists(atPath: url.path) ? (digest, url) : nil
        }
        let ceiling = manifest.textCeiling
        guard indexedFiles.count > ceiling else { return 0 }
        let sorted = indexedFiles.sorted { lhs, rhs in
            let l = (try? lhs.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        var removed = 0
        for item in sorted.prefix(indexedFiles.count - ceiling) {
            guard (try? fm.removeItem(at: item.url)) != nil else { continue }
            verifiedKCaptchaIndex.removeValue(forKey: item.digest)
            removed += 1
        }
        if removed > 0 { _ = writeVerifiedKCaptchaIndex() }
        return removed
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
        _ = writeVerifiedKCaptchaIndex()
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
