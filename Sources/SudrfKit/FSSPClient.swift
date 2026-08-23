import Foundation
import SwiftSoup

/// CAPTCHA, выданная публичным поиском Банка данных ФССП.
///
/// `requestURL` содержит исходные параметры формы, включая одноразовый
/// `code_id`. При отправке к нему добавляется только введённый пользователем
/// код; параметры поиска заново не конструируются.
public struct FSSPCaptchaChallenge: Codable, Sendable, Equatable, Identifiable {
    public let courtDocumentID: String
    public let codeID: String
    public let imagePNG: Data
    public let requestURL: URL

    public var id: String { codeID }

    public init(courtDocumentID: String, codeID: String, imagePNG: Data,
                requestURL: URL) {
        self.courtDocumentID = courtDocumentID
        self.codeID = codeID
        self.imagePNG = imagePNG
        self.requestURL = requestURL
    }
}

/// Один результат шага ФССП: форма CAPTCHA остаётся отдельным состоянием, а
/// выдача не смешивает «нет записи» с ошибкой разбора/сети.
public enum FSSPSearchStep: Sendable, Equatable {
    case captchaRequired(FSSPCaptchaChallenge)
    case found(EnforcementLookup)
    case notFound(EnforcementLookup)
    case ambiguous(EnforcementLookup)
    case error(String)

    /// Persistable часть шага. Для CAPTCHA достаточно сохранить состояние,
    /// изображение и `code_id` намеренно остаются только в свежей задаче UI.
    public var lookup: EnforcementLookup? {
        switch self {
        case .captchaRequired(let challenge):
            return EnforcementLookup(
                state: .captchaRequired,
                record: EnforcementRecord(courtDocumentID: challenge.courtDocumentID,
                                          source: .bailiffs,
                                          discoveryState: .captchaRequired,
                                          status: "", lastAttemptAt: Date()))
        case .found(let lookup), .notFound(let lookup), .ambiguous(let lookup):
            return lookup
        case .error:
            return nil
        }
    }
}

/// Клиент публичного JSONP-поиска Банка данных исполнительных производств
/// ФССП. Старый официальный API закрыт, поэтому здесь нет скрытого API-ключа
/// или обхода CAPTCHA: пользовательский код отправляется только из ручного
/// потока (а в следующей поставке — после отдельно валидированной on-device
/// модели).
public actor FSSPClient {
    public static let defaultEndpoint = URL(string: "https://is-go.fssp.gov.ru/ajax_search")!
    public static let publicSearchURL = URL(string: "https://fssp.gov.ru/iss/ip/")!

    private let session: URLSession
    private let endpoint: URL
    private let minInterval: TimeInterval
    private let maxAttempts: Int
    private var nextAllowedAt: Date?

    /// Production path is deliberately fixed at the documented three-second
    /// interval. The internal initializer below only permits shorter spacing
    /// for deterministic URLProtocol tests.
    public init() {
        self.init(session: Self.makeSession(), minInterval: 3,
                  endpoint: Self.defaultEndpoint, maxAttempts: 2)
    }

    /// Internal test initializer. URLSession injection keeps the public client
    /// compact while still exercising JSONP, retry and query semantics.
    internal init(session: URLSession, minInterval: TimeInterval = 0,
                  endpoint: URL = FSSPClient.defaultEndpoint,
                  maxAttempts: Int = 2) {
        self.session = session
        self.minInterval = max(0, minInterval)
        self.endpoint = endpoint
        self.maxAttempts = min(max(1, maxAttempts), 2)
    }

    /// Starts a fresh search for the electronic identifier, falling back to a
    /// paper writ number only when the court did not publish an electronic ID.
    public func discover(document: CourtEnforcementDocument) async throws -> FSSPSearchStep {
        guard let number = Self.searchNumber(for: document) else {
            return .error("Суд не опубликовал номер исполнительного документа для поиска ФССП.")
        }
        return try await run(url: Self.searchURL(endpoint: endpoint, number: number),
                             document: document)
    }

    /// Submits a manually entered five-digit code to the exact URL received
    /// with the challenge. A rejected answer simply produces a new challenge.
    public func submit(code: String, for challenge: FSSPCaptchaChallenge,
                       document: CourtEnforcementDocument) async throws -> FSSPSearchStep {
        guard challenge.courtDocumentID == document.id else {
            return .error("Задача CAPTCHA ФССП относится к другому исполнительному документу.")
        }
        guard Self.sameHTTPSOrigin(challenge.requestURL, endpoint) else {
            return .error("ФССП вернула небезопасный адрес отправки CAPTCHA.")
        }
        let code = String(code.filter { ("0"..."9").contains($0) })
        guard code.count == 5 else {
            return .error("Код CAPTCHA ФССП должен содержать пять цифр.")
        }
        return try await run(url: Self.submissionURL(challenge.requestURL, code: code),
                             document: document)
    }

    /// URL shape used by the current public service. It contains only the
    /// court-published document number and all-regions selector.
    internal static func searchURL(endpoint: URL, number: String) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "callback", value: "sudrfFSSP"),
            URLQueryItem(name: "system", value: "ip"),
            URLQueryItem(name: "is[extended]", value: "1"),
            URLQueryItem(name: "nocache", value: "1"),
            URLQueryItem(name: "is[variant]", value: "4"),
            URLQueryItem(name: "is[region_id][0]", value: "-1"),
            URLQueryItem(name: "is[id_number]", value: number)
        ]
        return components.url!
    }

    private func run(url: URL, document: CourtEnforcementDocument) async throws -> FSSPSearchStep {
        do {
            let data = try await fetch(url)
            return try Self.parseStep(data: data, responseURL: url, document: document)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var lastError: Error = SudrfError.http(status: 0)
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            try await reserveRequestSlot()
            var request = URLRequest(url: url)
            request.setValue("Sudrf FSSPClient", forHTTPHeaderField: "User-Agent")
            request.setValue("application/javascript, application/json, text/html", forHTTPHeaderField: "Accept")
            request.setValue("ru,en;q=0.8", forHTTPHeaderField: "Accept-Language")

            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 200
                if (200..<300).contains(status) { return data }

                lastError = SudrfError.http(status: status)
                if attempt + 1 < maxAttempts, Self.isTemporary(status) {
                    deferRequests(for: Self.retryAfter(http) ?? 0)
                    continue
                }
                throw lastError
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                if attempt + 1 < maxAttempts, Self.isTemporary(error) { continue }
                throw error
            }
        }
        throw lastError
    }

    /// Reserving a slot before the first await makes overlapping actor calls
    /// queue correctly despite actor reentrancy while URLSession is in flight.
    private func reserveRequestSlot() async throws {
        let now = Date()
        let slot = max(now, nextAllowedAt ?? now)
        nextAllowedAt = slot.addingTimeInterval(minInterval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            try await Task.sleep(for: .seconds(wait))
        }
    }

    private func deferRequests(for interval: TimeInterval) {
        guard interval > 0 else { return }
        let retryAt = Date().addingTimeInterval(interval)
        if let nextAllowedAt {
            self.nextAllowedAt = max(nextAllowedAt, retryAt)
        } else {
            nextAllowedAt = retryAt
        }
    }

    private static func parseStep(data: Data, responseURL: URL,
                                  document: CourtEnforcementDocument) throws -> FSSPSearchStep {
        let html = try jsonpHTML(data)
        let page = try SwiftSoup.parse(html)
        if let challenge = try captchaChallenge(page: page, responseURL: responseURL,
                                                courtDocumentID: document.id) {
            return .captchaRequired(challenge)
        }
        return try resultStep(page: page, document: document)
    }

    private static func jsonpHTML(_ data: Data) throws -> String {
        guard let response = String(data: data, encoding: .utf8),
              let opening = response.firstIndex(of: "("),
              let closing = response.lastIndex(of: ")"), opening < closing else {
            throw SudrfError.parsing("JSONP Банка данных ФССП")
        }
        let function = response[..<opening]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !function.isEmpty else { throw SudrfError.parsing("JSONP Банка данных ФССП") }
        let json = String(response[response.index(after: opening)..<closing])
        guard let payload = try? JSONDecoder().decode(JSONPPayload.self, from: Data(json.utf8)),
              !payload.data.isEmpty else {
            throw SudrfError.parsing("JSONP Банка данных ФССП")
        }
        return payload.data
    }

    private static func captchaChallenge(page: Document, responseURL: URL,
                                         courtDocumentID: String) throws -> FSSPCaptchaChallenge? {
        guard let form = try page.select("form#ncapcha").first() else { return nil }
        let codeID = clean(try form.select("input[name=code_id]").first()?.attr("value"))
        let imageSource = clean(try form.select("img#capchaVisualImage").first()?.attr("src"))
        let rawURL = clean(try form.attr("url"))
        guard let codeID, let imageSource, let rawURL,
              let requestURL = requestURL(rawURL, relativeTo: responseURL),
              let query = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems,
              query.contains(where: { $0.name == "code_id" && $0.value == codeID }),
              let imagePNG = pngData(from: imageSource), !imagePNG.isEmpty else {
            throw SudrfError.parsing("CAPTCHA Банка данных ФССП")
        }
        return FSSPCaptchaChallenge(courtDocumentID: courtDocumentID, codeID: codeID,
                                    imagePNG: imagePNG, requestURL: requestURL)
    }

    /// `URL(string:relativeTo:)` interprets the raw `%23` values from the
    /// form attribute as text because its query also contains unescaped `[`.
    /// Build the path and percent-encoded query separately, so the opaque
    /// source parameters are preserved byte-for-byte in the repeated request.
    private static func requestURL(_ rawURL: String, relativeTo responseURL: URL) -> URL? {
        let parts = rawURL.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawPath = parts.first,
              let resolved = URL(string: String(rawPath), relativeTo: responseURL)?.absoluteURL,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if parts.count == 2 {
            // The official form uses raw brackets in PHP-style parameter
            // names, while its values are already percent-encoded.
            components.percentEncodedQuery = String(parts[1])
                .replacingOccurrences(of: "[", with: "%5B")
                .replacingOccurrences(of: "]", with: "%5D")
        }
        guard let requestURL = components.url,
              sameHTTPSOrigin(requestURL, responseURL) else { return nil }
        return requestURL
    }

    private static func sameHTTPSOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == "https",
              rhs.scheme?.lowercased() == "https",
              lhs.host?.lowercased() == rhs.host?.lowercased() else { return false }
        return (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    private static func resultStep(page: Document,
                                   document: CourtEnforcementDocument) throws -> FSSPSearchStep {
        let target = searchNumber(for: document).map(CourtEnforcementDocument.normalizedNumber) ?? ""
        guard !target.isEmpty else {
            return .error("Суд не опубликовал номер исполнительного документа для поиска ФССП.")
        }

        var exactRows: [BailiffEnforcementDetails] = []
        var hasRecognizedTable = false
        for table in try page.select("table").array() {
            let rows = try table.select("tr").array()
            guard let headerIndex = rows.indices.first(where: {
                recognizedColumns(in: rows[$0]).document != nil
            }) else { continue }
            let columns = recognizedColumns(in: rows[headerIndex])
            guard let documentColumn = columns.document else { continue }
            hasRecognizedTable = true
            for row in rows.dropFirst(headerIndex + 1) {
                let cells = cells(in: row)
                guard cells.count > documentColumn,
                      let documentText = try? cells[documentColumn].text(),
                      exactDocumentNumber(in: documentText, equals: target) else { continue }
                exactRows.append(try details(cells: cells, columns: columns))
            }
        }

        if exactRows.count == 1, let details = exactRows.first {
            let attemptedAt = Date()
            let record = EnforcementRecord(
                courtDocumentID: document.id,
                source: .bailiffs,
                discoveryState: .found,
                sourceRecordID: details.proceedingNumber,
                status: "",
                organization: details.department,
                lastAttemptAt: attemptedAt,
                lastSuccessAt: attemptedAt,
                sourceURL: publicSearchURL,
                bailiffDetails: details)
            return .found(EnforcementLookup(state: .found, record: record))
        }
        if exactRows.count > 1 {
            let record = EnforcementRecord(courtDocumentID: document.id, source: .bailiffs,
                                           discoveryState: .ambiguous, status: "",
                                           lastAttemptAt: Date(), sourceURL: publicSearchURL)
            return .ambiguous(EnforcementLookup(state: .ambiguous, record: record))
        }
        if hasRecognizedTable || hasEmptyResultMarker(page) {
            let record = EnforcementRecord(courtDocumentID: document.id, source: .bailiffs,
                                           discoveryState: .notFound, status: "",
                                           lastAttemptAt: Date(), sourceURL: publicSearchURL)
            return .notFound(EnforcementLookup(state: .notFound, record: record))
        }
        return .error("Банк данных ФССП вернул ответ без ожидаемой выдачи.")
    }

    private static func details(cells: [Element], columns: FSSPColumns) throws -> BailiffEnforcementDetails {
        func value(_ column: FSSPColumn) -> String? {
            guard let index = columns[column], cells.indices.contains(index) else { return nil }
            return clean(try? cells[index].text())
        }
        let proceeding = value(.proceeding)
        let bailiffCell = value(.bailiff)
        return BailiffEnforcementDetails(
            proceedingNumber: firstMatch(#"\b\d+/\d+/\d+-ИП\b"#, in: proceeding) ?? proceeding,
            proceedingOpenedRaw: firstMatch(#"\b\d{2}\.\d{2}\.\d{4}\b"#, in: proceeding),
            previousProceedingNumbers: previousProceedingNumbers(in: proceeding),
            debtor: value(.debtor),
            executiveDocumentDetails: value(.document),
            endOrTermination: value(.end),
            subjectAndOutstandingBalance: value(.subject),
            department: value(.department),
            bailiff: bailiffName(in: bailiffCell),
            bailiffPhone: firstMatch(#"(?:\+7|8)[\d()\s-]{8,}"#, in: bailiffCell))
    }

    private static func recognizedColumns(in row: Element) -> FSSPColumns {
        var out = FSSPColumns()
        for (index, cell) in cells(in: row).enumerated() {
            let heading = normalizeHeading((try? cell.text()) ?? "")
            if heading.contains("реквизиты исполнительного документа") {
                out[.document] = index
            } else if heading.contains("исполнительное производство") {
                out[.proceeding] = index
            } else if heading.contains("должник") {
                out[.debtor] = index
            } else if heading.contains("причина окончания") || heading.contains("прекращения ип") {
                out[.end] = index
            } else if heading.contains("предмет исполнения") {
                out[.subject] = index
            } else if heading.contains("отдел судебных приставов") {
                out[.department] = index
            } else if heading.contains("судебный пристав") {
                out[.bailiff] = index
            }
        }
        return out
    }

    private static func cells(in row: Element) -> [Element] {
        row.children().array().filter {
            let tag = $0.tagName().lowercased()
            return tag == "td" || tag == "th"
        }
    }

    /// Exact equality is tested against every contiguous alphanumeric token
    /// sequence. This handles both `ФС № 049…` and electronic IDs containing
    /// `#`, `/` and `-` without accepting a prefix/suffix match.
    private static func exactDocumentNumber(in text: String, equals target: String) -> Bool {
        let tokens = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for start in tokens.indices {
            var candidate = ""
            for end in start..<tokens.endIndex {
                candidate += tokens[end]
                if CourtEnforcementDocument.normalizedNumber(candidate) == target { return true }
                if candidate.count > target.count + 16 { break }
            }
        }
        return false
    }

    private static func previousProceedingNumbers(in value: String?) -> [String] {
        guard let value,
              let marker = value.range(of: "предыдущие номера", options: .caseInsensitive) else {
            return []
        }
        return allMatches(#"\b\d+/\d+/\d+-ИП\b"#, in: String(value[marker.upperBound...]))
    }

    private static func bailiffName(in value: String?) -> String? {
        guard let value else { return nil }
        guard let phone = firstMatch(#"(?:\+7|8)[\d()\s-]{8,}"#, in: value) else {
            return clean(value)
        }
        return clean(value.replacingOccurrences(of: phone, with: ""))
    }

    private static func firstMatch(_ pattern: String, in value: String?) -> String? {
        allMatches(pattern, in: value).first
    }

    private static func allMatches(_ pattern: String, in value: String?) -> [String] {
        guard let value,
              let expression = try? NSRegularExpression(pattern: pattern,
                                                         options: [.caseInsensitive]) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    private static func hasEmptyResultMarker(_ page: Document) -> Bool {
        let text = ((try? page.text()) ?? "").lowercased()
        return text.contains("найдено записей: 0") || text.contains("записей не найдено")
    }

    private static func normalizeHeading(_ value: String) -> String {
        value.replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "Е")
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func pngData(from source: String) -> Data? {
        let prefix = "data:image/png;base64,"
        guard source.lowercased().hasPrefix(prefix) else { return nil }
        return Data(base64Encoded: String(source.dropFirst(prefix.count)), options: .ignoreUnknownCharacters)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func searchNumber(for document: CourtEnforcementDocument) -> String? {
        [document.electronicID, document.blankNumber].compactMap(clean).first
    }

    private static func submissionURL(_ url: URL, code: String) -> URL {
        let separator = url.query == nil ? "?" : "&"
        // Текущий официальный nscript.js добавляет этот hidden-параметр перед
        // сериализацией формы CAPTCHA.
        return URL(string: url.absoluteString + separator
                   + "t=eb6237r6793v6f&code=" + code)!
    }

    private static func isTemporary(_ status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    private static func isTemporary(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func retryAfter(_ response: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw).map { max(0, $0.timeIntervalSinceNow) }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }
}

private struct JSONPPayload: Decodable {
    var data: String
}

private enum FSSPColumn: Hashable {
    case debtor, proceeding, document, end, subject, department, bailiff
}

private struct FSSPColumns {
    private var values: [FSSPColumn: Int] = [:]

    subscript(_ column: FSSPColumn) -> Int? {
        get { values[column] }
        set { values[column] = newValue }
    }

    var document: Int? { self[.document] }
}
