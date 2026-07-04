//  MosGorSudClient.swift — Sudrf
//  Сетевой клиент портала судов Москвы (mos-gorsud.ru). Отличия от SudrfClient:
//   • ответы в UTF-8 (URL собирается через URLComponents);
//   • капчи нет; модуль sud_delo на портале отсутствует — свой /search;
//   • перед порталом стоит анти-DDoS (Qrator) — троттлинг здесь чуть щедрее
//     обычного (2 с между запросами).
//  TLS: mos-gorsud.ru отдаёт сертификат на корнях Минцифры — используется тот же
//  SudrfTLSDelegate, что и для судов sudrf.ru (домен уже в его списке).

import Foundation

public actor MosGorSudClient {

    private let session: URLSession
    private let userAgent: String
    private let minInterval: TimeInterval
    private var lastRequestAt: Date?
    public var maxAttempts = 3

    public init(minInterval: TimeInterval = 2.0,
                userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                trustCourtCertificates: Bool = true) {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        let delegate: (any URLSessionDelegate)? = trustCourtCertificates ? SudrfTLSDelegate() : nil
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        self.userAgent = userAgent
        self.minInterval = minInterval
    }

    /// Поиск по порталу. Пустой courtAlias — по всем судам Москвы сразу.
    public func search(courtAlias: String? = nil,
                       uid: String? = nil,
                       caseNumber: String? = nil,
                       participant: String? = nil,
                       instance: Int,
                       processType: MosGorSudProcessType) async throws -> [MosGorSudResult] {
        guard let url = MosGorSudEndpoint.searchURL(courtAlias: courtAlias, uid: uid,
                                                    caseNumber: caseNumber,
                                                    participant: participant,
                                                    instance: instance,
                                                    processType: processType) else {
            throw SudrfError.parsing("не удалось собрать URL поиска mos-gorsud")
        }
        let html = try await fetchUTF8(url)
        return try MosGorSudResultsParser.parse(html: html)
    }

    /// Карточка дела по ссылке из выдачи (/…/details/…).
    public func fetchCard(url: URL) async throws -> MosGorSudCard {
        let html = try await fetchUTF8(url)
        return try MosGorSudCardParser.parse(html: html)
    }

    // MARK: - сеть

    private func fetchUTF8(_ url: URL) async throws -> String {
        var lastError: Error = SudrfError.http(status: 0)
        for attempt in 0..<max(1, maxAttempts) {
            try await throttle()
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            req.setValue("ru,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            do {
                let (data, response) = try await session.data(for: req)
                let http = response as? HTTPURLResponse
                if let http, (500..<600).contains(http.statusCode) {
                    lastError = SudrfError.http(status: http.statusCode)
                    try await backoff(attempt); continue
                }
                if let http, !(200..<300).contains(http.statusCode) {
                    throw SudrfError.http(status: http.statusCode)
                }
                if let s = String(data: data, encoding: .utf8) { return s }
                throw SudrfError.decodingFailed
            } catch let e as URLError {
                lastError = e
                try await backoff(attempt); continue
            }
        }
        throw lastError
    }

    private func backoff(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(Double(attempt + 1) * 0.8 * 1_000_000_000))
    }
    private func throttle() async throws {
        if let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minInterval {
                try await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
    }
}
