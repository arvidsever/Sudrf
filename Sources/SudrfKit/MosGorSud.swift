//  MosGorSud.swift — Sudrf
//  Суды Москвы живут НЕ на платформе ГАС «Правосудие»: у них единый портал
//  mos-gorsud.ru (Мосгорсуд + все районные суды города). Поиск — обычный GET
//  /search без обязательной капчи, ответы в UTF-8.
//
//  Параметры формы выверены по ЖИВОМУ URL портала (webarchive):
//    /search?courtAlias=mgs&participant=…&instance=1&processType=1&…
//  Пустой courtAlias ищет по ВСЕМ судам города сразу — название/алиас суда
//  виден в пути ссылки результата (/mgs/… либо /rs/<алиас>/…), поэтому
//  справочник алиасов не нужен.
//
//  Коды `instance` и `processType`, а также раздел (сегмент пути ссылки)
//  взяты из собственного JS портала (scripts.js: instanceTypes/processTypes,
//  mgsLinksMapping/rsLinksMapping) — см. MosGorSudRouting ниже.

import Foundation

/// Вид производства в терминах формы поиска mos-gorsud (`processType`).
/// Значения — из `processTypes` портала.
public enum MosGorSudProcessType: Int, Sendable {
    case cas = 1          // Административное (КАС)
    case civil = 2        // Гражданское
    case admin = 3        // Дела об административных правонарушениях (КоАП)
    // 4 — «Первичные документы», не ищем
    case material = 5     // Производства по материалам
    case criminal = 6     // Уголовное
}

public enum MosGorSudEndpoint {
    public static let host = "mos-gorsud.ru"

    /// URL поиска. UTF-8, поэтому обычный URLComponents (в отличие от sud_delo
    /// с его cp1251). `instance`: 1 — первая, 2 — апелляция, 3 — второй
    /// пересмотр (надзор), 4 — кассационная (см. MosGorSudInstance).
    /// Передаётся ровно одно из uid/caseNumber/participant.
    public static func searchURL(courtAlias: String? = nil,
                                 uid: String? = nil,
                                 caseNumber: String? = nil,
                                 participant: String? = nil,
                                 instance: Int,
                                 processType: MosGorSudProcessType) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = "/search"
        var items: [URLQueryItem] = []
        // courtAlias присутствует всегда (пустой = по всем судам Москвы),
        // как в живой форме портала.
        items.append(URLQueryItem(name: "courtAlias", value: courtAlias ?? ""))
        if let uid, !uid.isEmpty { items.append(URLQueryItem(name: "uid", value: uid)) }
        if let caseNumber, !caseNumber.isEmpty {
            items.append(URLQueryItem(name: "caseNumber", value: caseNumber))
        }
        if let participant, !participant.isEmpty {
            items.append(URLQueryItem(name: "participant", value: participant))
        }
        items.append(URLQueryItem(name: "instance", value: String(instance)))
        items.append(URLQueryItem(name: "processType", value: String(processType.rawValue)))
        comps.queryItems = items
        return comps.url
    }
}

/// Инстанция в терминах формы поиска mos-gorsud (`instance`).
/// Значения — из `instanceTypes` портала. ВНИМАНИЕ: кассация — это `4`,
/// а `3` — «Второй пересмотр» (надзор), их легко перепутать.
public enum MosGorSudInstance {
    public static let first = 1
    public static let appeal = 2
    public static let review = 3       // Второй пересмотр (надзор)
    public static let cassation = 4    // Кассационная
}

/// Строка выдачи портала. cardURL ведёт на страницу «карточки» дела
/// (/…/services/cases/<section>/details/…). `section` — сегмент пути,
/// он же вид производства×инстанция (напр. `first-civil`, `appeal-criminal`).
public struct MosGorSudResult: Sendable, Equatable {
    public var caseNumber: String
    public var uid: String?
    public var court: String?
    public var judge: String?
    public var receiptDate: String?
    public var participants: String?
    public var result: String?
    public var category: String?
    public var section: String?
    public var cardURL: URL?

    public init(caseNumber: String, uid: String? = nil, court: String? = nil,
                judge: String? = nil, receiptDate: String? = nil,
                participants: String? = nil, result: String? = nil,
                category: String? = nil, section: String? = nil, cardURL: URL? = nil) {
        self.caseNumber = caseNumber; self.uid = uid; self.court = court
        self.judge = judge; self.receiptDate = receiptDate
        self.participants = participants; self.result = result
        self.category = category; self.section = section; self.cardURL = cardURL
    }
}

/// Карточка дела на портале. Тексты актов на mos-gorsud публикуются
/// ВЛОЖЕНИЯМИ (DOC/PDF, ссылка /…/cases/docs/content/…), а не инлайном —
/// поэтому вместо текста `actLinks`.
public struct MosGorSudCard: Sendable, Equatable {
    public var uid: String?
    public var caseNumber: String?
    public var court: String?
    public var judge: String?
    public var category: String?
    public var result: String?
    public var receiptDate: String?
    public var legalForceDate: String?
    public var higherNumber: String?
    public var sessions: [CaseSession]
    public var participants: [String]
    public var actLinks: [URL]
    public var rawText: String

    public init(uid: String? = nil, caseNumber: String? = nil, court: String? = nil,
                judge: String? = nil, category: String? = nil, result: String? = nil,
                receiptDate: String? = nil, legalForceDate: String? = nil,
                higherNumber: String? = nil, sessions: [CaseSession] = [],
                participants: [String] = [], actLinks: [URL] = [], rawText: String = "") {
        self.uid = uid; self.caseNumber = caseNumber; self.court = court
        self.judge = judge; self.category = category; self.result = result
        self.receiptDate = receiptDate; self.legalForceDate = legalForceDate
        self.higherNumber = higherNumber; self.sessions = sessions
        self.participants = participants; self.actLinks = actLinks; self.rawText = rawText
    }
}

public enum MosGorSudRouting {
    /// (вид производства, инстанция) формы mos-gorsud для картотеки нашего
    /// реестра: `u*` → уголовные, `p*` → КАС, `adm*` → КоАП, `m` → материалы,
    /// `g*` → гражданские; суффикс — инстанция (*2 — апелляция, *3/33 —
    /// кассация → на портале это `4`).
    public static func map(cartoteka: Cartoteka) -> (processType: MosGorSudProcessType, instance: Int) {
        let pt: MosGorSudProcessType
        switch true {
        case cartoteka.id.hasPrefix("u"):   pt = .criminal
        case cartoteka.id.hasPrefix("p"):   pt = .cas
        case cartoteka.id.hasPrefix("adm"): pt = .admin
        case cartoteka.id == "m":           pt = .material
        default:                            pt = .civil
        }
        let instance: Int
        // Кассация нашего реестра (суффикс 3/33) на портале — `4` (Кассационная),
        // НЕ `3` (Второй пересмотр). Апелляция — `2`.
        if cartoteka.id.hasSuffix("33") || cartoteka.id.hasSuffix("3") {
            instance = MosGorSudInstance.cassation
        } else if cartoteka.id.hasSuffix("2") {
            instance = MosGorSudInstance.appeal
        } else {
            instance = MosGorSudInstance.first
        }
        return (pt, instance)
    }

    /// Суд портала mos-gorsud? (домен отображаемый или сетевой)
    public static func isMosGorSud(domain: String) -> Bool {
        let d = domain.lowercased()
        return d == MosGorSudEndpoint.host || d.hasSuffix("." + MosGorSudEndpoint.host)
            || d.hasPrefix("www." + MosGorSudEndpoint.host)
    }

    // MARK: - Разделы (сегменты пути ссылки результата)

    // Ключи разделов из scripts.js портала (instanceTypes/processTypes.keys)
    // и их отображение в сегмент пути ссылки (mgsLinksMapping/rsLinksMapping).
    private static let instanceKeys: [Int: Set<String>] = [
        1: ["AA", "AA_KAS", "CS", "US", "CS_KAS", "CHH", "UHH", "CHH_KAS", "AS", "AA_US"],
        2: ["DX", "CA", "UA", "CA_KAS", "CA_APPEAL", "UA_APPEAL", "CA_KAS_APPEAL", "DA"],
        3: ["AN", "CNK", "UNK", "CNK_KAS"],
        4: ["AN", "CN", "UN", "CN_KAS"],
    ]
    private static let processKeys: [Int: Set<String>] = [
        1: ["CS_KAS", "CA_KAS_APPEAL", "CA_KAS", "CNK_KAS", "CN_KAS"],
        2: ["CS", "CA_APPEAL", "CA", "CNK", "CN"],
        3: ["DX", "AN", "AS", "DA"],
        5: ["CHH", "UHH", "CHH_KAS"],
        6: ["US", "UA_APPEAL", "UA", "UNK", "UN"],
    ]
    private static let keyToMGS: [String: String] = [
        "AA": "claim-civil", "AA_KAS": "claim-admin", "CS": "first-civil",
        "US": "first-criminal", "CS_KAS": "first-admin", "CHH": "first-civil-exec",
        "UHH": "first-criminal-exec", "CHH_KAS": "first-admin-exec",
        "CA": "appeal-civil", "UA": "appeal-criminal", "CA_KAS": "appeal-admin",
        "DX": "review-not-yet", "AN": "review-supervision", "CA_APPEAL": "board-civil",
        "UA_APPEAL": "board-criminal", "CA_KAS_APPEAL": "board-admin",
        "MAGCAS_CIVIL": "magistrate-cassation-civil",
        "MAGCAS_CRIMINAL": "magistrate-cassation-criminal",
        "MAGCAS_ADMIN": "magistrate-cassation-admin",
    ]
    private static let keyToRS: [String: String] = [
        "AA": "claim-civil", "AA_KAS": "claim-admin", "AA_US": "claim-criminal",
        "CS": "civil", "US": "criminal", "CS_KAS": "kas", "AS": "admin",
        "CA": "appeal-civil", "UA": "appeal-criminal", "CA_KAS": "appeal-kas",
        "DA": "appeal-admin", "UHH": "criminal-materials", "CHH": "civil-exec",
        "CHH_KAS": "admin-exec",
    ]

    /// Допустимые сегменты пути ссылки для выбранных (вид, инстанция) —
    /// объединение вариантов Мосгорсуда и районных судов (поиск идёт по обоим).
    /// Пусто — если раздел неизвестен (тогда фильтровать не нужно).
    public static func sectionSegments(processType: MosGorSudProcessType, instance: Int) -> Set<String> {
        guard let ik = instanceKeys[instance], let pk = processKeys[processType.rawValue] else { return [] }
        let keys = ik.intersection(pk)
        var out: Set<String> = []
        for k in keys {
            if let s = keyToMGS[k] { out.insert(s) }
            if let s = keyToRS[k] { out.insert(s) }
        }
        return out
    }

    /// То же, но по картотеке нашего реестра.
    public static func sectionSegments(cartoteka: Cartoteka) -> Set<String> {
        let route = map(cartoteka: cartoteka)
        return sectionSegments(processType: route.processType, instance: route.instance)
    }

    /// Сегмент раздела из ссылки карточки: /…/services/cases/<section>/details/…
    public static func section(fromCardURL url: URL) -> String? {
        section(fromPath: url.path)
    }

    static func section(fromPath path: String) -> String? {
        guard let r = path.range(of: #"/services/cases/[a-z-]+/details"#,
                                 options: .regularExpression) else { return nil }
        let match = String(path[r])                       // /services/cases/<section>/details
        let parts = match.split(separator: "/")           // [services, cases, <section>, details]
        return parts.count >= 3 ? String(parts[2]) : nil
    }
}
