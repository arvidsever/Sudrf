import Foundation
import SwiftSoup

enum MoscowMagistrateKoAPSource {
    static let host = "mos-sud.ru"
    static let family = "moscow-magistrate-koap"
    static let searchURL = URL(string: "https://mos-sud.ru/search")!
}

enum MoscowMagistrateKoAPURLPolicy {
    static func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == MoscowMagistrateKoAPSource.host
            && url.user == nil && url.password == nil && url.port == nil
    }
}

final class MoscowMagistrateKoAPSessionDelegate: NSObject,
                                                 URLSessionDelegate,
                                                 URLSessionTaskDelegate,
                                                 @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, MoscowMagistrateKoAPURLPolicy.allows(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum MoscowMagistrateKoAPSearchURL {
    static func make(court: Court, cartoteka: Cartoteka,
                     field: SearchField, value: String) throws -> URL {
        guard court.level == .magistrate,
              court.domain.lowercased() == MoscowMagistrateKoAPSource.host else {
            throw SudrfError.searchModuleUnavailable(domain: court.domain)
        }
        guard let supportedCartoteka = CartotekaRegistry.find(level: .magistrate, id: "adm"),
              cartoteka == supportedCartoteka else {
            throw SudrfError.unknownCartoteka(cartoteka.id)
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SudrfError.searchModuleUnavailable(domain: MoscowMagistrateKoAPSource.host)
        }
        let queryName: String
        switch field {
        case .caseNumber: queryName = "caseNumber"
        case .uid: queryName = "uid"
        case .name: queryName = "participant"
        }
        var components = URLComponents(url: MoscowMagistrateKoAPSource.searchURL,
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: queryName, value: value)]
        guard let url = components?.url else {
            throw SudrfError.searchModuleUnavailable(domain: MoscowMagistrateKoAPSource.host)
        }
        return url
    }
}

enum MoscowMagistrateKoAPResultsParser {
    static func parse(html: String, field: SearchField,
                      requestedValue: String) throws -> [CaseSearchResult] {
        guard let doc = try? SwiftSoup.parse(html),
              let adm = CartotekaRegistry.find(level: .magistrate, id: "adm") else {
            throw SudrfError.searchModuleUnavailable(domain: MoscowMagistrateKoAPSource.host)
        }
        var results: [CaseSearchResult] = []
        var seenIdentities = Set<SourceNativeCardIdentity>()
        let requestedNumber = CartotekaRegistry.normalizedNumber(requestedValue)

        for row in (try? doc.select("tr").array()) ?? [] {
            let cells = (try? row.select("td").array()) ?? []
            guard !cells.isEmpty else { continue }
            let hrefs = (try? row.select("a[href]").array()) ?? []
            let locatorAndURL = hrefs.compactMap { anchor -> (SourceNativeCardLocator, URL)? in
                guard let href = try? anchor.attr("href"),
                      let url = URL(string: href, relativeTo: MoscowMagistrateKoAPSource.searchURL)?.absoluteURL,
                      let locator = SourceNativeCardLocator.moscowMagistrateKoAP(
                        url: url, cartoteka: adm) else {
                    return nil
                }
                return (locator, Self.canonicalCardURL(url))
            }
            guard let (locator, cardURL) = locatorAndURL.first else { continue }

            let rawNumber = ((try? cells[0].text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let numberWithoutMarker = rawNumber.hasPrefix("№")
                ? String(rawNumber.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                : rawNumber
            let number = numberWithoutMarker.components(separatedBy: .whitespacesAndNewlines)
                .first ?? ""
            guard !number.isEmpty else { continue }
            let cellUID = cells.compactMap { cell in
                MGSParse.firstUID(in: (try? cell.text()) ?? "")
            }.first
            switch field {
            case .caseNumber:
                guard CartotekaRegistry.normalizedNumber(number) == requestedNumber else { continue }
            case .uid:
                if let cellUID,
                   cellUID.localizedCaseInsensitiveCompare(requestedValue) != .orderedSame {
                    continue
                }
            case .name:
                break
            }
            guard seenIdentities.insert(locator.identity).inserted else { continue }

            func text(_ index: Int) -> String? {
                guard cells.indices.contains(index),
                      let value = try? cells[index].text(),
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            results.append(CaseSearchResult(
                caseNumber: number,
                essence: text(1),
                result: text(2),
                caseID: locator.sourceNativeID,
                caseUID: cellUID,
                cardURL: cardURL))
        }

        guard !results.isEmpty else {
            // The source's empty-result markup is not yet verified. Unknown or
            // filtered output must not be presented as a confirmed zero.
            throw SudrfError.searchModuleUnavailable(domain: MoscowMagistrateKoAPSource.host)
        }
        return results
    }

    private static func canonicalCardURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? url
    }
}

enum MoscowMagistrateKoAPMetaRefresh {
    enum Decision {
        case none
        case target(URL)
        case unsupported
    }

    static func decision(in html: String, baseURL: URL) -> Decision {
        guard let doc = try? SwiftSoup.parse(html) else { return .unsupported }
        let refreshes = (try? doc.select("meta[http-equiv]").array())?.filter {
            (try? $0.attr("http-equiv"))?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("refresh") == .orderedSame
        } ?? []
        guard !refreshes.isEmpty else { return .none }
        guard refreshes.count == 1,
              let rawContent = try? refreshes[0].attr("content") else { return .unsupported }

        let parts = rawContent.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) == 0 else {
            return .unsupported
        }
        let destination = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard destination.lowercased().hasPrefix("url=") else { return .unsupported }
        var rawURL = String(destination.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        if rawURL.count >= 2,
           (rawURL.first == "\"" && rawURL.last == "\""
             || rawURL.first == "'" && rawURL.last == "'") {
            rawURL.removeFirst()
            rawURL.removeLast()
        }
        rawURL = rawURL.replacingOccurrences(of: "&amp;", with: "&")
        guard !rawURL.isEmpty,
              let target = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL else {
            return .unsupported
        }
        return .target(target)
    }
}

public actor MoscowMagistrateKoAPClient: CaseProviding {
    private let transport: HTMLCourtTransport
    private let maxAttempts: Int
    private let sessionDelegate: MoscowMagistrateKoAPSessionDelegate
    // A defensive cap matching the pinned reference's behavior, not a claim
    // that every current portal response uses exactly this many redirects.
    private let maxMetaRefreshHops = 3

    public init(minInterval: TimeInterval = 2.0,
                userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15") {
        let configuration = Self.ephemeralConfiguration()
        let delegate = MoscowMagistrateKoAPSessionDelegate()
        self.sessionDelegate = delegate
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.transport = HTMLCourtTransport(
            session: session, userAgent: userAgent, minInterval: minInterval,
            // Strict decode is fail-closed. Current mos-sud charset has not
            // been independently validated, so invalid bytes remain an error.
            decodingPolicy: .utf8Only, throttleSemantics: .lastRequestStart)
        self.maxAttempts = 2
    }

    internal init(session: URLSession, minInterval: TimeInterval = 0,
                  maxAttempts: Int = 1) {
        self.sessionDelegate = MoscowMagistrateKoAPSessionDelegate()
        self.transport = HTMLCourtTransport(
            session: session, userAgent: "SudrfKitTests", minInterval: minInterval,
            decodingPolicy: .utf8Only, throttleSemantics: .lastRequestStart)
        self.maxAttempts = max(1, maxAttempts)
    }

    public func search(court: Court, cartoteka: Cartoteka,
                       field: SearchField, value: String) async throws -> [CaseSearchResult] {
        let url = try MoscowMagistrateKoAPSearchURL.make(
            court: court, cartoteka: cartoteka, field: field, value: value)
        let response = try await fetchDocument(url)
        try Self.requireSearchablePage(response.html, formURL: url)
        return try MoscowMagistrateKoAPResultsParser.parse(
            html: response.html, field: field, requestedValue: value)
    }

    public func searchOutcome(court: Court, cartoteka: Cartoteka,
                              field: SearchField, value: String,
                              operation: SourceOperation) async throws
        -> SourceOutcome<[CaseSearchResult]> {
        do {
            let rows = try await search(court: court, cartoteka: cartoteka,
                                        field: field, value: value)
            let attempt = SourceAttempt(
                kind: .partial,
                provenance: SourceProvenance(operation: operation,
                                             sourceFamily: MoscowMagistrateKoAPSource.family,
                                             host: MoscowMagistrateKoAPSource.host))
            return .partial(rows, attempt)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw error
        } catch SudrfError.captchaRequired(let formURL) {
            let attempt = SourceOutcomeClassifier.attempt(
                for: SudrfError.captchaRequired(formURL: formURL), operation: operation,
                sourceFamily: MoscowMagistrateKoAPSource.family,
                host: MoscowMagistrateKoAPSource.host)
            return .captcha(formURL: formURL, attempt)
        } catch {
            let attempt = SourceOutcomeClassifier.attempt(
                for: error, operation: operation,
                sourceFamily: MoscowMagistrateKoAPSource.family,
                host: MoscowMagistrateKoAPSource.host)
            let message = (error as? SudrfError)?.description
                ?? "Источник \(MoscowMagistrateKoAPSource.host) не ответил."
            switch attempt.kind {
            case .maintenance: return .maintenance(message: message, attempt)
            case .transportFailure: return .transportFailure(message: message, attempt)
            default: return .parserFailure(message: message, attempt)
            }
        }
    }

    public func fetchCard(court: Court, caseID: String, caseUID: String,
                          deloID: String, new: String) async throws -> CaseCard {
        throw SudrfError.parsing("Для карточки mos-sud требуется опубликованная ссылка с УИД карточки")
    }

    public func fetchCard(url: URL) async throws -> CaseCard {
        try await fetchCardWithResponseURL(url: url).card
    }

    public func fetchCardWithResponseURL(url: URL) async throws -> SudrfCaseCardFetchResult {
        guard let cartoteka = CartotekaRegistry.find(level: .magistrate, id: "adm"),
              let requestedLocator = SourceNativeCardLocator.moscowMagistrateKoAP(
                url: url, cartoteka: cartoteka) else {
            throw SudrfError.parsing("Ссылка не является карточкой КоАП мирового судьи Москвы")
        }
        let response = try await fetchDocument(url)
        guard let responseLocator = SourceNativeCardLocator.moscowMagistrateKoAP(
            url: response.finalURL, cartoteka: cartoteka),
              responseLocator.identity == requestedLocator.identity else {
            throw SudrfError.caseCardTemporarilyUnavailable
        }
        try Self.requireCardPage(response.html, formURL: MoscowMagistrateKoAPSource.searchURL)

        let sourceCard = try MosGorSudCardParser.parse(html: response.html)
        guard let number = sourceCard.caseNumber,
              !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SudrfError.caseCardTemporarilyUnavailable
        }
        let parties = CaseParties(
            kind: .koap,
            roleItems: sourceCard.participants.compactMap(Self.roleItem(from:)))
        let card = CaseCard(
            rawText: sourceCard.rawText,
            actText: nil,
            sessions: sourceCard.sessions,
            judge: sourceCard.judge,
            result: sourceCard.result,
            uid: sourceCard.uid,
            caseNumber: number,
            category: sourceCard.category,
            receiptDate: sourceCard.receiptDate,
            legalForceDate: sourceCard.legalForceDate,
            parties: parties,
            processKind: .koap)
        return SudrfCaseCardFetchResult(card: card, responseURL: response.finalURL)
    }

    private func fetchDocument(_ startURL: URL) async throws -> HTMLCourtTransport.DownloadedHTML {
        guard MoscowMagistrateKoAPURLPolicy.allows(startURL) else {
            throw SudrfError.searchModuleUnavailable(domain: MoscowMagistrateKoAPSource.host)
        }
        var nextURL = startURL
        for hop in 0...maxMetaRefreshHops {
            let response = try await transport.fetchHTML(
                nextURL,
                maxAttempts: maxAttempts,
                referer: MoscowMagistrateKoAPSource.searchURL,
                allowedFinalHosts: [MoscowMagistrateKoAPSource.host])
            guard MoscowMagistrateKoAPURLPolicy.allows(response.finalURL) else {
                throw SudrfError.searchModuleUnavailable(domain: MoscowMagistrateKoAPSource.host)
            }
            switch MoscowMagistrateKoAPMetaRefresh.decision(in: response.html,
                                                            baseURL: response.finalURL) {
            case .none:
                return response
            case .unsupported:
                throw SudrfError.searchModuleUnavailable(domain: MoscowMagistrateKoAPSource.host)
            case .target(let target):
                guard MoscowMagistrateKoAPURLPolicy.allows(target), hop < maxMetaRefreshHops else {
                    throw SudrfError.searchModuleUnavailable(domain: MoscowMagistrateKoAPSource.host)
                }
                nextURL = target
            }
        }
        throw SudrfError.searchModuleUnavailable(domain: MoscowMagistrateKoAPSource.host)
    }

    private static func requireSearchablePage(_ html: String, formURL: URL) throws {
        switch SearchPageClassifier.classify(html: html) {
        case .captcha, .captchaRejected:
            throw SudrfError.captchaRequired(formURL: formURL)
        case .maintenance:
            throw SudrfError.sourceMaintenance(domain: MoscowMagistrateKoAPSource.host)
        default:
            return
        }
    }

    private static func requireCardPage(_ html: String, formURL: URL) throws {
        switch SearchPageClassifier.classify(html: html) {
        case .captcha, .captchaRejected:
            throw SudrfError.captchaRequired(formURL: formURL)
        case .maintenance:
            throw SudrfError.caseCardTemporarilyUnavailable
        default:
            return
        }
    }

    private static func roleItem(from raw: String) -> RoleItem? {
        guard let separator = raw.firstIndex(of: ":") else { return nil }
        let role = raw[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let name = raw[raw.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !role.isEmpty, !name.isEmpty else { return nil }
        return RoleItem(role: role, name: name)
    }

    private static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return configuration
    }
}
