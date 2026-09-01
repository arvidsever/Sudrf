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
//       – движение     → таблица с заголовком «ДВИЖЕНИЕ ДЕЛА»,
//                        «ДВИЖЕНИЕ МАТЕРИАЛА» или «СЛУШАНИЯ»;
//       – акты         → блоки `<div id="cont_doc{N}">` под ярлыками
//                        `<li id="tab_doc{N}">` («Судебный акт #N (тип)»).
//   • Таблица движения — «событие первое»: колонки
//       Наименование события | Дата | Время | Место проведения | Результат события | …
//     (поэтому старая проверка «дата в колонке 0» отбрасывала все строки).

import Foundation
import SwiftSoup

public enum CaseCardParser {

    /// `cardURL` must be the effective response URL, not a reconstructed card
    /// URL: a published predecessor link can be relative to a redirected host.
    public static func parse(html: String, cardURL: URL? = nil) throws -> CaseCard {
        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw SudrfError.parsing("SwiftSoup не смог разобрать карточку") }

        let body: Element? = doc.body() ?? doc
        let rawText = body.map {
            HTMLTextExtractor.normalizedBlockText($0, style: .sudrf)
        } ?? ""

        // Некоторые sudrf-серверы отвечают HTTP 200 и общей оболочкой сайта,
        // но вместо карточки кладут штатную заглушку «Информация временно
        // недоступна… Попробуйте обратиться позже». Без этой проверки parser
        // возвращал валидный CaseCard с пустыми полями, а RefreshCenter считал
        // fetch успешным и затирал сохранённые УИД, движение, стороны и акты.
        // Два маркера уменьшают риск принять обычное уведомление в chrome за
        // недоступную карточку.
        let lowerText = rawText.lowercased()
        if lowerText.contains("информация временно недоступна"),
           lowerText.contains("попробуйте обратиться позже") {
            throw SudrfError.caseCardTemporarilyUnavailable
        }

        // «Винтажная» версия модуля (VNKOD-суды: Воронеж, Ульяновск, Амур и др.)
        // рисует карточку совсем иначе: вкладки tab_content_* вместо cont{N}.
        let previousRegistration = parsePreviousRegistration(doc, cardURL: cardURL)

        if isVintage(doc) {
            return try parseVintage(doc, html: html, rawText: rawText,
                                    previousRegistration: previousRegistration)
        }

        let meta = parseMeta(doc)
        let sessions = sortSessions(parseMovement(doc)
                                  + parseComplaintMovement(doc)
                                  + parseEarlyComplaintMovement(doc))
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
        let caseNumber = parseCaseNumber(doc: doc)
        let appeals = parseAppeals(doc)
        let parties = parseParties(doc)
        let lowerCourt = parseLowerCourt(doc)
        let executionDocuments = parseExecutionDocuments(doc)

        // HTTP 200 is not evidence of a card: WAF/protection pages are valid
        // HTML too. Accept only a shape that contributed card data.
        guard caseNumber != nil || !meta.isEmpty || !sessions.isEmpty || !acts.isEmpty
                || !appeals.isEmpty || !parties.isEmpty || lowerCourt != nil
                || !executionDocuments.isEmpty else {
            throw SudrfError.parsing("страница не содержит признаков карточки дела")
        }

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
                        parties: parties,
                        lowerCourt: lowerCourt,
                        previousRegistration: previousRegistration,
                        executionDocuments: executionDocuments)
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

    private static func parseVintage(_ doc: Document, html _: String, rawText: String,
                                     previousRegistration: PreviousRegistrationReference?) throws -> CaseCard {
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
        let executionDocuments = parseExecutionDocuments(doc)
        let sessions = vintageSessions(doc)
        let caseNumber = parseCaseNumber(doc: doc)
        let parties = vintageParties(doc)
        let lowerCourt = parseLowerCourt(doc)
        guard caseNumber != nil || !meta.isEmpty || !sessions.isEmpty || !acts.isEmpty
                || !parties.isEmpty || lowerCourt != nil || !executionDocuments.isEmpty else {
            throw SudrfError.parsing("страница не содержит признаков винтажной карточки дела")
        }

        return CaseCard(rawText: rawText,
                        actText: acts.first?.body,
                        sessions: sessions,
                        judge: meta["председательствующий судья"]
                            ?? meta["судья"]
                            ?? meta["докладчик"],
                        result: meta["результат рассмотрения"]
                            ?? meta["решение"]
                            ?? vintageResult(doc),
                        uid: meta["уникальный идентификатор дела"],
                        caseNumber: caseNumber,
                        category: meta["категория"] ?? meta["категория дела"],
                        receiptDate: meta["дата поступления"],
                        decisionDate: meta["дата рассмотрения"],
                        legalForceDate: meta["дата вступления в законную силу"],
                        acts: acts,
                        appeals: [],   // вкладки «Обжалование» в винтажной карточке нет
                        parties: parties,
                        lowerCourt: lowerCourt,
                        previousRegistration: previousRegistration,
                        executionDocuments: executionDocuments)
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
            let body = HTMLTextExtractor.normalizedBlockText(div, style: .sudrf)
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

    /// Ссылка в строке «Номер по предыдущей регистрации» — официальное
    /// доказательство continuity. Номер и адрес берутся из одной опубликованной
    /// строки; адрес не реконструируется из `case_id`/картотеки.
    private static func parsePreviousRegistration(
        _ doc: Document,
        cardURL: URL?
    ) -> PreviousRegistrationReference? {
        guard let cardURL else { return nil }
        for row in (try? doc.select("tr").array()) ?? [] {
            let cells = directCells(row, tags: ["td", "th"])
            guard cells.count >= 2,
                  normalizeHeader((try? cells[0].text()) ?? "")
                    == "номер по предыдущей регистрации",
                  let link = (try? cells[1].select("a[href]").first()) ?? nil else {
                continue
            }
            let caseNumber = ((try? link.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let href = (try? link.attr("href")) ?? ""
            guard !caseNumber.isEmpty, !href.isEmpty,
                  let url = URL(string: href, relativeTo: cardURL)?.absoluteURL else {
                continue
            }
            return PreviousRegistrationReference(caseNumber: caseNumber, url: url)
        }
        return nil
    }

    /// Вкладка апелляционной/кассационной карточки с реквизитами исходного
    /// рассмотрения. Ищем по заголовку, а не по номеру contN: порядок вкладок
    /// различается между судами и видами производства.
    private static func parseLowerCourt(_ doc: Document) -> LowerCourtReference? {
        let marker = "рассмотрение в нижестоящем суде"
        let vintage = (try? doc.select("div[id^=tab_content_]").array()) ?? []
        guard let cont = (tabContainers(doc) + vintage).first(where: {
            ((try? $0.text()) ?? "").lowercased().contains(marker)
        }) else { return nil }

        var map: [String: String] = [:]
        for row in (try? cont.select("tr").array()) ?? [] {
            let cells = (try? row.select("td, th").array()) ?? []
            guard cells.count >= 2 else { continue }
            let key = ((try? cells[0].text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = ((try? cells[1].text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            map[key] = value
        }

        let ref = LowerCourtReference(
            region: map["регион суда первой инстанции"],
            courtTitle: map["суд (судебный участок) первой инстанции"]
                ?? map["суд первой инстанции"],
            caseNumber: map["номер дела в первой инстанции"],
            decisionDate: map["дата решения первой инстанции"],
            judge: map["судья (мировой судья) первой инстанции"]
                ?? map["судья первой инстанции"])
        return ref.isEmpty ? nil : ref
    }

    // MARK: - Исполнительные листы

    /// Таблица «ИСПОЛНИТЕЛЬНЫЕ ЛИСТЫ» встречается в современных и винтажных
    /// карточках с одинаковыми заголовками, но с разным порядком вкладок.
    /// Поэтому ищем её по пяти колонкам, а не по номеру `contN`/названию
    /// вкладки. В строке допускаются пустые бумажный или электронный номер:
    /// реальные карточки публикуют оба вида документа в одной таблице.
    private static func parseExecutionDocuments(_ doc: Document) -> [CourtEnforcementDocument] {
        let required = ["date", "blank", "electronic", "status", "recipient"]
        for table in (try? doc.select("table").array()) ?? [] {
            let rows = directRows(table)
            var columns: [String: Int] = [:]
            var headerIndex: Int?
            for (index, row) in rows.enumerated() {
                let cells = (try? row.select("td, th").array()) ?? []
                let headers = cells.map { normalizeHeader((try? $0.text()) ?? "") }
                for (column, text) in headers.enumerated() {
                    if text.contains("дата выдачи") { columns["date"] = column }
                    else if text.contains("серия") && text.contains("номер") && text.contains("бланка") {
                        columns["blank"] = column
                    } else if text.contains("номер электронного") && text.contains("ид") {
                        columns["electronic"] = column
                    } else if text == "статус" || text.hasPrefix("статус ") {
                        columns["status"] = column
                    } else if text.contains("кому выдан") {
                        columns["recipient"] = column
                    }
                }
                if required.allSatisfy({ columns[$0] != nil }) {
                    headerIndex = index
                    break
                }
            }
            guard let headerIndex else { continue }

            var result: [CourtEnforcementDocument] = []
            for row in rows.dropFirst(headerIndex + 1) {
                let cells = directCells(row, tags: ["td"])
                guard !cells.isEmpty else { continue }
                func value(_ key: String) -> String? {
                    guard let column = columns[key], column < cells.count else { return nil }
                    let text = ((try? cells[column].text()) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                }
                let document = CourtEnforcementDocument(
                    date: value("date"),
                    blankNumber: value("blank"),
                    electronicID: value("electronic"),
                    courtStatus: value("status"),
                    recipient: value("recipient"))
                guard document.date != nil || document.blankNumber != nil
                        || document.electronicID != nil || document.courtStatus != nil
                        || document.recipient != nil else { continue }
                result.append(document)
            }
            return result
        }
        return []
    }

    private static func normalizeHeader(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00A0}", with: " ")
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func directRows(_ table: Element) -> [Element] {
        var rows: [Element] = []
        for child in table.children().array() {
            if child.tagName().lowercased() == "tr" {
                rows.append(child)
            } else if ["thead", "tbody", "tfoot"].contains(child.tagName().lowercased()) {
                rows.append(contentsOf: child.children().array().filter {
                    $0.tagName().lowercased() == "tr"
                })
            }
        }
        return rows
    }

    private static func directCells(_ row: Element, tags: Set<String>) -> [Element] {
        row.children().array().filter { tags.contains($0.tagName().lowercased()) }
    }

    /// Номер из заголовка карточки: «ДЕЛО № …», «ПРОИЗВОДСТВО № …»
    /// или «МАТЕРИАЛ № …».
    /// Для КСОЮ это, например, «8Г-2430/2026 [88-4097/2026]».
    private static func parseCaseNumber(doc: Document) -> String? {
        let headers = (try? doc.select(".casenumber, .case-num").array()) ?? []
        for header in headers {
            let text = ((try? header.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = text.wholeMatch(
                of: /^(?i:ДЕЛО|ПРОИЗВОДСТВО|МАТЕРИАЛ)\s*№\s*(.{1,60})$/
            ) else { continue }
            let trimmed = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Движение дела

    /// Раннее производство по жалобе на КСОЮ имеет отдельную вкладку
    /// «ЖАЛОБА», где пока опубликована только дата поступления. Это не та же
    /// таблица, что зрелая вкладка «ЖАЛОБЫ»: сохраняем единственный факт без
    /// догадки о стадии или результате.
    private static func parseEarlyComplaintMovement(_ doc: Document) -> [CaseSession] {
        guard let tab = ((try? doc.select("ul.tabs li").array()) ?? []).first(where: {
            normalizeHeader((try? $0.text()) ?? "") == "жалоба"
        }),
        let tabNumber = number(in: (try? tab.attr("id")) ?? ""),
        let container = (try? doc.select("#cont\(tabNumber)").first()) ?? nil else {
            return []
        }

        for table in (try? container.select("table").array()) ?? [] {
            for row in directRows(table) {
                let cells = directCells(row, tags: ["td", "th"])
                guard cells.count >= 2 else { continue }
                let key = normalizeHeader((try? cells[0].text()) ?? "")
                guard key == "дата поступления" else { continue }
                let date = ((try? cells[1].text()) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !date.isEmpty else { continue }
                return [CaseSession(date: date, event: "Поступление жалобы в суд")]
            }
        }
        return []
    }

    /// КСОЮ публикуют ранние этапы кассационного производства отдельной
    /// таблицей «ЖАЛОБЫ». В разных картотеках в ней семь или десять колонок;
    /// индексы не закреплены, поэтому читаем только опубликованные даты по
    /// заголовкам. Одна строка таблицы — одна жалоба.
    private static func parseComplaintMovement(_ doc: Document) -> [CaseSession] {
        guard let table = complaintTable(doc) else { return [] }
        let rows = directRows(table)

        var columns: [String: Int] = [:]
        var headerIndex: Int?
        for (index, row) in rows.enumerated() {
            let cells = directCells(row, tags: ["td", "th"])
            let headers = cells.map { normalizeHeader((try? $0.text()) ?? "") }
            guard headers.contains(where: { $0.contains("дата поступления")
                                            && !$0.contains("исправленной") }) else { continue }

            for (column, header) in headers.enumerated() {
                if header.contains("поступления исправленной") {
                    columns["corrected"] = column
                } else if header.contains("дата поступления") {
                    columns["received"] = column
                } else if header.contains("дата передачи") && header.contains("изучен") {
                    columns["study"] = column
                } else if header.contains("истребованием дела") {
                    columns["requested"] = column
                } else if header.contains("оставл") && header.contains("без движения") {
                    columns["withoutMovement"] = column
                } else if header.contains("срок") && header.contains("устранения") {
                    columns["deadline"] = column
                } else if header.contains("вынесения определения")
                            && header.contains("итогам изучения") {
                    // Some courts have a typo in this heading («Дта»), so do
                    // not require a literal «дата» prefix here.
                    columns["studied"] = column
                } else if header.contains("результат изучения") {
                    columns["studyResult"] = column
                }
            }
            guard columns["received"] != nil,
                  columns["study"] != nil || columns["studied"] != nil else { continue }
            headerIndex = index
            break
        }
        guard let headerIndex else { return [] }

        var sessions: [CaseSession] = []
        for row in rows.dropFirst(headerIndex + 1) {
            let values = directCells(row, tags: ["td"]).map {
                ((try? $0.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !values.isEmpty else { continue }
            func value(_ key: String) -> String? {
                guard let column = columns[key], column < values.count else { return nil }
                let value = values[column]
                return value.isEmpty ? nil : value
            }

            var rowSessions: [CaseSession] = []
            var datedActions: [(session: Int, column: Int)] = []
            if let date = value("received") {
                rowSessions.append(CaseSession(
                    date: date, event: "Поступление жалобы (представления) в суд"))
                if let column = columns["received"] {
                    datedActions.append((rowSessions.count - 1, column))
                }
            }

            let requested = value("requested").map { raw in
                let normalized = raw.lowercased()
                return normalized == "да" || normalized.contains("с истребованием")
            } ?? false
            if let date = value("study") {
                rowSessions.append(CaseSession(
                    date: date,
                    event: "Передача жалобы (представления) на изучение",
                    result: requested ? "С истребованием дела" : nil))
                if let column = columns["study"] {
                    datedActions.append((rowSessions.count - 1, column))
                }
            }

            if let date = value("withoutMovement") {
                let deadline = value("deadline").map {
                    "Срок для устранения недостатков: \($0)"
                }
                rowSessions.append(CaseSession(
                    date: date, event: "Оставление жалобы (представления) без движения",
                    result: deadline))
                if let column = columns["withoutMovement"] {
                    datedActions.append((rowSessions.count - 1, column))
                }
            }

            if let date = value("corrected") {
                rowSessions.append(CaseSession(
                    date: date,
                    event: "Поступление исправленной жалобы (представления) в суд"))
                if let column = columns["corrected"] {
                    datedActions.append((rowSessions.count - 1, column))
                }
            }

            if let date = value("studied") {
                rowSessions.append(CaseSession(
                    date: date,
                    event: "Определение по итогам изучения жалобы (представления)",
                    result: value("studyResult")))
                if let column = columns["studied"] {
                    datedActions.append((rowSessions.count - 1, column))
                }
            }

            // «С истребованием дела» не является самостоятельным событием.
            // Если дата передачи не опубликована, сохраняем пометку на
            // ближайшем датированном действии этой же строки, не создавая дату.
            if requested, value("study") == nil, let requestedColumn = columns["requested"],
               let index = datedActions.min(by: {
                   abs($0.column - requestedColumn) < abs($1.column - requestedColumn)
               })?.session {
                let current = rowSessions[index].result
                rowSessions[index].result = [current, "С истребованием дела"]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: "; ")
            }

            sessions.append(contentsOf: rowSessions)
        }
        return sessions
    }

    /// Находит именно таблицу с построчными сведениями о жалобах. Проверка по
    /// заголовкам не зависит от номера контейнера и от вложенных таблиц актов.
    private static func complaintTable(_ doc: Document) -> Element? {
        for table in (try? doc.select("table").array()) ?? [] {
            let rows = directRows(table)
            for row in rows {
                let headers = directCells(row, tags: ["td", "th"])
                    .map { normalizeHeader((try? $0.text()) ?? "") }
                let hasReceived = headers.contains {
                    $0.contains("дата поступления") && !$0.contains("исправленной")
                }
                let hasComplaintAction = headers.contains {
                    ($0.contains("дата передачи") && $0.contains("изучен"))
                        || ($0.contains("вынесения определения")
                            && $0.contains("итогам изучения"))
                }
                if hasReceived && hasComplaintAction { return table }
            }
        }
        return nil
    }

    /// Сортировка сессий по опубликованной дате. `sorted` в Swift не обещает
    /// стабильность, поэтому исходный индекс используется явным tie-breaker:
    /// строки жалоб и события с одинаковой датой не теряют порядок суда.
    private static func sortSessions(_ sessions: [CaseSession]) -> [CaseSession] {
        sessions.enumerated().sorted { left, right in
            let leftKey = MovementService.dateSortKey(left.element.date)
            let rightKey = MovementService.dateSortKey(right.element.date)
            return leftKey == rightKey ? left.offset < right.offset : leftKey < rightKey
        }.map { $0.element }
    }

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

    /// Таблица, заголовок (`<th>`) которой содержит «ДВИЖЕНИЕ ДЕЛА»,
    /// «ДВИЖЕНИЕ МАТЕРИАЛА» или «СЛУШАНИЯ».
    private static func movementTable(_ doc: Document) -> Element? {
        for table in (try? doc.select("table").array()) ?? [] {
            for th in (try? table.select("th").array()) ?? [] {
                let t = ((try? th.text()) ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines).uppercased()
                if t.contains("ДВИЖЕНИЕ ДЕЛА") || t == "ДВИЖЕНИЕ МАТЕРИАЛА"
                    || t.contains("СЛУШАНИЯ") { return table }
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
            let body = HTMLTextExtractor.normalizedBlockText(div, style: .sudrf)
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

}
