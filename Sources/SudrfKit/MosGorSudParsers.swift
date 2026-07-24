//  MosGorSudParsers.swift — Sudrf
//  Разбор HTML портала mos-gorsud.ru (выдача поиска и карточка дела).
//
//  Селекторы выверены по ЖИВЫМ фикстурам портала (Tests/…/Fixtures/mosgorsud):
//   • строка выдачи — это `<tr data-href="/mgs|/rs/<alias>/services/cases/
//     <section>/details/<uuid>?…">` (НЕ `<a href>`); колонки читаются по
//     заголовкам `<thead>` (набор колонок отличается между поиском по МГС и
//     глобальным), раздел (вид×инстанция) — из сегмента пути;
//   • карточка — пары `<div class="row"><div class="left">КЛЮЧ</div>
//     <div class="right">ЗНАЧЕНИЕ</div></div>` (НЕ `<th>/<td>`); «Судья»
//     пишется латинской C («Cудья») — ключи ищем по вхождению; заседания/
//     состояние — таблицы по заголовкам («Зал»/«Состояние»); тексты актов —
//     вложения по ссылке `/…/cases/docs/content/<uuid>`.

import Foundation
import SwiftSoup

enum MGSParse {
    /// УИД вида 77RS0021-01-2024-001234-56 / 77OS0000-01-2020-003295-18.
    static let uidRegex = try! NSRegularExpression(
        pattern: #"\b\d{2}[A-ZА-Я]{2}\d{4}-\d{2}-\d{4}-\d{6}-\d{2}\b"#)

    static func firstUID(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = uidRegex.firstMatch(in: text, range: range),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    /// Первый «токен» до пробела/тильды — номер дела из ячейки, где рядом бывают
    /// кнопки «Скопировать», прежние номера в скобках и материальный №.
    static func firstNumber(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for sep in [" ", "\u{223C}", "~", "("] {   // ∼ (U+223C) — разделитель на портале
            if let i = trimmed.firstIndex(of: Character(sep)) {
                let head = String(trimmed[..<i]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty { return head }
            }
        }
        return trimmed
    }

    static func absoluteURL(_ href: String) -> URL? {
        let clean = href.split(separator: "?").first.map(String.init) ?? href
        if clean.hasPrefix("http") { return URL(string: clean) }
        let path = clean.hasPrefix("/") ? clean : "/\(clean)"
        return URL(string: "https://\(MosGorSudEndpoint.host)\(path)")
    }
}

public enum MosGorSudResultsParser {

    public static func parse(html: String) throws -> [MosGorSudResult] {
        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw SudrfError.parsing("SwiftSoup не смог разобрать выдачу mos-gorsud") }

        // Заголовки таблицы результатов → индексы колонок (по вхождению).
        let headers = ((try? doc.select("thead th").array()) ?? [])
            .map { (try? $0.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func idx(_ needle: String) -> Int {
            headers.firstIndex { $0.localizedCaseInsensitiveContains(needle) } ?? -1
        }
        // «№ дела» и «Категория дела» обе содержат «дела» — номер ищем по «№».
        let iNumber = idx("№")
        let iParties = idx("Стороны")
        let iState = idx("состояние")
        let iCategory = idx("Категория")
        let iJudge = idx("Судья")

        // Опорная точка — строки со ссылкой на карточку в атрибуте `data-href`.
        // Берём все <tr> и фильтруем по атрибуту вручную (не полагаемся на
        // поддержку `[attr*=…]` в CSS-парсере SwiftSoup).
        let rows = (try? doc.select("tr").array()) ?? []
        var out: [MosGorSudResult] = []
        for tr in rows {
            let href = (try? tr.attr("data-href")) ?? ""
            guard href.contains("/details/") else { continue }
            let cardURL = MGSParse.absoluteURL(href)
            let section = MosGorSudRouting.section(fromPath: href.split(separator: "?").first.map(String.init) ?? href)

            let cells = ((try? tr.select("td").array()) ?? [])
                .map { (try? $0.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            func cell(_ i: Int, fallback: Int) -> String? {
                let j = i >= 0 ? i : fallback
                guard cells.indices.contains(j) else { return nil }
                let v = cells[j].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            let numberRaw = cell(iNumber, fallback: 0) ?? ""
            let number = MGSParse.firstNumber(in: numberRaw)
            guard !number.isEmpty else { continue }

            out.append(MosGorSudResult(
                caseNumber: number,
                uid: cells.compactMap { MGSParse.firstUID(in: $0) }.first,
                court: nil,
                judge: cell(iJudge, fallback: -1),
                receiptDate: nil,
                participants: cell(iParties, fallback: 1),
                result: cell(iState, fallback: 2),
                category: cell(iCategory, fallback: -1),
                section: section,
                cardURL: cardURL))
        }
        return dedupe(out)
    }

    private static func dedupe(_ items: [MosGorSudResult]) -> [MosGorSudResult] {
        var seen = Set<String>()
        var out: [MosGorSudResult] = []
        for r in items {
            let key = (r.cardURL?.absoluteString ?? "") + "|" + r.caseNumber
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }
}

public enum MosGorSudCardParser {

    public static func parse(html: String) throws -> MosGorSudCard {
        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw SudrfError.parsing("SwiftSoup не смог разобрать карточку mos-gorsud") }

        let rawText = (try? doc.text()) ?? ""

        // Поля карточки: пары `<div class="left">КЛЮЧ</div><div class="right">ЗНАЧ</div>`.
        var fields: [(key: String, value: String)] = []
        var partiesRawHTML: String?
        for left in (try? doc.select("div.left").array()) ?? [] {
            guard let right = try? left.nextElementSibling(),
                  right.hasClass("right"),
                  let k = try? left.text(), let v = try? right.text() else { continue }
            let key = k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            fields.append((key, v.trimmingCharacters(in: .whitespacesAndNewlines)))
            if key.contains("сторон") { partiesRawHTML = try? right.html() }
        }
        func field(_ needles: String...) -> String? {
            for n in needles {
                if let hit = fields.first(where: { $0.key.contains(n.lowercased()) }),
                   !hit.value.isEmpty { return hit.value }
            }
            return nil
        }

        // Заседания: таблица с колонкой «Зал» (Дата и время | Зал | Стадия | Результат | …).
        var sessions: [CaseSession] = []
        if let table = headerTable(in: doc, containing: "Зал") {
            let heads = tableHeaders(table)
            let iDate = heads.firstIndex { $0.localizedCaseInsensitiveContains("Дата") } ?? 0
            let iRoom = heads.firstIndex { $0.localizedCaseInsensitiveContains("Зал") } ?? -1
            let iStage = heads.firstIndex { $0.localizedCaseInsensitiveContains("Стадия") } ?? -1
            let iResult = heads.firstIndex { $0.localizedCaseInsensitiveContains("Результат") } ?? -1
            for tr in (try? table.select("tr").array()) ?? [] {
                let cells = ((try? tr.select("td").array()) ?? [])
                    .map { (try? $0.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                guard let dc = value(cells, iDate),
                      let dt = parseDateTime(dc) else { continue }
                sessions.append(CaseSession(
                    date: dt.date, time: dt.time,
                    room: value(cells, iRoom),
                    event: value(cells, iStage) ?? "Судебное заседание",
                    result: value(cells, iResult)))
            }
        }

        // Тексты актов — вложения по ссылке /…/cases/docs/content/<uuid>.
        var actLinks: [URL] = []
        for a in (try? doc.select("a[href]").array()) ?? [] {
            let href = (try? a.attr("href")) ?? ""
            guard href.contains("cases/docs/content") else { continue }
            if let url = MGSParse.absoluteURL(href) { actLinks.append(url) }
        }

        // Стороны: пары `<p class="table-bold-text">Роль</p>Имя<br/>Имя…`.
        var participants: [String] = []
        if let raw = partiesRawHTML {
            participants = parseParties(raw)
        }

        let numberRaw = field("номер дела", "номер заявления", "номер материала") ?? ""

        return MosGorSudCard(
            uid: field("уникальный идентификатор").flatMap(MGSParse.firstUID(in:))
                ?? MGSParse.firstUID(in: rawText),
            caseNumber: numberRaw.isEmpty ? nil : MGSParse.firstNumber(in: numberRaw),
            court: field("наименование суда", "суд первой инстанции"),
            judge: field("удья"),   // «Cудья» — латинская C, ищем по вхождению
            category: field("категория дела", "категория"),
            result: field("текущее состояние", "результат рассмотрения", "решение первой инстанции"),
            receiptDate: field("дата поступления", "дата регистрации"),
            legalForceDate: field("дата вступления"),
            higherNumber: field("вышестоящей инстанции").flatMap(firstCaseNumberLike),
            sessions: sessions,
            participants: participants,
            actLinks: actLinks,
            rawText: rawText)
    }

    // MARK: - helpers

    private static func headerTable(in doc: Document, containing needle: String) -> Element? {
        for t in (try? doc.select("table").array()) ?? [] {
            if tableHeaders(t).contains(where: { $0.localizedCaseInsensitiveContains(needle) }) { return t }
        }
        return nil
    }

    private static func tableHeaders(_ table: Element) -> [String] {
        ((try? table.select("th").array()) ?? [])
            .map { (try? $0.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    private static func value(_ cells: [String], _ i: Int) -> String? {
        guard i >= 0, cells.indices.contains(i) else { return nil }
        let v = cells[i].trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private static func parseDateTime(_ s: String) -> (date: String, time: String?)? {
        guard let r = s.range(of: #"^\d{2}\.\d{2}\.\d{4}"#, options: .regularExpression) else { return nil }
        let date = String(s[r])
        let rest = s[r.upperBound...]
        let time = rest.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression).map { String(rest[$0]) }
        return (date, time)
    }

    private static func firstCaseNumberLike(_ s: String) -> String? {
        s.range(of: #"\d+[а-яё]?-\d+/\d{4}"#, options: .regularExpression).map { String(s[$0]) }
    }

    /// `<p class="table-bold-text">Роль</p>Имя<br/>Имя…` → ["Роль: Имя", …].
    static func parseParties(_ rawHTML: String) -> [String] {
        // Raw-строка Swift (#"…"#): кавычки пишутся как есть, без экранирования.
        let pattern = #"<p class="table-bold-text">([\s\S]*?)</p>([\s\S]*?)(?=<p class="table-bold-text">|$)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = rawHTML as NSString
        var out: [String] = []
        for m in re.matches(in: rawHTML, range: NSRange(location: 0, length: ns.length)) {
            let role = stripTags(ns.substring(with: m.range(at: 1)))
            for chunk in splitBR(ns.substring(with: m.range(at: 2))) {
                let name = stripTags(chunk)
                if !role.isEmpty && !name.isEmpty { out.append("\(role): \(name)") }
            }
        }
        return out
    }

    private static func splitBR(_ s: String) -> [String] {
        s.replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
