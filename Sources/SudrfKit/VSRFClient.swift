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

    private let transport: HTMLCourtTransport
    private let actFileLoader: ActFileLoader
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
        let delegate = VSRFTLSDelegate(trustVSRFCertificate: trustVSRFCertificate)
        self.transport = HTMLCourtTransport(
            session: URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil),
            userAgent: userAgent, minInterval: minInterval,
            decodingPolicy: .utf8ThenWindows1251, throttleSemantics: .reserveSlots)
        self.actFileLoader = ActFileLoader()
    }

    /// Внутренний init для тестов с URLProtocol-stub'ом.
    internal init(session: URLSession,
                  minInterval: TimeInterval = 1.5,
                  userAgent: String = "SudrfKitTests") {
        self.transport = HTMLCourtTransport(
            session: session, userAgent: userAgent, minInterval: minInterval,
            decodingPolicy: .utf8ThenWindows1251, throttleSemantics: .reserveSlots)
        self.actFileLoader = ActFileLoader()
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

    /// Fetches a published PDF from a Supreme Court production card. The PDF
    /// bytes are retained even when PDFKit cannot extract text (for scanned
    /// judgments); MGS continues to require searchable text.
    public func fetchPublishedAct(url: URL,
                                  expectedProductionNumber: String? = nil) async throws -> PublishedActFile {
        guard PublishedActURLPolicy.isAllowedVSRFPublishedAct(url) else {
            throw PublishedActFileError.unsafeSourceURL
        }
        let response = try await transport.fetchFile(
            url, maxAttempts: maxAttempts,
            allowedHosts: PublishedActURLPolicy.allowedVSRFHosts,
            maxBytes: ActFileLoader.Limits.production.maxDownloadBytes)
        guard PublishedActURLPolicy.isAllowedVSRFPublishedAct(response.finalURL) else {
            throw PublishedActFileError.unsafeFinalURL
        }
        let file = try await actFileLoader.extract(
            data: response.data,
            sourceURL: url,
            finalURL: response.finalURL,
            contentType: response.contentType,
            allowEmptyPDFText: true,
            expectedProductionNumber: expectedProductionNumber)
        guard file.provenance.format == .pdf else {
            throw PublishedActFileError.unsupportedFormat
        }
        return file
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
        try await transport.fetch(url, maxAttempts: maxAttempts)
    }
}

/// Делегат TLS, принимающий серверный сертификат ТОЛЬКО для vsrf.ru
/// (включается опционально — если vsrf.ru отдаёт сертификат на корнях Минцифры).
final class VSRFTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let trustVSRFCertificate: Bool

    init(trustVSRFCertificate: Bool = true) {
        self.trustVSRFCertificate = trustVSRFCertificate
        super.init()
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              trustVSRFCertificate else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let host = challenge.protectionSpace.host.lowercased()
        if PublishedActURLPolicy.allowedVSRFHosts.contains(host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, PublishedActURLPolicy.isAllowedVSRFHostURL(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
