import Foundation

/// Сбрасывает HTML-ответы и сопутствующие данные на диск при
/// нештатных путях поиска — для отладки изменений в HTML судов,
/// которые ломают `CaptchaDetector` / `SearchPageClassifier` /
/// `ResultsParser`. Папка: `~/Library/Application Support/Sudrf/diagnostics/`,
/// до 50 файлов, FIFO-эвикция. Все методы — best-effort: ошибки записи
/// глотаются (не должны ломать основной поток).
///
/// Триггеры (вызывающий код решает, когда):
///   1. `dumpFormCheck(...)` — `CaptchaDetector` сказал «нет капчи» на
///      форме, по которой мы ожидали её увидеть (т.е. captcha-включённый
///      суд). Это значит, детектор не узнал новый формат маркера.
///   2. `dumpVariant(...)` — все варианты выдачи вернули `.unrecognized`.
///      Это значит, `SearchPageClassifier` не узнал ни одного маркера
///      в ответах. **Это путь, который сейчас выкидывает
///      `searchModuleUnavailable`** — диагностика критична для v0.38.5.
///   3. `dumpSolverMismatch(...)` — авто-солвер вернул high-confidence
///      ответ, токен сохранён, но сервер отклонил его (captcha-Required
///      на retry). Это значит, солвер промахнулся — нужна
///      `logFailedImage(...)` (v0.38.3) + dump ответа, чтобы
///      понять, как выглядела «правильная» капча глазами сервера.
///   4. `dumpCaptchaRejected(...)` — суд вернул страницу результатов
///      с маркером «неверный проверочный код» (v0.38.9 добавил
///      `SearchPageKind.captchaRejected`). Это значит, наш токен в
///      `CaptchaTokenStore` больше не валиден. Дамп — для
///      диагностики, что суд реально прислал; основной фикс —
///      инвалидация токена в `SudrfClient.runVariants` (v0.38.10).
public enum SearchDiagnostics {

    public static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    private static let enabledKey = "captcha.diagnosticsEnabled"

    private static let maxFiles: Int = 50

    /// Каталог для записи диагностических HTML-ответов. По умолчанию —
    /// `~/Library/Application Support/Sudrf/diagnostics/`. Тесты могут
    /// подменить на temp-dir через `setDirForTesting(_:)`.
    private static var dir: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("Sudrf", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Подмена каталога для тестов. Возвращает предыдущее значение
    /// для восстановления в `tearDown`.
    @discardableResult
    static func setDirForTesting(_ url: URL?) -> URL {
        let previous = dir
        if let url {
            dir = url
        }
        return previous
    }

    /// Сохранить HTML-ответ, на котором `SearchPageClassifier` вернул
    /// `.unrecognized` для всех вариантов выдачи. Это путь, который
    /// сейчас приводит к `SudrfError.searchModuleUnavailable` —
    /// диагностика нужна, чтобы понять, что суд прислал.
    ///
    /// `data` — сырые байты ответа (в кодировке, заявленной сервером).
    /// Записываются в файл **verbatim** — без перекодирования, чтобы
    /// файл можно было открыть в браузере (который прочитает `<meta
    /// charset=...>` из самого HTML и применит его) и в `iconv` / `xxd`
    /// без потерь.
    public static func dumpVariant(data: Data, host: String) {
        save(data: data, kind: "variant", host: host, suffix: nil)
    }

    /// Сохранить HTML формы поиска, на которой `CaptchaDetector`
    /// сказал «нет капчи». Это значит, что у captcha-включённого
    /// суда детектор не узнал маркер капчи — нужно посмотреть,
    /// как выглядит форма.
    public static func dumpFormCheck(data: Data, host: String) {
        save(data: data, kind: "form", host: host, suffix: nil)
    }

    /// String-overload для тестов и редких случаев, когда сырых
    /// байт нет (например, ошибочные пути в юнит-тестах). В продакшене
    /// предпочитайте `data:`-версию — она не искажает кодировку.
    public static func dumpVariant(html: String, host: String) {
        save(data: Data(html.utf8), kind: "variant", host: host, suffix: nil)
    }

    public static func dumpFormCheck(html: String, host: String) {
        save(data: Data(html.utf8), kind: "form", host: host, suffix: nil)
    }

    /// Сохранить HTML-ответ с маркером «неверный проверочный код»
    /// (v0.38.9: `SearchPageKind.captchaRejected`). Префикс `rejected_`
    /// отличает этот дамп от «суд вернул неизвестный формат»
    /// (`variant_`) — это два разных диагноза. Дамп — для разбора;
    /// основной фикс (инвалидация токена) — в `SudrfClient.runVariants`.
    public static func dumpCaptchaRejected(data: Data, host: String) {
        save(data: data, kind: "rejected", host: host, suffix: nil)
    }

    /// String-overload для тестов и редких случаев.
    public static func dumpCaptchaRejected(html: String, host: String) {
        save(data: Data(html.utf8), kind: "rejected", host: host, suffix: nil)
    }

    /// Сохранить HTML ответа и PNG капчи, на которой авто-солвер
    /// вернул уверенный ответ, но сервер отклонил токен. Это
    /// означает, что солвер промахнулся — нужно сравнить его ответ
    /// с «правильным» (который мы не знаем, но видим последствия
    /// в ответе сервера).
    public static func dumpSolverMismatch(png: Data, responseData: Data, host: String) {
        save(data: responseData, kind: "solver-mismatch", host: host, suffix: nil)
        // Дополнительно — сохраняем PNG, чтобы можно было посмотреть
        // глазами на ту капчу, которую солвер не угадал.
        let dir = self.dir
        let safeHost = host.replacingOccurrences(of: "/", with: "_")
                            .replacingOccurrences(of: ":", with: "")
        let url = dir.appendingPathComponent(
            "\(safeHost)_\(timestampSafe())_solver-mismatch.png"
        )
        try? png.write(to: url, options: .atomic)
        evictIfNeeded(in: dir)
    }

    /// Внутренний writer. `kind` определяет префикс имени файла,
    /// `suffix` — необязательный тег (сейчас не используется,
    /// зарезервировано под будущее).
    private static func save(data: Data, kind: String, host: String, suffix: String?) {
        guard enabled else { return }
        let dir = self.dir
        let safeHost = host.replacingOccurrences(of: "/", with: "_")
                            .replacingOccurrences(of: ":", with: "")
        let tag = suffix.map { "_\($0)" } ?? ""
        let url = dir.appendingPathComponent(
            "\(safeHost)_\(timestampSafe())_\(kind)\(tag).html"
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // best-effort: ошибка записи не должна ломать основной поток
        }
        evictIfNeeded(in: dir)
    }

    private static func evictIfNeeded(in dir: URL) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }
        guard entries.count > maxFiles else { return }
        let sorted: [URL] = entries.sorted { (lhs: URL, rhs: URL) -> Bool in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        let toDelete = sorted.prefix(entries.count - maxFiles)
        for url in toDelete {
            try? fm.removeItem(at: url)
        }
    }

    private static func timestampSafe() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
