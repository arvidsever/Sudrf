import Foundation
import os.log

/// Логгер солвера: пишет в OSLog и в файл `captcha-solve.log` в
/// `Application Support` с ротацией (1 МБ × 3 поколения). Дополнительно
/// сохраняет PNG-картинки, на которых солвер сдался, в
/// `captcha-failures/` (≤ 50 файлов, FIFO) — для ручной отладки
/// точности и регрессий.
///
/// Используется из `RefreshCenter.tryAutoSolve`, `SearchModel.runSearch`,
/// `AppRouter.beginCaptcha(for:)` и из самого `CaptchaSolver` — для
/// отладки точности и обнаружения регрессий.
public final class CaptchaSolverLog: @unchecked Sendable {

    public static var shared: CaptchaSolverLog = {
        // Default: production instance, writes to
        // ~/Library/Application Support/Sudrf/.
        CaptchaSolverLog()
    }()

    private let osLog = Logger(subsystem: "ru.sudrf.app", category: "CaptchaSolver")
    private let queue = DispatchQueue(label: "ru.sudrf.app.CaptchaSolverLog", qos: .utility)
    private let fileURL: URL?
    private let failuresDir: URL?
    private let diagnosticsDir: URL?
    private let maxBytes: Int = 1_048_576   // 1 MB
    private let maxRotations: Int = 3
    private let maxFailureImages: Int = 50

    private init() {
        let fm = FileManager.default
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = support.appendingPathComponent("Sudrf", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("captcha-solve.log")
            let failures = dir.appendingPathComponent("captcha-failures", isDirectory: true)
            try? fm.createDirectory(at: failures, withIntermediateDirectories: true)
            self.failuresDir = failures
            let diagnostics = dir.appendingPathComponent("diagnostics", isDirectory: true)
            try? fm.createDirectory(at: diagnostics, withIntermediateDirectories: true)
            self.diagnosticsDir = diagnostics
        } else {
            self.fileURL = nil
            self.failuresDir = nil
            self.diagnosticsDir = nil
        }
    }

    /// Инициализатор для тестов: позволяет писать в произвольный каталог
    /// вместо `~/Library/Application Support/Sudrf/`.
    init(fileURL: URL?, failuresDir: URL?, diagnosticsDir: URL? = nil) {
        self.fileURL = fileURL
        self.failuresDir = failuresDir
        self.diagnosticsDir = diagnosticsDir
    }

    public func logAttempt(host: String, kind: CaptchaKind, attempt: CaptchaAttempt) {
        let line = "\(timestamp())\t\(host)\t\(kind.label)\tvalue=\(attempt.value)\tconf=\(String(format: "%.2f", attempt.confidence))\tdur_ms=\(Int(attempt.duration * 1000))"
        write(line)
    }

    public func logSkip(host: String, kind: CaptchaKind, reason: String) {
        let line = "\(timestamp())\t\(host)\t\(kind.label)\tSKIP\t\(reason)"
        write(line)
    }

    public func logError(host: String, kind: CaptchaKind, error: Error) {
        let line = "\(timestamp())\t\(host)\t\(kind.label)\tERROR\t\(error)"
        write(line)
    }

    /// Сохранить PNG, на которой солвер не справился. Возвращает путь
    /// к сохранённому файлу или `nil`, если запись не удалась (например,
    /// `failuresDir` не настроен). FIFO-eviction: если в папке уже
    /// `maxFailureImages` файлов, самый старый удаляется.
    @discardableResult
    public func logFailedImage(png: Data, host: String, kind: CaptchaKind) -> URL? {
        guard let dir = failuresDir else { return nil }
        let safeHost = host.replacingOccurrences(of: "/", with: "_")
                          .replacingOccurrences(of: ":", with: "")
        let name = "\(safeHost)_\(timestampFileSafe())_\(kind.label).png"
        let url = dir.appendingPathComponent(name)
        do {
            try png.write(to: url, options: .atomic)
            evictOldFailuresIfNeeded(in: dir)
            return url
        } catch {
            osLog.error("failed to write failure image: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Записать диагностический файл с топ-N кандидатами Vision для
    /// одной попытки распознавания. Файл пишется в `diagnosticsDir`
    /// (рядом с `failuresDir`). Используется `AutoCaptchaSolver` для
    /// офлайн-разбора: «почему солвер выбрал именно этот текст» и
    /// «что ещё увидел Vision». Не подлежит FIFO-вытеснению —
    /// кандидаты это десятки байт, а пользователь сам смотрит папку.
    @discardableResult
    public func logCandidates(host: String,
                              kind: CaptchaKind,
                              submitted: String,
                              confidence: Double,
                              alternatives: [(text: String, confidence: Double)],
                              preprocessed: Bool) -> URL? {
        guard let dir = diagnosticsDir else { return nil }
        let safeHost = host.replacingOccurrences(of: "/", with: "_")
                          .replacingOccurrences(of: ":", with: "")
        let name = "\(safeHost)_\(timestampFileSafe())_\(kind.label)_candidates.txt"
        let url = dir.appendingPathComponent(name)
        var lines: [String] = []
        lines.append("host=\(host)")
        lines.append("kind=\(kind.label)")
        lines.append("preprocessed=\(preprocessed ? "yes" : "no")")
        lines.append("submitted=\(submitted)")
        lines.append(String(format: "confidence=%.4f", confidence))
        lines.append("alternatives:")
        for (i, alt) in alternatives.enumerated() {
            lines.append(String(format: "  %d. \"%@\" conf=%.4f",
                                i + 1, alt.text, alt.confidence))
        }
        let payload = (lines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
        do {
            try payload.write(to: url, options: .atomic)
            return url
        } catch {
            osLog.error("failed to write candidates diagnostic: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Снимок числа успешных попыток за сегодня. Используется меню «Captcha»
    /// для отображения статуса. Считывается из лог-файла — лёгкий парсер,
    /// а не полноценный счётчик в памяти.
    public func solvedCountToday() -> Int {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var n = 0
        for line in text.split(separator: "\n").reversed() {
            // Первая tab-разделённая колонка содержит полный ISO-8601
            // timestamp, включая обязательный designator часового пояса.
            guard let timestamp = line.split(separator: "\t", maxSplits: 1).first else {
                continue
            }
            let dateString = String(timestamp)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: dateString) else { continue }
            if calendar.startOfDay(for: date) != today { break }
            let columns = line.split(separator: "\t")
            let isSuccessfulAttempt = columns.contains { $0.hasPrefix("value=") }
                && columns.contains { $0.hasPrefix("conf=") }
                && !columns.contains("SKIP")
                && !columns.contains("ERROR")
            if columns.contains("OK") || isSuccessfulAttempt {
                n += 1
            }
        }
        return n
    }

    private func write(_ line: String) {
        osLog.info("\(line, privacy: .public)")
        guard let url = fileURL else { return }
        queue.async { [weak self] in
            self?.appendToFile(line: line, url: url)
        }
    }

    /// Корректное append: открываем файл для чтения+записи
    /// (`forUpdating:`) и перематываем в конец перед записью. Иначе
    /// (`forWriting:`) handle стоит на offset 0 и каждая запись
    /// затирает файл с начала.
    private func appendToFile(line: String, url: URL) {
        let fm = FileManager.default
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        // Сначала ротация — иначе запись может пройти до неё и
        // превысить лимит.
        rotateIfNeeded(url: url, fm: fm)
        if !fm.fileExists(atPath: url.path) {
            try? payload.write(to: url)
            return
        }
        do {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } catch {
            // Фолбэк: затираем и пишем заново. Лучше потерять
            // предыдущие строки, чем оставить файл в полусломанном виде.
            try? payload.write(to: url)
        }
    }

    private func rotateIfNeeded(url: URL, fm: FileManager) {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        for i in stride(from: maxRotations - 1, through: 1, by: -1) {
            let src = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).\(i)")
            let dst = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).\(i + 1)")
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
        let first = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).1")
        try? fm.removeItem(at: first)
        try? fm.moveItem(at: url, to: first)
    }

    private func evictOldFailuresIfNeeded(in dir: URL) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }
        let pngs = entries.filter { $0.pathExtension.lowercased() == "png" }
        guard pngs.count > maxFailureImages else { return }
        let sorted: [URL] = pngs.sorted { (lhs: URL, rhs: URL) -> Bool in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        let toDelete = sorted.prefix(pngs.count - maxFailureImages)
        for url in toDelete {
            try? fm.removeItem(at: url)
        }
    }

    private func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    /// Имя файла без `:` (некоторые ФС не любят).
    private func timestampFileSafe() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
