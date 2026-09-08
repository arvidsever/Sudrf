import Foundation
import SwiftSoup

public struct IncompleteCaseSearchError: Error, Sendable, Equatable, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "Источник не подтвердил полноту поисковой выдачи."
    }
}

/// Разбор страницы выдачи (`name_op=r`) в массив результатов.
///
/// Опорная точка — ссылки на карточку (`name_op=case`): из их href надёжно
/// достаются case_id и case_uid независимо от вёрстки таблицы. Привязка ячеек
/// строки к полям сделана по позиции и при изменении вёрстки сайта может
/// потребовать подстройки (текст ссылки = № дела извлекается надёжно).
public enum ResultsParser {

    public static func parse(html: String, court: Court) throws -> [CaseSearchResult] {
        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw SudrfError.parsing("SwiftSoup не смог разобрать документ") }

        let anchors = (try? doc.select("a[href*=name_op=case]").array()) ?? []
        guard !anchors.isEmpty else { return [] }

        var results: [CaseSearchResult] = []
        for a in anchors {
            let href = (try? a.attr("href")) ?? ""
            let number = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !number.isEmpty else { continue }

            // Современный модуль: case_id/case_uid; винтажный (VNKOD-суды): _id/_uid.
            let caseID = queryValue("case_id", in: href) ?? queryValue("_id", in: href)
            let caseUID = queryValue("case_uid", in: href) ?? queryValue("_uid", in: href)
            let cardURL = absoluteURL(href, domain: court.domain)

            var cells: [String] = []
            var actTextLinks: [CaseActLink] = []
            if let row = closestRow(of: a) {
                if let tds = try? row.select("td") {
                    cells = tds.array()
                        .compactMap { try? $0.text() }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                actTextLinks = parseActTextLinks(in: row, domain: court.domain)
            }

            results.append(CaseSearchResult(
                caseNumber: number,
                receiptDate: cell(cells, at: 1),
                essence: cell(cells, at: 2),
                judge: cell(cells, at: 3),
                decisionDate: cell(cells, at: 4),
                result: cell(cells, at: 5),
                legalForceDate: cell(cells, at: 6),
                caseID: caseID,
                caseUID: caseUID,
                cardURL: cardURL,
                actTextLinks: actTextLinks
            ))
        }
        return dedupe(results)
    }

    /// Parses a first-page search only when the source's own counter proves
    /// that every matching row is present on that page.
    public static func parseComplete(html: String, court: Court) throws -> [CaseSearchResult] {
        let rows = try parse(html: html, court: court)
        let text: String
        do { text = try SwiftSoup.parse(html).text() }
        catch { throw IncompleteCaseSearchError() }
        guard let total = firstInteger(
            in: text,
            pattern: #"Всего\s+по\s+запросу\s+найдено\s*[-—–:]\s*(\d{1,3}(?:[\s,]\d{3})+|\d+)"#
        ), total == rows.count else {
            throw IncompleteCaseSearchError()
        }
        if let range = firstIntegerPair(
            in: text,
            pattern: #"На\s+странице\s+записи\s+с\s*(\d+)\s+по\s*(\d+)"#
        ) {
            let validEmpty = total == 0 && rows.isEmpty && range.0 == 0 && range.1 == 0
            let validNonEmpty = range.0 == 1 && range.1 == total
                && range.1 - range.0 + 1 == rows.count
            if !validEmpty && !validNonEmpty { throw IncompleteCaseSearchError() }
        }
        return rows
    }

    // MARK: - helpers

    static func queryValue(_ name: String, in href: String) -> String? {
        let normalized = href.hasPrefix("http") ? href : "https://placeholder/\(href)"
        guard let comps = URLComponents(string: normalized) else { return nil }
        return comps.queryItems?.first { $0.name == name }?.value
    }

    /// Ссылки на тексты актов из строки выдачи (`name_op=doc`).
    ///
    /// Ищем по всей строке, а не в последней ячейке: число колонок у разных
    /// судов отличается (дату вступления в силу дают не все), а `name_op=doc`
    /// встречается только в колонке «Судебные акты».
    ///
    /// Ссылки без `number` пропускаем — без него запрос текста не собрать.
    /// `text_number` по умолчанию 1: у подавляющего большинства дел акт один.
    private static func parseActTextLinks(in row: Element, domain: String) -> [CaseActLink] {
        let anchors = (try? row.select("a[href*=name_op=doc]").array()) ?? []
        var links: [CaseActLink] = []
        var seen = Set<String>()
        for a in anchors {
            let href = (try? a.attr("href")) ?? ""
            guard let number = queryValue("number", in: href), !number.isEmpty,
                  let url = absoluteURL(href, domain: domain) else { continue }
            let textNumber = queryValue("text_number", in: href).flatMap(Int.init) ?? 1
            let kind = (try? a.attr("title"))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(url.absoluteString).inserted else { continue }
            links.append(CaseActLink(number: number,
                                     textNumber: textNumber,
                                     kind: (kind?.isEmpty ?? true) ? nil : kind,
                                     url: url))
        }
        return links.sorted { $0.textNumber < $1.textNumber }
    }

    private static func closestRow(of el: Element) -> Element? {
        el.parents().array().first { $0.tagName() == "tr" }
    }

    private static func absoluteURL(_ href: String, domain: String) -> URL? {
        if href.hasPrefix("http") { return URL(string: href) }
        let path = href.hasPrefix("/") ? href : "/\(href)"
        return URL(string: "https://\(domain)\(path)")
    }

    private static func cell(_ cells: [String], at i: Int) -> String? {
        guard i >= 0, i < cells.count else { return nil }
        let v = cells[i].trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private static func dedupe(_ items: [CaseSearchResult]) -> [CaseSearchResult] {
        var indexes: [String: Int] = [:]
        var out: [CaseSearchResult] = []
        for r in items {
            let key = sourceIdentity(r)
            if let index = indexes[key] {
                if richness(r) > richness(out[index]) { out[index] = r }
            } else {
                indexes[key] = out.count
                out.append(r)
            }
        }
        return out
    }

    private static func sourceIdentity(_ row: CaseSearchResult) -> String {
        guard let url = row.cardURL, let link = try? SudrfCaseCardLink(url: url) else {
            return row.stableID
        }
        let sourceID = link.caseID.map { "id:\($0)" }
            ?? link.caseUID.map { "uid:\($0)" }
            ?? row.stableID
        return [link.moduleHost, link.srvNum ?? "1", link.deloID,
                link.resolvedNew, sourceID].joined(separator: "|")
    }

    private static func richness(_ row: CaseSearchResult) -> Int {
        [row.caseID, row.caseUID, row.receiptDate, row.essence, row.judge,
         row.decisionDate, row.result, row.legalForceDate]
            .compactMap { $0 }.filter { !$0.isEmpty }.count
            + (row.cardURL == nil ? 0 : 1)
    }

    private static func firstInteger(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(String(text[range].filter(\.isNumber)))
    }

    private static func firstIntegerPair(in text: String, pattern: String) -> (Int, Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let firstRange = Range(match.range(at: 1), in: text),
              let secondRange = Range(match.range(at: 2), in: text),
              let first = Int(text[firstRange]), let second = Int(text[secondRange]) else {
            return nil
        }
        return (first, second)
    }
}
