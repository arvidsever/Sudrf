import Foundation
import SwiftSoup

public struct MagistrateURLBuilder {
    public let court: Court
    public init(court: Court) { self.court = court }

    private var base: String { "https://\(court.domain)/modules.php" }

    public func formURL() throws -> URL {
        var c = URLComponents(string: base)
        c?.queryItems = [
            URLQueryItem(name: "name", value: "sud_delo"),
            URLQueryItem(name: "op", value: "hl")
        ]
        guard let url = c?.url else { throw SudrfError.parsing("не удалось собрать URL формы мирового участка") }
        return url
    }

    public func searchURL(cartoteka: Cartoteka, field: SearchField,
                          value: String, page: Int? = nil) throws -> URL {
        guard field != .uid else {
            throw SudrfError.parsing("на сайтах мировых судей нет поля поиска по УИД")
        }
        let fieldName = field == .caseNumber ? cartoteka.caseNumberField : cartoteka.nameField
        var items = [
            URLQueryItem(name: "name", value: "sud_delo"),
            URLQueryItem(name: "op", value: "sf"),
            URLQueryItem(name: "delo_id", value: cartoteka.deloID),
            URLQueryItem(name: fieldName, value: value)
        ]
        if let page, page > 0 {
            items.append(URLQueryItem(name: "pageNum_Recordset1", value: String(page)))
        }
        var c = URLComponents(string: base)
        c?.queryItems = items
        guard let url = c?.url else { throw SudrfError.parsing("не удалось собрать URL поиска мирового участка") }
        return url
    }
}

public enum MagistrateResultsParser {

    public static func parse(html: String, court: Court) throws -> [CaseSearchResult] {
        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw SudrfError.parsing("SwiftSoup не смог разобрать выдачу мирового участка") }

        let anchors = (try? doc.select("#search_results a[href*=op=cs][href*=case_id]").array()) ?? []
        var rows: [CaseSearchResult] = []
        for a in anchors {
            let href = (try? a.attr("href")) ?? ""
            let number = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !number.isEmpty else { continue }
            let cells = closestRow(of: a).map(rowTexts) ?? []
            rows.append(CaseSearchResult(
                caseNumber: number,
                receiptDate: cell(cells, at: 1),
                essence: cell(cells, at: 2),
                judge: cell(cells, at: 3),
                decisionDate: cell(cells, at: 4),
                result: cell(cells, at: 5),
                caseID: queryValue("case_id", in: href),
                caseUID: nil,
                cardURL: absoluteURL(href, domain: court.domain)
            ))
        }
        return dedupe(rows)
    }

    public static func pageNumbers(html: String) -> [Int] {
        guard let doc = try? SwiftSoup.parse(html) else { return [] }
        let anchors = (try? doc.select("a[href*=pageNum_Recordset1]").array()) ?? []
        var pages = Set<Int>()
        for a in anchors {
            let href = (try? a.attr("href")) ?? ""
            if let raw = queryValue("pageNum_Recordset1", in: href), let n = Int(raw) {
                pages.insert(n)
            }
        }
        return pages.sorted()
    }

    static func queryValue(_ name: String, in href: String) -> String? {
        let normalized = href.hasPrefix("http") ? href : "https://placeholder/\(href.hasPrefix("/") ? String(href.dropFirst()) : href)"
        guard let comps = URLComponents(string: normalized) else { return nil }
        return comps.queryItems?.first { $0.name == name }?.value
    }

    private static func closestRow(of el: Element) -> Element? {
        el.parents().array().first { $0.tagName() == "tr" }
    }

    private static func rowTexts(_ row: Element) -> [String] {
        ((try? row.select("td").array()) ?? [])
            .map { (((try? $0.text()) ?? "")).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func absoluteURL(_ href: String, domain: String) -> URL? {
        if href.hasPrefix("http") { return URL(string: href) }
        let path = href.hasPrefix("/") ? href : "/\(href)"
        return URL(string: "https://\(domain)\(path)")
    }

    private static func cell(_ cells: [String], at i: Int) -> String? {
        guard cells.indices.contains(i) else { return nil }
        let v = cells[i].trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private static func dedupe(_ items: [CaseSearchResult]) -> [CaseSearchResult] {
        var seen = Set<String>()
        var out: [CaseSearchResult] = []
        for r in items {
            let key = (r.caseID ?? r.cardURL?.absoluteString ?? "") + "|" + r.caseNumber
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }
}

public enum MagistrateCardParser {

    public static func parse(html: String) throws -> CaseCard {
        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw SudrfError.parsing("SwiftSoup не смог разобрать карточку мирового участка") }

        let root = (try? doc.select("div.lawcase-content").first()) ?? doc
        let rawText = normalize(blockText(root))
        let tabs = (try? root.select(".tab-content").array()) ?? []

        let metaTab = tabs.first { (($0.ownTextSafe + " " + text($0)).lowercased()).contains("уникальный идентификатор дела") }
            ?? tabs.first
        let movementTab = tabs.first { text($0).lowercased().contains("наименование события") }
        let partiesTab = tabs.first { text($0).lowercased().contains("процессуальный статус") }
        let actTab = tabs.first { (($0.attrSafe("class") + " " + text($0)).contains("WordSection1")) }
            ?? tabs.last

        let meta = metaTab.map(parseMeta) ?? [:]
        let acts = parseActs(from: actTab)
        return CaseCard(
            rawText: rawText,
            actText: acts.first?.body,
            sessions: movementTab.map(parseMovement) ?? [],
            judge: meta["председательствующий судья"] ?? meta["судья"],
            result: meta["результат рассмотрения"] ?? meta["результат"],
            uid: meta["уникальный идентификатор дела"],
            caseNumber: parseCaseNumber(doc: doc, html: html),
            category: meta["категория"] ?? meta["категория дела"],
            receiptDate: meta["дата поступления"],
            decisionDate: meta["дело рассмотрено (выдан приказ)"] ?? meta["дата рассмотрения"],
            legalForceDate: meta["дата вступления в законную силу"],
            acts: acts,
            parties: partiesTab.map(parseParties) ?? CaseParties()
        )
    }

    private static func parseMeta(_ el: Element) -> [String: String] {
        var map: [String: String] = [:]
        for row in (try? el.select("tr").array()) ?? [] {
            let cells = (try? row.select("td, th").array()) ?? []
            guard cells.count >= 2 else { continue }
            let key = cleanKey(text(cells[0]))
            let val = text(cells[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !val.isEmpty, key.count <= 80 else { continue }
            if map[key] == nil { map[key] = val }
        }
        return map
    }

    private static func parseMovement(_ el: Element) -> [CaseSession] {
        guard let table = (try? el.select("table").array())?.first(where: {
            text($0).lowercased().contains("наименование события")
        }) else { return [] }
        let rows = (try? table.select("tr").array()) ?? []
        var cols: [String: Int] = [:]
        var headerIndex = -1
        for (i, row) in rows.enumerated() {
            let cells = (try? row.select("td, th").array()) ?? []
            let labels = cells.map { text($0).lowercased() }
            guard labels.contains(where: { $0.contains("наименование события") }) else { continue }
            for (j, label) in labels.enumerated() {
                if label.contains("наименование события") { cols["event"] = j }
                else if label.contains("результат события") { cols["result"] = j }
                else if label.contains("дата события") { cols["date"] = j }
                else if label.contains("время события") { cols["time"] = j }
                else if label.contains("зал") || label.contains("место") { cols["room"] = j }
            }
            headerIndex = i
            break
        }
        guard headerIndex >= 0, let eventCol = cols["event"] else { return [] }
        var out: [CaseSession] = []
        for row in rows.dropFirst(headerIndex + 1) {
            let cells = (try? row.select("td").array()) ?? []
            let values = cells.map(text)
            guard values.indices.contains(eventCol), !values[eventCol].isEmpty else { continue }
            func value(_ key: String) -> String? {
                guard let i = cols[key], values.indices.contains(i), !values[i].isEmpty else { return nil }
                return values[i]
            }
            out.append(CaseSession(date: value("date") ?? "",
                                   time: value("time"),
                                   room: value("room"),
                                   event: values[eventCol],
                                   result: value("result")))
        }
        return out
    }

    private static func parseParties(_ el: Element) -> CaseParties {
        var parties = CaseParties()
        guard let table = (try? el.select("table").array())?.first(where: {
            text($0).lowercased().contains("процессуальный статус")
        }) else { return parties }
        let rows = (try? table.select("tr").array()) ?? []
        var roleCol = 0
        var nameCol = 1
        var headerSeen = false
        for row in rows {
            let cells = (try? row.select("td, th").array()) ?? []
            let values = cells.map(text)
            let lower = values.map { $0.lowercased() }
            if lower.contains(where: { $0.contains("процессуальный статус") }) {
                headerSeen = true
                roleCol = lower.firstIndex { $0.contains("процессуальный статус") } ?? 0
                nameCol = lower.firstIndex { $0 == "лицо" || $0.contains("лицо,") } ?? min(1, max(0, values.count - 1))
                continue
            }
            guard headerSeen, values.indices.contains(roleCol), values.indices.contains(nameCol) else { continue }
            let role = values[roleCol]
            let name = values[nameCol]
            guard !role.isEmpty, !name.isEmpty else { continue }
            parties.add(role: role, name: name)
        }
        return parties
    }

    private static func parseActs(from el: Element?) -> [CaseActText] {
        guard let el else { return [] }
        let word = (try? el.select(".WordSection1").first()) ?? el
        let body = normalize(blockText(word))
        guard !body.isEmpty else { return [] }
        return [CaseActText(id: "doc1", kind: "Судебный акт",
                            label: "Судебный акт", body: body)]
    }

    private static func parseCaseNumber(doc: Document, html: String) -> String? {
        if let h2 = try? doc.select("div.lawcase-content h2").first(),
           let number = caseNumber(from: text(h2)) { return number }
        return caseNumber(from: html)
    }

    private static func caseNumber(from value: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"ДЕЛО\s*№\s*([^<\n]{1,80})"#,
                                                options: [.caseInsensitive]) else { return nil }
        let ns = value as NSString
        guard let m = re.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let number = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return number.isEmpty ? nil : number
    }

    private static func cleanKey(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " :\n\t\r")).lowercased()
    }

    private static func text(_ el: Element) -> String {
        ((try? el.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let blockTags: Set<String> = [
        "p", "div", "tr", "li", "table", "section", "article", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6"
    ]

    private static func blockText(_ element: Element) -> String {
        var out = ""
        appendText(of: element, to: &out)
        return out
    }

    private static func appendText(of node: Node, to out: inout String) {
        for child in node.getChildNodes() {
            if let text = child as? TextNode {
                out += text.getWholeText()
            } else if let el = child as? Element {
                let tag = el.tagName().lowercased()
                if tag == "br" { out += "\n"; continue }
                if tag == "script" || tag == "style" { continue }
                let isBlock = blockTags.contains(tag)
                if isBlock && !out.hasSuffix("\n") { out += "\n" }
                appendText(of: el, to: &out)
                if isBlock && !out.hasSuffix("\n") { out += "\n" }
            }
        }
    }

    private static func normalize(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
        var out: [String] = []
        for line in lines {
            if line.isEmpty {
                if let last = out.last, !last.isEmpty { out.append("") }
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Element {
    var ownTextSafe: String { ownText().trimmingCharacters(in: .whitespacesAndNewlines) }
    func attrSafe(_ key: String) -> String { ((try? attr(key)) ?? "") }
}

public actor MagistrateClient: CaseProviding {
    private let client: SudrfClient
    public var maxPages = 50

    public init(sudrfClient: SudrfClient = SudrfClient()) {
        self.client = sudrfClient
    }

    public func search(court: Court, cartoteka: Cartoteka,
                       field: SearchField, value: String) async throws -> [CaseSearchResult] {
        guard isMagistrate(court) else {
            return try await client.search(court: court, cartoteka: cartoteka, field: field, value: value)
        }
        let builder = MagistrateURLBuilder(court: court)
        let firstURL = try builder.searchURL(cartoteka: cartoteka, field: field, value: value)
        let firstHTML = try await client.fetchHTML(firstURL)
        if CaptchaDetector.hasCaptcha(in: firstHTML) {
            throw SudrfError.captchaRequired(formURL: try builder.formURL())
        }
        // v0.38.10: проверяем на .captchaRejected (через общий
        // SearchPageClassifier) ДО MagistratePageClassifier —
        // если суд отверг наш токен, это другой диагноз, чем
        // «неизвестный формат». Дамп отдельно + searchModuleUnavailable.
        if SearchPageClassifier.classify(html: firstHTML) == .captchaRejected {
            SearchDiagnostics.dumpCaptchaRejected(data: Data(firstHTML.utf8), host: court.domain)
            throw SudrfError.searchModuleUnavailable(domain: court.domain)
        }
        guard MagistratePageClassifier.classify(html: firstHTML) != .unrecognized else {
            throw SudrfError.searchModuleUnavailable(domain: court.domain)
        }
        var rows = try MagistrateResultsParser.parse(html: firstHTML, court: court)
        let pages = MagistrateResultsParser.pageNumbers(html: firstHTML)
            .filter { $0 > 0 && $0 < maxPages }
        for page in pages {
            let url = try builder.searchURL(cartoteka: cartoteka, field: field,
                                            value: value, page: page)
            let html = try await client.fetchHTML(url)
            if CaptchaDetector.hasCaptcha(in: html) {
                throw SudrfError.captchaRequired(formURL: try builder.formURL())
            }
            if SearchPageClassifier.classify(html: html) == .captchaRejected {
                SearchDiagnostics.dumpCaptchaRejected(data: Data(html.utf8), host: court.domain)
                throw SudrfError.searchModuleUnavailable(domain: court.domain)
            }
            rows += try MagistrateResultsParser.parse(html: html, court: court)
        }
        return dedupe(rows)
    }

    public func fetchCard(court: Court, caseID: String, caseUID: String,
                          deloID: String, new: String) async throws -> CaseCard {
        guard isMagistrate(court) else {
            return try await client.fetchCard(court: court, caseID: caseID,
                                              caseUID: caseUID, deloID: deloID, new: new)
        }
        var c = URLComponents(string: "https://\(court.domain)/modules.php")
        c?.queryItems = [
            URLQueryItem(name: "name", value: "sud_delo"),
            URLQueryItem(name: "op", value: "cs"),
            URLQueryItem(name: "case_id", value: caseID),
            URLQueryItem(name: "delo_id", value: deloID)
        ]
        guard let url = c?.url else { throw SudrfError.parsing("не удалось собрать URL карточки мирового участка") }
        return try await fetchCard(url: url)
    }

    public func fetchCard(url: URL) async throws -> CaseCard {
        if url.host.map(SudrfHost.isMSudrfHost) == true {
            let html = try await client.fetchHTML(url)
            if CaptchaDetector.hasCaptcha(in: html) {
                throw SudrfError.captchaRequired(formURL: url)
            }
            return try MagistrateCardParser.parse(html: html)
        }
        return try await client.fetchCard(url: url)
    }

    private func isMagistrate(_ court: Court) -> Bool {
        court.level == .magistrate || SudrfHost.isMSudrfHost(court.domain)
    }

    private func dedupe(_ items: [CaseSearchResult]) -> [CaseSearchResult] {
        var seen = Set<String>()
        var out: [CaseSearchResult] = []
        for r in items {
            let key = (r.caseID ?? r.cardURL?.absoluteString ?? "") + "|" + r.caseNumber
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }
}

public enum MagistratePageClassifier {
    public static func classify(html: String) -> SearchPageKind {
        if CaptchaDetector.hasCaptcha(in: html) { return .captcha }
        if let doc = try? SwiftSoup.parse(html),
           let anchors = try? doc.select("a[href*=op=cs][href*=case_id]"),
           anchors.size() > 0 {
            return .results
        }
        if html.contains("Найдено дел: 0") || html.contains("Данных по запросу не обнаружено")
            || html.contains("Ничего не найдено") {
            return .empty
        }
        if html.contains("id=\"search_results\"") || html.contains("case-count") {
            return .empty
        }
        return .unrecognized
    }
}
