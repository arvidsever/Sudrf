//  VSRFCard.swift — Sudrf
//
//  Верховный Суд РФ — ОТДЕЛЬНАЯ платформа (vsrf.ru), не sud_delo. Карточки и
//  поисковая выдача отдаются сервером в UTF-8 (а не cp1251, как sudrf.ru), без капчи.
//
//  ── Карточка производства ──────────────────────────────────────────────────
//      https://vsrf.ru/lk/practice/cases/{id}      — для дела
//      https://vsrf.ru/lk/practice/appeals/{id}    — для жалобы
//  Обе ссылки для одного и того же дела ведут в итоге на одну и ту же карточку.
//  где {id} — `data-subscribe-claim-id` блока (дело «12-…», жалоба «21-…»). Одно
//  дело порождает 1..N производств. На реальной карточке (дело Воробьёва, Респ.
//  Коми, фикстура vsrf_card_vorobyev.html) их два:
//    • ЖАЛОБА (`vs-items-separate vs-appeal-title`, id «21-…»): № «3-КФ22-336-К3»,
//      Дата поступления, Суд 1-ой инстанции, Предмет иска, Кассационный суд,
//      Обжалуется, «В интересах», событие «Истребовано дело». УИД ОТСУТСТВУЕТ.
//    • ДЕЛО (`vs-items-separate vs-case-title`, id «12-…»): № «3-КГ23-1-К3»,
//      Вид судопроизводства, Инстанция, «Уникальный идентификатор дела» (= УИД),
//      Судебная коллегия, Суд 1-ой инстанции, По иску, Заявители, Ответчики,
//      «Движение по делу», Докладчик.
//
//  ── Выдача поиска ──────────────────────────────────────────────────────────
//      GET https://vsrf.ru/lk/practice/claims
//          ?registerDateExact=off&considerationDateExact=off&numberExact=true
//           [&uniqueNumber=<УИД>] [&oldCaseNumber1=<№ дела 1-й инст.>] [&keywords=<ФИО>]
//  Текущая выдача использует `.CaseStyle_case_item__*` и ссылки
//  `/lk/practice/claims/{id}`; `Найдено: N` — явное число найденных производств.
//  Более старый формат (`vs-items-separate` + `vs-item-detail`, `/cases/` и
//  `/appeals/`) тоже поддерживается. Число может превышать видимые строки.
//
//  ── Нюанс УИД и тройка ─────────────────────────────────────────────────────
//  УИД появляется ТОЛЬКО когда в ВС поступило именно ДЕЛО (сплошная кассация
//  части споров КАС/УПК; выборочная — если дело ИСТРЕБОВАНО). У «жалобных»
//  производств УИД нет. Поэтому сквозная привязка к нижестоящим судам (и обратно)
//  идёт по УИД, а при его отсутствии — по тройке, присутствующей в ЛЮБОМ
//  производстве: (суд 1-й инст., № дела 1-й инст., фамилия заявителя). См.
//  `VSRFLinkKey`.
//
//  ── Разбор ──────────────────────────────────────────────────────────────────
//  Поиск разбирается из текущих result-card блоков либо из legacy
//  `vs-items-separate`/`vs-item-detail`; карточки дела по-прежнему используют
//  `data-subscribe-claim-id` и старые production-блоки.

import Foundation
import SwiftSoup

// MARK: - Модель

/// Тип производства.
public enum VSRFProductionKind: String, Sendable, Equatable {
    case complaint   // ЖАЛОБА (КФ; vs-appeal-title) — УИД отсутствует, ссылка /appeals/
    case caseFile    // ДЕЛО   (КГ/КА/КУ; vs-case-title) — УИД присутствует, ссылка /cases/
    case other
}

/// Раздел карточки в адресе ВС РФ.
public enum VSRFCardSection: String, Sendable, Equatable {
    case cases      // дела:   /lk/practice/cases/{id}
    case appeals    // жалобы: /lk/practice/appeals/{id}
    case claims     // новый портал: /lk/practice/claims/{id}
}

/// Реквизиты суда 1-й инстанции из составной ячейки «Суд 1-ой инстанции».
public struct VSRFFirstInstance: Sendable, Equatable {
    public var court: String?          // «Сыктывкарский городской суд»
    public var caseNumber: String?     // «2-1649/2022»
    public var judge: String?          // «О.А. Машкалева» (в жалобе может отсутствовать)
    public var decisionDate: String?   // «02.03.2022» («Решение от …»)
    public var result: String?         // «Иск удовлетворён полностью» (`.vs-items-black`)

    public init(court: String? = nil, caseNumber: String? = nil, judge: String? = nil,
                decisionDate: String? = nil, result: String? = nil) {
        self.court = court; self.caseNumber = caseNumber; self.judge = judge
        self.decisionDate = decisionDate; self.result = result
    }
}

/// Событие движения (с датой): «Истребовано дело», «Передано судье»,
/// «Отказ в передаче дела в суд кассационной инстанции», «Возврат без рассмотрения» и т. п.
public struct VSRFEvent: Sendable, Equatable, Identifiable {
    public var id: String { (date ?? "—") + "|" + text }
    public var date: String?
    public var text: String
    public init(date: String?, text: String) { self.date = date; self.text = text }
}

/// Одно производство ВС РФ — общая модель для блока карточки и строки выдачи.
public struct VSRFProduction: Sendable, Equatable, Identifiable {
    /// id карточки (`data-subscribe-claim-id` / id из ссылки). Есть и у дела
    /// («12-…»), и у жалобы («21-…»).
    public var cardID: String?
    /// Раздел карточки для сборки URL. Если из разметки не извлечён — выводится
    /// из типа: дело → cases, жалоба → appeals.
    public var cardSection: VSRFCardSection?
    public var kind: VSRFProductionKind
    public var number: String?             // «3-КГ23-1-К3» / «3-КФ22-336-К3»
    public var incomingDate: String?       // «Дата поступления»
    public var procedureType: String?      // «Вид судопроизводства» (дело)
    public var instanceType: String?       // «Инстанция» (дело)
    public var uid: String?                // «Уникальный идентификатор дела» (ТОЛЬКО дело)
    public var collegium: String?          // «Судебная коллегия (Состав)»
    public var cassationCourt: String?     // «Кассационный суд» (жалоба)
    public var appealedAct: String?        // «Обжалуется» (жалоба)
    public var subject: String?            // «Предмет иска» / «По иску»
    public var firstInstance: VSRFFirstInstance
    public var applicant: String?          // «В интересах» (жалоба) / 1-й «Заявитель» (дело)
    public var claimants: [String]         // «Заявители (истцы / административные истцы)»
    public var respondents: [String]       // «Ответчики / административные ответчики»
    public var rapporteur: String?         // «Докладчик»
    public var events: [VSRFEvent]         // движение / события

    public init(cardID: String? = nil, cardSection: VSRFCardSection? = nil,
                kind: VSRFProductionKind = .other, number: String? = nil,
                incomingDate: String? = nil, procedureType: String? = nil, instanceType: String? = nil,
                uid: String? = nil, collegium: String? = nil, cassationCourt: String? = nil,
                appealedAct: String? = nil, subject: String? = nil,
                firstInstance: VSRFFirstInstance = VSRFFirstInstance(), applicant: String? = nil,
                claimants: [String] = [], respondents: [String] = [], rapporteur: String? = nil,
                events: [VSRFEvent] = []) {
        self.cardID = cardID; self.cardSection = cardSection; self.kind = kind
        self.number = number; self.incomingDate = incomingDate
        self.procedureType = procedureType; self.instanceType = instanceType; self.uid = uid
        self.collegium = collegium; self.cassationCourt = cassationCourt; self.appealedAct = appealedAct
        self.subject = subject; self.firstInstance = firstInstance; self.applicant = applicant
        self.claimants = claimants; self.respondents = respondents; self.rapporteur = rapporteur
        self.events = events
    }

    public var id: String { cardID ?? ((number ?? "—") + "|" + (incomingDate ?? "")) }

    /// Раздел с учётом типа (fallback, если из разметки не извлечён).
    public var resolvedSection: VSRFCardSection {
        cardSection ?? (kind == .complaint ? .appeals : .cases)
    }

    /// Ссылка на карточку (есть только когда есть `cardID`).
    public var cardURL: URL? {
        cardID.flatMap { VSRFEndpoint.cardURL(productionID: $0, section: resolvedSection) }
    }

    /// true, если дело было истребовано (событие «Истребовано дело»).
    public var caseRequested: Bool {
        events.contains { $0.text.range(of: "Истребовано дело", options: .caseInsensitive) != nil }
    }

    /// Ключ привязки к карточкам в иных судах / производствах.
    public var linkKey: VSRFLinkKey {
        VSRFLinkKey(uid: uid,
                    firstInstanceCourt: firstInstance.court,
                    firstInstanceCaseNumber: firstInstance.caseNumber,
                    applicantName: applicant ?? claimants.first)
    }
}

/// Карточка дела ВС РФ целиком: набор производств (жалобы + дела) одного дела.
public struct VSRFCard: Sendable {
    public var productions: [VSRFProduction]
    public var rawText: String
    public init(productions: [VSRFProduction], rawText: String = "") {
        self.productions = productions; self.rawText = rawText
    }
    /// УИД дела (из «дельного» производства; у «жалобных» его нет).
    public var uid: String? { productions.compactMap(\.uid).first }
    /// Производство-дело (с УИД), если оно есть.
    public var caseProduction: VSRFProduction? {
        productions.first { $0.kind == .caseFile } ?? productions.first { $0.uid != nil }
    }
    /// Основной номер: дело приоритетнее жалобы.
    public var primaryNumber: String? { caseProduction?.number ?? productions.first?.number }
}

/// Результат поиска по выдаче ВС РФ. `total` — «НАЙДЕНО: N» (может превышать
/// число `results`, если выдача когда-нибудь окажется постраничной).
public struct VSRFSearchResults: Sendable {
    public var total: Int
    public var results: [VSRFProduction]
    public init(total: Int, results: [VSRFProduction]) { self.total = total; self.results = results }

    /// Результаты, привязываемые к заданному ключу (УИД или тройка).
    public func matching(_ key: VSRFLinkKey) -> [VSRFProduction] {
        results.filter { $0.linkKey.matches(key) }
    }
}

// MARK: - Ключ привязки (УИД + тройка)

/// Ключ сквозной привязки производства ВС РФ к карточкам в нижестоящих судах
/// (и обратно). Прямой матч — по УИД, когда он есть. Когда УИД нет (жалоба без
/// истребования) — по тройке: суд 1-й инст. + № дела 1-й инст. + фамилия заявителя.
public struct VSRFLinkKey: Sendable, Equatable {
    public var uid: String?
    public var firstInstanceCourt: String?
    public var firstInstanceCaseNumber: String?
    public var applicantName: String?

    public init(uid: String? = nil, firstInstanceCourt: String? = nil,
                firstInstanceCaseNumber: String? = nil, applicantName: String? = nil) {
        self.uid = uid; self.firstInstanceCourt = firstInstanceCourt
        self.firstInstanceCaseNumber = firstInstanceCaseNumber; self.applicantName = applicantName
    }

    public func uidMatches(_ other: VSRFLinkKey) -> Bool {
        guard let a = Self.normUID(uid), let b = Self.normUID(other.uid) else { return false }
        return a == b
    }

    public func tripleMatches(_ other: VSRFLinkKey) -> Bool {
        guard let c1 = Self.normCourt(firstInstanceCourt),
              let c2 = Self.normCourt(other.firstInstanceCourt), c1 == c2,
              let n1 = Self.normCaseNo(firstInstanceCaseNumber),
              let n2 = Self.normCaseNo(other.firstInstanceCaseNumber), n1 == n2,
              let s1 = Self.surname(applicantName),
              let s2 = Self.surname(other.applicantName), s1 == s2
        else { return false }
        return true
    }

    /// Привязка: сперва по УИД, затем фолбэк на тройку.
    public func matches(_ other: VSRFLinkKey) -> Bool { uidMatches(other) || tripleMatches(other) }

    // Нормализация
    static func normUID(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        let t = s.uppercased().filter { !$0.isWhitespace }
        return t.isEmpty ? nil : t
    }
    static func normCourt(_ s: String?) -> String? {
        guard let s else { return nil }
        var t = s.lowercased().replacingOccurrences(of: "ё", with: "е")
        t = t.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: ",", with: " ")
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.isEmpty ? nil : t
    }
    static func normCaseNo(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.uppercased().replacingOccurrences(of: "Ё", with: "Е").filter { !$0.isWhitespace }
        return t.isEmpty ? nil : t
    }
    /// Фамилия из ФИО: первая лексема, верхний регистр, ё→е.
    static func surname(_ s: String?) -> String? {
        guard let s else { return nil }
        let first = s.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let up = first.uppercased().replacingOccurrences(of: "Ё", with: "Е").filter { $0.isLetter || $0 == "-" }
        return up.isEmpty ? nil : up
    }
}

// MARK: - URL-эндпоинты ВС РФ

public enum VSRFEndpoint {
    public static let host = "vsrf.ru"
    private static let base = "https://vsrf.ru/lk/practice"

    public static func cardURL(productionID: String, section: VSRFCardSection = .cases) -> URL? {
        let root = section == .claims ? "https://www.vsrf.ru/lk/practice" : base
        return URL(string: "\(root)/\(section.rawValue)/\(productionID)")
    }

    /// Сборка URL выдачи. Кодировка — UTF-8 (через URLComponents), капчи нет.
    public static func searchURL(uniqueNumber: String? = nil,
                                 oldCaseNumber: String? = nil,
                                 keywords: String? = nil) -> URL? {
        var items: [URLQueryItem] = [
            .init(name: "registerDateExact", value: "off"),
            .init(name: "considerationDateExact", value: "off"),
            .init(name: "numberExact", value: "true")
        ]
        if let v = uniqueNumber?.trimmed, !v.isEmpty { items.append(.init(name: "uniqueNumber", value: v)) }
        if let v = oldCaseNumber?.trimmed, !v.isEmpty { items.append(.init(name: "oldCaseNumber1", value: v)) }
        if let v = keywords?.trimmed, !v.isEmpty { items.append(.init(name: "keywords", value: v)) }
        var c = URLComponents(string: "\(base)/claims")
        c?.queryItems = items
        return c?.url
    }
}

// MARK: - Парсеры

public enum VSRFCardParser {
    /// Разбор карточки производства (`/lk/practice/cases|appeals/{id}`).
    public static func parse(html: String) throws -> VSRFCard {
        let doc = try Self.document(html)
        let prods = VSRFDOM.extractProductions(doc)
        let raw = (try? doc.text()) ?? ""
        return VSRFCard(productions: prods, rawText: raw)
    }
    static func document(_ html: String) throws -> Document {
        do { return try SwiftSoup.parse(html) }
        catch { throw SudrfError.parsing("SwiftSoup не смог разобрать страницу ВС РФ") }
    }
}

public enum VSRFSearchParser {
    /// Разбор страницы выдачи (`/lk/practice/claims?…`).
    public static func parse(html: String) throws -> VSRFSearchResults {
        let doc = try VSRFCardParser.document(html)
        guard VSRFDOM.isSearchResultsPage(doc) else {
            throw SudrfError.parsing("Неизвестный формат выдачи ВС РФ")
        }
        let results = VSRFDOM.extractSearchProductions(doc)
        guard results.allSatisfy(Self.isLinkable) else {
            throw SudrfError.parsing("Строка выдачи ВС РФ не содержит ссылку, номер или ключ привязки")
        }
        guard let total = Self.foundCount(doc) else {
            guard !results.isEmpty else {
                throw SudrfError.parsing("В выдаче ВС РФ нет явного счётчика пустого результата")
            }
            return VSRFSearchResults(total: results.count, results: results)
        }
        guard total >= results.count,
              (total == 0) == results.isEmpty else {
            throw SudrfError.parsing("Счётчик выдачи ВС РФ не согласуется со строками результатов")
        }
        return VSRFSearchResults(total: total, results: results)
    }
    private static func foundCount(_ doc: Document) -> Int? {
        let legacy = VSRFDOM.firstEl(doc, ".count-label").flatMap { try? $0.text() }
        let current = VSRFDOM.firstEl(doc, "[class*=SearchPage_resultsBlock__]")
            .flatMap { try? $0.text() }
        for text in [legacy, current].compactMap({ $0 }) {
            guard let range = text.range(of: #"Найдено\s*[:：]?\s*\d+"#,
                                         options: [.regularExpression, .caseInsensitive]) else { continue }
            return Int(text[range].filter(\.isNumber))
        }
        return nil
    }

    private static func isLinkable(_ result: VSRFProduction) -> Bool {
        guard result.cardID?.isEmpty == false, result.number?.isEmpty == false else { return false }
        if JudicialUIDObservation.validity(of: result.uid) == .valid { return true }
        return [result.firstInstance.court, result.firstInstance.caseNumber,
                result.applicant ?? result.claimants.first]
            .allSatisfy { $0?.trimmed.isEmpty == false }
    }
}

// MARK: - Общий извлекатель производств (карточка + выдача)

enum VSRFDOM {

    static func isSearchResultsPage(_ doc: Document) -> Bool {
        if firstEl(doc, "[class*=SearchPage_resultsBlock__]") != nil { return true }
        return firstEl(doc, "#filter-form") != nil
            && (firstEl(doc, "#vs-search-items") != nil || firstEl(doc, ".count-label") != nil)
    }

    static func extractSearchProductions(_ doc: Document) -> [VSRFProduction] {
        let currentItems = (try? doc.select("[class*=CaseStyle_case_item__]").array()) ?? []
        if !currentItems.isEmpty { return currentItems.map(buildCurrentSearchItem) }
        return extractProductions(doc)
    }

    private static func buildCurrentSearchItem(_ item: Element) -> VSRFProduction {
        let link = searchCardLink(of: item)
        var meta: [String: String] = [:]
        var firstInstanceCell: Element?
        for row in (try? item.select("[class*=RowElement_container__]").array()) ?? [] {
            guard let label = firstEl(row, "[class*=CaseStyle_registerDateRow_attribute__]"),
                  let value = firstEl(row, "[class*=CaseStyle_case_value__]") else { continue }
            let key = clean((try? label.text()) ?? "").lowercased()
            let raw = clean((try? value.text()) ?? "")
            if key.hasPrefix("суд 1-й инстанции") { firstInstanceCell = value }
            if !raw.isEmpty { meta[key] = raw }
        }

        var claimants: [String] = []
        var respondents: [String] = []
        var applicant: String?
        for row in (try? item.select("[class*=CaseStyle_case_personalList_item__]").array()) ?? [] {
            guard let label = firstEl(row, "[class*=CaseStyle_registerDateRow_attribute__]") else { continue }
            let key = clean((try? label.text()) ?? "").lowercased()
            let value = firstEl(row, "[class*=CaseStyle_case_personalListName__]") ?? row
            if key.hasPrefix("в интересах") { applicant = names(in: value).first }
            else if key.hasPrefix("заявител") {
                claimants = names(in: value)
                if applicant == nil { applicant = claimants.first }
            }
            else if key.hasPrefix("ответчик") { respondents = names(in: value) }
        }

        var rapporteur: String?
        var events: [VSRFEvent] = []
        for row in (try? item.select("[class*=FinalActRow_container__]").array()) ?? [] {
            if let reporter = firstEl(row, ".vs-reporter-name"),
               let text = try? reporter.text(), !clean(text).isEmpty {
                rapporteur = clean(text)
            }
            let date = firstEl(row, "[class*=FinalActRow_date__]")
                .flatMap { (try? $0.text()).map(clean) }
                .flatMap { firstDate(in: $0) }
            var text = clean(stripRapporteur(clean((try? row.text()) ?? "")))
            if let date { text = clean(text.replacingOccurrences(of: date, with: "")) }
            if !text.isEmpty { events.append(VSRFEvent(date: date, text: text)) }
        }

        let uid = meta["уникальный идентификатор дела:"]
        let kind = kind(header: item, uid: uid, cardID: link?.id)
        return VSRFProduction(
            cardID: link?.id,
            cardSection: link?.section ?? (kind == .complaint ? .appeals : .cases),
            kind: kind,
            number: link?.number,
            incomingDate: meta["дата поступления:"].flatMap { firstDate(in: $0) } ?? meta["дата поступления:"],
            procedureType: meta["вид судопроизводства:"],
            instanceType: meta["инстанция:"],
            uid: uid,
            subject: meta["по иску:"],
            firstInstance: parseFirstInstance(firstInstanceCell),
            applicant: applicant ?? claimants.first,
            claimants: claimants,
            respondents: respondents,
            rapporteur: rapporteur,
            events: events)
    }

    private static func searchCardLink(of item: Element) -> (id: String, section: VSRFCardSection?, number: String?)? {
        guard let title = firstEl(item, "[class*=CaseStyle_case_link__]"),
              let href = try? title.attr("href"),
              let match = href.firstMatch(of: /\/lk\/practice\/(cases|appeals|claims)\/([0-9-]+)/) else { return nil }
        return (String(match.2), VSRFCardSection(rawValue: String(match.1)),
                clean((try? title.text()) ?? "").nonEmpty)
    }

    /// Сегментирует документ по заголовкам `vs-items-separate` в порядке документа;
    /// следующие `vs-item-detail` принадлежат текущему производству.
    static func extractProductions(_ doc: Document) -> [VSRFProduction] {
        let nodes = (try? doc.select("div.vs-items-separate, div.row.vs-item-detail").array()) ?? []
        var out: [VSRFProduction] = []
        var header: Element?
        var details: [Element] = []
        func flush() {
            if let h = header { out.append(build(header: h, details: details)) }
            header = nil; details = []
        }
        for n in nodes {
            if n.hasClass("vs-items-separate") {
                flush(); header = n; details = []
            } else if header != nil {
                details.append(n)
            }
        }
        flush()
        return out
    }

    private static func build(header: Element, details: [Element]) -> VSRFProduction {
        let link = cardLink(of: header)     // (id, section?) из /cases|appeals/ или предка

        // Пары «метка → значение» и составная ячейка «Суд 1-ой инстанции».
        var meta: [String: String] = [:]
        var firstInstanceCell: Element?
        var claimants: [String] = []
        var respondents: [String] = []
        for row in details {
            guard let label = firstEl(row, ".col-md-3"),
                  let value = firstEl(row, ".col-md-7") else { continue }
            let key = clean((try? label.text()) ?? "").lowercased()
            if key.isEmpty { continue }
            let raw = clean((try? value.text()) ?? "")
            if key.hasPrefix("суд 1-ой инстанции") { firstInstanceCell = value }
            if key.hasPrefix("заявител") { claimants = names(in: value) }
            else if key.hasPrefix("ответчик") { respondents = names(in: value) }
            if !raw.isEmpty { meta[key] = raw }
        }

        let uid = meta["уникальный идентификатор дела:"]
        let kind = kind(header: header, uid: uid, cardID: link?.id)

        // Докладчик — из `span.vs-reporter-name` ЭТОГО производства (в выдаче
        // производств несколько, поэтому ищем строго внутри своих details).
        var rapporteur: String?
        for row in details {
            if let el = (try? row.select(".vs-reporter-name").first()) ?? nil,
               let t = try? el.text() {
                let c = clean(t)
                if !c.isEmpty { rapporteur = c; break }
            }
        }

        // События — строки без метки col-md-3.
        var events: [VSRFEvent] = []
        for row in details {
            if let l = firstEl(row, ".col-md-3"), !clean((try? l.text()) ?? "").isEmpty { continue }
            guard let textCell = firstEl(row, ".col-md-7") else { continue }
            if clean((try? textCell.text()) ?? "").hasPrefix("Показать подробную") { continue }
            let cols = (try? row.select(".col-md-2").array()) ?? []
            let date = cols.compactMap { firstDate(in: clean((try? $0.text()) ?? "")) }.first
            let text = clean(stripRapporteur(clean((try? textCell.text()) ?? "")))
            if text.isEmpty { continue }
            events.append(VSRFEvent(date: date, text: text))
        }

        let incoming = meta["дата поступления:"].flatMap { firstDate(in: $0) } ?? meta["дата поступления:"]
        let applicant = meta["в интересах:"] ?? claimants.first
        let parsedSection: VSRFCardSection? = link.flatMap { $0.section }
        let section = parsedSection ?? (kind == .complaint ? .appeals : .cases)

        return VSRFProduction(
            cardID: link?.id,
            cardSection: link?.id == nil ? nil : section,
            kind: kind,
            number: number(of: header),
            incomingDate: incoming,
            procedureType: meta["вид судопроизводства:"],
            instanceType: meta["инстанция:"],
            uid: uid,
            collegium: meta["судебная коллегия (состав):"],
            cassationCourt: meta["кассационный суд:"],
            appealedAct: meta["обжалуется:"],
            subject: meta["предмет иска:"] ?? meta["по иску:"],
            firstInstance: parseFirstInstance(firstInstanceCell),
            applicant: applicant,
            claimants: claimants,
            respondents: respondents,
            rapporteur: rapporteur,
            events: events
        )
    }

    // MARK: заголовок

    /// id + раздел карточки. В выдаче — из ссылки `/lk/practice/(cases|appeals|claims)/{id}`
    /// (у ссылки жалобы возможен хвост `#…`, он отбрасывается). На карточке ссылок
    /// нет — id берётся из ближайшего предка `[data-subscribe-claim-id]`, раздел
    /// возвращается nil (выводится из типа выше).
    private static func cardLink(of header: Element) -> (id: String, section: VSRFCardSection?)? {
        if let a = (try? header.select("a[href*='/lk/practice/']").first()) ?? nil,
           let href = try? a.attr("href"),
           let match = href.firstMatch(of: /\/lk\/practice\/(cases|appeals|claims)\/([0-9-]+)/) {
            return (String(match.2), VSRFCardSection(rawValue: String(match.1)))
        }
        var p: Element? = header.parent()
        while let cur = p {
            if let v = try? cur.attr("data-subscribe-claim-id"), !v.isEmpty { return (v, nil) }
            p = cur.parent()
        }
        return nil
    }

    private static func number(of header: Element) -> String? {
        func textOf(_ css: String) -> String? {
            guard let el = firstEl(header, css) else { return nil }
            return (try? el.text()).map(clean)
        }
        for c in [textOf(".vs-items-label a"), textOf(".vs-items-label"), textOf(".vs-items-additional-info")] {
            if let v = c, !v.isEmpty {
                return v.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            }
        }
        return nil
    }

    private static func kind(header: Element, uid: String?, cardID: String?) -> VSRFProductionKind {
        if header.hasClass("vs-appeal-title") { return .complaint }   // карточка: жалоба
        if header.hasClass("vs-case-title") { return .caseFile }      // карточка: дело
        // выдача (vs-border): УИД ⇒ дело; иначе жалоба. id-префикс/слово «Жалоба» — подсказки.
        if uid != nil { return .caseFile }
        if let cardID, cardID.hasPrefix("12-") { return .caseFile }
        if let cardID, cardID.hasPrefix("21-") { return .complaint }
        let t = clean((try? header.text()) ?? "")
        if t.range(of: "Жалоб", options: .caseInsensitive) != nil { return .complaint }
        return .complaint
    }

    // MARK: составная ячейка «Суд 1-ой инстанции»

    private static func parseFirstInstance(_ cell: Element?) -> VSRFFirstInstance {
        guard let cell else { return VSRFFirstInstance() }
        let result = ((try? cell.select(".vs-items-black").first()) ?? nil).flatMap { el -> String? in
            let t = clean((try? el.text()) ?? ""); return t.isEmpty ? nil : t
        }
        let text = clean((try? cell.text()) ?? "")
        var court: String?
        if let r = text.range(of: #"Решение|Судья:|Номер дела"#, options: .regularExpression) {
            court = clean(String(text[..<r.lowerBound]))
        } else {
            court = text
        }
        court = court?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).nonEmpty
        return VSRFFirstInstance(
            court: court,
            caseNumber: text.firstMatch(of: /Номер дела 1-(?:ой|й) инстанции:\s*([0-9А-Яа-яЁё\/-]+)/)
                .flatMap { clean(String($0.1)).nonEmpty },
            judge: text.firstMatch(of: /Судья:\s*(.+?)\s*(?:Номер дела|$)/)
                .flatMap { clean(String($0.1)).nonEmpty },
            decisionDate: text.firstMatch(of: /Решение\s*от\s*(\d{2}\.\d{2}\.\d{4})/)
                .flatMap { clean(String($0.1)).nonEmpty },
            result: result)
    }

    // MARK: helpers

    /// Первый элемент по CSS в пределах `root`, «сплющенный» до Element? (без
    /// двойных optional, которые даёт `try? …first()` над бросающим select).
    static func firstEl(_ root: Element, _ css: String) -> Element? {
        (try? root.select(css).first()) ?? nil
    }

    private static func names(in cell: Element) -> [String] {
        let spans = (try? cell.select("span").array()) ?? []
        let list = spans.compactMap { (try? $0.text()).map(clean) }.filter { !$0.isEmpty }
        if !list.isEmpty { return list }
        let t = clean((try? cell.text()) ?? "")
        return t.isEmpty ? [] : [t]
    }
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func firstDate(in s: String) -> String? {
        s.firstMatch(of: /\d{2}\.\d{2}\.\d{4}/).map { String($0.output) }
    }
    private static func stripRapporteur(_ s: String) -> String {
        guard let r = s.range(of: #"\s*Докладчик:.*$"#, options: .regularExpression) else { return s }
        return String(s[..<r.lowerBound])
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
