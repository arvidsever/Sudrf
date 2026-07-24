//  MosGorSudCourtDirectory.swift — Sudrf
//  Справочник районных судов Москвы портала mos-gorsud.ru. Москва не на
//  платформе sudrf.ru, живого резолвера районных судов для неё нет — список
//  запечён из собственного JS портала (объекты {code, alias, fullName} формы
//  поиска). `alias` уходит в запрос как `courtAlias`, он же виден в пути
//  ссылки результата (/rs/<alias>/…). Мосгорсуд (77OS0000/mgs) — звено
//  субъекта, здесь только районные (77RS…).

import Foundation

public struct MosGorSudCourt: Sendable, Equatable {
    public let alias: String    // courtAlias портала, напр. "tverskoj"
    public let code: String     // классификационный код, напр. "77RS0027"
    public let title: String    // «Тверской районный суд»

    public init(alias: String, code: String, title: String) {
        self.alias = alias; self.code = code; self.title = title
    }
}

public enum MosGorSudCourtDirectory {
    /// Числовой код субъекта «город Москва» (77) — по нему гейтим ветку портала,
    /// отделяя от Московской области (50).
    public static let moscowSubjectCode = "77"

    /// Алиас Мосгорсуда (звено субъекта) в форме поиска портала.
    public static let mgsAlias = "mgs"

    /// 35 районных судов Москвы, отсортированы по названию.
    public static let districtCourts: [MosGorSudCourt] = [
        MosGorSudCourt(alias: "babushkinskij", code: "77RS0001", title: "Бабушкинский районный суд"),
        MosGorSudCourt(alias: "basmannyj", code: "77RS0002", title: "Басманный районный суд"),
        MosGorSudCourt(alias: "butyrskij", code: "77RS0003", title: "Бутырский районный суд"),
        MosGorSudCourt(alias: "gagarinskij", code: "77RS0004", title: "Гагаринский районный суд"),
        MosGorSudCourt(alias: "golovinskij", code: "77RS0005", title: "Головинский районный суд"),
        MosGorSudCourt(alias: "dorogomilovskij", code: "77RS0006", title: "Дорогомиловский районный суд"),
        MosGorSudCourt(alias: "zamoskvoreckij", code: "77RS0007", title: "Замоскворецкий районный суд"),
        MosGorSudCourt(alias: "zelenogradskij", code: "77RS0008", title: "Зеленоградский районный суд"),
        MosGorSudCourt(alias: "zyuzinskij", code: "77RS0009", title: "Зюзинский районный суд"),
        MosGorSudCourt(alias: "izmajlovskij", code: "77RS0010", title: "Измайловский районный суд"),
        MosGorSudCourt(alias: "koptevskij", code: "77RS0011", title: "Коптевский районный суд"),
        MosGorSudCourt(alias: "kuzminskij", code: "77RS0012", title: "Кузьминский районный суд"),
        MosGorSudCourt(alias: "kuncevskij", code: "77RS0013", title: "Кунцевский районный суд"),
        MosGorSudCourt(alias: "lefortovskij", code: "77RS0014", title: "Лефортовский районный суд"),
        MosGorSudCourt(alias: "lyublinskij", code: "77RS0015", title: "Люблинский районный суд"),
        MosGorSudCourt(alias: "meshchanskij", code: "77RS0016", title: "Мещанский районный суд"),
        MosGorSudCourt(alias: "nagatinskij", code: "77RS0017", title: "Нагатинский районный суд"),
        MosGorSudCourt(alias: "nikulinskij", code: "77RS0018", title: "Никулинский районный суд"),
        MosGorSudCourt(alias: "ostankinskij", code: "77RS0019", title: "Останкинский районный суд"),
        MosGorSudCourt(alias: "perovskij", code: "77RS0020", title: "Перовский районный суд"),
        MosGorSudCourt(alias: "presnenskij", code: "77RS0021", title: "Пресненский районный суд"),
        MosGorSudCourt(alias: "preobrazhenskij", code: "77RS0022", title: "Преображенский районный суд"),
        MosGorSudCourt(alias: "savelovskij", code: "77RS0023", title: "Савёловский районный суд"),
        MosGorSudCourt(alias: "simonovskij", code: "77RS0024", title: "Симоновский районный суд"),
        MosGorSudCourt(alias: "solncevskij", code: "77RS0025", title: "Солнцевский районный суд"),
        MosGorSudCourt(alias: "taganskij", code: "77RS0026", title: "Таганский районный суд"),
        MosGorSudCourt(alias: "tverskoj", code: "77RS0027", title: "Тверской районный суд"),
        MosGorSudCourt(alias: "timiryazevskij", code: "77RS0028", title: "Тимирязевский районный суд"),
        MosGorSudCourt(alias: "tushinskij", code: "77RS0029", title: "Тушинский районный суд"),
        MosGorSudCourt(alias: "hamovnicheskij", code: "77RS0030", title: "Хамовнический районный суд"),
        MosGorSudCourt(alias: "horoshevskij", code: "77RS0031", title: "Хорошёвский районный суд"),
        MosGorSudCourt(alias: "cheremushkinskij", code: "77RS0032", title: "Черёмушкинский районный суд"),
        MosGorSudCourt(alias: "chertanovskij", code: "77RS0033", title: "Чертановский районный суд"),
        MosGorSudCourt(alias: "shcherbinskij", code: "77RS0034", title: "Щербинский районный суд"),
        MosGorSudCourt(alias: "troickij", code: "77RS0035", title: "Троицкий районный суд"),
    ].sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

    public static func title(forAlias alias: String) -> String? {
        districtCourts.first { $0.alias == alias }?.title
    }
}
