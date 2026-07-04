import Foundation
import SwiftSoup

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
            if let row = closestRow(of: a), let tds = try? row.select("td") {
                cells = tds.array()
                    .compactMap { try? $0.text() }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
                cardURL: cardURL
            ))
        }
        return dedupe(results)
    }

    // MARK: - helpers

    static func queryValue(_ name: String, in href: String) -> String? {
        let normalized = href.hasPrefix("http") ? href : "https://placeholder/\(href)"
        guard let comps = URLComponents(string: normalized) else { return nil }
        return comps.queryItems?.first { $0.name == name }?.value
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
        var seen = Set<String>()
        var out: [CaseSearchResult] = []
        for r in items {
            let key = (r.caseID ?? "") + "|" + r.caseNumber
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }
}
