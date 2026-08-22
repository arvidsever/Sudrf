import Foundation
import SwiftSoup

/// Канал, через который исполняется судебный документ.
public enum EnforcementChannel: String, Codable, Sendable, Equatable {
    case treasury
    case bailiffs
}

/// Состояние поиска записи во внешнем источнике.
public enum EnforcementDiscoveryState: String, Codable, Sendable, Equatable {
    case found
    case notFound
    case ambiguous
    case error
}

/// Одно изменение стадии исполнения из RSS-истории Казначейства.
public struct EnforcementEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var guid: String?
    public var dateRaw: String?
    public var date: Date?
    public var text: String
    public var sourceOrder: Int

    public init(id: String? = nil,
                guid: String? = nil,
                dateRaw: String? = nil,
                date: Date? = nil,
                text: String,
                sourceOrder: Int) {
        self.guid = Self.clean(guid)
        self.dateRaw = Self.clean(dateRaw)
        self.date = date
        self.text = text
        self.sourceOrder = sourceOrder
        self.id = id ?? Self.stableID(guid: self.guid, dateRaw: self.dateRaw,
                                      text: text, sourceOrder: sourceOrder)
    }

    public static func stableID(guid: String?, dateRaw: String?, text: String,
                                sourceOrder: Int) -> String {
        if let guid = clean(guid) { return guid }
        // RSS order is presentation, not identity. Real Treasury events have
        // guid; this fallback keeps a malformed feed stable across reordering.
        let key = [clean(dateRaw) ?? "", text].joined(separator: "|")
        return "treasury-event:\(key)"
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

/// Нормализованная запись источника исполнения.
public struct EnforcementRecord: Codable, Sendable, Equatable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case courtDocumentID, source, discoveryState, sourceRecordID, status,
             organization, subdivision, sourceUpdatedRaw, events, lastAttemptAt,
             lastSuccessAt, error, sourceURL
    }

    public var courtDocumentID: String
    public var source: EnforcementChannel
    /// Состояние последней попытки поиска, включая сохранённые notFound /
    /// ambiguous записи без sourceRecordID.
    public var discoveryState: EnforcementDiscoveryState
    public var sourceRecordID: String?
    /// Точный текст текущей стадии из источника, без словаря/перефразирования.
    public var status: String
    public var organization: String?
    public var subdivision: String?
    public var sourceUpdatedRaw: String?
    public var events: [EnforcementEvent]
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var error: String?
    public var sourceURL: URL?

    public var id: String { "\(source.rawValue):\(courtDocumentID)" }

    public init(courtDocumentID: String,
                source: EnforcementChannel,
                discoveryState: EnforcementDiscoveryState = .found,
                sourceRecordID: String? = nil,
                status: String,
                organization: String? = nil,
                subdivision: String? = nil,
                sourceUpdatedRaw: String? = nil,
                events: [EnforcementEvent] = [],
                lastAttemptAt: Date? = nil,
                lastSuccessAt: Date? = nil,
                error: String? = nil,
                sourceURL: URL? = nil) {
        self.courtDocumentID = courtDocumentID
        self.source = source
        self.discoveryState = discoveryState
        self.sourceRecordID = sourceRecordID
        self.status = status
        self.organization = organization
        self.subdivision = subdivision
        self.sourceUpdatedRaw = sourceUpdatedRaw
        self.events = events
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.error = error
        self.sourceURL = sourceURL
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        courtDocumentID = try values.decode(String.self, forKey: .courtDocumentID)
        source = try values.decode(EnforcementChannel.self, forKey: .source)
        discoveryState = try values.decodeIfPresent(EnforcementDiscoveryState.self,
                                                    forKey: .discoveryState) ?? .found
        sourceRecordID = try values.decodeIfPresent(String.self, forKey: .sourceRecordID)
        status = try values.decode(String.self, forKey: .status)
        organization = try values.decodeIfPresent(String.self, forKey: .organization)
        subdivision = try values.decodeIfPresent(String.self, forKey: .subdivision)
        sourceUpdatedRaw = try values.decodeIfPresent(String.self, forKey: .sourceUpdatedRaw)
        events = try values.decodeIfPresent([EnforcementEvent].self, forKey: .events) ?? []
        lastAttemptAt = try values.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastSuccessAt = try values.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        sourceURL = try values.decodeIfPresent(URL.self, forKey: .sourceURL)
    }
}

/// Результат поиска. Отсутствие записи и неоднозначность не являются
/// ошибками транспорта, поэтому возвращаются явно вместе с optional-записью.
public struct EnforcementLookup: Codable, Sendable, Equatable {
    public var state: EnforcementDiscoveryState
    public var record: EnforcementRecord?

    public init(state: EnforcementDiscoveryState, record: EnforcementRecord? = nil) {
        self.state = state
        self.record = record
    }
}

// MARK: - RSS wire format

private struct TreasuryRSSItem: Sendable, Equatable {
    var title: String = ""
    var link: String = ""
    var description: String = ""
    var guid: String = ""
    var pubDate: String = ""

    var fields: [String: String] {
        TreasuryDescriptionParser.parse(description)
    }

    var sourceRecordID: String? {
        for raw in [link, guid] {
            guard let url = URL(string: raw),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let id = components.queryItems?.first(where: { $0.name == "documentId" })?.value,
                  !id.isEmpty else { continue }
            return id
        }
        // Some RSS producers emit the document identifier as a bare guid,
        // without the historical document-details URL.
        if let guid = guid.nilIfEmpty, !guid.contains("://"), !guid.contains("/") {
            return guid
        }
        return nil
    }
}

private final class TreasuryRSSParser: NSObject, XMLParserDelegate {
    private(set) var items: [TreasuryRSSItem] = []
    private var current: TreasuryRSSItem?
    private var field: String?
    private var buffer = ""

    static func parse(_ xml: String) throws -> [TreasuryRSSItem] {
        let parser = TreasuryRSSParser()
        // The transport has already decoded cp1251 into a Swift String.  The
        // old declaration would otherwise make XMLParser interpret the new
        // UTF-8 bytes as cp1251 a second time ("Исп" -> "РСЃ").
        var utf8XML = xml
        if let declarationStart = utf8XML.range(of: "<?xml", options: .caseInsensitive),
           let declarationEnd = utf8XML.range(of: "?>",
                                               range: declarationStart.upperBound..<utf8XML.endIndex) {
            utf8XML.removeSubrange(declarationStart.lowerBound..<declarationEnd.upperBound)
        }
        let xmlParser = XMLParser(data: Data(utf8XML.utf8))
        xmlParser.delegate = parser
        guard xmlParser.parse() else {
            throw xmlParser.parserError ?? SudrfError.parsing("RSS Казначейства")
        }
        return parser.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        if name == "item" {
            current = TreasuryRSSItem()
            field = nil
            buffer = ""
            return
        }
        guard current != nil,
              ["title", "link", "description", "guid", "pubdate"].contains(name) else { return }
        field = name
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard current != nil, field != nil else { return }
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard current != nil, field != nil else { return }
        buffer += String(data: CDATABlock, encoding: .utf8)
            ?? String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name == "item" {
            if let current { items.append(current) }
            current = nil
            field = nil
            buffer = ""
            return
        }
        guard var current, field == name else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": current.title = value
        case "link": current.link = value
        case "description": current.description = value
        case "guid": current.guid = value
        case "pubdate": current.pubDate = value
        default: break
        }
        self.current = current
        field = nil
        buffer = ""
    }
}

/// Извлекает пары «жирная подпись → значение» из CDATA HTML RSS.
private enum TreasuryDescriptionParser {
    static func parse(_ html: String) -> [String: String] {
        guard let document = try? SwiftSoup.parseBodyFragment(html),
              let body = document.body() else { return [:] }
        var result: [String: String] = [:]
        for bold in (try? body.select("b").array()) ?? [] {
            guard let rawKey = try? bold.text() else { continue }
            let key = normalize(rawKey)
            guard !key.isEmpty else { continue }

            var fragment = ""
            var node = bold.nextSibling()
            while let current = node {
                if let element = current as? Element, element.tagName().lowercased() == "b" { break }
                fragment += (try? current.outerHtml()) ?? ""
                node = current.nextSibling()
            }
            guard let valueDocument = try? SwiftSoup.parseBodyFragment(fragment),
                  let valueBody = valueDocument.body(),
                  let value = try? valueBody.text() else { continue }
            result[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func value(_ fields: [String: String], containing marker: String) -> String? {
        fields.first(where: { $0.key.contains(marker) })?.value
    }

    static func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00A0}", with: " ")
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    }
}

private struct TreasuryDetails {
    var organization: String?
    var subdivision: String?
    var status: String?
    var sourceUpdatedRaw: String?

    static func parse(_ html: String) -> TreasuryDetails {
        guard let document = try? SwiftSoup.parse(html) else {
            return TreasuryDetails(organization: nil, subdivision: nil, status: nil,
                                   sourceUpdatedRaw: nil)
        }

        var rows: [(String, String)] = []
        for row in (try? document.select("tr").array()) ?? [] {
            let cells = row.children().array().filter {
                let tag = $0.tagName().lowercased()
                return tag == "td" || tag == "th"
            }
            guard cells.count >= 2,
                  let key = try? cells[0].text(),
                  let value = try? cells[1].text() else { continue }
            let keyValue = clean(key)
            let cellValue = clean(value)
            if !keyValue.isEmpty { rows.append((keyValue, cellValue)) }
        }

        func rowValue(_ marker: String) -> String? {
            rows.first(where: { $0.0.lowercased().contains(marker) })?.1.nilIfEmpty
        }

        // The organ is rendered as a heading followed by a one-cell table, not
        // as a key/value row. Keep labels as a fallback and read the first
        // non-empty text after the heading.
        let spans = (try? document.select("span").array())?.compactMap { try? $0.text() }
            .map(clean) ?? []
        let organIndex = spans.firstIndex {
            $0.lowercased() == "орган федерального казначейства"
                || $0.lowercased().contains("орган федерального казначейства")
        }
        let organFromHeading = organIndex.flatMap { index in
            spans.dropFirst(index + 1).first(where: {
                !$0.isEmpty && !$0.lowercased().contains("информация о ходе")
            })
        }
        let subdivisionFromHeading = organIndex.flatMap { index in
            spans.dropFirst(index + 1).first(where: {
                let lower = $0.lowercased()
                return lower.hasPrefix("отдел")
            })
        }

        let statusSpans = (try? document.select("span.iceOutFrmt").array())?.compactMap { try? $0.text() }
            .map(clean)
            .filter { !$0.isEmpty && !$0.hasPrefix("/") } ?? []

        return TreasuryDetails(
            organization: organFromHeading ?? rowValue("орган федерального казначейства"),
            subdivision: subdivisionFromHeading ?? rowValue("отделение") ?? rowValue("подразделение"),
            status: statusSpans.last ?? rowValue("стадия исполнения") ?? rowValue("статус"),
            sourceUpdatedRaw: rowValue("дата последнего изменения"))
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Client

/// Клиент официального RSS/HTML-сервиса «Исполнительные документы».
///
/// У сервиса нет стабильного JSON API: RSS-значения приходят в cp1251, а
/// ссылки в RSS исторически указывают на `zakupki.gov.ru`. Клиент делает
/// только GET к текущему `app.roskazna.ru`, выбирает кандидата строго и не
/// считает несколько одинаковых результатов найденным документом.
public actor TreasuryClient {
    public static let defaultBaseURL = URL(string: "https://app.roskazna.ru")!

    private let baseURL: URL
    private let transport: HTMLCourtTransport
    private let maxAttempts: Int

    public init(minInterval: TimeInterval = 1.5) {
        self.init(session: Self.makeSession(), minInterval: minInterval,
                  baseURL: Self.defaultBaseURL, maxAttempts: 3)
    }

    /// Internal test initializer. `URLProtocol` injection keeps the public API
    /// free of a one-implementation transport protocol.
    internal init(session: URLSession,
                  minInterval: TimeInterval = 1.5,
                  baseURL: URL = TreasuryClient.defaultBaseURL,
                  maxAttempts: Int = 3) {
        self.baseURL = baseURL
        self.maxAttempts = max(1, maxAttempts)
        self.transport = HTMLCourtTransport(
            session: session,
            userAgent: "Sudrf TreasuryClient",
            minInterval: minInterval,
            decodingPolicy: .utf8ThenWindows1251,
            throttleSemantics: .reserveSlots)
    }

    public func discover(document: CourtEnforcementDocument,
                         caseNumber: String? = nil,
                         court: String? = nil) async throws -> EnforcementLookup {
        let attempt = Date()
        let list = try await transport.fetch(
            listURL(number: document.blankNumber ?? document.electronicID),
            maxAttempts: maxAttempts)
        try Self.validateRSS(list)
        let items = try TreasuryRSSParser.parse(list)
        let candidates = matchingCandidates(items, document: document,
                                             caseNumber: caseNumber, court: court)
        guard let item = candidates.first else {
            let record = EnforcementRecord(courtDocumentID: document.id, source: .treasury,
                                           discoveryState: .notFound, status: "",
                                           lastAttemptAt: attempt)
            return EnforcementLookup(state: .notFound, record: record)
        }
        guard candidates.count == 1, let sourceID = item.sourceRecordID else {
            let record = EnforcementRecord(courtDocumentID: document.id, source: .treasury,
                                           discoveryState: .ambiguous, status: "",
                                           lastAttemptAt: attempt)
            return EnforcementLookup(state: .ambiguous, record: record)
        }

        let historyXML = try await transport.fetch(historyURL(documentID: sourceID),
                                                    maxAttempts: maxAttempts)
        try Self.validateRSS(historyXML)
        let historyItems = try TreasuryRSSParser.parse(historyXML)
        let events = historyItems.enumerated().map { index, event in
            let fields = event.fields
            let status = TreasuryDescriptionParser.value(fields, containing: "стадия исполнения")
                ?? event.title
            return EnforcementEvent(guid: event.guid.nilIfEmpty,
                                    dateRaw: event.pubDate.nilIfEmpty,
                                    date: Self.parseDate(event.pubDate),
                                    text: status,
                                    sourceOrder: index)
        }

        let detailsXML = try await transport.fetch(detailsURL(documentID: sourceID),
                                                    maxAttempts: maxAttempts)
        try Self.rejectCaptcha(detailsXML)
        let details = TreasuryDetails.parse(detailsXML)
        let listFields = item.fields
        let status = details.status
            ?? events.last?.text
            ?? TreasuryDescriptionParser.value(listFields, containing: "стадия исполнения")
            ?? ""
        let record = EnforcementRecord(
            courtDocumentID: document.id,
            source: .treasury,
            discoveryState: .found,
            sourceRecordID: sourceID,
            status: status,
            organization: details.organization,
            subdivision: details.subdivision,
            sourceUpdatedRaw: details.sourceUpdatedRaw,
            events: events,
            lastAttemptAt: attempt,
            lastSuccessAt: Date(),
            sourceURL: detailsURL(documentID: sourceID))
        return EnforcementLookup(state: .found, record: record)
    }

    /// Exact list URL: Base64 is computed from UTF-8, and an empty `number`
    /// keeps the query shape used by the service for an unfiltered list.
    internal func listURL() -> URL { Self.listURL(baseURL: baseURL, number: nil) }
    internal func listURL(number: String?) -> URL {
        Self.listURL(baseURL: baseURL, number: number)
    }
    internal func historyURL(documentID: String) -> URL {
        Self.historyURL(baseURL: baseURL, documentID: documentID)
    }
    internal func detailsURL(documentID: String) -> URL {
        Self.detailsURL(baseURL: baseURL, documentID: documentID)
    }

    internal static func listURL(baseURL: URL) -> URL {
        listURL(baseURL: baseURL, number: nil)
    }

    internal static func listURL(baseURL: URL, number: String?) -> URL {
        makeURL(baseURL: baseURL, path: "roskazna/rss", queryItems: [
            URLQueryItem(name: "searchType", value: base64("list")),
            URLQueryItem(name: "seriesNumberDoc", value: base64(number ?? ""))
        ])
    }

    internal static func historyURL(baseURL: URL, documentID: String) -> URL {
        makeURL(baseURL: baseURL, path: "roskazna/rss", queryItems: [
            URLQueryItem(name: "searchType", value: base64("document")),
            URLQueryItem(name: "documentId", value: base64(documentID))
        ])
    }

    internal static func detailsURL(baseURL: URL, documentID: String) -> URL {
        makeURL(baseURL: baseURL, path: "roskazna/spring/document_details",
                queryItems: [URLQueryItem(name: "documentId", value: documentID)])
    }

    private func matchingCandidates(_ items: [TreasuryRSSItem],
                                    document: CourtEnforcementDocument,
                                    caseNumber: String?, court: String?) -> [TreasuryRSSItem] {
        let targetNumber = CourtEnforcementDocument.normalizedNumber(
            document.blankNumber ?? document.electronicID)
        var candidates: [TreasuryRSSItem]
        if targetNumber.isEmpty {
            candidates = items
        } else {
            candidates = items.filter {
                let fields = $0.fields
                let sourceNumber = TreasuryDescriptionParser.value(
                    fields, containing: "серия и номер исполнительного документа")
                    ?? $0.title.split(separator: " ", maxSplits: 3).dropFirst(2).joined(separator: " ")
                return CourtEnforcementDocument.normalizedNumber(sourceNumber) == targetNumber
            }
        }

        // If the exact number still identifies several rows, every available
        // discriminator must agree. Conflicting metadata keeps the original
        // ambiguity instead of letting a later field select a different row.
        if candidates.count > 1 {
            let targetCase = Self.normalizeMatch(caseNumber)
            let targetDate = Self.normalizeMatch(document.date)
            let targetCourt = Self.normalizeMatch(court)
            let filtered = candidates.filter { item in
                let fields = item.fields
                return (targetCase.isEmpty || Self.normalizeMatch(
                    TreasuryDescriptionParser.value(fields, containing: "номер судебного дела")) == targetCase)
                    && (targetDate.isEmpty || Self.normalizeMatch(
                        TreasuryDescriptionParser.value(fields, containing: "дата выдачи исполнительного документа")) == targetDate)
                    && (targetCourt.isEmpty || Self.normalizeMatch(
                        TreasuryDescriptionParser.value(fields, containing: "наименование судебного органа")) == targetCourt)
            }
            if !filtered.isEmpty { candidates = filtered }
        }
        return candidates
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    private static func validateRSS(_ value: String) throws {
        try rejectCaptcha(value)
        guard value.range(of: "<rss", options: .caseInsensitive) != nil else {
            throw SudrfError.parsing("RSS Казначейства")
        }
    }

    private static func rejectCaptcha(_ value: String) throws {
        let lower = value.lowercased()
        if lower.contains("captcha") || lower.contains("код с картинки")
            || lower.contains("проверочный код") {
            throw SudrfError.parsing("Казначейство потребовало CAPTCHA")
        }
    }

    private static func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func makeURL(baseURL: URL, path: String,
                                queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = prefix.isEmpty ? "/\(suffix)" : "/\(prefix)/\(suffix)"
        components.queryItems = queryItems
        return components.url!
    }

    private static func normalizeMatch(_ value: String?) -> String {
        guard let value else { return "" }
        return value.replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "Е")
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss",
            "dd.MM.yyyy HH:mm:ss",
            "dd.MM.yyyy"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
