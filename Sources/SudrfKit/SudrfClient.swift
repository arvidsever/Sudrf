import Foundation
import Security

/// Сетевой клиент: прямые HTTP-запросы к суду, троттлинг, cookies, декодирование cp1251.
///
/// Важно: на машине пользователя (в отличие от песочницы Claude) запросы к
/// `*.sudrf.ru` проходят напрямую — браузер не нужен.
public actor SudrfClient {

    private let session: URLSession
    private let userAgent: String
    private let minInterval: TimeInterval
    /// Троттл пер-хост: у каждого суда СОЮ свой сервер, поэтому пауза `minInterval`
    /// держится ОТДЕЛЬНО для каждого хоста. Значение — момент, начиная с которого
    /// хосту можно слать следующий запрос (см. `throttle(host:)`).
    private var nextAllowedAt: [String: Date] = [:]

    private let variantStore: WorkingVariantStore
    private let captchaStore: CaptchaTokenStore

    public init(minInterval: TimeInterval = 1.5,
                userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                trustCourtCertificates: Bool = true,
                variantStore: WorkingVariantStore = .shared,
                captchaStore: CaptchaTokenStore = .shared) {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        // Сайты судов используют российские корневые сертификаты (Минцифры),
        // которых нет в доверенном хранилище Apple. Делегат принимает сертификат
        // ТОЛЬКО для доменов судов; для прочих хостов — обычная проверка.
        let delegate: (any URLSessionDelegate)? = trustCourtCertificates ? SudrfTLSDelegate() : nil
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        self.userAgent = userAgent
        self.minInterval = minInterval
        self.variantStore = variantStore
        self.captchaStore = captchaStore
    }

    /// Внутренний init для тестов: позволяет подсунуть свой `URLSession`,
    /// сконфигурированный с `URLProtocol` stub'ом (URLSessionConfiguration.default
    /// НЕ подхватывает глобально зарегистрированные protocol classes —
    /// только тот configuration, на котором они указаны явно).
    internal init(session: URLSession,
                   minInterval: TimeInterval = 1.5,
                   userAgent: String = "SudrfKitTests",
                   variantStore: WorkingVariantStore = .shared,
                   captchaStore: CaptchaTokenStore = .shared) {
        self.session = session
        self.userAgent = userAgent
        self.minInterval = minInterval
        self.variantStore = variantStore
        self.captchaStore = captchaStore
    }

    /// Число повторов при временных ошибках (502/503/504, обрывы соединения).
    public var maxAttempts = 3

    /// Тестовый хук для сценариев, где повтор сетевой ошибки не нужен.
    internal func setMaxAttemptsForTesting(_ value: Int) {
        maxAttempts = value
    }

    /// Загрузить страницу и декодировать как windows-1251.
    public func fetchHTML(_ url: URL) async throws -> String {
        try await fetchHTML(url, allowHTTPFallback: true)
    }

    /// Загрузить HTML формы поиска (страница с капчей). Семантически то
    /// же, что `fetchHTML`, но имя сигнализирует о намерении — нужно
    /// `RefreshCenter.tryAutoSolve` для авто-солвера.
    public func fetchForm(_ url: URL) async throws -> String {
        try await fetchHTML(url, allowHTTPFallback: true)
    }

    private func fetchHTML(_ url: URL, allowHTTPFallback: Bool) async throws -> String {
        let (_, html) = try await fetchHTMLData(url, allowHTTPFallback: allowHTTPFallback)
        return html
    }

    /// Внутренний helper, возвращающий и сырые байты, и декодированную
    /// строку. Используется там, где нужно сбросить HTML-ответ на диск
    /// в его исходной кодировке (например, `SearchDiagnostics.dumpVariant`):
    /// `String`-перегрузка `fetchHTML` теряет исходные байты при
    /// перекодировании, а пользователю нужны именно байты — иначе
    /// файл в браузере показывает mojibake.
    private func fetchHTMLData(_ url: URL, allowHTTPFallback: Bool) async throws -> (Data, String) {
        var lastError: Error = SudrfError.http(status: 0)
        let attempts = max(1, maxAttempts)
        for attempt in 0..<attempts {
            try await throttle(host: url.host?.lowercased() ?? "")
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            req.setValue("ru,en;q=0.8", forHTTPHeaderField: "Accept-Language")

            do {
                let (data, response) = try await session.data(for: req)
                let http = response as? HTTPURLResponse
                if let http, (500..<600).contains(http.statusCode) {
                    // Сервер суда периодически отдаёт 502/503 — повторяем.
                    lastError = SudrfError.http(status: http.statusCode)
                    guard attempt + 1 < attempts else { break }   // после последней попытки не спим
                    try await backoff(attempt)
                    continue
                }
                if let http, !(200..<300).contains(http.statusCode) {
                    throw SudrfError.http(status: http.statusCode)
                }
                // Суды отдают windows-1251, единый портал — тоже cp1251; UTF-8 как запасной.
                let ctype = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                if ctype.contains("utf-8"), let s = String(data: data, encoding: .utf8) { return (data, s) }
                if let s = Cyrillic1251.decode(data) { return (data, s) }
                if let s = String(data: data, encoding: .utf8) { return (data, s) }
                throw SudrfError.decodingFailed
            } catch let e as URLError {
                if allowHTTPFallback, e.isTLSError,
                   let httpURL = url.msudrfHTTPFallbackURL {
                    // Privacy tradeoff: magistrate searches may carry personal
                    // data in query parameters. Plain HTTP is allowed only for
                    // msudrf hosts, only after TLS fails, and only for this one
                    // retry so broken government TLS does not silently broaden.
                    return try await fetchHTMLData(httpURL, allowHTTPFallback: false)
                }
                lastError = e
                guard attempt + 1 < attempts else { break }
                try await backoff(attempt)
                continue
            }
            // 5xx (SudrfError.http) — НЕ URLError, летит через L106 /
            // withHostFallback (L309-316), в финальной классификации не
            // участвует. .badURL / .cancelled / .badServerResponse — это
            // URLError, попадают в `catch let e as URLError`, ретраятся 3
            // раза, lastError обновляется на каждой попытке; на финале
            // urlErr.isTransient == false → проброс исходной ошибки. Это
            // согласуется с тестом testFatalURLErrorNotMarkedTransient
            // (requestCount == 3, проброс URLError(.badURL) / .cancelled).
        }
        // Финальная классификация: только последняя ошибка ретрая-цикла
        // решает, transient это или нет. Если на 1-й был transient, а на
        // 3-й — fatal URLError (.badURL, .cancelled) — lastError
        // перезаписан fatal'ом → финал fatal. Если на 1-й был fatal, а на
        // 3-й — transient — lastError перезаписан transient'ом → финал
        // transient. Это корректно: финальная попытка определяет результат.
        if let urlErr = lastError as? URLError, urlErr.isTransient {
            throw SudrfError.transientNetworkError(
                domain: url.host ?? "", code: urlErr.code, attempt: attempts)
            // attempts (= 3) — полное число попыток (= 2 повтора + 1 начальная).
            // Пользователь видит «после 3 попыток», что соответствует факту.
        }
        throw lastError
    }

    private func backoff(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(Double(attempt + 1) * 0.8 * 1_000_000_000))
    }

    /// Высокоуровневый поиск. Если на форме или выдаче есть капча — бросает
    /// `.captchaRequired` (решать её программно нельзя).
    /// Модульный хост приводится к дефисной форме; при сетевой ошибке — фолбэк
    /// на точечную форму хоста (перебор обоих вариантов).
    public func search(court: Court,
                       cartoteka: Cartoteka,
                       field: SearchField,
                       value: String) async throws -> [CaseSearchResult] {
        try await withHostFallback(court) { c in
            try await self.searchOnce(court: c, cartoteka: cartoteka, field: field, value: value)
        }
    }

    private func searchOnce(court: Court,
                            cartoteka: Cartoteka,
                            field: SearchField,
                            value: String) async throws -> [CaseSearchResult] {
        let builder = SudrfURLBuilder(court: court)

        // 0) Решённая ранее капча этого суда: без предпроверки формы, сразу
        // на выдачу с парой captcha/captchaid (минус запрос и минус окно).
        // Отклонённая судом пара инвалидируется, поток идёт обычным путём.
        if let token = await captchaStore.token(forDomain: court.domain) {
            do {
                return try await runVariants(builder: builder, court: court,
                                             cartoteka: cartoteka, field: field,
                                             value: value, captcha: token)
            } catch SudrfError.captchaRequired {
                await captchaStore.invalidate(domain: court.domain)
            }
        }

        // 1) Предпроверка формы на капчу — только у современного интерфейса.
        // У винтажного (vnkod) форма своя, а капча равно видна на самой выдаче —
        // её распознает классификатор, экономя запрос.
        if builder.pattern == .primary {
            let formURL = try builder.formURL(cartoteka)
            let (formData, formHTML) = try await fetchHTMLData(formURL, allowHTTPFallback: true)
            if CaptchaDetector.hasCaptcha(in: formHTML) {
                throw SudrfError.captchaRequired(formURL: formURL)
            }
            // Диагностика: форма у этого суда (captcha-включённого, раз
            // мы здесь на .primary) не распознана как содержащая капчу.
            // Скорее всего суд изменил маркер — сохраним форму, чтобы
            // увидеть, как она выглядит сейчас. Сохраняем СЫРЫЕ байты,
            // чтобы файл можно было открыть в браузере (тот прочитает
            // `<meta charset=...>` из самого HTML и применит его).
            SearchDiagnostics.dumpFormCheck(data: formData, host: court.domain)
        }

        // 2) Перебор вариантов выдачи.
        return try await runVariants(builder: builder, court: court,
                                     cartoteka: cartoteka, field: field,
                                     value: value, captcha: nil)
    }

    /// Перебор вариантов поискового URL. Рабочий вариант прошлых запросов —
    /// первым. «Пустой» ответ не прерывает перебор: у винтажных судов запрос
    /// не в ту таблицу (напр., КАС в гражданской) даёт валидную пустую выдачу,
    /// хотя дело есть в соседней. Результаты выигрывают у пустоты; пустота — у ошибки.
    private func runVariants(builder: SudrfURLBuilder,
                             court: Court,
                             cartoteka: Cartoteka,
                             field: SearchField,
                             value: String,
                             captcha: CaptchaToken?) async throws -> [CaseSearchResult] {
        var variants = try builder.searchURLVariants(cartoteka: cartoteka, field: field,
                                                     value: value, captcha: captcha)
        if let workingID = await variantStore.workingVariantID(domain: court.domain, cartoteka: cartoteka),
           let i = variants.firstIndex(where: { $0.id == workingID }), i > 0 {
            variants.insert(variants.remove(at: i), at: 0)
        }

        var sawEmpty = false
        var lastData: Data? = nil
        var lastWasCaptchaRejected = false
        for v in variants {
            let (data, html) = try await fetchHTMLData(v.url, allowHTTPFallback: true)
            switch SearchPageClassifier.classify(html: html) {
            case .captcha:
                throw SudrfError.captchaRequired(formURL: try builder.formURL(cartoteka))
            case .captchaRejected:
                // Сервер отверг наш проверочный код (v0.38.9). Это не
                // форма captcha — это та же страница результатов, на
                // которой сервер сообщил «неверный код». Наш токен в
                // `CaptchaTokenStore` больше не валиден — следующий
                // search с ним даст тот же ответ. Инвалидируем сейчас,
                // чтобы вызывающая сторона не зацикливалась на плохом
                // токене (v0.38.10).
                if captcha != nil {
                    await captchaStore.invalidate(domain: court.domain)
                }
                // Дамп — отдельно от variant_, чтобы при разборе было
                // видно «суд отверг токен» vs «суд вернул неизвестный
                // формат». Дальше ведём себя как unrecognized: пробрасываем
                // `searchModuleUnavailable` наверх.
                lastData = data
                lastWasCaptchaRejected = true
                continue
            case .results:
                await variantStore.remember(variantID: v.id, domain: court.domain, cartoteka: cartoteka)
                return try ResultsParser.parse(html: html, court: court)
            case .empty:
                sawEmpty = true
            case .unrecognized:
                lastData = data
                lastWasCaptchaRejected = false
                continue
            }
        }
        if sawEmpty { return [] }
        // Ни один вариант не дал ни выдачи, ни валидной пустоты: суд отвечает
        // в неизвестном формате (другой интерфейс, JS-защита, заглушка).
        // Сбрасываем последний ответ (сырые байты + декодированную строку),
        // чтобы пользователь мог посмотреть, что суд реально прислал —
        // `SearchPageClassifier` не узнал ни одного маркера. Это и есть
        // путь к `searchModuleUnavailable`. Байты нужны без перекодирования,
        // иначе файл в браузере показывает mojibake (как в v0.38.5).
        if let lastData {
            if lastWasCaptchaRejected {
                SearchDiagnostics.dumpCaptchaRejected(data: lastData, host: court.domain)
            } else {
                SearchDiagnostics.dumpVariant(data: lastData, host: court.domain)
            }
        }
        // A2: суд детерминированно отверг наш токен (`.captchaRejected`
        // хотя бы на одном варианте). Токен уже инвалидирован внутри
        // цикла, retry не зациклится. UI должен получить `.captchaRequired`
        // — тогда manual sheet / captcha-queue / авто-солвер (три
        // обработчика: `searchOnce` cached-token catch, `SearchModel.
        // handleCaptcha`, `RefreshCenter.performRefresh`) сработают, как
        // ожидается. `try?` — fallback на старое поведение при
        // несобираемом formURL (битый cartoteka). В отличие от прежнего
        // `searchModuleUnavailable` этот throw не проходит `withHostFallback`:
        // rejection детерминирован для обеих форм одного сервера
        // (один и тот же back-end), дополнительный GET бесполезен.
        if lastWasCaptchaRejected, let formURL = try? builder.formURL(cartoteka) {
            throw SudrfError.captchaRequired(formURL: formURL)
        }
        throw SudrfError.searchModuleUnavailable(domain: court.domain)
    }

    /// Загрузить карточку дела и извлечь метаданные, движение и тексты актов
    /// (капчи здесь нет). Для апелляции/кассации передавайте `new` из картотеки.
    public func fetchCard(court: Court,
                          caseID: String,
                          caseUID: String,
                          deloID: String,
                          new: String = "0") async throws -> CaseCard {
        try await withHostFallback(court) { c in
            let builder = SudrfURLBuilder(court: c)
            let url = try builder.cardURL(caseID: caseID, caseUID: caseUID, deloID: deloID, new: new)
            let html = try await self.fetchHTML(url)
            return try CaseCardParser.parse(html: html)
        }
    }

    /// Карточка по ГОТОВОЙ ссылке из выдачи. Нужна, когда пары case_id/case_uid
    /// в строке выдачи нет (винтажные суды вроде Благовещенского дают только
    /// `_uid`) — ссылка выдачи всегда «родного» формата и самодостаточна.
    /// Без host-фолбэка: URL пришёл с уже отвечавшего хоста.
    public func fetchCard(url: URL) async throws -> CaseCard {
        let html = try await fetchHTML(url)
        return try CaseCardParser.parse(html: html)
    }

    /// Выполняет запрос на дефисной форме хоста; при сетевой/HTTP-ошибке повторяет
    /// на альтернативной (точечной) форме. Капча — не проблема хоста, пробрасывается.
    private func withHostFallback<T>(_ court: Court,
                                     _ body: (Court) async throws -> T) async throws -> T {
        let primary = court.withDomain(SudrfHost.moduleHost(court.domain))
        do {
            return try await body(primary)
        } catch let e as SudrfError {
            if case .captchaRequired = e { throw e }
            guard let alt = SudrfHost.alternate(primary.domain) else { throw e }
            return try await body(court.withDomain(alt))
        } catch {
            guard let alt = SudrfHost.alternate(primary.domain) else { throw error }
            return try await body(court.withDomain(alt))
        }
    }

    // MARK: - throttle

    /// Пер-хост троттл: держит паузу не короче `minInterval` между запросами К ОДНОМУ
    /// хосту, не мешая запросам к другим судам идти параллельно. Слот бронируется
    /// АТОМАРНО (до `await` — внутри actor между чтением и записью словаря нет точки
    /// приостановки), поэтому параллельные вызовы к одному хосту честно встают в очередь
    /// с шагом `minInterval`, а не читают одно и то же «последнее время» и не проходят
    /// вместе.
    private func throttle(host: String) async throws {
        let now = Date()
        let previousTail = nextAllowedAt[host]
        let slot = max(now, previousTail ?? now)
        let reservation = slot.addingTimeInterval(minInterval)
        nextAllowedAt[host] = reservation
        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch {
                // Освобождаем только собственный хвост очереди. Если после нас
                // уже забронирован новый слот, его расписание не трогаем.
                if nextAllowedAt[host] == reservation {
                    if let previousTail, previousTail > now {
                        nextAllowedAt[host] = previousTail
                    } else {
                        nextAllowedAt[host] = nil
                    }
                }
                throw error
            }
        }
    }
}

private extension URLError {
    var isTLSError: Bool {
        switch code {
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
    }

    /// Transient (сетевые) коды — суд «не ответил» (timeout, DNS, нет сети),
    /// НЕ ошибка запроса/отмены. Используется в `fetchHTMLData` для
    /// классификации исчерпанного URLError → `SudrfError.transientNetworkError`.
    /// ИСКЛЮЧЕНИЯ:
    ///   • `.cancelled` (-999) — отменённая Task, не ошибка пользователя,
    ///     transient-stub ставить нельзя.
    ///   • 5xx (`SudrfError.http`) — не URLError, идёт через L106.
    ///   • `.badURL`, `.unsupportedURL`, `.badServerResponse` — фатальные,
    ///     пробрасываются как есть (тест `testFatalURLErrorNotMarkedTransient`).
    var isTransient: Bool {
        switch code {
        case .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,                 // DNS
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable,
             .internationalRoamingOff,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}

private extension URL {
    var msudrfHTTPFallbackURL: URL? {
        guard scheme?.lowercased() == "https",
              let host = host?.lowercased(),
              SudrfHost.isMSudrfHost(host),
              var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = "http"
        return components.url
    }
}

/// Делегат TLS для доменов судов: сайты используют сертификаты российских
/// корней (Минцифры), которых нет в доверенном хранилище Apple. Корень и
/// промежуточные сертификаты Минцифры (из ресурсов пакета) добавляются
/// ЯКОРЯМИ к системным, после чего цепочка проверяется штатной оценкой SecTrust.
///
/// Проверка для судов МЯГКАЯ: если цепочка не прошла даже с якорями Минцифры
/// (у части «винтажных» судов — Воронеж и др. — она попросту кривая, из-за чего
/// запросы падали с NSURLError -999 «отменено»), сертификат всё равно
/// принимается — но ТОЛЬКО для доменов судов. Данные судов публичные, встроенное
/// капча-окно (CaptchaWebView) ведёт себя так же, а альтернатива — уходить на
/// голый http, как делает апстрим sudrfscraper. Для всех прочих хостов —
/// стандартная системная проверка без послаблений.
final class SudrfTLSDelegate: NSObject, URLSessionDelegate {

    private let trustedSuffixes = ["sudrf.ru", "msudrf.ru", "mos-gorsud.ru"]

    /// «Russian Trusted Root CA» и промежуточные «Russian Trusted Sub CA»
    /// (2022 и 2024) — DER-файлы из ресурсов SudrfKit.
    /// internal (не private) — доступность ресурсов проверяется тестом.
    static let russianAnchors: [SecCertificate] = {
        ["RussianTrustedRootCA", "RussianTrustedSubCA", "RussianTrustedSubCA2024"]
            .compactMap { Bundle.module.url(forResource: $0, withExtension: "cer") }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }()

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host.lowercased()
        guard trustedSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Российские корни — В ДОПОЛНЕНИЕ к системным (не вместо них):
        // суды с сертификатами публичных ЦС тоже проходят.
        SecTrustSetAnchorCertificates(trust, Self.russianAnchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        _ = SecTrustEvaluateWithError(trust, nil)
        // Провал оценки не отклоняет соединение (см. докстринг): сертификат
        // суда принимается как есть.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
