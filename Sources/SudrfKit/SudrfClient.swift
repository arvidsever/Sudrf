import Foundation
import Security
import SwiftSoup

/// Сетевой клиент: прямые HTTP-запросы к суду, троттлинг, cookies, декодирование cp1251.
///
/// Важно: на машине пользователя (в отличие от песочницы Claude) запросы к
/// `*.sudrf.ru` проходят напрямую — браузер не нужен.
public actor SudrfClient {

    private struct FetchedHTML {
        let data: Data
        let html: String
        let responseURL: URL
    }

    private struct FetchedData {
        let data: Data
        let response: URLResponse
        let responseURL: URL
    }

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

    /// Load a magistrate-court KCaptcha challenge through this client's
    /// existing URLSession.  The returned image and the form state therefore
    /// share the same cookie jar and can be submitted without a WebView.
    public func loadMagistrateCaptcha(formURL: URL) async throws -> MagistrateCaptchaChallenge {
        guard Self.isHTTPURL(formURL),
              let host = formURL.host,
              SudrfHost.isMSudrfHost(host) else {
            throw SudrfError.parsing("CAPTCHA мировых судей: небезопасный адрес формы")
        }
        let response = try await fetchHTMLData(formURL, allowHTTPFallback: true)
        guard Self.sameOriginOrHTTPFallback(formURL, response.responseURL) else {
            throw SudrfError.parsing("CAPTCHA мировых судей: форма перенаправлена на другой адрес")
        }
        return try await makeMagistrateCaptchaChallenge(
            html: response.html, responseURL: response.responseURL)
    }

    /// Submit a code to the exact KCaptcha form state that produced the
    /// challenge.  A response containing another KCaptcha form is rejected
    /// with a newly fetched image; every response without CAPTCHA is merely an
    /// unlocked session and must still be confirmed by the caller's search.
    public func submitMagistrateCaptcha(
        code: String,
        challenge: MagistrateCaptchaChallenge
    ) async throws -> MagistrateCaptchaSubmission {
        let state = challenge.submissionState
        guard Self.isHTTPURL(state.actionURL) else {
            throw SudrfError.parsing("CAPTCHA мировых судей: небезопасный адрес отправки")
        }

        var request = URLRequest(url: state.actionURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = true
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("ru,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.formURLEncoded(
            state.hiddenFields + [MagistrateCaptchaChallenge.Field(name: "captcha-response", value: code)])

        let response = try await performDataRequest(request, allowHTTPFallback: true)
        guard Self.sameOriginOrHTTPFallback(state.actionURL, response.responseURL) else {
            throw SudrfError.parsing("CAPTCHA мировых судей: ответ пришёл с другого адреса")
        }
        let html = try decodeHTML(response).html
        guard Self.containsMagistrateCaptcha(in: html) else {
            return .accepted
        }
        return .rejected(try await makeMagistrateCaptchaChallenge(
            html: html, responseURL: response.responseURL))
    }

    private func fetchHTML(_ url: URL, allowHTTPFallback: Bool) async throws -> String {
        try await fetchHTMLData(url, allowHTTPFallback: allowHTTPFallback).html
    }

    /// Внутренний helper, возвращающий сырые байты, декодированную строку
    /// и фактический URL ответа после redirect. Используется там, где нужно
    /// сбросить HTML-ответ на диск или разрешить относительные ссылки
    /// в его исходной кодировке (например, `SearchDiagnostics.dumpVariant`):
    /// `String`-перегрузка `fetchHTML` теряет исходные байты при
    /// перекодировании, а пользователю нужны именно байты — иначе
    /// файл в браузере показывает mojibake.
    private func fetchHTMLData(_ url: URL, allowHTTPFallback: Bool) async throws -> FetchedHTML {
        var lastError: Error = SudrfError.http(status: 0)
        let attempts = max(1, maxAttempts)
        for attempt in 0..<attempts {
            try await throttle(host: url.host?.lowercased() ?? "")
            var req = URLRequest(url: url)
            req.httpShouldHandleCookies = true
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
                let responseURL = response.url ?? url
                // Суды отдают windows-1251, единый портал — тоже cp1251; UTF-8 как запасной.
                let ctype = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                if ctype.contains("utf-8"), let s = String(data: data, encoding: .utf8) {
                    return FetchedHTML(data: data, html: s, responseURL: responseURL)
                }
                if let s = Cyrillic1251.decode(data) {
                    return FetchedHTML(data: data, html: s, responseURL: responseURL)
                }
                if let s = String(data: data, encoding: .utf8) {
                    return FetchedHTML(data: data, html: s, responseURL: responseURL)
                }
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

    /// Raw request path used by the session-based magistrate CAPTCHA flow.
    /// It intentionally mirrors `fetchHTMLData`'s retry and narrow HTTP
    /// fallback policy while retaining method, headers and body for POST.
    private func performDataRequest(_ request: URLRequest,
                                    allowHTTPFallback: Bool) async throws -> FetchedData {
        guard let url = request.url else { throw URLError(.badURL) }
        var lastError: Error = SudrfError.http(status: 0)
        let attempts = max(1, maxAttempts)
        for attempt in 0..<attempts {
            try await throttle(host: url.host?.lowercased() ?? "")
            do {
                let (data, response) = try await session.data(
                    for: request,
                    delegate: MagistrateCaptchaRedirectDelegate()
                )
                let http = response as? HTTPURLResponse
                if let http, (500..<600).contains(http.statusCode) {
                    lastError = SudrfError.http(status: http.statusCode)
                    guard attempt + 1 < attempts else { break }
                    try await backoff(attempt)
                    continue
                }
                if let http, !(200..<300).contains(http.statusCode) {
                    throw SudrfError.http(status: http.statusCode)
                }
                return FetchedData(data: data, response: response,
                                   responseURL: response.url ?? url)
            } catch let error as URLError {
                if allowHTTPFallback, error.isTLSError,
                   let httpURL = url.msudrfHTTPFallbackURL {
                    var fallback = request
                    fallback.url = httpURL
                    return try await performDataRequest(fallback, allowHTTPFallback: false)
                }
                lastError = error
                guard attempt + 1 < attempts else { break }
                try await backoff(attempt)
            }
        }
        if let urlError = lastError as? URLError, urlError.isTransient {
            throw SudrfError.transientNetworkError(
                domain: url.host ?? "", code: urlError.code, attempt: attempts)
        }
        throw lastError
    }

    private func decodeHTML(_ response: FetchedData) throws -> FetchedHTML {
        let ctype = ((response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if ctype.contains("utf-8"), let html = String(data: response.data, encoding: .utf8) {
            return FetchedHTML(data: response.data, html: html, responseURL: response.responseURL)
        }
        if let html = Cyrillic1251.decode(response.data) {
            return FetchedHTML(data: response.data, html: html, responseURL: response.responseURL)
        }
        if let html = String(data: response.data, encoding: .utf8) {
            return FetchedHTML(data: response.data, html: html, responseURL: response.responseURL)
        }
        throw SudrfError.decodingFailed
    }

    private func makeMagistrateCaptchaChallenge(
        html: String,
        responseURL: URL
    ) async throws -> MagistrateCaptchaChallenge {
        guard Self.isHTTPURL(responseURL) else {
            throw SudrfError.parsing("CAPTCHA мировых судей: небезопасный адрес формы")
        }
        let document: Document
        do {
            document = try SwiftSoup.parse(html)
        } catch {
            throw SudrfError.parsing("CAPTCHA мировых судей: не удалось разобрать форму")
        }
        guard let form = try document.select("form#kcaptchaForm").first() else {
            throw SudrfError.parsing("CAPTCHA мировых судей: форма kcaptchaForm не найдена")
        }
        let method = ((try? form.attr("method")) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard method == "post" else {
            throw SudrfError.parsing("CAPTCHA мировых судей: форма должна отправляться POST")
        }

        let rawAction = ((try? form.attr("action")) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actionURL: URL
        if rawAction.isEmpty {
            actionURL = responseURL
        } else if let resolved = URL(string: rawAction, relativeTo: responseURL)?.absoluteURL {
            actionURL = resolved
        } else {
            throw SudrfError.parsing("CAPTCHA мировых судей: некорректный action формы")
        }
        guard Self.isHTTPURL(actionURL), Self.sameOrigin(responseURL, actionURL) else {
            throw SudrfError.parsing("CAPTCHA мировых судей: action ведёт на другой адрес")
        }

        guard let image = try form.select("img[src]").first() else {
            throw SudrfError.parsing("CAPTCHA мировых судей: картинка не найдена")
        }
        let rawImageURL = ((try? image.attr("src")) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawImageURL.isEmpty,
              let imageURL = URL(string: rawImageURL, relativeTo: responseURL)?.absoluteURL,
              Self.isHTTPURL(imageURL), Self.sameOrigin(responseURL, imageURL) else {
            throw SudrfError.parsing("CAPTCHA мировых судей: картинка ведёт на другой адрес")
        }

        var hiddenFields: [MagistrateCaptchaChallenge.Field] = []
        for input in try form.select("input").array() {
            guard !Self.isDisabled(input) else { continue }
            let name = ((try? input.attr("name")) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let type = ((try? input.attr("type")) ?? "text")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "hidden" else { continue }
            // The submitted code always replaces a stale field from the
            // document, rather than sending two values for this name.
            guard name.caseInsensitiveCompare("captcha-response") != .orderedSame else {
                continue
            }
            hiddenFields.append(.init(name: name, value: (try? input.attr("value")) ?? ""))
        }

        var imageRequest = URLRequest(url: imageURL)
        imageRequest.httpShouldHandleCookies = true
        imageRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        imageRequest.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
                              forHTTPHeaderField: "Accept")
        imageRequest.setValue("ru,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let imageResponse = try await performDataRequest(imageRequest, allowHTTPFallback: true)
        guard Self.sameOriginOrHTTPFallback(imageURL, imageResponse.responseURL) else {
            throw SudrfError.parsing("CAPTCHA мировых судей: картинка перенаправлена на другой адрес")
        }
        let imageData = try Self.validateMagistrateCaptchaImage(imageResponse)
        return MagistrateCaptchaChallenge(
            imageData: imageData,
            submissionState: .init(actionURL: actionURL, hiddenFields: hiddenFields))
    }

    private static func containsMagistrateCaptcha(in html: String) -> Bool {
        if let document = try? SwiftSoup.parse(html),
           (try? document.select("form#kcaptchaForm").first()) != nil {
            return true
        }
        return CaptchaDetector.hasCaptcha(in: html)
    }

    private static func isDisabled(_ input: Element) -> Bool {
        if input.hasAttr("disabled") { return true }
        return input.parents().array().contains {
            $0.tagName().lowercased() == "fieldset" && $0.hasAttr("disabled")
        }
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard isHTTPURL(lhs), isHTTPURL(rhs),
              lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased() else { return false }
        return effectivePort(lhs) == effectivePort(rhs)
    }

    private static func sameOriginOrHTTPFallback(_ requested: URL, _ actual: URL) -> Bool {
        if sameOrigin(requested, actual) { return true }
        guard requested.scheme?.lowercased() == "https",
              actual.scheme?.lowercased() == "http",
              requested.host?.lowercased() == actual.host?.lowercased(),
              sameExplicitPort(requested, actual),
              let host = requested.host,
              SudrfHost.isMSudrfHost(host) else { return false }
        return true
    }

    private static func sameExplicitPort(_ lhs: URL, _ rhs: URL) -> Bool {
        switch (lhs.port, rhs.port) {
        case let (left?, right?): return left == right
        case (nil, nil): return true
        default: return false
        }
    }

    private static func effectivePort(_ url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "http" ? 80 : 443
    }

    private static func formURLEncoded(
        _ fields: [MagistrateCaptchaChallenge.Field]
    ) throws -> Data {
        let pairs = try fields.map { field -> String in
            guard let name = Cyrillic1251.percentEncodeQueryValue(field.name),
                  let value = Cyrillic1251.percentEncodeQueryValue(field.value) else {
                throw SudrfError.parsing(
                    "CAPTCHA мировых судей: поле формы не представимо в Windows-1251")
            }
            return "\(name)=\(value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func validateMagistrateCaptchaImage(_ response: FetchedData) throws -> Data {
        let data = response.data
        guard !data.isEmpty, data.count <= 1_048_576 else {
            throw SudrfError.parsing("CAPTCHA мировых судей: недопустимый размер картинки")
        }
        let contentType = ((response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? "")
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        guard !isHTML(data), !contentType.hasPrefix("text/html"),
              contentType.hasPrefix("image/") || hasKnownImageSignature(data) else {
            throw SudrfError.parsing("CAPTCHA мировых судей: ответ не является картинкой")
        }
        return data
    }

    private static func isHTML(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(512), encoding: .utf8)?.lowercased() else {
            return false
        }
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html")
            || prefix.hasPrefix("<head") || prefix.hasPrefix("<body")
            || prefix.hasPrefix("<script")
    }

    private static func hasKnownImageSignature(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
            return true
        }
        return bytes.starts(with: Array("RIFF".utf8))
            && bytes.count >= 12
            && bytes[8..<12].elementsEqual(Array("WEBP".utf8))
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
                await captchaStore.invalidate(domain: court.domain, matching: token)
            }
        }

        // 1) Предпроверка формы на капчу — только у современного интерфейса.
        // У винтажного (vnkod) форма своя, а капча равно видна на самой выдаче —
        // её распознает классификатор, экономя запрос.
        if builder.pattern == .primary {
            let formURL = try builder.formURL(cartoteka)
            let response = try await fetchHTMLData(formURL, allowHTTPFallback: true)
            if CaptchaDetector.hasCaptcha(in: response.html) {
                throw SudrfError.captchaRequired(formURL: response.responseURL)
            }
            // Диагностика: форма у этого суда (captcha-включённого, раз
            // мы здесь на .primary) не распознана как содержащая капчу.
            // Скорее всего суд изменил маркер — сохраним форму, чтобы
            // увидеть, как она выглядит сейчас. Сохраняем СЫРЫЕ байты,
            // чтобы файл можно было открыть в браузере (тот прочитает
            // `<meta charset=...>` из самого HTML и применит его).
            SearchDiagnostics.dumpFormCheck(
                data: response.data,
                host: response.responseURL.host?.lowercased() ?? court.domain
            )
        }

        // 2) Перебор вариантов выдачи.
        return try await runVariants(builder: builder, court: court,
                                     cartoteka: cartoteka, field: field,
                                     value: value, captcha: nil)
    }

    /// Перебор вариантов поискового URL. Рабочий вариант прошлых запросов —
    /// первым. «Пустой» ответ не прерывает перебор: у винтажных судов запрос
    /// не в ту таблицу (напр., КАС в гражданской) даёт валидную пустую выдачу,
    /// хотя дело есть в соседней. Результаты выигрывают у пустоты. Пустота
    /// считается достоверной только когда остальные варианты не дали сбоя:
    /// смешанный empty + failure — частичный, а не «честный ноль».
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
        var captchaRejectedResponse: (data: Data, host: String)?
        var maintenanceHost: String?
        var lastTransportError: Error?
        var lastResponseHost = court.domain
        for v in variants {
            let response: FetchedHTML
            do {
                response = try await fetchHTMLData(v.url, allowHTTPFallback: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                throw error
            } catch {
                // Один endpoint варианта мог временно отвалиться, тогда как
                // соседний вариант той же формы вполне отвечает. Пустая
                // валидная выдача по-прежнему выигрывает у такой ошибки.
                lastTransportError = error
                continue
            }
            let responseHost = response.responseURL.host?.lowercased() ?? court.domain
            let responseCourt = court.withDomain(responseHost)
            switch SearchPageClassifier.classify(html: response.html) {
            case .captcha:
                throw SudrfError.captchaRequired(
                    formURL: try SudrfURLBuilder(court: responseCourt).formURL(cartoteka)
                )
            case .captchaRejected:
                // Сервер отверг наш проверочный код (v0.38.9). Это не
                // форма captcha — это та же страница результатов, на
                // которой сервер сообщил «неверный код». Наш токен в
                // `CaptchaTokenStore` больше не валиден — следующий
                // search с ним даст тот же ответ. Инвалидируем сейчас,
                // чтобы вызывающая сторона не зацикливалась на плохом
                // токене (v0.38.10).
                if let captcha {
                    await captchaStore.invalidate(domain: court.domain, matching: captcha)
                }
                // Дамп — отдельно от variant_, чтобы при разборе было
                // видно «суд отверг токен» vs «суд вернул неизвестный
                // формат». Дальше ведём себя как unrecognized: пробрасываем
                // `searchModuleUnavailable` наверх.
                lastData = response.data
                lastResponseHost = responseHost
                captchaRejectedResponse = (response.data, responseHost)
                continue
            case .results:
                await variantStore.remember(variantID: v.id, domain: court.domain, cartoteka: cartoteka)
                return try ResultsParser.parse(html: response.html, court: responseCourt)
            case .empty:
                sawEmpty = true
            case .maintenance:
                lastData = response.data
                lastResponseHost = responseHost
                maintenanceHost = responseHost
            case .unrecognized:
                lastData = response.data
                lastResponseHost = responseHost
                continue
            }
        }
        if sawEmpty, maintenanceHost == nil, lastTransportError == nil, lastData == nil { return [] }
        // Ни один вариант не дал ни выдачи, ни валидной пустоты: суд отвечает
        // в неизвестном формате.
        // Сбрасываем последний ответ (сырые байты + декодированную строку),
        // чтобы пользователь мог посмотреть, что суд реально прислал —
        // `SearchPageClassifier` не узнал ни одного маркера. Это и есть
        // путь к `searchModuleUnavailable`. Байты нужны без перекодирования,
        // иначе файл в браузере показывает mojibake (как в v0.38.5).
        if let captchaRejectedResponse {
            SearchDiagnostics.dumpCaptchaRejected(
                data: captchaRejectedResponse.data,
                host: captchaRejectedResponse.host
            )
        } else if let lastData {
            SearchDiagnostics.dumpVariant(data: lastData, host: lastResponseHost)
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
        if let captchaRejectedResponse,
           let formURL = try? SudrfURLBuilder(
               court: court.withDomain(captchaRejectedResponse.host)
           ).formURL(cartoteka) {
            throw SudrfError.captchaRequired(formURL: formURL)
        }
        if let maintenanceHost { throw SudrfError.sourceMaintenance(domain: maintenanceHost) }
        if let lastTransportError { throw lastTransportError }
        throw SudrfError.searchModuleUnavailable(domain: lastResponseHost)
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
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw error
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

/// CAPTCHA form values must never follow an automatic redirect to another
/// origin. URLSession asks this task delegate before replaying a 307/308 POST,
/// so the code and hidden fields cannot leave the court host before our final
/// response validation runs.
final class MagistrateCaptchaRedirectDelegate: NSObject, URLSessionTaskDelegate,
                                                @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let source = response.url ?? task.originalRequest?.url,
              let target = request.url,
              Self.allows(source: source, target: target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func allows(source: URL, target: URL) -> Bool {
        guard let sourceHost = source.host?.lowercased(),
              sourceHost == target.host?.lowercased(),
              source.user == nil, source.password == nil,
              target.user == nil, target.password == nil else { return false }
        let sourceScheme = source.scheme?.lowercased()
        let targetScheme = target.scheme?.lowercased()
        guard sourceScheme == "http" || sourceScheme == "https",
              targetScheme == "http" || targetScheme == "https" else { return false }
        if sourceScheme == targetScheme {
            return source.port == target.port
        }
        // Upgrade from the explicit msudrf HTTP fallback is safe; an automatic
        // HTTPS downgrade is not (the existing fallback remains error-driven).
        return sourceScheme == "http" && targetScheme == "https"
            && source.port == nil && target.port == nil
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
    private let strictEvaluation: Bool
    private let allowedRedirectHosts: Set<String>?

    init(strictEvaluation: Bool = false, allowedRedirectHosts: Set<String>? = nil) {
        self.strictEvaluation = strictEvaluation
        self.allowedRedirectHosts = allowedRedirectHosts
    }

    /// «Russian Trusted Root CA» и промежуточные «Russian Trusted Sub CA»
    /// (2022 и 2024) — DER-файлы из ресурсов SudrfKit.
    /// internal (не private) — доступность ресурсов проверяется тестом.
    static let russianAnchors: [SecCertificate] = {
        ["RussianTrustedRootCA", "RussianTrustedSubCA", "RussianTrustedSubCA2024"]
            .compactMap { PackagedResource.url($0, withExtension: "cer") }
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
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, Self.russianAnchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        let accepted = SecTrustEvaluateWithError(trust, nil)
        if strictEvaluation, !accepted {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Провал оценки не отклоняет соединение (см. докстринг): сертификат
        // суда принимается как есть только в историческом soft-режиме.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let allowedRedirectHosts else {
            completionHandler(request)
            return
        }
        guard let url = request.url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              allowedRedirectHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
