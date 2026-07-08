import Foundation
import os.log

/// Логгер солвера: пишет в OSLog и в файл `captcha-solve.log` в
/// `Application Support` с ротацией (1 МБ × 3 поколения).
///
/// Используется из `RefreshCenter.tryAutoSolve` и из `CaptchaSolver` — для
/// отладки точности и обнаружения регрессий. Не пишет в файл, если родитель
/// не настроен путь (по умолчанию включён).
public final class CaptchaSolverLog: @unchecked Sendable {

    public static let shared = CaptchaSolverLog()

    private let osLog = Logger(subsystem: "ru.sudrf.app", category: "CaptchaSolver")
    private let queue = DispatchQueue(label: "ru.sudrf.app.CaptchaSolverLog", qos: .utility)
    private let fileURL: URL?
    private let maxBytes: Int = 1_048_576   // 1 MB
    private let maxRotations: Int = 3

    private init() {
        let fm = FileManager.default
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = support.appendingPathComponent("Sudrf", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("captcha-solve.log")
        } else {
            self.fileURL = nil
        }
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
            // Быстрый разбор: первые 19 символов — это ISO-8601 дата.
            guard line.count > 19 else { continue }
            let dateString = String(line.prefix(19))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: dateString) else { continue }
            if calendar.startOfDay(for: date) != today { break }
            if line.contains("\tOK") || (line.range(of: #"value=\S+\s+conf="#) != nil
                && !line.contains("\tSKIP") && !line.contains("\tERROR")) {
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

    private func appendToFile(line: String, url: URL) {
        let fm = FileManager.default
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        if fm.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                if #available(macOS 10.15.4, *) {
                    try? handle.write(contentsOf: payload)
                } else {
                    handle.write(payload)
                }
            }
        } else {
            try? payload.write(to: url)
        }
        rotateIfNeeded(url: url, fm: fm)
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
            try? fm.moveItem(at: src, to: dst)
        }
        let first = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).1")
        try? fm.moveItem(at: url, to: first)
    }

    private func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
