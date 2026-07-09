import Foundation

/// Загрузчик реальных captcha-PNG из
/// `~/Library/Application Support/Sudrf/captcha-failures/` — папки,
/// куда `CaptchaSolverLog.logFailedImage` пишет PNG, на которых
/// солвер сдался (см. v0.38.3, FIFO 50 файлов). Используется в
/// real-PNG тестах `PreprocessorTests` и `AutoCaptchaSolverTests` —
/// «честный» оракул точности вместо синтетики.
///
/// В CI / на чистом checkout эта папка пуста, поэтому все тесты,
/// использующие `RealCaptchaFixture`, делают `XCTSkip` при отсутствии
/// фикстуры. Это сохраняет зелёный билд на чистом клоне.
///
/// Окружение `SUDRF_FIXTURE_DIR` позволяет указать альтернативный
/// каталог (например, смонтировать `captcha-failures/` из бэкапа в CI).
enum RealCaptchaFixture {

    /// Структура фикстуры: хост, исходное имя файла и PNG-байты.
    struct Item {
        let host: String
        let filename: String
        let png: Data
    }

    /// Возвращает каталог, из которого читать PNG: сначала
    /// `SUDRF_FIXTURE_DIR`, иначе дефолтный `captcha-failures/`.
    /// Возвращает `nil`, если каталог не существует — тест должен
    /// сделать XCTSkip.
    static func directory() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SUDRF_FIXTURE_DIR"] {
            let url = URL(fileURLWithPath: override)
            if fm.fileExists(atPath: url.path) { return url }
        }
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let defaultDir = support
            .appendingPathComponent("Sudrf", isDirectory: true)
            .appendingPathComponent("captcha-failures", isDirectory: true)
        return fm.fileExists(atPath: defaultDir.path) ? defaultDir : nil
    }

    /// Загружает все PNG из `directory()`. Возвращает массив фикстур;
    /// пустой массив означает «каталог недоступен» или «в нём нет PNG».
    static func loadAll() -> [Item] {
        guard let dir = directory() else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [Item] = []
        for url in entries where url.pathExtension.lowercased() == "png" {
            guard let data = try? Data(contentsOf: url) else { continue }
            // Имя файла: "<host>_<timestamp>_<kind>.png" — отрезаем
            // timestamp и kind, оставляя host в качестве префикса.
            let stem = url.deletingPathExtension().lastPathComponent
            let host = extractHost(from: stem)
            out.append(Item(host: host, filename: url.lastPathComponent, png: data))
        }
        return out
    }

    /// Загружает все PNG, относящиеся к конкретному хосту (без учёта
    /// регистра и подчёркиваний-разделителей). Используется в
    /// per-host тестах.
    static func load(host: String) -> [Item] {
        let needle = host.lowercased().replacingOccurrences(of: "--", with: "_")
        return loadAll().filter { $0.host.lowercased() == needle }
    }

    /// Самая свежая PNG для указанного хоста (по дате модификации).
    /// `nil`, если для хоста нет фикстур.
    static func latest(host: String) -> Item? {
        guard let dir = directory() else { return nil }
        let fm = FileManager.default
        let needle = host.lowercased().replacingOccurrences(of: "--", with: "_")
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let matching = entries.filter { url in
            guard url.pathExtension.lowercased() == "png" else { return false }
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            return stem.hasPrefix(needle + "_") || stem.hasPrefix(needle)
        }
        let sorted = matching.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        guard let url = sorted.last else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Item(host: host, filename: url.lastPathComponent, png: data)
    }

    /// Извлекает хост из имени файла. Ожидаемый формат:
    /// `<host>_<YYYYMMDD-HHMMSS>_<kind>.png` — берём всё до первого
    /// «_YY» (год). Если формат другой — возвращаем весь stem.
    private static func extractHost(from stem: String) -> String {
        guard let firstUnderscore = stem.firstIndex(of: "_") else { return stem }
        let suffix = stem[stem.index(after: firstUnderscore)...]
        // Год начинается с «2» (2000–2999): 4 цифры после leading 2.
        if let yearChar = suffix.first, yearChar == "2",
           suffix.count >= 9 {
            let idx = suffix.index(suffix.startIndex, offsetBy: 8)
            if suffix[..<idx].allSatisfy(\.isNumber) {
                return String(stem[..<firstUnderscore])
            }
        }
        return stem
    }
}
