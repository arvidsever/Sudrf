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

    private let transport: HTMLCourtTransport
    private let actFileLoader: ActFileLoader
    public var maxAttempts = 3

    public init(minInterval: TimeInterval = 2.0,
                userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                trustCourtCertificates: Bool = true) {
        let cfg = Self.productionConfiguration()
        let delegate: (any URLSessionDelegate)? = trustCourtCertificates
            ? SudrfTLSDelegate(strictEvaluation: true,
                               allowedRedirectHosts: PublishedActURLPolicy.allowedMosGorSudHosts)
            : nil
        self.transport = HTMLCourtTransport(
            session: URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil),
            userAgent: userAgent, minInterval: minInterval,
            decodingPolicy: .utf8Only, throttleSemantics: .lastRequestStart)
        self.actFileLoader = ActFileLoader()
    }

    static func productionConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        return cfg
    }

    /// Внутренний init для тестов с URLProtocol-stub'ом.
    internal init(session: URLSession,
                  minInterval: TimeInterval = 2.0,
                  userAgent: String = "SudrfKitTests") {
        self.transport = HTMLCourtTransport(
            session: session, userAgent: userAgent, minInterval: minInterval,
            decodingPolicy: .utf8Only, throttleSemantics: .lastRequestStart)
        self.actFileLoader = ActFileLoader()
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
        let rows = try MosGorSudResultsParser.parse(html: html)
        // Дизамбигуация раздела: короткие номера пересекаются между видами
        // производства/инстанциями (уголовные 01-… vs апелляция 10-… vs КоАП
        // 05-…/12-…). Оставляем строки, чей сегмент пути соответствует
        // выбранным (вид, инстанция); если раздел неизвестен — не режем.
        let allowed = MosGorSudRouting.sectionSegments(processType: processType, instance: instance)
        // Пусто — раздел не определяется (см. sectionSegments): отдаём как есть,
        // сервер уже отфильтровал по instance/processType. Резать в ноль нельзя.
        guard !allowed.isEmpty else { return rows }
        return rows.filter { row in row.section.map { allowed.contains($0) } ?? true }
    }

    /// Карточка дела по ссылке из выдачи (/…/details/…).
    public func fetchCard(url: URL) async throws -> MosGorSudCard {
        let html = try await fetchUTF8(url)
        return try MosGorSudCardParser.parse(html: html)
    }

    /// Fetches and verifies a published attachment. A successful HTTP request
    /// alone is not enough: HTML/CAPTCHA responses, misleading MIME types and
    /// unsafe Office containers are rejected before any caller can persist an
    /// act or make it searchable.
    public func fetchPublishedAct(url: URL) async throws -> PublishedActFile {
        let response = try await transport.fetchFile(
            url, maxAttempts: maxAttempts,
            allowedHosts: PublishedActURLPolicy.allowedMosGorSudHosts,
            maxBytes: ActFileLoader.Limits.production.maxDownloadBytes)
        return try await actFileLoader.extract(
            data: response.data, sourceURL: url, finalURL: response.finalURL,
            contentType: response.contentType)
    }

    // MARK: - сеть

    private func fetchUTF8(_ url: URL) async throws -> String {
        try await transport.fetch(url, maxAttempts: maxAttempts)
    }
}
