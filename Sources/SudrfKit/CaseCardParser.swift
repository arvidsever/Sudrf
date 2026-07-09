//  CaseCardParser.swift — Sudrf
//
//  Разбор карточки дела (`name_op=case`). ВАЖНО: `name_op=case` — это КАРТОЧКА
//  (метаданные + движение + вкладки), а НЕ страница текста акта. Текст акта на
//  этом движке лежит ИНЛАЙН внутри вкладки «СУДЕБНЫЕ АКТЫ» (блоки `cont_doc{N}`),
//  поэтому отдельный запрос (`name_op=doc`) не нужен.
//
//  Прежняя версия делала `body.text()` всей карточки и резала от первого «УИД»
//  до «опубликовано». Первый «УИД» — в шапке метаданных, поэтому в текст акта
//  попадала «простыня» из метаданных + движения + сторон. Исправлено: разбор
//  идёт по вкладкам/контейнерам, а не позиционно.
//
//  Структура (проверено на реальных карточках СГС / ВС РК / 3 КСОЮ, Республика Коми):
//   • Вкладки `<li id="tab{N}">` ↔ контейнеры `<div id="cont{N}">`.
//     Набор и ПОРЯДОК вкладок различаются по инстанциям, поэтому контейнеры
//     ищутся по содержимому, а не по номеру:
//       – метаданные  → контейнер с «Уникальный идентификатор дела»
//                        (вкладка «ДЕЛО» / «ПРОИЗВОДСТВО»);
//       – движение     → таблица с заголовком «ДВИЖЕНИЕ ДЕЛА» или «СЛУШАНИЯ»;
//       – акты         → блоки `<div id="cont_doc{N}">` под ярлыками
//                        `<li id="tab_doc{N}">` («Судебный акт #N (тип)»).
//   • Таблица движения — «событие первое»: колонки
//       Наименование события | Дата | Время | Место проведения | Результат события | …
//     (поэтому старая проверка «дата в колонке 0» отбрасывала все строки).

import Foundation
import SwiftSoup

public enum CaseCardParser {

    public static func parse(html: String) throws -> CaseCard {
        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw SudrfError.parsing("SwiftSoup не смог разобрать карточку") }

        let body: Element? = doc.body() ?? doc
        let rawText = body.map { normalize(blockText($0)) } ?? ""

        // «Винтажная» версия модуля (VNKOD-суды: Воронеж, Ульяновск, Амур и др.)
        // рисует карточку совсем иначе: вкладки tab_content_* вместо cont{N}.
        if isVintage(doc) {
            return parseVintage(doc, html: html, rawText: rawText)
        }

        let meta = parseMeta(doc)
        let sessions = parseMovement(doc)
        let acts = parseActs(doc)

        let uid = meta["уникальный идентификатор дела"]
        let judge = meta["судья"]
            ?? meta["председательствующий судья"]
            ?? meta["судья-докладчик"]
        let result = meta["результат рассмотрения"]
            ?? meta["результат кассационного рассмотрения"]
        let receipt = meta["дата поступления"]
        let decision = meta["дата рассмотрения"]
        let legalForce = meta["дата вступления в законную силу"]
        let category = meta["категория дела"]
        let caseNumber = parseCaseNumber(html: html)
        let appeals = parseAppeals(doc)
        let parties = parseParties(doc)

        return CaseCard(rawText: rawText,
                        actText: acts.first?.body,
                        sessions: sessions,
                        judge: judge,
                        result: result,
                        uid: uid,
                        caseNumber: caseNumber,
                        category: category,
                        receiptDate: receipt,
                        decisionDate: decision,
                        legalForceDate: legalForce,
                        acts: acts,
                        appeals: appeals,
                        parties: parties)
    }

    // MARK: - Винтажная карточка (VNKOD-суды)
    //
    // Разметка выверена по живой карточке Заволжского районного суда
    // г. Ульяновска (фикстура zavolgskiy_card.html):
    //   • шапка: <div class="case-num">ДЕЛО № …</div>;
    //   • вкладки #tab_content_Case (пары <td><b>метка</b></td><td>значение</td>),
    //     #tab_content_ClaimList (Вид требования | Решение | Дата решения),
    //     #tab_content_EventList (Наименование события | Результат события |
    //     Основания | Дата события | Время события | Дата размещения),
    //     #tab_content_PersonList (Процессуальный статус | ФИО | ИНН | КПП | ОГРН);
    //   • у таблиц есть мобильные дубли в div.block-mobile — берётся только
    //     настольная таблица (.non-list), иначе всё задваивается;
    //   • акты: #tab_id_DocumentN + #tab_content_DocumentN (Самарский облсуд).

    static func isVintage(_ doc: Document) -> Bool {
        if (try? doc.select("#case_bookmarks").first()) ?? nil != nil { return true }
        return !(((try? doc.select("div[id^=tab_content_]").array()) ?? []).isEmpty)
    }

    private static func parseVintage(_ doc: Document, html: String, rawText: String) -> CaseCard {
        // Метаданные: вкладка «Дело». УИД может лежать внутри <a class="dashed">.
        var meta: [String: String] = [:]
        if let cont = vintageTab(doc, "Case") {
            for row in (try? cont.select("tr").array()) ?? [] {
                let cells = (try? row.select("td").array()) ?? []
                guard cells.count >= 2 else { continue }
                let key = ((try? cells[0].text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let val = ((try? cells[1].text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !val.isEmpty, key.count <= 60 else { continue }
                let k = key.lowercased()
                if meta[k] == nil { meta[k] = val }
            }
        }

        let acts = vintageActs(doc)

        return CaseCard(rawText: rawText,
                        actText: acts.first?.body,
                        sessions: vintageSessions(doc),
                        judge: meta["председательствующий судья"]
                            ?? meta["судья"]
                            ?? meta["докладчик"],
                        result: meta["результат рассмотрения"]
                            ?? meta["решение"]
                            ?? vintageResult(doc),
                        uid: meta["уникальный идентификатор дела"],
                        caseNumber: parseCaseNumber(html: html),
                        category: meta["категория"] ?? meta["категория дела"],
                        receiptDate: meta["дата поступления"],
                        decisionDate: meta["дата рассмотрения"],
                        legalForceDate: meta["дата вступления в законную силу"],
                        acts: acts,
                        appeals: [],   // вкладки «Обжалование» в винтажной карточке нет
                        parties: vintageParties(doc))
    }

    /// Вкладка по имени: #tab_content_<name>.
    private static func vintageTab(_ doc: Document, _ name: String) -> Element? {
        (try? doc.select("#tab_content_\(name)").first()) ?? nil
    }

    /// Настольная таблица вкладки — с классом `none-mobile` (мобильный дубль в
    /// div.block-mobile его лишён). Второй классовый маркер разнится по судам:
    /// Ульяновск — «non-list», Благовещенск — «list», поэтому опора на него
    /// ненадёжна.
    private static func vintageDesktopRows(_ tab: Element) -> [Element] {
        guard let table = (try? tab.select("table.none-mobile").first()) ?? nil else { return [] }
        return (try? table.select("tbody tr").array()) ?? []
    }

    private static func vintageSessions(_ doc: Document) -> [CaseSession] {
        guard let tab = vintageTab(doc, "EventList") else { return [] }
        // Индексы колонок — по шапке (thead), чтобы пережить перестановки.
        // Названия колонок разнятся по судам: Ульяновск — «Дата события» /
        // «Время события», Благовещенск — «Дата» / «Время слушания».
        var cols: [String: Int] = [:]
        if let table = (try? tab.select("table.none-mobile").first()) ?? nil,
           let head = (try? table.select("thead tr").first()) ?? nil {
            let texts = ((try? head.select("td, th").array()) ?? [])
                .map { (((try? $0.text()) ?? "")).trimmingCharacters(in: .whitespaces) }
            for (j, t) in texts.enumerated() {
                if t.contains("Наименование события")     { cols["event"] = j }
                else if t.contains("Результат события")   { cols["result"] = j }
                else if t.contains("Дата события") || t == "Дата" { cols["date"] = j }
                else if t.hasPrefix("Время")              { cols["time"] = j }
                else if t.contains("Место проведения")    { cols["room"] = j }
            }
        }
        guard let eventCol = cols["event"] else { return [] }

        var sessions: [CaseSession] = []
        for row in vintageDesktopRows(tab) {
            let texts = ((try? row.select("td").array()) ?? [])
                .map { (((try? $0.text()) ?? "")).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard eventCol < texts.count, !texts[eventCol].isEmpty else { continue }
            func value(_ key: String) -> String? {
                guard let j = cols[key], j < texts.count, !texts[j].isEmpty else { return nil }
                return texts[j]
            }
            sessions.append(CaseSession(date: value("date") ?? "",
                                        time: value("time"),
                                        room: value("room"),
                                        event: texts[eventCol],
                                        result: value("result")))
        }
        return sessions
    }

    private static func vintageParties(_ doc: Document) -> CaseParties {
        var parties = CaseParties()
        guard let tab = vintageTab(doc, "PersonList") else { return parties }
        for row in vintageDesktopRows(tab) {
            let cells = (try? row.select("td").array()) ?? []
            guard cells.count >= 2 else { continue }
            let role = ((try? cells[0].text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = ((try? cells[1].text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !role.isEmpty, !name.isEmpty else { continue }
            if role.lowercased().contains("статус лица") { continue }   // шапка колонок
            parties.add(role: role, name: name)
        }
        return parties
    }

    /// Результат дела: колонка «Решение» вкладки «Требования» (если заполнена).
    private static func vintageResult(_ doc: Document) -> String? {
        guard let tab = vintageTab(doc, "ClaimList") else { return nil }
        for row in vintageDesktopRows(tab) {
            let texts = ((try? row.select("td").array()) ?? [])
                .map { (((try? $0.text()) ?? "")).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard texts.count >= 2 else { continue }
            if !texts[1].isEmpty { return texts[1] }
        }
        return nil
    }

    /// Тексты актов старой VNKOD-карточки: ярлык `tab_id_DocumentN`, тело —
    /// `tab_content_DocumentN`.
    private static func vintageActs(_ doc: Document) -> [CaseActText] {
        var labels: [Int: String] = [:]
        for li in (try? doc.select("li[id^=tab_id_Document]").array()) ?? [] {
            guard let n = number(in: (try? li.attr("id")) ?? "") else { continue }
            let label = ((try? li.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { labels[n] = label }
        }

        var bodies: [(Int, Element)] = []
        for div in (try? doc.select("div[id^=tab_content_Document]").array()) ?? [] {
            guard let n = number(in: (try? div.attr("id")) ?? "") else { continue }
            bodies.append((n, div))
        }
        bodies.sort { $0.0 < $1.0 }

        var acts: [CaseActText] = []
        for (n, div) in bodies {
            let body = normalize(blockText(div))
            guard !body.isEmpty else { continue }
            let label = labels[n] ?? "Судебный акт #\(n)"
            acts.append(CaseActText(id: "doc\(n)",
                                    kind: actKind(from: label),
                                    label: label,
                                    body: body))
        }
        return acts
    }

    // MARK: - Участники (вкладки «СТОРОНЫ [ПО ДЕЛУ]» / «УЧАСТНИКИ» / «ЛИЦА»)
    //
    //  Тип таблицы участников определяется по ЗАГОЛОВКАМ КОЛОНОК, а не по тексту
    //  вкладки `<th>` — он варьируется по инстанциям и виду дела («СТОРОНЫ ПО
    //  ДЕЛУ», «СТОРОНЫ ПО ДЕЛУ (ТРЕТЬИ ЛИЦА)», «УЧАСТНИКИ», «СТОРОНЫ», «ЛИЦА»):
    //   • колонка «Вид лица…» → обычная таблица сторон «роль | имя»;
    //   • иначе колонка «Перечень статей» → таблица ЛИЦ (уголовные подсудимые):
    //     «Фамилия / наименование | Перечень статей | …» — колонка 0 это ИМЯ.
    //  Порядок проверок КРИТИЧЕН: у КоАП таблица «СТОРОНЫ ПО ДЕЛУ» содержит ОБЕ
    //  колонки — «Вид лица» И «Перечень статей», поэтому «Вид лица» проверяется
    //  первым (иначе КоАП уехал бы в разбор ЛИЦ и стал бы «Подсудимым»).
    //  Уголовное дело публикует ДВЕ таблицы (вкладки «ЛИЦА» + «СТОРОНЫ»); КоАП —
    //  только «СТОРОНЫ ПО ДЕЛУ» с ролью «ПРИВЛЕКАЕМОЕ ЛИЦО» (таблицы ЛИЦ нет).

    private static func parseParties(_ doc: Document) -> CaseParties {
        var parties = CaseParties()
        for table in (try? doc.select("table").array()) ?? [] {
            let headers = columnHeaders(table)
            if headers.contains(where: { $0.contains("вид лица") }) {
                parsePartiesTable(table, into: &parties)          // «СТОРОНЫ» — роль | имя
            } else if headers.contains(where: { $0.contains("перечень статей") }) {
                parsePersonsTable(table, into: &parties)          // «ЛИЦА» — подсудимые
            }
        }
        return parties
    }

    /// Тексты (в нижнем регистре) ячеек строки-шапки колонок таблицы участников —
    /// первого `tr`, у которого есть `<td>` (строка с одним `<th>`-названием
    /// вкладки пропускается, так как не содержит `<td>`).
    private static func columnHeaders(_ table: Element) -> [String] {
        for row in (try? table.select("tr").array()) ?? [] {
            let cells = (try? row.select("td").array()) ?? []
            guard !cells.isEmpty else { continue }
            return cells.map {
                (((try? $0.text()) ?? "")).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }
        return []
    }

    /// Обычная таблица сторон: строки «Вид лица | ФИО (наименование)». Шапка
    /// колонок («Вид лица…») пропускается; роль → корзина — через CaseParties.
    /// У КоАП тут есть и колонка «Перечень статей» — цепляем её к привлекаемому
    /// лицу (у защитника/представителя ячейка пуста).
    private static func parsePartiesTable(_ table: Element, into parties: inout CaseParties) {
        let headers = columnHeaders(table)
        let articleCol = headers.firstIndex { $0.contains("перечень статей") }
        for row in (try? table.select("tr").array()) ?? [] {
            let cells = (try? row.select("td").array()) ?? []
            guard cells.count >= 2 else { continue }
            let role = ((try? cells[0].text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = ((try? cells[1].text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !role.isEmpty, !name.isEmpty else { continue }
            if role.lowercased().contains("вид лица") { continue }   // шапка колонок
            let articles = articleCol.flatMap { $0 < cells.count ? cells[$0] : nil }
                .map { (((try? $0.text()) ?? "")).trimmingCharacters(in: .whitespacesAndNewlines) }
            parties.add(role: role, name: name, articles: articles)
        }
    }

    /// Таблица «ЛИЦА» уголовной карточки: «Фамилия / наименование | Перечень
    /// статей | Дата… | Результат…». Роль в вёрстке не указана — синтезируем
    /// «Подсудимый» (эта таблица есть только в УПК; у КоАП её нет), а перечень
    /// статей кладём в под-роль: «Подсудимый · ст.158 ч.3 п.г УК РФ».
    private static func parsePersonsTable(_ table: Element, into parties: inout CaseParties) {
        // Индексы колонок «имя» и «статьи» — по шапке, с фолбэком 0/1.
        let headers = columnHeaders(table)
        let nameCol = headers.firstIndex { $0.contains("фамилия") || $0.contains("наименование") } ?? 0
        let articleCol = headers.firstIndex { $0.contains("перечень статей") } ?? 1
        for row in (try? table.select("tr").array()) ?? [] {
            let cells = (try? row.select("td").array()) ?? []
            guard cells.count >= 2, nameCol < cells.count else { continue }
            let name = ((try? cells[nameCol].text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.lowercased().contains("фамилия") else { continue }   // шапка
            let articles = articleCol < cells.count
                ? ((try? cells[articleCol].text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            // Роль-ярлык нужен только для маршрутизации (→ УПК, сторона защиты);
            // сам перечень статей идёт отдельным полем, чтобы в шапке рисоваться
            // после ФИО через значок щита, без слова «Подсудимый».
            parties.add(role: "Подсудимый", name: name, articles: articles)
        }
    }

    // MARK: - Вкладка «Обжалование»

    /// Записи вкладки «Обжалование решений, определений (пост.)» из карточки
    /// 1-й инстанции. Каждая ЖАЛОБА № N — отдельная таблица `tablcont`, внутри —
    /// строки «Вид жалобы (представления)», «Вышестоящий суд» и вложенная таблица
    /// «ДВИЖЕНИЕ ЖАЛОБЫ» с датами и результатом. Источник истины для различения
    /// круг апелляции/кассации vs частная жалоба — поле «Вид жалобы».
    private static func parseAppeals(_ doc: Document) -> [AppealRecord] {
        let marker = "вид жалобы (представлен"
        // Берём «самые внутренние» таблицы с маркером: те, где маркер есть, но ни в
        // одной вложенной таблице его нет. Так отсекаются объемлющие layout-таблицы
        // (важно, когда жалоба одна — тогда счётчик вхождений не помог бы).
        func contains(_ el: Element) -> Bool {
            occurrences(of: marker, in: ((try? el.text()) ?? "").lowercased()) >= 1
        }
        let tables = ((try? doc.select("table").array()) ?? []).filter { t in
            guard contains(t) else { return false }
            let inner = ((try? t.select("table").array()) ?? []).filter { $0 !== t }
            return !inner.contains(where: contains)
        }
        var out: [AppealRecord] = []
        for table in tables {
            var map: [String: String] = [:]
            for row in (try? table.select("tr").array()) ?? [] {
                let cells = (try? row.select("td, th").array()) ?? []
                guard cells.count >= 2 else { continue }
                let key = ((try? cells[0].text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let val = ((try? cells[1].text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !val.isEmpty, key.count <= 60 else { continue }
                if map[key] == nil { map[key] = val }
            }
            guard let rawKind = map["вид жалобы (представления)"] else { continue }
            out.append(AppealRecord(
                kind: appealKind(from: rawKind),
                rawKind: rawKind,
                higherCourt: map["вышестоящий суд"],
                sentUpDate: map["направлено в вышестоящую инстанцию"],
                returnedDate: map["возвращено из вышестоящей инстанции"],
                hearingDate: map["дата рассмотрения жалобы"],
                result: map["результат обжалования"]))
        }
        return out
    }

    /// «Вид жалобы (представления)» → тип. Порядок проверок важен: частная жалоба
    /// проверяется до апелляции/кассации.
    static func appealKind(from raw: String) -> AppealKind {
        let s = raw.lowercased()
        if s.contains("частн")   { return .privateComplaint }  // «Частная жалоба»
        if s.contains("кассац")  { return .cassation }         // «Кассационная …»
        if s.contains("апелляц") { return .appeal }            // «Апелляционная …»
        return .other            // замечания на протокол, надзор и пр. — не круг
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0, idx = haystack.startIndex
        while let r = haystack.range(of: needle, range: idx..<haystack.endIndex) {
            count += 1; idx = r.upperBound
        }
        return count
    }

    // MARK: - Контейнеры вкладок

    /// Контейнеры `<div id="cont{N}">` (без `cont_doc…`), отсортированные по N.
    private static func tabContainers(_ doc: Document) -> [Element] {
        let all = (try? doc.select("div[id^=cont]").array()) ?? []
        let containers = all.filter { el in
            let id = (try? el.attr("id")) ?? ""
            return id.range(of: #"^cont\d+$"#, options: .regularExpression) != nil
        }
        return containers.sorted { a, b in
            (number(in: (try? a.attr("id")) ?? "") ?? 0) < (number(in: (try? b.attr("id")) ?? "") ?? 0)
        }
    }

    private static func number(in s: String) -> Int? {
        guard let r = s.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    // MARK: - Метаданные (вкладка «ДЕЛО» / «ПРОИЗВОДСТВО»)

    /// Карта «метка (нижний регистр) → значение» из контейнера, где встречается
    /// «Уникальный идентификатор дела». Берётся первое значение для каждой метки.
    private static func parseMeta(_ doc: Document) -> [String: String] {
        let marker = "уникальный идентификатор дела"
        let cont = tabContainers(doc).first { el in
            ((try? el.text()) ?? "").lowercased().contains(marker)
        }
        var map: [String: String] = [:]
        guard let cont else { return map }
        for row in (try? cont.select("tr").array()) ?? [] {
            let cells = (try? row.select("td, th").array()) ?? []
            guard cells.count >= 2 else { continue }
            let key = ((try? cells[0].text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let val = ((try? cells[1].text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !val.isEmpty, key.count <= 60 else { continue }
            let k = key.lowercased()
            if map[k] == nil { map[k] = val }
        }
        return map
    }

    /// Номер дела из заголовка карточки: «ДЕЛО № …» / «ПРОИЗВОДСТВО № …».
    /// Для КСОЮ это, например, «8Г-2430/2026 [88-4097/2026]».
    private static func parseCaseNumber(html: String) -> String? {
        guard let raw = firstMatch(#"(?:ДЕЛО|ПРОИЗВОДСТВО)\s*№\s*([^<\n]{1,60})"#, in: html) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Движение дела

    private static func parseMovement(_ doc: Document) -> [CaseSession] {
        guard let table = movementTable(doc) else { return [] }
        let rows = (try? table.select("tr").array()) ?? []

        // Находим строку-шапку колонок и индексы нужных колонок.
        var cols: [String: Int] = [:]
        var headerIndex = -1
        for (i, row) in rows.enumerated() {
            let cells = (try? row.select("td, th").array()) ?? []
            let texts = cells.map { (((try? $0.text()) ?? "")).trimmingCharacters(in: .whitespaces) }
            let joined = texts.joined(separator: " ")
            guard joined.contains("Наименование события") else { continue }
            for (j, t) in texts.enumerated() {
                if t.contains("Наименование события")      { cols["event"] = j }
                else if t == "Дата"                        { cols["date"] = j }
                else if t == "Время"                       { cols["time"] = j }
                else if t.contains("Место проведения")     { cols["room"] = j }
                else if t.contains("Результат события")    { cols["result"] = j }
            }
            headerIndex = i
            break
        }
        guard headerIndex >= 0, let eventCol = cols["event"] else { return [] }

        func value(_ texts: [String], _ key: String) -> String? {
            guard let j = cols[key], j >= 0, j < texts.count else { return nil }
            let v = texts[j]
            return v.isEmpty ? nil : v
        }

        var sessions: [CaseSession] = []
        for row in rows[(headerIndex + 1)...] {
            let cells = (try? row.select("td").array()) ?? []
            guard !cells.isEmpty else { continue }
            let texts = cells.map { (((try? $0.text()) ?? "")).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard eventCol < texts.count else { continue }
            let event = texts[eventCol]
            guard !event.isEmpty else { continue }
            sessions.append(CaseSession(date: value(texts, "date") ?? "",
                                        time: value(texts, "time"),
                                        room: value(texts, "room"),
                                        event: event,
                                        result: value(texts, "result")))
        }
        return sessions
    }

    /// Таблица, заголовок (`<th>`) которой содержит «ДВИЖЕНИЕ ДЕЛА» или «СЛУШАНИЯ».
    private static func movementTable(_ doc: Document) -> Element? {
        for table in (try? doc.select("table").array()) ?? [] {
            for th in (try? table.select("th").array()) ?? [] {
                let t = ((try? th.text()) ?? "").uppercased()
                if t.contains("ДВИЖЕНИЕ ДЕЛА") || t.contains("СЛУШАНИЯ") { return table }
            }
        }
        return nil
    }

    // MARK: - Тексты судебных актов (инлайн, вкладка «СУДЕБНЫЕ АКТЫ»)

    private static func parseActs(_ doc: Document) -> [CaseActText] {
        // Ярлыки: <li id="tab_doc{N}"><a …>Судебный акт #N (тип)</a></li>
        var labels: [Int: String] = [:]
        for li in (try? doc.select("li[id^=tab_doc]").array()) ?? [] {
            guard let n = number(in: (try? li.attr("id")) ?? "") else { continue }
            var label = ""
            if let a = (try? li.select("a"))?.first(), let t = try? a.text() {
                label = t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            labels[n] = label
        }
        // Тела: <div id="cont_doc{N}"> … </div>
        var bodies: [(Int, Element)] = []
        for div in (try? doc.select("div[id^=cont_doc]").array()) ?? [] {
            guard let n = number(in: (try? div.attr("id")) ?? "") else { continue }
            bodies.append((n, div))
        }
        bodies.sort { $0.0 < $1.0 }

        var acts: [CaseActText] = []
        for (n, div) in bodies {
            let body = normalize(blockText(div))
            guard !body.isEmpty else { continue }
            let label = labels[n] ?? "Судебный акт #\(n)"
            acts.append(CaseActText(id: "doc\(n)",
                                    kind: actKind(from: label),
                                    label: label,
                                    body: body))
        }
        return acts
    }

    /// Тип акта из ярлыка «Судебный акт #1 (Решения)» → «Решения».
    private static func actKind(from label: String) -> String {
        guard let open = label.lastIndex(of: "("),
              let close = label.lastIndex(of: ")"),
              open < close else { return "" }
        let inner = label[label.index(after: open)..<close]
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Извлечение текста с сохранением абзацев

    private static let blockTags: Set<String> = [
        "p", "div", "tr", "li", "table", "section", "article", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
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

    /// Схлопывает пробелы внутри строк и серии пустых строк, сохраняя абзацы.
    private static func normalize(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                  .trimmingCharacters(in: .whitespaces)
            }
        var result: [String] = []
        for line in lines {
            if line.isEmpty {
                if let last = result.last, !last.isEmpty { result.append("") }
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Регэксп-хелпер

    private static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }
}
