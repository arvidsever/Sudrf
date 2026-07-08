import Foundation

/// Параметры картотеки (вид производства × инстанция). Пары `delo_id`/`new`
/// выверены по универсальному JS-переключателю видов производства, который
/// платформа sud_delo вшивает в каждую страницу (см. фикстуры в тестах:
/// функция `select_delo_id_new` одинакова на районном суде, суде субъекта и
/// КСОЮ). Канонические пары:
///   уголовные:  1540006 (1 инст) · 4&new=4 (апелляция) · 4&new=2450001 (кассация) · 2450001 (президиум)
///   гражданские: 1540005 · 5&new=5 · 5&new=2800001 · 2800001
///   КАС:        41 · 42 · 43
///   КоАП:       1500001 (дела об АП) · 1502001 (жалобы на постановления)
///               · 1513001 (на решения по жалобам) · 2550001 (вступившие в силу)
///   материалы:  1610001 (районное звено) · 1610002 (вышестоящие звенья)
public struct Cartoteka: Sendable, Equatable {
    public var id: String              // короткий ключ для CLI, напр. "adm"
    public var title: String
    /// Индексы номенклатуры дел (префиксы № дела) без дефиса, в нижнем регистре:
    /// «2а» матчит «2а-3021/2023», «3/» — материалы вида «3/1-44/2026».
    /// Пустой массив — индекс не задан (авто-выбор по номеру не сработает).
    public var prefixes: [String]
    public var deloID: String          // delo_id (нормализованный — как уходит в name_op=r)
    public var new: String             // new (для 1-й инстанции = "0"; апелляция/кассация — иное)
    public var deloTable: String       // delo_table, напр. "adm_case"
    public var caseNumberField: String // поле № дела, напр. "adm_case__CASE_NUMBERSS"
    public var uidField: String        // поле УИД
    public var nameField: String       // поле ФИО

    public init(id: String, title: String, prefixes: [String] = [],
                deloID: String, new: String = "0",
                deloTable: String, caseNumberField: String, uidField: String, nameField: String) {
        self.id = id; self.title = title; self.prefixes = prefixes
        self.deloID = deloID; self.new = new
        self.deloTable = deloTable; self.caseNumberField = caseNumberField
        self.uidField = uidField; self.nameField = nameField
    }
}

public enum CartotekaRegistry {

    /// Найти картотеку по звену суда и ключу (id). nil — если такой нет.
    public static func find(level: CourtLevel, id: String) -> Cartoteka? {
        sets(for: level).first { $0.id == id }
    }

    /// Все картотеки для звена. У каждого звена — свой набор; id уникальны
    /// внутри звена, но повторяются между звеньями (g2 районного суда —
    /// апелляция на мировых, g2 суда субъекта — апелляция на районные,
    /// g2 АСОЮ — апелляция на 1-инстанционные акты судов субъектов).
    public static func sets(for level: CourtLevel) -> [Cartoteka] {
        switch level {
        case .magistrate:return magistrate
        case .district:  return district
        case .subject:   return subject
        case .appeal:    return appealSOYu
        case .cassation: return cassationSOYu
        }
    }

    // MARK: - Подбор картотеки по индексу номера дела

    /// Картотеки звена, чьим индексам соответствует номер дела.
    /// «2а-3021/2023» → КАС 1-й инстанции; «11а-12/2026» → апелляция КАС на
    /// мировых; «3/1-44/2026» → материалы. При равной длине индекса возможна
    /// неоднозначность (в суде субъекта «21-…» — обе КоАП-картотеки второй
    /// инстанции) — тогда возвращаются все кандидаты, выбор за вызывающим.
    public static func matches(caseNumber: String, level: CourtLevel) -> [Cartoteka] {
        let n = normalizedNumber(caseNumber)
        guard !n.isEmpty else { return [] }
        var hits: [(cart: Cartoteka, len: Int)] = []
        for c in sets(for: level) {
            for raw in c.prefixes {
                let p = normalizedNumber(raw)
                let ok = p.hasSuffix("/") ? n.hasPrefix(p) : n.hasPrefix(p + "-")
                if ok { hits.append((c, p.count)); break }
            }
        }
        guard let best = hits.map(\.len).max() else { return [] }
        return hits.filter { $0.len == best }.map(\.cart)
    }

    /// Соответствует ли номер дела индексам данной картотеки.
    /// Картотека без индексов считается подходящей (судить не по чему).
    public static func prefixMatches(_ c: Cartoteka, caseNumber: String) -> Bool {
        guard !c.prefixes.isEmpty else { return true }
        let n = normalizedNumber(caseNumber)
        guard !n.isEmpty else { return true }
        return c.prefixes.contains { raw in
            let p = normalizedNumber(raw)
            return p.hasSuffix("/") ? n.hasPrefix(p) : n.hasPrefix(p + "-")
        }
    }

    /// Нормализация для сравнения индексов: первый токен (до пробела/«~»),
    /// без ведущего «№», нижний регистр, латинские двойники → кириллица
    /// (пользователи набирают «2a-», «8g-», «7y-» с латиницей).
    public static func normalizedNumber(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("№") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if let cut = t.firstIndex(where: { $0 == " " || $0 == "~" }) { t = String(t[..<cut]) }
        let latin: [Character: Character] = ["a": "а", "g": "г", "k": "к",
                                             "m": "м", "y": "у", "u": "у"]
        return String(t.map { latin[$0] ?? $0 })
    }

    // MARK: - Мировой судья / судебный участок

    /// Сайты `*.msudrf.ru` используют собственный интерфейс `op=sf` без поля УИД.
    /// Пары `delo_id` совпадают с первой инстанцией районного звена, но имена
    /// полей в форме местами отличаются регистром.
    public static let magistrate: [Cartoteka] = [
        Cartoteka(id: "u1", title: "Уголовные дела",
                  prefixes: ["1"],
                  deloID: "1540006", deloTable: "u1_case",
                  caseNumberField: "u1_case__CASE_NUMBERSS",
                  uidField: "",
                  nameField: "U1_DEFENDANT__NAMESS"),
        Cartoteka(id: "g1", title: "Гражданские и административные",
                  prefixes: ["2", "2а", "м", "9"],
                  deloID: "1540005", deloTable: "g1_case",
                  caseNumberField: "g1_case__CASE_NUMBERSS",
                  uidField: "",
                  nameField: "G1_PARTS__NAMESS"),
        Cartoteka(id: "adm", title: "Дела об административных правонарушениях",
                  prefixes: ["5"],
                  deloID: "1500001", deloTable: "adm_case",
                  caseNumberField: "adm_case__CASE_NUMBERSS",
                  uidField: "",
                  nameField: "adm_parts__NAMESS"),
        Cartoteka(id: "m", title: "Материалы",
                  prefixes: ["3/", "4/", "13"],
                  deloID: "1610001", deloTable: "m_case",
                  caseNumberField: "m_case__CASE_NUMBERSS",
                  uidField: "",
                  nameField: "M_PARTS__NAMESS")
    ]

    // MARK: - Районный / городской суд

    /// Первая инстанция, материалы, жалобы по КоАП и апелляция на мировых судей.
    /// Сайты мировых судей проектом не охватываются, но апелляционные дела по их
    /// актам (индексы 10-/11-/11а-) ведутся в картотеках районного суда — поэтому
    /// они здесь.
    public static let district: [Cartoteka] = [
        Cartoteka(id: "u1",   title: "Уголовное, 1-я инстанция",
                  prefixes: ["1"],
                  deloID: "1540006", deloTable: "u1_case",
                  caseNumberField: "u1_case__CASE_NUMBERSS",
                  uidField: "u1_case__JUDICIAL_UIDSS",
                  nameField: "U1_DEFENDANT__NAMESS"),
        Cartoteka(id: "u2",   title: "Уголовное, апелляция на мировых судей",
                  prefixes: ["10"],
                  deloID: "4", new: "4", deloTable: "u2_case",
                  caseNumberField: "u2_case__CASE_NUMBERSS",
                  uidField: "u2_case__JUDICIAL_UIDSS",
                  nameField: "U2_DEFENDANT__NAMESS"),
            // Платформенная пара 4&new=4 — из универсального переключателя
            // видов производства; на районном звене живьём не прогонялась.
        Cartoteka(id: "g1",   title: "Гражданское, 1-я инстанция",
                  prefixes: ["2", "м", "9"],
                  deloID: "1540005", deloTable: "g1_case",
                  caseNumberField: "g1_case__CASE_NUMBERSS",
                  uidField: "g1_case__JUDICIAL_UIDSS",
                  nameField: "G1_PARTS__NAMESS"),
            // «М-…» — материал до принятия иска (номера выдачи вида
            // «2-7212/2025 ~ М-5922/2025»): по «М-…» ищут в той же картотеке.
        Cartoteka(id: "g2",   title: "Гражданское, апелляция на мировых судей",
                  prefixes: ["11"],
                  deloID: "5", new: "5", deloTable: "g2_case",
                  caseNumberField: "g2_case__CASE_NUMBERSS",
                  uidField: "g2_case__JUDICIAL_UIDSS",
                  nameField: "G2_PARTS__NAMESS"),
        Cartoteka(id: "p1",   title: "КАС (административное), 1-я инстанция",
                  prefixes: ["2а"],
                  deloID: "41", deloTable: "p1_case",
                  caseNumberField: "p1_case__CASE_NUMBERSS",
                  uidField: "p1_case__JUDICIAL_UIDSS",
                  nameField: "P1_PARTS__NAMESS"),
        Cartoteka(id: "p2",   title: "КАС, апелляция на мировых судей",
                  prefixes: ["11а"],
                  deloID: "42", deloTable: "p2_case",
                  caseNumberField: "p2_case__CASE_NUMBERSS",
                  uidField: "p2_case__JUDICIAL_UIDSS",
                  nameField: "P2_PARTS__NAMESS"),
        Cartoteka(id: "adm",  title: "Дела об АП, 1-я инстанция",
                  prefixes: ["5"],
                  deloID: "1500001", deloTable: "adm_case",
                  caseNumberField: "adm_case__CASE_NUMBERSS",
                  uidField: "adm_case__JUDICIAL_UIDSS",
                  nameField: "adm_parts__NAMESS"),
        Cartoteka(id: "admj", title: "Жалобы по делам об АП",
                  prefixes: ["12"],
                  deloID: "1502001", deloTable: "adm1_case",
                  caseNumberField: "adm1_case__CASE_NUMBERSS",
                  uidField: "adm1_case__JUDICIAL_UIDSS",
                  nameField: "adm1_parts__NAMESS"),
        Cartoteka(id: "m",    title: "Материалы",
                  prefixes: ["3/", "4/", "13"],
                  deloID: "1610001", deloTable: "m_case",
                  caseNumberField: "m_case__CASE_NUMBERSS",
                  uidField: "m_case__JUDICIAL_UIDSS",
                  nameField: "M_PARTS__NAMESS")
    ]

    // MARK: - Суд субъекта РФ (ВС республики / краевой / областной и приравненные)

    public static let subject: [Cartoteka] = [
        Cartoteka(id: "u1",  title: "Уголовное, 1-я инстанция",
                  prefixes: ["2"],
                  deloID: "1540006", new: "0", deloTable: "u1_case",
                  caseNumberField: "u1_case__CASE_NUMBERSS",
                  uidField: "u1_case__JUDICIAL_UIDSS",
                  nameField: "U1_DEFENDANT__NAMESS"),
        Cartoteka(id: "u2",  title: "Уголовное, апелляция",
                  prefixes: ["22", "22к"],
                  deloID: "4", new: "4", deloTable: "u2_case",
                  caseNumberField: "u2_case__CASE_NUMBERSS",
                  uidField: "u2_case__JUDICIAL_UIDSS",
                  nameField: "U2_DEFENDANT__NAMESS"),
            // «22К-…» — апелляция по материалам (частные жалобы на постановления
            // районных судов по м-производствам); ведётся в той же картотеке.
        Cartoteka(id: "u33", title: "Уголовное, кассация/надзор (президиум)",
                  prefixes: ["44у", "4у"],
                  deloID: "2450001", new: "2450001", deloTable: "u33_case",
                  caseNumberField: "u33_case__CASE_NUMBERSS",
                  uidField: "u33_case__JUDICIAL_UIDSS",
                  nameField: "U33_DEFENDANT__NAMESS"),
            // Историческая (до 01.10.2019) кассация в президиуме суда субъекта:
            // «4У-…» — изучение жалоб судьёй, «44У-…» — рассмотрение президиумом.
        Cartoteka(id: "g1",  title: "Гражданское, 1-я инстанция",
                  prefixes: ["3"],
                  deloID: "1540005", new: "0", deloTable: "g1_case",
                  caseNumberField: "g1_case__CASE_NUMBERSS",
                  uidField: "g1_case__JUDICIAL_UIDSS",
                  nameField: "G1_PARTS__NAMESS"),
        Cartoteka(id: "g2",  title: "Гражданское, апелляция",
                  prefixes: ["33"],
                  deloID: "5", new: "5", deloTable: "g2_case",
                  caseNumberField: "g2_case__CASE_NUMBERSS",
                  uidField: "g2_case__JUDICIAL_UIDSS",
                  nameField: "G2_PARTS__NAMESS"),
        Cartoteka(id: "g33", title: "Гражданское, кассация (президиум)",
                  prefixes: ["44г", "4г"],
                  deloID: "2800001", new: "2800001", deloTable: "g33_case",
                  caseNumberField: "g33_case__CASE_NUMBERSS",
                  uidField: "g33_case__JUDICIAL_UIDSS",
                  nameField: "G33_PARTS__NAMESS"),
        Cartoteka(id: "p1",  title: "КАС, 1-я инстанция",
                  prefixes: ["3а"],
                  deloID: "41", new: "0", deloTable: "p1_case",
                  caseNumberField: "p1_case__CASE_NUMBERSS",
                  uidField: "p1_case__JUDICIAL_UIDSS",
                  nameField: "P1_PARTS__NAMESS"),
        Cartoteka(id: "p2",  title: "КАС, апелляция",
                  prefixes: ["33а"],
                  deloID: "42", new: "0", deloTable: "p2_case",
                  caseNumberField: "p2_case__CASE_NUMBERSS",
                  uidField: "p2_case__JUDICIAL_UIDSS",
                  nameField: "P2_PARTS__NAMESS"),
        Cartoteka(id: "p33", title: "КАС, кассация (президиум)",
                  prefixes: ["4га", "44га"],
                  deloID: "43", new: "0", deloTable: "p33_case",
                  caseNumberField: "p33_case__CASE_NUMBERSS",
                  uidField: "p33_case__JUDICIAL_UIDSS",
                  nameField: "P33_PARTS__NAMESS"),
            // Историческая (2015–2019) КАС-кассация в президиуме суда субъекта:
            // «4Га-…» — изучение жалоб судьёй, «44Га-…» — рассмотрение президиумом.
        Cartoteka(id: "adm1", title: "АП: жалобы на постановления",
                  prefixes: ["12"],
                  deloID: "1502001", new: "0", deloTable: "adm1_case",
                  caseNumberField: "adm1_case__CASE_NUMBERSS",
                  uidField: "adm1_case__JUDICIAL_UIDSS",
                  nameField: "adm1_parts__NAMESS"),
            // Жалобы на НЕ вступившие в силу постановления по делам об АП, вынесенные
            // судьёй 1-й инстанции (adm_case). Рассматривает суд субъекта (ВС/обл./
            // край.) по гл. 30 КоАП. Та же таблица adm1_case и тот же индекс
            // «12-», что и у районной картотеки «Жалобы по делам об АП», —
            // различается только суд.
        Cartoteka(id: "adm2", title: "АП: жалобы на решения по жалобам",
                  prefixes: ["21", "7"],
                  deloID: "1513001", new: "0", deloTable: "adm2_case",
                  caseNumberField: "adm2_case__CASE_NUMBERSS",
                  uidField: "adm2_case__JUDICIAL_UIDSS",
                  nameField: "adm2_parts__NAMESS"),
            // Жалобы/протесты на НЕ вступившие в силу решения по делам об АП
            // (вторая инстанция в суде субъекта). Сюда уходит протест прокурора
            // на решение райсуда по жалобе на постановление по делу об АП.
            // Индекс различается по регионам: «21-…» (напр., Коми) либо
            // «7-…» (напр., Санкт-Петербург).
        Cartoteka(id: "adm33", title: "АП: на вступившие в силу (до 10.2019)",
                  prefixes: ["4а", "п4а"],
                  deloID: "2550001", new: "0", deloTable: "adm33_case",
                  caseNumberField: "adm33_case__CASE_NUMBERSS",
                  uidField: "adm33_case__JUDICIAL_UIDSS",
                  nameField: "ADM33_PARTS__NAMESS")
            // Пересмотр вступивших постановлений председателем суда субъекта;
            // с 01.10.2019 эта компетенция передана КСОЮ (см. cassationSOYu).
    ]

    // MARK: - Апелляционные суды общей юрисдикции (АСОЮ, с 01.10.2019)

    /// АСОЮ рассматривают апелляции на акты судов субъектов, принятые ИМИ по
    /// первой инстанции (а также промежуточные акты). КоАП-производств в АСОЮ
    /// нет: решения судов субъектов по гл. 30 КоАП вступают в силу немедленно
    /// и пересматриваются сразу в КСОЮ.
    public static let appealSOYu: [Cartoteka] = [
        Cartoteka(id: "u2", title: "Уголовное, апелляция (АСОЮ)",
                  prefixes: ["55", "55к"],
                  deloID: "4", new: "4", deloTable: "u2_case",
                  caseNumberField: "u2_case__CASE_NUMBERSS",
                  uidField: "u2_case__JUDICIAL_UIDSS",
                  nameField: "U2_DEFENDANT__NAMESS"),
        Cartoteka(id: "g2", title: "Гражданское, апелляция (АСОЮ)",
                  prefixes: ["66"],
                  deloID: "5", new: "5", deloTable: "g2_case",
                  caseNumberField: "g2_case__CASE_NUMBERSS",
                  uidField: "g2_case__JUDICIAL_UIDSS",
                  nameField: "G2_PARTS__NAMESS"),
        Cartoteka(id: "p2", title: "КАС, апелляция (АСОЮ)",
                  prefixes: ["66а"],
                  deloID: "42", new: "0", deloTable: "p2_case",
                  caseNumberField: "p2_case__CASE_NUMBERSS",
                  uidField: "p2_case__JUDICIAL_UIDSS",
                  nameField: "P2_PARTS__NAMESS")
    ]

    // MARK: - Кассационные суды общей юрисдикции (КСОЮ, с 01.10.2019)

    /// «Первая» (сплошная/выборочная) кассация. Пары `delo_id`/`new` — из
    /// универсального переключателя видов производства (фикстура КСОЮ):
    /// уголовные 4&new=2450001, гражданские 5&new=2800001, КАС 43.
    /// Индексы КСОЮ: «7У-/8Г-/8а-» — изучение жалобы судьёй,
    /// «77-/88-/88а-» — кассационное производство в заседании.
    public static let cassationSOYu: [Cartoteka] = [
        Cartoteka(id: "u3", title: "Уголовное, кассация (КСОЮ)",
                  prefixes: ["77", "7у"],
                  deloID: "4", new: "2450001", deloTable: "u33_case",
                  caseNumberField: "u33_case__CASE_NUMBERSS",
                  uidField: "u33_case__JUDICIAL_UIDSS",
                  nameField: "U33_DEFENDANT__NAMESS"),
        Cartoteka(id: "g3", title: "Гражданское, кассация (КСОЮ)",
                  prefixes: ["88", "8г"],
                  deloID: "5", new: "2800001", deloTable: "g33_case",
                  caseNumberField: "g33_case__CASE_NUMBERSS",
                  uidField: "g33_case__JUDICIAL_UIDSS",
                  nameField: "G33_PARTS__NAMESS"),
        Cartoteka(id: "p3", title: "КАС, кассация (КСОЮ)",
                  prefixes: ["88а", "8а"],
                  deloID: "43", new: "0", deloTable: "p33_case",
                  caseNumberField: "p33_case__CASE_NUMBERSS",
                  uidField: "p33_case__JUDICIAL_UIDSS",
                  nameField: "P33_PARTS__NAMESS"),
        Cartoteka(id: "adm3", title: "АП: на вступившие в силу (КСОЮ)",
                  prefixes: ["16", "п16"],
                  deloID: "2550001", new: "0", deloTable: "adm33_case",
                  caseNumberField: "adm33_case__CASE_NUMBERSS",
                  uidField: "adm33_case__JUDICIAL_UIDSS",
                  nameField: "ADM33_PARTS__NAMESS")
            // Ст. 30.13 КоАП: жалобы/протесты на вступившие в силу постановления
            // и решения по делам об АП рассматривает КСОЮ (судья единолично,
            // акт — постановление). «П16-…» встречается наряду с «16-…».
    ]
}
