import ArgumentParser
import CryptoKit
import Foundation
import SwiftSoup
import SudrfKit

enum PortalCanaryFamily: String, CaseIterable, Codable, Sendable {
    case sudrfDistrict = "sudrf-district"
    case vnkodLegacy = "vnkod-legacy"
    case subjectCourt = "subject-court"
    case ksoyu = "ksoyu"
    case magistrate = "msudrf"
    case supremeCourt = "vsrf"
    case moscow = "mosgorsud"
}

enum PortalCanaryPage: Sendable {
    case sudrf(court: Court, cartoteka: Cartoteka)
    case magistrate(court: Court, cartoteka: Cartoteka)
    case supremeCourt
    case moscow
}

struct PortalCanaryTarget: Sendable {
    let family: PortalCanaryFamily
    let host: String
    let url: URL
    let page: PortalCanaryPage

    var expectedFieldNames: [String] {
        switch page {
        case .sudrf(_, let cartoteka), .magistrate(_, let cartoteka):
            let key = cartoteka.caseNumberField.lowercased()
            // The displayed form field can add a presentation suffix such as
            // `_ISS`; match the stable cartoteka prefix instead of its value.
            let common = key.components(separatedBy: "ss").first ?? key
            let platformFields = family == .vnkodLegacy ? ["case__case_numberss"] : []
            return ([common] + platformFields).filter { !$0.isEmpty }
        case .supremeCourt:
            return ["uniqueNumber", "oldCaseNumber1", "keywords"]
        case .moscow:
            return ["caseNumber", "uid", "participant"]
        }
    }
}

enum PortalCanaryOutcome: String, Codable, Sendable {
    case searchForm
    case parsedListing
    case emptyListing
    case captcha
    case maintenance
    case parserContractFailure
    case unknownPage
    case redirectBlocked
    case httpFailure
    case bodyTooLarge
    case nonHTMLResponse
    case decodeFailure
    case networkFailure
}

struct PortalCanaryDOMSnapshot: Codable, Sendable {
    let elementCounts: [String: Int]
    let hasExpectedSearchControl: Bool
    let hasKnownListingStructure: Bool
    let hasCaptcha: Bool
}

struct PortalCanaryReportRow: Codable, Sendable {
    let family: PortalCanaryFamily
    let host: String
    let outcome: PortalCanaryOutcome
    let stage: String
    let httpStatus: Int?
    let bytes: Int?
    let sha256: String?
    let declaredCharset: String
    let decodedCharset: String?
    let safeDOM: PortalCanaryDOMSnapshot?
}

struct PortalCanaryReport: Codable, Sendable {
    let generatedAt: Date
    let requests: [PortalCanaryReportRow]

    var satisfiesWorkflowOutcomePolicy: Bool {
        guard requests.count == PortalCanaryFamily.allCases.count else { return false }
        return requests.allSatisfy {
            $0.outcome == .searchForm || $0.outcome == .parsedListing || $0.outcome == .captcha
        }
    }
}

enum PortalCanaryTargets {
    static func make() throws -> [PortalCanaryTarget] {
        let district = Court.syktyvkarskiy
        let legacy = Court(domain: "zavolgskiy--uln.sudrf.ru",
                           title: "",
                           level: .district)
        guard let subject = CourtDirectory.subjectCourts.first(where: {
            $0.domain == "sankt-peterburgsky.spb.sudrf.ru"
        })?.court,
        let ksoyu = CourtDirectory.cassationCourts.first(where: {
            $0.domain == "3kas.sudrf.ru"
        })?.court,
        let districtCartoteka = CartotekaRegistry.find(level: .district, id: "g1"),
        let subjectCartoteka = CartotekaRegistry.find(level: .subject, id: "g2"),
        let ksoyuCartoteka = CartotekaRegistry.find(level: .cassation, id: "g3"),
        let magistrateCartoteka = CartotekaRegistry.find(level: .magistrate, id: "g1") else {
            throw PortalCanaryConfigurationError.targetDirectoryUnavailable
        }

        let districtURL = try SudrfURLBuilder(court: district).formURL(districtCartoteka)
        let legacyURL = try SudrfURLBuilder(court: legacy).formURL(districtCartoteka)
        let subjectURL = try SudrfURLBuilder(court: subject).formURL(subjectCartoteka)
        let ksoyuURL = try SudrfURLBuilder(court: ksoyu).formURL(ksoyuCartoteka)
        let magistrate = Court(domain: "petrozavodskoj.komi.msudrf.ru",
                               title: "",
                               level: .magistrate)
        let magistrateURL = try MagistrateURLBuilder(court: magistrate).formURL()
        let vsrfURL = try blankQuery(VSRFEndpoint.searchURL())
        let moscowURL = try blankQuery(MosGorSudEndpoint.searchURL(
            courtAlias: "", instance: MosGorSudInstance.first, processType: .civil))

        return [
            target(.sudrfDistrict, districtURL, .sudrf(court: district, cartoteka: districtCartoteka)),
            target(.vnkodLegacy, legacyURL, .sudrf(court: legacy, cartoteka: districtCartoteka)),
            target(.subjectCourt, subjectURL, .sudrf(court: subject, cartoteka: subjectCartoteka)),
            target(.ksoyu, ksoyuURL, .sudrf(court: ksoyu, cartoteka: ksoyuCartoteka)),
            target(.magistrate, magistrateURL, .magistrate(court: magistrate, cartoteka: magistrateCartoteka)),
            target(.supremeCourt, vsrfURL, .supremeCourt),
            target(.moscow, moscowURL, .moscow)
        ]
    }

    private static func target(_ family: PortalCanaryFamily,
                               _ url: URL,
                               _ page: PortalCanaryPage) -> PortalCanaryTarget {
        PortalCanaryTarget(family: family, host: url.host?.lowercased() ?? "", url: url, page: page)
    }

    private static func blankQuery(_ url: URL?) throws -> URL {
        guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw PortalCanaryConfigurationError.targetDirectoryUnavailable
        }
        components.query = nil
        guard let blank = components.url else {
            throw PortalCanaryConfigurationError.targetDirectoryUnavailable
        }
        return blank
    }
}

enum PortalCanaryConfigurationError: Error {
    case targetDirectoryUnavailable
}

struct PortalCanaryRunner {
    private static let maximumResponseBytes = 1_000_000
    private static let diagnosticTags: Set<String> = [
        "html", "head", "body", "form", "input", "select", "option", "button",
        "table", "thead", "tbody", "tr", "th", "td", "a", "img", "iframe",
        "script", "div", "span", "section", "main", "header", "footer", "h1", "h2"
    ]

    let session: URLSession

    init(session: URLSession = PortalCanaryRunner.makeLiveSession()) {
        self.session = session
    }

    static func makeLiveSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return makeSession(configuration: configuration)
    }

    static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration,
                   delegate: PortalCanaryRedirectBlocker(),
                   delegateQueue: nil)
    }

    func run(_ targets: [PortalCanaryTarget],
             now: Date = Date()) async -> PortalCanaryReport {
        var rows: [PortalCanaryReportRow] = []
        for (index, target) in targets.enumerated() {
            if index > 0 { try? await Task.sleep(for: .seconds(1.5)) }
            rows.append(await check(target))
        }
        return PortalCanaryReport(generatedAt: now, requests: rows)
    }

    private func check(_ target: PortalCanaryTarget) async -> PortalCanaryReportRow {
        guard target.url.scheme?.lowercased() == "https",
              target.url.host?.lowercased() == target.host else {
            return row(target, .unknownPage, "request_policy", nil, nil, nil, "unspecified", nil, nil)
        }

        var request = URLRequest(url: target.url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("ru,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("SudrfPortalCanary/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                stream.task.cancel()
                return row(target, .httpFailure, "http_response", nil, nil,
                           nil, "unspecified", nil, nil)
            }
            let declared = safeCharset(http.value(forHTTPHeaderField: "Content-Type"))
            guard !(300..<400).contains(http.statusCode) else {
                stream.task.cancel()
                return row(target, .redirectBlocked, "redirect", http.statusCode, nil,
                           nil, declared, nil, nil)
            }
            guard http.statusCode == 200 else {
                stream.task.cancel()
                return row(target, .httpFailure, "http", http.statusCode, nil,
                           nil, declared, nil, nil)
            }
            guard isHTML(http.value(forHTTPHeaderField: "Content-Type")) else {
                stream.task.cancel()
                return row(target, .nonHTMLResponse, "content_type", http.statusCode, nil,
                           nil, declared, nil, nil)
            }
            var data = Data()
            data.reserveCapacity(32_768)
            for try await byte in stream {
                guard data.count < Self.maximumResponseBytes else {
                    stream.task.cancel()
                    return row(target, .bodyTooLarge, "body_limit", http.statusCode,
                               data.count, nil, declared, nil, nil)
                }
                data.append(byte)
            }
            let hash = digest(data)
            guard let decoded = decode(data, family: target.family, declared: declared) else {
                return row(target, .decodeFailure, "decode", http.statusCode, data.count,
                           hash, declared, nil, nil)
            }

            let classification = classify(decoded.html, target: target)
            let safeDOM = safeSnapshot(decoded.html, target: target)
            let outcome: PortalCanaryOutcome
            let stage: String
            switch classification {
            case .captcha:
                outcome = .captcha; stage = "classification"
            case .maintenance:
                outcome = .maintenance; stage = "classification"
            case .parsedListing:
                outcome = .parsedListing; stage = "source_parser"
            case .emptyListing:
                outcome = .emptyListing; stage = "source_classifier"
            case .searchForm:
                outcome = .searchForm; stage = "form_structure"
            case .parserFailure:
                outcome = .parserContractFailure; stage = "source_parser"
            case .unknown:
                outcome = .unknownPage; stage = "classification"
            }
            let artifact = outcome == .unknownPage || outcome == .parserContractFailure
                || outcome == .emptyListing || outcome == .maintenance || outcome == .captcha
                ? safeDOM : nil
            return row(target, outcome, stage, http.statusCode, data.count,
                       hash, declared, decoded.encoding.rawValue, artifact)
        } catch let error as URLError {
            return row(target, .networkFailure, networkCategory(error.code), nil,
                       nil, nil, "unspecified", nil, nil)
        } catch {
            return row(target, .networkFailure, "network", nil, nil, nil,
                       "unspecified", nil, nil)
        }
    }

    private enum Classification {
        case searchForm, parsedListing, emptyListing, captcha, maintenance, parserFailure, unknown
    }

    private enum DecodedCharset: String {
        case utf8 = "utf-8"
        case windows1251 = "windows-1251"
    }

    private func classify(_ html: String, target: PortalCanaryTarget) -> Classification {
        let common = SearchPageClassifier.classify(html: html)
        switch common {
        case .captcha, .captchaRejected: return .captcha
        case .maintenance: return .maintenance
        case .results:
            return sourceParserClassification(html, target: target)
        case .empty: return .emptyListing
        case .unrecognized: break
        }

        if case .magistrate = target.page {
            switch MagistratePageClassifier.classify(html: html) {
            case .captcha, .captchaRejected: return .captcha
            case .maintenance: return .maintenance
            case .results:
                return sourceParserClassification(html, target: target)
            case .empty: return .emptyListing
            case .unrecognized: break
            }
        }

        if CaptchaDetector.hasCaptcha(in: html) { return .captcha }
        let hasSearchForm = expectedSearchFormExists(html, target: target)
        switch target.page {
        case .sudrf, .magistrate:
            if hasPositiveResultCount(html, target: target) { return .parserFailure }
            return hasSearchForm ? .searchForm : .unknown
        case .supremeCourt, .moscow:
            let parsed = sourceParserClassification(html, target: target)
            switch parsed {
            case .parsedListing:
                return .parsedListing
            case .emptyListing:
                // The VSRF parser only accepts an empty listing when the page
                // publishes an explicit zero count. With real form controls,
                // that remains a recognized blank search page.
                if case .supremeCourt = target.page, hasSearchForm { return .searchForm }
                return .emptyListing
            case .parserFailure:
                if hasKnownListingStructure(html, target: target) { return .parserFailure }
                return hasSearchForm ? .searchForm : .unknown
            case .searchForm, .captcha, .maintenance, .unknown:
                return parsed
            }
        }
    }

    private func hasPositiveResultCount(_ html: String, target: PortalCanaryTarget) -> Bool {
        switch target.page {
        case .sudrf:
            return SearchPageClassifier.resultCount(in: html).map { $0 > 0 } ?? false
        case .magistrate:
            return MagistratePageClassifier.resultCount(in: html).map { $0 > 0 } ?? false
        case .supremeCourt, .moscow:
            return false
        }
    }

    private func hasKnownListingStructure(_ html: String, target: PortalCanaryTarget) -> Bool {
        safeSnapshot(html, target: target)?.hasKnownListingStructure ?? false
    }

    /// The existing family parser is used only as an in-memory recognition
    /// check. Parsed case data never enters the report or an artifact.
    private func sourceParserClassification(_ html: String,
                                            target: PortalCanaryTarget) -> Classification {
        switch target.page {
        case .sudrf(let court, _):
            guard let rows = try? ResultsParser.parse(html: html, court: court),
                  !rows.isEmpty else { return .parserFailure }
            return .parsedListing
        case .magistrate(let court, _):
            guard let rows = try? MagistrateResultsParser.parse(html: html, court: court),
                  !rows.isEmpty else { return .parserFailure }
            return .parsedListing
        case .supremeCourt:
            guard let results = try? VSRFSearchParser.parse(html: html) else { return .parserFailure }
            return results.results.isEmpty ? .emptyListing : .parsedListing
        case .moscow:
            guard let rows = try? MosGorSudResultsParser.parse(html: html) else { return .parserFailure }
            return rows.isEmpty ? .emptyListing : .parsedListing
        }
    }

    private func expectedSearchFormExists(_ html: String, target: PortalCanaryTarget) -> Bool {
        guard let document = try? SwiftSoup.parse(html) else { return false }
        let forms = (try? document.select("form").array()) ?? []
        guard !forms.isEmpty else { return false }
        let names = forms.flatMap { form in
            (try? form.select("input[name], select[name], textarea[name]").array()) ?? []
        }
            .compactMap { try? $0.attr("name").lowercased() }
        let fields = target.expectedFieldNames.map { $0.lowercased() }
        let hasField = names.contains { name in fields.contains { field in name == field || name.hasPrefix(field) } }
        switch target.page {
        case .sudrf, .magistrate:
            let hasSudrfContext = names.contains("name_op") || names.contains("delo_id")
                || forms.contains { ((try? $0.attr("action")) ?? "").contains("sud_delo") }
            return hasSudrfContext && hasField
        case .supremeCourt:
            return hasField
        case .moscow:
            return hasField
        }
    }

    private func safeSnapshot(_ html: String, target: PortalCanaryTarget) -> PortalCanaryDOMSnapshot? {
        guard let document = try? SwiftSoup.parse(html) else { return nil }
        var counts: [String: Int] = [:]
        for element in (try? document.getAllElements().array()) ?? [] {
            let tag = element.tagName().lowercased()
            if Self.diagnosticTags.contains(tag) { counts[tag, default: 0] += 1 }
        }
        let control = expectedSearchFormExists(html, target: target)
        let knownListing = switch target.page {
        case .sudrf, .magistrate:
            ((try? document.select("a[href*=name_op=case], a[href*=op=cs][href*=case_id]").size()) ?? 0) > 0
                || hasPositiveResultCount(html, target: target)
        case .supremeCourt:
            ((try? document.select("#vs-search-items, .count-label, [class*=SearchPage_resultsBlock__]").size()) ?? 0) > 0
        case .moscow:
            ((try? document.select("table.search-form__table").size()) ?? 0) > 0
                || ((try? document.select("tr[data-href]").array()) ?? [])
                .contains { ((try? $0.attr("data-href")) ?? "").contains("/details/") }
        }
        return PortalCanaryDOMSnapshot(
            elementCounts: counts,
            hasExpectedSearchControl: control,
            hasKnownListingStructure: knownListing,
            hasCaptcha: CaptchaDetector.hasCaptcha(in: html))
    }

    private func decode(_ data: Data, family: PortalCanaryFamily,
                        declared: String) -> (html: String, encoding: DecodedCharset)? {
        let utf8 = { String(data: data, encoding: .utf8) }
        let cp1251 = { Cyrillic1251.decode(data) }
        let result: (String?, DecodedCharset?)
        switch family {
        case .moscow:
            result = (utf8(), .utf8)
        case .supremeCourt:
            if let value = utf8() { result = (value, .utf8) }
            else { result = (cp1251(), .windows1251) }
        default:
            if declared == "utf-8" {
                if let value = utf8() { result = (value, .utf8) }
                else { result = (cp1251(), .windows1251) }
            } else if let value = cp1251() {
                result = (value, .windows1251)
            } else {
                result = (utf8(), .utf8)
            }
        }
        guard let html = result.0, let encoding = result.1 else { return nil }
        return (html, encoding)
    }

    private func isHTML(_ contentType: String?) -> Bool {
        let mediaType = contentType?.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return mediaType == "text/html" || mediaType == "application/xhtml+xml"
    }

    private func safeCharset(_ contentType: String?) -> String {
        guard let contentType else { return "unspecified" }
        let lower = contentType.lowercased()
        guard let range = lower.range(of: #"charset\s*=\s*['\"]?([^;\s'\"]+)"#,
                                      options: .regularExpression) else { return "unspecified" }
        let raw = String(lower[range]).split(separator: "=", maxSplits: 1).last
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) } ?? ""
        switch raw {
        case "utf-8", "utf8": return "utf-8"
        case "windows-1251", "cp1251", "windows1251": return "windows-1251"
        case "iso-8859-1", "latin1": return "iso-8859-1"
        default: return "other"
        }
    }

    private func networkCategory(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "timeout"
        case .cannotFindHost, .dnsLookupFailed: return "dns"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "tls"
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return "connection"
        case .cancelled: return "cancelled"
        default: return "network"
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func row(_ target: PortalCanaryTarget,
                     _ outcome: PortalCanaryOutcome,
                     _ stage: String,
                     _ httpStatus: Int?,
                     _ bytes: Int?,
                     _ sha256: String?,
                     _ declaredCharset: String,
                     _ decodedCharset: String?,
                     _ safeDOM: PortalCanaryDOMSnapshot?) -> PortalCanaryReportRow {
        PortalCanaryReportRow(family: target.family, host: target.host, outcome: outcome,
                              stage: stage, httpStatus: httpStatus, bytes: bytes, sha256: sha256,
                              declaredCharset: declaredCharset, decodedCharset: decodedCharset,
                              safeDOM: safeDOM)
    }
}

final class PortalCanaryRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension SudrfCLI {
    struct PortalCanary: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "portal-canary",
            abstract: "Однократная ежедневная проверка публичной структуры семи порталов.")

        @Flag(name: .long, help: "Подтвердить единственный внешний GET к каждому источнику.")
        var live = false

        @Option(name: .long, help: "Каталог для безопасного JSON-отчёта.")
        var outputDirectory: String?

        func run() async throws {
            guard live else { throw ValidationError("Для запуска canary требуется флаг --live.") }
            let targets: [PortalCanaryTarget]
            do { targets = try PortalCanaryTargets.make() }
            catch { throw ValidationError("Не удалось собрать зафиксированные URL источников canary.") }

            let report = await PortalCanaryRunner().run(targets)
            try write(report)
            for item in report.requests {
                let status = item.httpStatus.map { String($0) } ?? "—"
                print("\(item.family.rawValue) host=\(item.host) stage=\(item.stage) outcome=\(item.outcome.rawValue) http=\(status)")
            }
            if !report.satisfiesWorkflowOutcomePolicy {
                throw ExitCode.failure
            }
        }

        private func write(_ report: PortalCanaryReport) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(report)
            if let outputDirectory {
                let directoryURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: directoryURL,
                                                       withIntermediateDirectories: true)
                try data.write(to: directoryURL.appendingPathComponent("portal-canary-report.json"),
                               options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
    }
}
