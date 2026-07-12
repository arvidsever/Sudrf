//  MosGorSudParsers.swift — Sudrf
//  Разбор HTML портала mos-gorsud.ru (выдача поиска и карточка дела).
//
//  ВНИМАНИЕ: селекторы best-effort — живой HTML портала из песочницы недоступен,
//  фикстуры ещё не сняты (см. TODO в MosGorSudParserTests). Парсеры написаны
//  максимально терпимо: опорная точка выдачи — ссылки на карточку (/details/),
//  поля карточки — пары «подпись → значение» и распознавание по формату
//  (УИД, даты дд.мм.гггг).

import Foundation
import SwiftSoup

public enum MosGorSudResultsParser {

    /// УИД вида 77RS0021-01-2024-001234-56.
    static let uidRegex = try! NSRegularExpression(
        pattern: #"\b\d{2}[A-ZА-Я]{2}\d{4}-\d{2}-\d{4}-\d{6}-\d{2}\b"#)

    public static func parse(html: String) throws -> [MosGorSudResult] {
        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw SudrfError.parsing("SwiftSoup не смог разобрать выдачу mos-gorsud") }

        // Опорная точка — ссылки на карточку дела.
        let anchors = (try? doc.select("a[href*=/details/]").array()) ?? []
        var results: [MosGorSudResult] = []
        for a in anchors {
            let text = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let href = (try? a.attr("href")) ?? ""
            let cardURL = absoluteURL(href)

            var cells: [String] = []
            if let row = a.parents().array().first(where: { $0.tagName() == "tr" }),
               let tds = try? row.select("td") {
                cells = tds.array().compactMap { try? $0.text() }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            let joined = cells.joined(separator: " · ")

            results.append(MosGorSudResult(
                caseNumber: text,
                uid: firstUID(in: joined),
                court: cells.first { cell in
                    let lower = cell.lowercased()
                    return ["районный суд", "городской суд", "областной суд", "верховный суд", "гарнизонный суд", "межрайонный суд"].contains { lower.contains($0) }
                },
                judge: nil,   // в выдаче судья не размечен однозначно — берётся из карточки
                receiptDate: firstDate(in: cells),
                participants: joined.isEmpty ? nil : joined,
                result: nil,
                cardURL: cardURL))
        }
        return results
    }

    static func firstUID(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = uidRegex.firstMatch(in: text, range: range),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    static func firstDate(in cells: [String]) -> String? {
        cells.first { $0.range(of: #"^\d{2}\.\d{2}\.\d{4}$"#, options: .regularExpression) != nil }
    }

    static func absoluteURL(_ href: String) -> URL? {
        if href.hasPrefix("http") { return URL(string: href) }
        let path = href.hasPrefix("/") ? href : "/\(href)"
        return URL(string: "https://\(MosGorSudEndpoint.host)\(path)")
    }
}

public enum MosGorSudCardParser {

    public static func parse(html: String) throws -> MosGorSudCard {
        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw SudrfError.parsing("SwiftSoup не смог разобрать карточку mos-gorsud") }

        let rawText = (try? doc.text()) ?? ""

        // Пары «подпись → значение»: строки таблиц из двух ячеек и dt/dd.
        var fields: [String: String] = [:]
        if let rows = try? doc.select("tr").array() {
            for row in rows {
                guard let cells = try? row.select("th, td").array(), cells.count == 2,
                      let k = try? cells[0].text(), let v = try? cells[1].text() else { continue }
                fields[normalize(k)] = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let dts = try? doc.select("dt").array() {
            for dt in dts {
                guard let dd = try? dt.nextElementSibling(), dd.tagName() == "dd",
                      let k = try? dt.text(), let v = try? dd.text() else { continue }
                fields[normalize(k)] = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        func field(_ keys: String...) -> String? {
            for k in keys {
                if let v = fields[normalize(k)], !v.isEmpty { return v }
            }
            return nil
        }

        // Заседания: строки таблиц, начинающиеся с даты дд.мм.гггг
        // (кроме пары «подпись → значение», уже разобранной выше).
        var sessions: [CaseSession] = []
        if let rows = try? doc.select("tr").array() {
            for row in rows {
                guard let cells = try? row.select("td").array(), cells.count >= 3 else { continue }
                let texts = cells.compactMap { try? $0.text() }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard let first = texts.first,
                      first.range(of: #"^\d{2}\.\d{2}\.\d{4}"#, options: .regularExpression) != nil
                else { continue }
                let date = String(first.prefix(10))
                let time = first.count > 10
                    ? String(first.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                    : nil
                sessions.append(CaseSession(date: date,
                                            time: (time?.isEmpty ?? true) ? nil : time,
                                            event: texts.count > 1 ? texts[1] : "Событие",
                                            result: texts.count > 2 ? texts[2] : nil))
            }
        }

        // Тексты актов — вложения (PDF/DOC), инлайновых текстов на портале нет.
        var actLinks: [URL] = []
        if let anchors = try? doc.select("a[href]").array() {
            for a in anchors {
                let href = (try? a.attr("href")) ?? ""
                let lower = href.lowercased()
                guard lower.contains("attach") || lower.hasSuffix(".pdf")
                    || lower.hasSuffix(".doc") || lower.hasSuffix(".docx") else { continue }
                if let url = MosGorSudResultsParser.absoluteURL(href) { actLinks.append(url) }
            }
        }

        return MosGorSudCard(
            uid: field("Уникальный идентификатор дела", "УИД")
                ?? MosGorSudResultsParser.firstUID(in: rawText),
            caseNumber: field("Номер дела", "Номер дела ~ материала", "№ дела"),
            court: field("Суд", "Наименование суда"),
            judge: field("Судья", "Судья (докладчик)", "Председательствующий судья"),
            category: field("Категория дела", "Категория", "Статья"),
            result: field("Результат", "Результат рассмотрения", "Текущее состояние"),
            receiptDate: field("Дата регистрации", "Дата поступления"),
            legalForceDate: field("Дата вступления в законную силу"),
            sessions: sessions,
            participants: field("Стороны", "Участники").map { [$0] } ?? [],
            actLinks: actLinks,
            rawText: rawText)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
