//  MosGorSud.swift — Sudrf
//  Суды Москвы живут НЕ на платформе ГАС «Правосудие»: у них единый портал
//  mos-gorsud.ru (Мосгорсуд + все районные суды города). Поиск — обычный GET
//  /search без капчи, ответы в UTF-8. Параметры формы выверены по боевому
//  паттерну tochno-st/sudrfscraper (MOSGORSUD_PATTERN):
//    /search?page=1&formType=fullForm&courtAlias=&uid=&instance=1|2|3
//      &processType=N&caseNumber=&participant=&judge=…
//  Пустой courtAlias ищет по ВСЕМ судам портала сразу — название суда
//  возвращается в строке выдачи, поэтому справочник алиасов не нужен.

import Foundation

/// Вид производства в терминах формы поиска mos-gorsud.
public enum MosGorSudProcessType: Int, Sendable {
    case cas = 1          // административные (КАС)
    case civil = 2        // гражданские
    case admin = 3        // дела об административных правонарушениях
    case material = 5     // производства по материалам
    case criminal = 6     // уголовные
}

public enum MosGorSudEndpoint {
    public static let host = "mos-gorsud.ru"

    /// URL поиска. UTF-8, поэтому обычный URLComponents (в отличие от sud_delo
    /// с его cp1251). instance: 1 — первая, 2 — апелляция, 3 — кассация.
    public static func searchURL(courtAlias: String? = nil,
                                 uid: String? = nil,
                                 caseNumber: String? = nil,
                                 participant: String? = nil,
                                 instance: Int,
                                 processType: MosGorSudProcessType,
                                 page: Int = 1) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = "/search"
        comps.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "formType", value: "fullForm"),
            URLQueryItem(name: "courtAlias", value: courtAlias ?? ""),
            URLQueryItem(name: "uid", value: uid ?? ""),
            URLQueryItem(name: "instance", value: String(instance)),
            URLQueryItem(name: "processType", value: String(processType.rawValue)),
            URLQueryItem(name: "caseNumber", value: caseNumber ?? ""),
            URLQueryItem(name: "participant", value: participant ?? "")
        ]
        return comps.url
    }
}

/// Строка выдачи портала. cardURL ведёт на страницу «карточки» дела
/// (/…/services/cases/…/details/…).
public struct MosGorSudResult: Sendable, Equatable {
    public var caseNumber: String
    public var uid: String?
    public var court: String?
    public var judge: String?
    public var receiptDate: String?
    public var participants: String?
    public var result: String?
    public var cardURL: URL?

    public init(caseNumber: String, uid: String? = nil, court: String? = nil,
                judge: String? = nil, receiptDate: String? = nil,
                participants: String? = nil, result: String? = nil, cardURL: URL? = nil) {
        self.caseNumber = caseNumber; self.uid = uid; self.court = court
        self.judge = judge; self.receiptDate = receiptDate
        self.participants = participants; self.result = result; self.cardURL = cardURL
    }
}

/// Карточка дела на портале. Тексты актов на mos-gorsud публикуются
/// ВЛОЖЕНИЯМИ (PDF/DOC), а не инлайном — поэтому вместо текста `actLinks`.
public struct MosGorSudCard: Sendable, Equatable {
    public var uid: String?
    public var caseNumber: String?
    public var court: String?
    public var judge: String?
    public var category: String?
    public var result: String?
    public var receiptDate: String?
    public var sessions: [CaseSession]
    public var participants: [String]
    public var actLinks: [URL]
    public var rawText: String

    public init(uid: String? = nil, caseNumber: String? = nil, court: String? = nil,
                judge: String? = nil, category: String? = nil, result: String? = nil,
                receiptDate: String? = nil, sessions: [CaseSession] = [],
                participants: [String] = [], actLinks: [URL] = [], rawText: String = "") {
        self.uid = uid; self.caseNumber = caseNumber; self.court = court
        self.judge = judge; self.category = category; self.result = result
        self.receiptDate = receiptDate; self.sessions = sessions
        self.participants = participants; self.actLinks = actLinks; self.rawText = rawText
    }
}

public enum MosGorSudRouting {
    /// (вид производства, инстанция) формы mos-gorsud для картотеки нашего
    /// реестра: `u*` → уголовные, `p*` → КАС, `adm*` → КоАП, `m` → материалы,
    /// `g*` → гражданские; суффикс — инстанция (*2 — апелляция, *3/33 — кассация).
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
        if cartoteka.id.hasSuffix("33") || cartoteka.id.hasSuffix("3") { instance = 3 }
        else if cartoteka.id.hasSuffix("2") { instance = 2 }
        else { instance = 1 }
        return (pt, instance)
    }

    /// Суд портала mos-gorsud? (домен отображаемый или сетевой)
    public static func isMosGorSud(domain: String) -> Bool {
        let d = domain.lowercased()
        return d == MosGorSudEndpoint.host || d.hasSuffix("." + MosGorSudEndpoint.host)
            || d.hasPrefix("www." + MosGorSudEndpoint.host)
    }
}
