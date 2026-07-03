//  VSRFClient.swift — Sudrf
//
//  Сетевой клиент Верховного Суда РФ (vsrf.ru). Отличия от `SudrfClient`:
//   • ответы в UTF-8 (а не cp1251), поэтому URL собирается через URLComponents;
//   • капчи нет — ни на форме, ни на выдаче;
//   • поиск идёт GET-запросом на /lk/practice/claims, карточка —
//     /lk/practice/cases/{id} (дело) или /lk/practice/appeals/{id} (жалоба).
//
//  Привязка к нижестоящим судам (и обратно): по УИД, когда он есть; иначе — по
//  тройке (суд 1-й инст. + № дела 1-й инст. + фамилия заявителя). Поскольку поиск
//  по одному № дела 1-й инстанции возвращает дела РАЗНЫХ регионов с тем же
//  номером, итоговый отбор делается на клиенте через `VSRFLinkKey`.
//
//  TLS: vsrf.ru — публичный сайт. По умолчанию используется обычная проверка
//  сертификата Apple. Если на машине пользователя vsrf.ru отдаёт сертификат на
//  корнях Минцифры (как суды на sudrf.ru), включите `trustVSRFCertificate: true` —
//  тогда сертификат принимается ТОЛЬКО для vsrf.ru (прочие хосты не затрагиваются).

import Foundation

public actor VSRFClient {

    private let session: URLSession
    private let userAgent: String
    private let minInterval: TimeInterval
    private var lastRequestAt: Date?
    public var maxAttempts = 3

    public init(minInterval: TimeInterval = 1.5,
                userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                trustVSRFCertificate: Bool = false) {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        let delegate: (any URLSessionDelegate)? = trustVSRFCertificate ? VSRFTLSDelegate() : nil
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        self.userAgent = userAgent
        self.minInterval = minInterval
    }

    // MARK: - Карточка

    /// Карточка производства ВС РФ по id и разделу (cases — дело, appeals — жалоба).
    public func fetchCard(productionID: String, section: VSRFCardSection = .cases) async throws -> VSRFCard {
        guard let url = VSRFEndpoint.cardURL(productionID: productionID, section: section) else {
            throw SudrfError.parsing("не удалось собрать URL карточки ВС РФ")
        }
        let html = try await fetchUTF8(url)
        return try VSRFCardParser.parse(html: html)
    }

    /// Удобная перегрузка: карточка по производству из выдачи (раздел уже известен).
    public func fetchCard(for production: VSRFProduction) async throws -> VSRFCard {
        guard let id = production.cardID else {
            throw SudrfError.parsing("у производства нет cardID — карточки нет")
        }
        return try await fetchCard(productionID: id, section: production.resolvedSection)
    }

    // MARK: - Поиск

    /// Базовый поиск по выдаче ВС РФ. Хотя бы один из параметров должен быть задан.
    public func search(uniqueNumber: String? = nil,
                       oldCaseNumber: String? = nil,
                       keywords: String? = nil) async throws -> VSRFSearchResults {
        guard let url = VSRFEndpoint.searchURL(uniqueNumber: uniqueNumber,
                                               oldCaseNumber: oldCaseNumber,
                                               keywords: keywords) else {
            throw SudrfError.parsing("не удалось собрать URL поиска ВС РФ")
        }
        let html = try await fetchUTF8(url)
        return try VSRFSearchParser.parse(html: html)
    }

    public func searchByUID(_ uid: String) async throws -> VSRFSearchResults {
        try await search(uniqueNumber: uid)
    }
    public func searchByCaseNumber(_ caseNumber: String, name: String? = nil) async throws -> VSRFSearchResults {
        try await search(oldCaseNumber: caseNumber, keywords: name)
    }
    public func searchByName(_ name: String) async throws -> VSRFSearchResults {
        try await search(keywords: name)
    }

    /// Найти производства ВС РФ, привязанные к делу нижестоящего суда (или к делу
    /// ВС — при обратном поиске). Сначала пробуем УИД (точный матч), затем фолбэк
    /// на тройку: ищем по № дела 1-й инстанции, сузив фамилией заявителя, и
    /// отбираем строки выдачи, где совпала тройка. Возвращает строки выдачи —
    /// у каждой есть `cardID`/`cardURL` для последующего `fetchCard`.
    public func findProductions(matching key: VSRFLinkKey) async throws -> [VSRFProduction] {
        if let uid = key.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty {
            let byUID = try await searchByUID(uid).matching(key)
            if !byUID.isEmpty { return byUID }
        }
        guard let caseNo = key.firstInstanceCaseNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              !caseNo.isEmpty else { return [] }
        let surname = VSRFLinkKey.surname(key.applicantName)
        let res = try await searchByCaseNumber(caseNo, name: surname)
        return res.matching(key)
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
                if let s = Cyrillic1251.decode(data) { return s }   // на всякий случай
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

/// Делегат TLS, принимающий серверный сертификат ТОЛЬКО для vsrf.ru
/// (включается опционально — если vsrf.ru отдаёт сертификат на корнях Минцифры).
final class VSRFTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let host = challenge.protectionSpace.host.lowercased()
        if host == "vsrf.ru" || host.hasSuffix(".vsrf.ru") {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
