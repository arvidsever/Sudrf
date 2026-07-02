import Foundation

/// Справочник судов субъектового, апелляционного и кассационного звеньев,
/// сгенерированный из справочника КонсультантПлюс «Верховный Суд РФ и федеральные
/// суды общей юрисдикции». Избавляет от веб-резолва доменов для этих звеньев.
///
/// ВНИМАНИЕ: районные/городские суды здесь НЕ перечислены (их в справочнике нет) —
/// их домены по-прежнему резолвятся отдельно.

/// Суд с фиксированным доменом.
public struct DirectoryCourt: Sendable, Equatable {
    public let title: String
    public let domain: String
    public let level: CourtLevel
    /// Домен на платформе sudrf.ru (для прочих модуль sud_delo может быть недоступен по этому хосту).
    public var isSudrfPlatform: Bool { domain.hasSuffix("sudrf.ru") }
    public var court: Court { Court(domain: domain, title: title, level: level) }
}

/// Кассационный/апелляционный суд ОСЮ с территориальной подсудностью.
public struct TerritorialCourt: Sendable, Equatable {
    public let number: Int
    public let title: String
    public let domain: String
    public let regions: [String]   // регионы как в подсудности
    public var court: Court {
        Court(domain: domain, title: title,
              level: title.contains("кассацион") ? .cassation : .appeal)
    }
}

public enum CourtDirectory {
    /// ВС республик, краевые/областные суды, города федерального значения, автономии.
    public static let subjectCourts: [DirectoryCourt] = [
        DirectoryCourt(title: "Верховный суд Республики Адыгея", domain: "vs.adg.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Алтай", domain: "vs.ralt.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Башкортостан", domain: "vs.bkr.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Бурятия", domain: "vs.bur.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Дагестан", domain: "vs.dag.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Ингушетия", domain: "vs.ing.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Кабардино-Балкарской Республики", domain: "vs.kbr.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Калмыкия", domain: "vs.kalm.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Карачаево-Черкесской Республики", domain: "vs.kchr.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Карелия", domain: "vs.kar.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Коми", domain: "vs--komi.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Крым", domain: "vs.krm.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Марий Эл", domain: "vs.mari.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Мордовия", domain: "vs.mor.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Саха (Якутия)", domain: "vs.jak.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Северная Осетия - Алания", domain: "vs.wlk.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Татарстан", domain: "vs.tat.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Тыва", domain: "vs.tva.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Удмуртской Республики", domain: "vs.udm.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Республики Хакасия", domain: "vs.hak.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Чеченской Республики", domain: "vs.chn.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный суд Чувашской Республики", domain: "vs.chv.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Алтайский краевой суд", domain: "kraevoy.alt.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Забайкальский краевой суд", domain: "oblsud.cht.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Камчатский краевой суд", domain: "oblsud.kam.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Краснодарский краевой суд", domain: "kraevoi.krd.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Красноярский краевой суд", domain: "kraevoy.krk.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Пермский краевой суд", domain: "oblsud.perm.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Приморский краевой суд", domain: "kraevoy.prm.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Ставропольский краевой суд", domain: "kraevoy.stv.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Хабаровский краевой суд", domain: "kraevoy.hbr.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Амурский областной суд", domain: "oblsud.amr.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Архангельский областной суд", domain: "oblsud.arh.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Астраханский областной суд", domain: "oblsud.ast.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Белгородский областной суд", domain: "oblsud.blg.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Брянский областной суд", domain: "oblsud.brj.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Владимирский областной суд", domain: "oblsud.wld.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Волгоградский областной суд", domain: "oblsud.vol.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Вологодский областной суд", domain: "oblsud.vld.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Воронежский областной суд", domain: "oblsud.vrn.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Ивановский областной суд", domain: "oblsud.iwn.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Иркутский областной суд", domain: "oblsud.irk.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Калининградский областной суд", domain: "oblsud.kln.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Калужский областной суд", domain: "oblsud.klg.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Кемеровский областной суд", domain: "oblsud.kmr.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Кировский областной суд", domain: "oblsud.kir.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Костромской областной суд", domain: "oblsud.kst.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Курганский областной суд", domain: "oblsud.krg.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Курский областной суд", domain: "oblsud.krs.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Ленинградский областной суд", domain: "oblsud.lo.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Липецкий областной суд", domain: "oblsud.lpk.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Магаданский областной суд", domain: "oblsud.mag.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Московский областной суд", domain: "oblsud.mo.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Мурманский областной суд", domain: "oblsud.mrm.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Нижегородский областной суд", domain: "nnoblsud.ru", level: .subject),
        DirectoryCourt(title: "Новгородский областной суд", domain: "oblsud.nvg.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Новосибирский областной суд", domain: "oblsud.nsk.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Омский областной суд", domain: "oblsud.oms.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Оренбургский областной суд", domain: "oblsud.orb.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Орловский областной суд", domain: "oblsud.orl.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Пензенский областной суд", domain: "oblsud.pnz.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Псковский областной суд", domain: "oblsud.psk.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Ростовский областной суд", domain: "oblsud.ros.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Рязанский областной суд", domain: "oblsud.riz.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Самарский областной суд", domain: "oblsud.sam.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Саратовский областной суд", domain: "oblsud.sar.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Сахалинский областной суд", domain: "oblsud.sah.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Свердловский областной суд", domain: "oblsud.svd.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Смоленский областной суд", domain: "oblsud.sml.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Тамбовский областной суд", domain: "oblsud.tmb.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Тверской областной суд", domain: "oblsud.twr.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Томский областной суд", domain: "oblsud.tms.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Тульский областной суд", domain: "oblsud.tula.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Тюменский областной суд", domain: "oblsud.tum.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Ульяновский областной суд", domain: "oblsud.uln.sudrf.ru", level: .subject),
        // Добавлены по живой выгрузке портала (в исходном справочнике отсутствовали):
        DirectoryCourt(title: "Севастопольский городской суд", domain: "gs.sev.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Запорожский областной суд", domain: "oblsud.zpr.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный Суд Донецкой Народной Республики", domain: "vs.dnr.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Верховный Суд Луганской Народной Республики", domain: "vs.lnr.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Херсонский областной суд", domain: "oblsud.hrs.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Челябинский областной суд", domain: "oblsud.chel.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Ярославский областной суд", domain: "oblsud.jrs.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Московский городской суд", domain: "www.mos-gorsud.ru", level: .subject),
        DirectoryCourt(title: "Санкт-Петербургский городской суд", domain: "sankt-peterburgsky.spb.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Суд Еврейской автономной области", domain: "os.brb.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Суд Ненецкого автономного округа", domain: "sud.nao.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Суд Ханты-Мансийского автономного округа - Югры", domain: "oblsud.hmao.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Суд Чукотского автономного округа", domain: "oblsud.chao.sudrf.ru", level: .subject),
        DirectoryCourt(title: "Суд Ямало-Ненецкого автономного округа", domain: "oblsud.ynao.sudrf.ru", level: .subject),
    ]

    /// Кассационные суды ОСЮ (1–9).
    public static let cassationCourts: [TerritorialCourt] = [
        TerritorialCourt(number: 1, title: "Первый кассационный суд", domain: "1kas.sudrf.ru", regions: ["Республика Мордовия", "Белгородская область", "Брянская область", "Воронежская область", "Калужская область", "Курская область", "Липецкая область", "Орловская область", "Московская область", "Нижегородская область", "Пензенская область", "Саратовская область", "Тульская область"]),
        TerritorialCourt(number: 2, title: "Второй кассационный суд", domain: "2kas.sudrf.ru", regions: ["город Москва", "Владимирская область", "Ивановская область", "Костромская область", "Рязанская область", "Смоленская область", "Тамбовская область", "Тверская область", "Ярославская область"]),
        TerritorialCourt(number: 3, title: "Третий кассационный суд", domain: "3kas.sudrf.ru", regions: ["город Санкт-Петербург", "Республика Карелия", "Республика Коми", "Архангельская область", "Вологодская область", "Калининградская область", "Ленинградская область", "Мурманская область", "Новгородская область", "Псковская область", "Ненецкий автономный округ"]),
        TerritorialCourt(number: 4, title: "Четвертый кассационный суд", domain: "4kas.sudrf.ru", regions: ["город Севастополь", "Республика Адыгея (Адыгея)", "Республика Калмыкия", "Республика Крым", "Краснодарский край", "Астраханская область", "Волгоградская область", "Ростовская область"]),
        TerritorialCourt(number: 5, title: "Пятый кассационный суд", domain: "5kas.sudrf.ru", regions: ["Республика Дагестан", "Республика Ингушетия", "Кабардино-Балкарская Республика", "Карачаево-Черкесская Республика", "Республика Северная Осетия - Алания", "Чеченская Республика", "Ставропольский край"]),
        TerritorialCourt(number: 6, title: "Шестой кассационный суд", domain: "6kas.sudrf.ru", regions: ["Республика Башкортостан", "Республика Марий Эл", "Республика Татарстан (Татарстан)", "Удмуртская Республика", "Чувашская Республика - Чувашия", "Кировская область", "Оренбургская область", "Самарская область", "Ульяновская область"]),
        TerritorialCourt(number: 7, title: "Седьмой кассационный суд", domain: "7kas.sudrf.ru", regions: ["Пермский край", "Курганская область", "Свердловская область", "Тюменская область", "Челябинская область", "Ханты-Мансийский автономный округ - Югра", "Ямало-Ненецкий автономный округ"]),
        TerritorialCourt(number: 8, title: "Восьмой кассационный суд", domain: "8kas.sudrf.ru", regions: ["Республика Алтай", "Республика Бурятия", "Республика Тыва", "Республика Хакасия", "Алтайский край", "Забайкальский край", "Красноярский край", "Иркутская область", "Кемеровская область", "Новосибирская область", "Омская область", "Томская область"]),
        TerritorialCourt(number: 9, title: "Девятый кассационный суд", domain: "9kas.sudrf.ru", regions: ["Республика Саха (Якутия)", "Камчатский край", "Приморский край", "Хабаровский край", "Амурская область", "Магаданская область", "Сахалинская область", "Еврейская автономная область", "Чукотский автономный округ"]),
    ]

    /// Апелляционные суды ОСЮ (1–5).
    public static let appealCourts: [TerritorialCourt] = [
        TerritorialCourt(number: 1, title: "Первый апелляционный суд", domain: "1ap.sudrf.ru", regions: ["город Москва", "Московская область", "Белгородская область", "Брянская область", "Владимирская область", "Воронежская область", "Ивановская область", "Калининградская область", "Калужская область", "Костромская область", "Курская область", "Липецкая область", "Новгородская область", "Орловская область", "Псковская область", "Рязанская область", "Смоленская область", "Тамбовская область", "Тверская область", "Тульская область", "Ярославская область"]),
        TerritorialCourt(number: 2, title: "Второй апелляционный суд", domain: "2ap.sudrf.ru", regions: ["город Санкт-Петербург", "Ленинградская область", "Республика Карелия", "Республика Коми", "Архангельская область", "Вологодская область", "Курганская область", "Мурманская область", "Свердловская область", "Тюменская область", "Челябинская область", "Ненецкий автономный округ", "Ханты-Мансийский автономный округ - Югра", "Ямало-Ненецкий автономный округ"]),
        TerritorialCourt(number: 3, title: "Третий апелляционный суд", domain: "3ap.sudrf.ru", regions: ["город Севастополь", "Республика Адыгея (Адыгея)", "Республика Дагестан", "Республика Ингушетия", "Кабардино-Балкарская Республика", "Республика Калмыкия", "Карачаево-Черкесская Республика", "Республика Крым", "Республика Северная Осетия - Алания", "Чеченская Республика", "Краснодарский край", "Ставропольский край", "Астраханская область", "Волгоградская область", "Ростовская область"]),
        TerritorialCourt(number: 4, title: "Четвертый апелляционный суд", domain: "4ap.sudrf.ru", regions: ["Республика Башкортостан", "Республика Марий Эл", "Республика Мордовия", "Республика Татарстан (Татарстан)", "Удмуртская Республика", "Чувашская Республика", "Пермский край", "Кировская область", "Нижегородская область", "Оренбургская область", "Пензенская область", "Самарская область", "Саратовская область", "Ульяновская область"]),
        TerritorialCourt(number: 5, title: "Пятый апелляционный суд", domain: "5ap.sudrf.ru", regions: ["Республика Алтай", "Республика Бурятия", "Республика Саха (Якутия)", "Республика Тыва", "Республика Хакасия", "Алтайский край", "Забайкальский край", "Камчатский край", "Красноярский край", "Приморский край", "Хабаровский край", "Амурская область", "Иркутская область", "Кемеровская область", "Магаданская область", "Новосибирская область", "Омская область", "Сахалинская область", "Томская область", "Еврейская автономная область", "Чукотский автономный округ"]),
    ]

    // MARK: - поиск и маршрутизация

    /// Кассационный суд ОСЮ по региону (субъекту РФ).
    public static func cassationCourt(forRegion region: String) -> TerritorialCourt? {
        cassationCourts.first { c in c.regions.contains { regionsMatch($0, region) } }
    }

    /// Апелляционный суд ОСЮ по региону (субъекту РФ).
    public static func appealCourt(forRegion region: String) -> TerritorialCourt? {
        appealCourts.first { c in c.regions.contains { regionsMatch($0, region) } }
    }

    /// Суд субъекта по подстроке названия (напр. "Коми", "Свердлов").
    public static func subjectCourt(matching query: String) -> DirectoryCourt? {
        let q = normalize(query)
        return subjectCourts.first { normalize($0.title).contains(q) }
    }

    /// Любой суд справочника по точному хосту.
    public static func court(forDomain domain: String) -> Court? {
        let host = domain.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let s = subjectCourts.first(where: { $0.domain == host }) { return s.court }
        if let k = cassationCourts.first(where: { $0.domain == host }) { return k.court }
        if let a = appealCourts.first(where: { $0.domain == host }) { return a.court }
        return nil
    }

    // MARK: - нормализация

    private static func regionsMatch(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.contains(y) || y.contains(x)
    }

    private static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) })
    }
}

// MARK: - Подсудность по региональным кодам

public extension CourtDirectory {

    /// Нормализация регионального кода: принимает «11», «11RS0001», «7» —
    /// возвращает двузначный код субъекта.
    static func normalizedSubjectCode(_ raw: String) -> String {
        let digits = String(raw.prefix(while: \.isNumber))
        let d = digits.isEmpty ? String(raw.filter(\.isNumber).prefix(2)) : String(digits.prefix(2))
        return d.count == 1 ? "0" + d : d
    }

    /// КСОЮ по региональному коду (первые две цифры классификационного кода
    /// суда / кода субъекта в УИД). Сгенерировано из территориальной
    /// подсудности и выверено вручную. Новые субъекты (90 Запорожская,
    /// 93 ДНР, 94 ЛНР, 96 Херсонская) не расписаны — дополнить по мере
    /// уточнения подсудности.
    static func cassationCourt(forSubjectCode raw: String) -> TerritorialCourt? {
        cassationNumberBySubjectCode[normalizedSubjectCode(raw)]
            .flatMap { n in cassationCourts.first { $0.number == n } }
    }

    /// АСОЮ по региональному коду.
    static func appealCourt(forSubjectCode raw: String) -> TerritorialCourt? {
        appealNumberBySubjectCode[normalizedSubjectCode(raw)]
            .flatMap { n in appealCourts.first { $0.number == n } }
    }

    /// Суд субъекта по региональному коду.
    static func subjectCourt(forSubjectCode raw: String) -> DirectoryCourt? {
        subjectCourtDomainByCode[normalizedSubjectCode(raw)]
            .flatMap { d in subjectCourts.first { $0.domain == d } }
    }

    /// Синонимичный «--»-домен платформы sudrf: каждый сайт доступен и как
    /// host.region.sudrf.ru, и как host--region.sudrf.ru (последняя точка
    /// перед sudrf.ru заменяется двойным дефисом); модуль sud_delo работает
    /// именно на дефисном варианте. Для односегментных хостов (3kas, vap,
    /// vkas, 2ap) и доменов вне платформы возвращает nil.
    static func dashVariant(of domain: String) -> String? {
        guard domain.hasSuffix(".sudrf.ru"), !domain.contains("--") else { return nil }
        let head = String(domain.dropLast(".sudrf.ru".count))
        guard let dot = head.lastIndex(of: ".") else { return nil }
        return head[..<dot] + "--" + head[head.index(after: dot)...] + ".sudrf.ru"
    }

    /// Региональный код по домену суда субъекта (обратная таблица).
    static func subjectCode(forDomain domain: String) -> String? {
        var host = domain.lowercased()
        for pre in ["https://", "http://"] where host.hasPrefix(pre) { host.removeFirst(pre.count) }
        host = host.split(separator: "/").first.map(String.init) ?? host
        return subjectCourtDomainByCode.first { $0.value == host }?.key
    }

    internal static let cassationNumberBySubjectCode: [String: Int] = [
        "13": 1, "31": 1, "32": 1, "36": 1, "40": 1, "46": 1, "48": 1,
        "50": 1, "52": 1, "57": 1, "58": 1, "64": 1, "71": 1,
        "33": 2, "37": 2, "44": 2, "62": 2, "67": 2, "68": 2, "69": 2, "76": 2, "77": 2,
        "90": 2, "93": 2, "94": 2, "96": 2,   // Запорожская, ДНР, ЛНР, Херсонская — Второй КСОЮ
        "10": 3, "11": 3, "29": 3, "35": 3, "39": 3, "47": 3, "51": 3,
        "53": 3, "60": 3, "78": 3, "83": 3,
        "01": 4, "08": 4, "23": 4, "30": 4, "34": 4, "61": 4, "91": 4, "92": 4,
        "05": 5, "06": 5, "07": 5, "09": 5, "15": 5, "20": 5, "26": 5,
        "03": 6, "12": 6, "16": 6, "18": 6, "21": 6, "43": 6, "56": 6, "63": 6, "73": 6,
        "45": 7, "59": 7, "66": 7, "72": 7, "74": 7, "86": 7, "89": 7,
        "02": 8, "04": 8, "17": 8, "19": 8, "22": 8, "24": 8, "38": 8,
        "42": 8, "54": 8, "55": 8, "70": 8, "75": 8,
        "14": 9, "25": 9, "27": 9, "28": 9, "41": 9, "49": 9, "65": 9, "79": 9, "87": 9
    ]

    internal static let appealNumberBySubjectCode: [String: Int] = [
        "31": 1, "32": 1, "33": 1, "36": 1, "37": 1, "39": 1, "40": 1, "44": 1,
        "46": 1, "48": 1, "50": 1, "53": 1, "57": 1, "60": 1, "62": 1, "67": 1,
        "68": 1, "69": 1, "71": 1, "76": 1, "77": 1,
        "90": 1, "93": 1, "94": 1, "96": 1,   // Запорожская, ДНР, ЛНР, Херсонская — Первый АСОЮ
        "10": 2, "11": 2, "29": 2, "35": 2, "45": 2, "47": 2, "51": 2,
        "66": 2, "72": 2, "74": 2, "78": 2, "83": 2, "86": 2, "89": 2,
        "01": 3, "05": 3, "06": 3, "07": 3, "08": 3, "09": 3, "15": 3, "20": 3,
        "23": 3, "26": 3, "30": 3, "34": 3, "61": 3, "91": 3, "92": 3,
        "03": 4, "12": 4, "13": 4, "16": 4, "18": 4, "21": 4, "43": 4, "52": 4,
        "56": 4, "58": 4, "59": 4, "63": 4, "64": 4, "73": 4,
        "02": 5, "04": 5, "14": 5, "17": 5, "19": 5, "22": 5, "24": 5, "25": 5,
        "27": 5, "28": 5, "38": 5, "41": 5, "42": 5, "49": 5, "54": 5, "55": 5,
        "65": 5, "70": 5, "75": 5, "79": 5, "87": 5
    ]

    /// Региональный код → домен суда субъекта. Сгенерировано сопоставлением
    /// справочника с портальной таблицей субъектов; коллизии («22» ВС Алтая ↔
    /// Алтайский краевой, «50/77» облсуд ↔ Мосгорсуд) разведены вручную.
    /// Полнота сверена с живой выгрузкой портала (court_type=OS): все 89
    /// кодов, включая Севастополь (92) и новые субъекты (90/93/94/96).
    /// Примечание: для Коми портал даёт официальный сайт vs.komi.sudrf.ru,
    /// здесь — рабочий sud_delo-хост vs--komi; движение дела пробует оба.
    internal static let subjectCourtDomainByCode: [String: String] = [
        "01": "vs.adg.sudrf.ru",      "02": "vs.ralt.sudrf.ru",
        "03": "vs.bkr.sudrf.ru",      "04": "vs.bur.sudrf.ru",
        "05": "vs.dag.sudrf.ru",      "06": "vs.ing.sudrf.ru",
        "07": "vs.kbr.sudrf.ru",      "08": "vs.kalm.sudrf.ru",
        "09": "vs.kchr.sudrf.ru",     "10": "vs.kar.sudrf.ru",
        "11": "vs--komi.sudrf.ru",    "12": "vs.mari.sudrf.ru",
        "13": "vs.mor.sudrf.ru",      "14": "vs.jak.sudrf.ru",
        "15": "vs.wlk.sudrf.ru",      "16": "vs.tat.sudrf.ru",
        "17": "vs.tva.sudrf.ru",      "18": "vs.udm.sudrf.ru",
        "19": "vs.hak.sudrf.ru",      "20": "vs.chn.sudrf.ru",
        "21": "vs.chv.sudrf.ru",      "22": "kraevoy.alt.sudrf.ru",
        "23": "kraevoi.krd.sudrf.ru", "24": "kraevoy.krk.sudrf.ru",
        "25": "kraevoy.prm.sudrf.ru", "26": "kraevoy.stv.sudrf.ru",
        "27": "kraevoy.hbr.sudrf.ru", "28": "oblsud.amr.sudrf.ru",
        "29": "oblsud.arh.sudrf.ru",  "30": "oblsud.ast.sudrf.ru",
        "31": "oblsud.blg.sudrf.ru",  "32": "oblsud.brj.sudrf.ru",
        "33": "oblsud.wld.sudrf.ru",  "34": "oblsud.vol.sudrf.ru",
        "35": "oblsud.vld.sudrf.ru",  "36": "oblsud.vrn.sudrf.ru",
        "37": "oblsud.iwn.sudrf.ru",  "38": "oblsud.irk.sudrf.ru",
        "39": "oblsud.kln.sudrf.ru",  "40": "oblsud.klg.sudrf.ru",
        "41": "oblsud.kam.sudrf.ru",  "42": "oblsud.kmr.sudrf.ru",
        "43": "oblsud.kir.sudrf.ru",  "44": "oblsud.kst.sudrf.ru",
        "45": "oblsud.krg.sudrf.ru",  "46": "oblsud.krs.sudrf.ru",
        "47": "oblsud.lo.sudrf.ru",   "48": "oblsud.lpk.sudrf.ru",
        "49": "oblsud.mag.sudrf.ru",  "50": "oblsud.mo.sudrf.ru",
        "51": "oblsud.mrm.sudrf.ru",  "52": "nnoblsud.ru",
        "53": "oblsud.nvg.sudrf.ru",  "54": "oblsud.nsk.sudrf.ru",
        "55": "oblsud.oms.sudrf.ru",  "56": "oblsud.orb.sudrf.ru",
        "57": "oblsud.orl.sudrf.ru",  "58": "oblsud.pnz.sudrf.ru",
        "59": "oblsud.perm.sudrf.ru", "60": "oblsud.psk.sudrf.ru",
        "61": "oblsud.ros.sudrf.ru",  "62": "oblsud.riz.sudrf.ru",
        "63": "oblsud.sam.sudrf.ru",  "64": "oblsud.sar.sudrf.ru",
        "65": "oblsud.sah.sudrf.ru",  "66": "oblsud.svd.sudrf.ru",
        "67": "oblsud.sml.sudrf.ru",  "68": "oblsud.tmb.sudrf.ru",
        "69": "oblsud.twr.sudrf.ru",  "70": "oblsud.tms.sudrf.ru",
        "71": "oblsud.tula.sudrf.ru", "72": "oblsud.tum.sudrf.ru",
        "73": "oblsud.uln.sudrf.ru",  "74": "oblsud.chel.sudrf.ru",
        "75": "oblsud.cht.sudrf.ru",  "76": "oblsud.jrs.sudrf.ru",
        "77": "www.mos-gorsud.ru",    "78": "sankt-peterburgsky.spb.sudrf.ru",
        "79": "os.brb.sudrf.ru",      "83": "sud.nao.sudrf.ru",
        "86": "oblsud.hmao.sudrf.ru", "87": "oblsud.chao.sudrf.ru",
        "89": "oblsud.ynao.sudrf.ru", "91": "vs.krm.sudrf.ru",
        // Живая выгрузка портала (коды NN OS 0000):
        "90": "oblsud.zpr.sudrf.ru",  "92": "gs.sev.sudrf.ru",
        "93": "vs.dnr.sudrf.ru",      "94": "vs.lnr.sudrf.ru",
        "96": "oblsud.hrs.sudrf.ru"
    ]
}

// MARK: - Военные суды: вышестоящие звенья (хардкод, снято живьём)

public extension CourtDirectory {

    /// Окружные (флотские) военные суды — все ДЕВЯТЬ, как их отдаёт портал
    /// (court_type=OV&court_subj=0): шесть окружных и три флотских. Домены и
    /// классификационные коды сняты с живой выдачи портала.
    static let okrugMilitaryCourts: [DirectoryCourt] = [
        DirectoryCourt(title: "1-й Восточный окружной военный суд",    domain: "1vovs.hbr.sudrf.ru",          level: .subject), // 27OV0000
        DirectoryCourt(title: "1-й Западный окружной военный суд",     domain: "1zovs.spb.sudrf.ru",          level: .subject), // 78OV0000
        DirectoryCourt(title: "2-й Восточный окружной военный суд",    domain: "2vovs.cht.sudrf.ru",          level: .subject), // 75OV0000
        DirectoryCourt(title: "2-й Западный окружной военный суд",     domain: "2zovs.msk.sudrf.ru",          level: .subject), // 77OV0000
        DirectoryCourt(title: "Балтийский флотский военный суд",       domain: "baltovs.kln.sudrf.ru",        level: .subject), // 39OV0000
        DirectoryCourt(title: "Северный флотский военный суд",         domain: "severnyfvs.mrm.sudrf.ru",     level: .subject), // 51OV0000
        DirectoryCourt(title: "Тихоокеанский флотский военный суд",    domain: "tihookeanskyfvs.prm.sudrf.ru", level: .subject), // 25OV0000
        DirectoryCourt(title: "Центральный окружной военный суд",      domain: "covs.svd.sudrf.ru",           level: .subject), // 66OV0001
        DirectoryCourt(title: "Южный окружной военный суд",            domain: "yovs.ros.sudrf.ru",           level: .subject)  // 61OV0000
    ]

    /// Апелляционный военный суд (г. Власиха Московской области) — один на
    /// страну. Домен живой: vap.sudrf.ru.
    static let appellateMilitaryCourt = DirectoryCourt(
        title: "Апелляционный военный суд", domain: "vap.sudrf.ru", level: .appeal)

    /// Кассационный военный суд (г. Новосибирск) — один на страну.
    /// Домен живой: vkas.sudrf.ru.
    static let cassationMilitaryCourt = DirectoryCourt(
        title: "Кассационный военный суд", domain: "vkas.sudrf.ru", level: .cassation)

    /// Территориальная юрисдикция окружных (флотских) военных судов —
    /// ст. 1 Федерального закона от 27.12.2009 № 345-ФЗ (ред. от 27.11.2023):
    /// региональный код субъекта → домен ОВС. Классификационный код
    /// гарнизонного суда несёт субъект ДИСЛОКАЦИИ (224 ГВС в СПб — 39GV0005,
    /// калининградский), и 345-ФЗ распределяет юрисдикцию именно по нему —
    /// поэтому маршрут «гарнизонный → его окружной» строится этой таблицей.
    static func okrugMilitaryCourt(forSubjectCode raw: String) -> DirectoryCourt? {
        okrugMilitaryDomainBySubjectCode[normalizedSubjectCode(raw)]
            .flatMap { d in okrugMilitaryCourts.first { $0.domain == d } }
    }

    internal static let okrugMilitaryDomainBySubjectCode: [String: String] = [
        // 1-й Западный: Карелия, Коми, Вологодская, Ленинградская,
        // Новгородская, Псковская, Санкт-Петербург
        "10": "1zovs.spb.sudrf.ru", "11": "1zovs.spb.sudrf.ru", "35": "1zovs.spb.sudrf.ru",
        "47": "1zovs.spb.sudrf.ru", "53": "1zovs.spb.sudrf.ru", "60": "1zovs.spb.sudrf.ru",
        "78": "1zovs.spb.sudrf.ru",
        // 2-й Западный: Белгородская…Ярославская и Москва
        "31": "2zovs.msk.sudrf.ru", "32": "2zovs.msk.sudrf.ru", "33": "2zovs.msk.sudrf.ru",
        "36": "2zovs.msk.sudrf.ru", "37": "2zovs.msk.sudrf.ru", "40": "2zovs.msk.sudrf.ru",
        "44": "2zovs.msk.sudrf.ru", "46": "2zovs.msk.sudrf.ru", "48": "2zovs.msk.sudrf.ru",
        "50": "2zovs.msk.sudrf.ru", "52": "2zovs.msk.sudrf.ru", "57": "2zovs.msk.sudrf.ru",
        "62": "2zovs.msk.sudrf.ru", "67": "2zovs.msk.sudrf.ru", "68": "2zovs.msk.sudrf.ru",
        "69": "2zovs.msk.sudrf.ru", "71": "2zovs.msk.sudrf.ru", "76": "2zovs.msk.sudrf.ru",
        "77": "2zovs.msk.sudrf.ru",
        // Южный: Адыгея, Дагестан, ДНР, Ингушетия, КБР, Калмыкия, КЧР, Крым,
        // ЛНР, Сев. Осетия, Чечня, Краснодарский, Ставропольский,
        // Астраханская, Волгоградская, Запорожская, Ростовская, Херсонская,
        // Севастополь
        "01": "yovs.ros.sudrf.ru", "05": "yovs.ros.sudrf.ru", "93": "yovs.ros.sudrf.ru",
        "06": "yovs.ros.sudrf.ru", "07": "yovs.ros.sudrf.ru", "08": "yovs.ros.sudrf.ru",
        "09": "yovs.ros.sudrf.ru", "91": "yovs.ros.sudrf.ru", "94": "yovs.ros.sudrf.ru",
        "15": "yovs.ros.sudrf.ru", "20": "yovs.ros.sudrf.ru", "23": "yovs.ros.sudrf.ru",
        "26": "yovs.ros.sudrf.ru", "30": "yovs.ros.sudrf.ru", "34": "yovs.ros.sudrf.ru",
        "90": "yovs.ros.sudrf.ru", "61": "yovs.ros.sudrf.ru", "96": "yovs.ros.sudrf.ru",
        "92": "yovs.ros.sudrf.ru",
        // Центральный: Башкортостан, Марий Эл, Мордовия, Татарстан, Удмуртия,
        // Чувашия, Пермский, Кировская, Курганская, Оренбургская, Пензенская,
        // Самарская, Саратовская, Свердловская, Тюменская, Ульяновская,
        // Челябинская, ХМАО, ЯНАО
        "03": "covs.svd.sudrf.ru", "12": "covs.svd.sudrf.ru", "13": "covs.svd.sudrf.ru",
        "16": "covs.svd.sudrf.ru", "18": "covs.svd.sudrf.ru", "21": "covs.svd.sudrf.ru",
        "59": "covs.svd.sudrf.ru", "43": "covs.svd.sudrf.ru", "45": "covs.svd.sudrf.ru",
        "56": "covs.svd.sudrf.ru", "58": "covs.svd.sudrf.ru", "63": "covs.svd.sudrf.ru",
        "64": "covs.svd.sudrf.ru", "66": "covs.svd.sudrf.ru", "72": "covs.svd.sudrf.ru",
        "73": "covs.svd.sudrf.ru", "74": "covs.svd.sudrf.ru", "86": "covs.svd.sudrf.ru",
        "89": "covs.svd.sudrf.ru",
        // 1-й Восточный: Саха (Якутия), Хабаровский, Амурская, Сахалинская, ЕАО
        "14": "1vovs.hbr.sudrf.ru", "27": "1vovs.hbr.sudrf.ru", "28": "1vovs.hbr.sudrf.ru",
        "65": "1vovs.hbr.sudrf.ru", "79": "1vovs.hbr.sudrf.ru",
        // 2-й Восточный: Алтай, Бурятия, Тыва, Хакасия, Алтайский,
        // Забайкальский, Красноярский, Иркутская, Кемеровская, Новосибирская,
        // Омская, Томская
        "02": "2vovs.cht.sudrf.ru", "04": "2vovs.cht.sudrf.ru", "17": "2vovs.cht.sudrf.ru",
        "19": "2vovs.cht.sudrf.ru", "22": "2vovs.cht.sudrf.ru", "75": "2vovs.cht.sudrf.ru",
        "24": "2vovs.cht.sudrf.ru", "38": "2vovs.cht.sudrf.ru", "42": "2vovs.cht.sudrf.ru",
        "54": "2vovs.cht.sudrf.ru", "55": "2vovs.cht.sudrf.ru", "70": "2vovs.cht.sudrf.ru",
        // Балтийский флотский: Калининградская
        "39": "baltovs.kln.sudrf.ru",
        // Северный флотский: Архангельская, Мурманская, НАО
        "29": "severnyfvs.mrm.sudrf.ru", "51": "severnyfvs.mrm.sudrf.ru",
        "83": "severnyfvs.mrm.sudrf.ru",
        // Тихоокеанский флотский: Камчатский, Приморский, Магаданская, Чукотский
        "41": "tihookeanskyfvs.prm.sudrf.ru", "25": "tihookeanskyfvs.prm.sudrf.ru",
        "49": "tihookeanskyfvs.prm.sudrf.ru", "87": "tihookeanskyfvs.prm.sudrf.ru"
    ]
}


// MARK: - Гарнизонные военные суды: подсудность по 466-ФЗ

public extension CourtDirectory {

    /// ОВС для гарнизонного военного суда — ст. 1 ФЗ от 29.12.2020 № 466-ФЗ
    /// (ред. от 03.04.2023, все 98 судов). Ключ — НАЗВАНИЕ суда: код субъекта
    /// в классификационном коде гарнизонного суда отражает дислокацию-историю,
    /// а не юрисдикцию (224 ГВС: код 39, юрисдикция — часть СПб и Ленобласти,
    /// вышестоящий — 1-й Западный ОВС). Фолбэк — региональный код через
    /// 345-ФЗ (для судов, не распознанных по имени).
    static func okrugMilitaryCourt(forGarrisonTitle title: String,
                                   code: String? = nil) -> DirectoryCourt? {
        // Порядок: полный классификационный код (живая выгрузка портала;
        // зарубежные ГВС — подведомственность от эксперта) → имя (карта
        // 466-ФЗ + зарубежные) → региональный фолбэк через 345-ФЗ для
        // судов, которых ещё нет ни в одной карте.
        if let raw = code?.uppercased(),
           let d = garrisonOkrugDomainByCode[raw],
           let c = okrugMilitaryCourts.first(where: { $0.domain == d }) {
            return c
        }
        if let d = garrisonOkrugDomainByKey[garrisonKey(title)],
           let c = okrugMilitaryCourts.first(where: { $0.domain == d }) {
            return c
        }
        return code.flatMap { okrugMilitaryCourt(forSubjectCode: $0) }
    }

    /// Полный классификационный код гарнизонного суда → домен его ОВС.
    /// Сгенерировано пересечением живой выгрузки портала (court_type=GV)
    /// с картой 466-ФЗ; именно полный код — надёжный ключ: региональный
    /// префикс врёт (224 ГВС — 39GV0005, Ярославский — 77GV0013).
    internal static let garrisonOkrugDomainByCode: [String: String] = [
        "25GV0001": "tihookeanskyfvs.prm.sudrf.ru",   // Владивостокский гарнизонный военный суд
        "25GV0002": "tihookeanskyfvs.prm.sudrf.ru",   // Фокинский гарнизонный военный суд
        "25GV0003": "tihookeanskyfvs.prm.sudrf.ru",   // Анадырский гарнизонный военный суд
        "25GV0004": "tihookeanskyfvs.prm.sudrf.ru",   // 35 гарнизонный военный суд
        "25GV0005": "1vovs.hbr.sudrf.ru",   // Советско-Гаванский гарнизонный военный суд
        "27GV0001": "1vovs.hbr.sudrf.ru",   // Хабаровский гарнизонный военный суд
        "27GV0002": "1vovs.hbr.sudrf.ru",   // Комсомольский-на-Амуре гарнизонный военный суд
        "27GV0003": "1vovs.hbr.sudrf.ru",   // Свободненский гарнизонный военный суд
        "27GV0004": "1vovs.hbr.sudrf.ru",   // Биробиджанский гарнизонный военный суд
        "27GV0005": "1vovs.hbr.sudrf.ru",   // Белогорский гарнизонный военный суд
        "27GV0006": "1vovs.hbr.sudrf.ru",   // Благовещенский гарнизонный военный суд
        "27GV0008": "tihookeanskyfvs.prm.sudrf.ru",   // Уссурийский гарнизонный военный суд
        "27GV0009": "tihookeanskyfvs.prm.sudrf.ru",   // Спасск-Дальний гарнизонный военный суд
        "27GV0010": "1vovs.hbr.sudrf.ru",   // Краснореченский гарнизонный военный суд
        "27GV0012": "1vovs.hbr.sudrf.ru",   // Южно-Сахалинский гарнизонный военный суд
        "27GV0013": "1vovs.hbr.sudrf.ru",   // Курильский гарнизонный военный суд
        "27GV0014": "1vovs.hbr.sudrf.ru",   // Якутский гарнизонный военный суд
        "31GV0007": "yovs.ros.sudrf.ru",   // Знаменский гарнизонный военный суд
        "31GV0008": "severnyfvs.mrm.sudrf.ru",   // Мирненский гарнизонный военный суд
        "39GV0001": "baltovs.kln.sudrf.ru",   // Калининградский гарнизонный военный суд
        "39GV0004": "baltovs.kln.sudrf.ru",   // Балтийский гарнизонный военный суд
        "39GV0005": "1zovs.spb.sudrf.ru",   // 224 гарнизонный военный суд
        "51GV0001": "severnyfvs.mrm.sudrf.ru",   // Североморский гарнизонный военный суд
        "51GV0002": "severnyfvs.mrm.sudrf.ru",   // Северодвинский гарнизонный военный суд
        "51GV0003": "severnyfvs.mrm.sudrf.ru",   // Полярнинский гарнизонный военный суд
        "51GV0004": "severnyfvs.mrm.sudrf.ru",   // Заозерский гарнизонный военный суд
        "51GV0006": "severnyfvs.mrm.sudrf.ru",   // Гаджиевский гарнизонный военный суд
        "51GV0007": "severnyfvs.mrm.sudrf.ru",   // Мурманский гарнизонный военный суд
        "54GV0001": "2vovs.cht.sudrf.ru",   // Новосибирский гарнизонный военный суд
        "54GV0002": "2vovs.cht.sudrf.ru",   // Абаканский гарнизонный военный суд
        "54GV0003": "2vovs.cht.sudrf.ru",   // Барнаульский гарнизонный военный суд
        "54GV0007": "2vovs.cht.sudrf.ru",   // Красноярский гарнизонный военный суд
        "54GV0008": "2vovs.cht.sudrf.ru",   // Омский гарнизонный военный суд
        "54GV0009": "2vovs.cht.sudrf.ru",   // Томский гарнизонный военный суд
        "61GV0001": "yovs.ros.sudrf.ru",   // Ростовский-на-Дону гарнизонный военный суд
        "61GV0002": "yovs.ros.sudrf.ru",   // Владикавказский гарнизонный военный суд
        "61GV0003": "yovs.ros.sudrf.ru",   // Астраханский гарнизонный военный суд
        "61GV0004": "yovs.ros.sudrf.ru",   // Краснодарский гарнизонный военный суд
        "61GV0005": "yovs.ros.sudrf.ru",   // Буденновский гарнизонный военный суд
        "61GV0006": "yovs.ros.sudrf.ru",   // Волгоградский гарнизонный военный суд
        "61GV0007": "yovs.ros.sudrf.ru",   // Ставропольский гарнизонный военный суд
        "61GV0008": "yovs.ros.sudrf.ru",   // Пятигорский гарнизонный военный суд
        "61GV0009": "yovs.ros.sudrf.ru",   // Сочинский гарнизонный военный суд
        "61GV0010": "yovs.ros.sudrf.ru",   // Майкопский гарнизонный военный суд
        "61GV0011": "yovs.ros.sudrf.ru",   // Махачкалинский гарнизонный военный суд
        "61GV0012": "yovs.ros.sudrf.ru",   // Грозненский гарнизонный военный суд
        "61GV0013": "yovs.ros.sudrf.ru",   // Новороссийский гарнизонный военный суд
        "61GV0014": "yovs.ros.sudrf.ru",   // Нальчикский гарнизонный военный суд
        "61GV0016": "yovs.ros.sudrf.ru",   // Новочеркасский гарнизонный военный суд
        "61GV0018": "yovs.ros.sudrf.ru",   // Крымский гарнизонный военный суд
        "61GV0019": "yovs.ros.sudrf.ru",   // Севастопольский гарнизонный военный суд
        "61GV0020": "yovs.ros.sudrf.ru",   // Донецкий гарнизонный военный суд
        "61GV0021": "yovs.ros.sudrf.ru",   // Луганский гарнизонный военный суд
        "61GV0022": "yovs.ros.sudrf.ru",   // Запорожский гарнизонный военный суд
        "61GV0023": "yovs.ros.sudrf.ru",   // Херсонский гарнизонный военный суд
        "63GV0001": "covs.svd.sudrf.ru",   // Самарский гарнизонный военный суд
        "63GV0002": "covs.svd.sudrf.ru",   // Оренбургский гарнизонный военный суд
        "63GV0003": "covs.svd.sudrf.ru",   // Саратовский гарнизонный военный суд
        "63GV0004": "covs.svd.sudrf.ru",   // Казанский гарнизонный военный суд
        "63GV0006": "covs.svd.sudrf.ru",   // Пермский гарнизонный военный суд
        "63GV0007": "covs.svd.sudrf.ru",   // Ульяновский гарнизонный военный суд
        "63GV0008": "covs.svd.sudrf.ru",   // Уфимский гарнизонный военный суд
        "63GV0009": "covs.svd.sudrf.ru",   // Пензенский гарнизонный военный суд
        "66GV0001": "covs.svd.sudrf.ru",   // Екатеринбургский гарнизонный военный суд
        "66GV0002": "covs.svd.sudrf.ru",   // Челябинский гарнизонный военный суд
        "66GV0003": "covs.svd.sudrf.ru",   // Нижнетагильский гарнизонный военный суд
        "66GV0006": "covs.svd.sudrf.ru",   // Магнитогорский гарнизонный военный суд
        "75GV0001": "2vovs.cht.sudrf.ru",   // Читинский гарнизонный военный суд
        "75GV0002": "2vovs.cht.sudrf.ru",   // Иркутский гарнизонный военный суд
        "75GV0004": "2vovs.cht.sudrf.ru",   // Улан-Удэнский гарнизонный военный суд
        "75GV0005": "2vovs.cht.sudrf.ru",   // Кяхтинский гарнизонный военный суд
        "75GV0007": "2vovs.cht.sudrf.ru",   // Борзинский гарнизонный военный суд
        "77GV0001": "2zovs.msk.sudrf.ru",   // Московский гарнизонный военный суд
        "77GV0002": "2zovs.msk.sudrf.ru",   // Рязанский гарнизонный военный суд
        "77GV0003": "2zovs.msk.sudrf.ru",   // Реутовский гарнизонный военный суд
        "77GV0004": "2zovs.msk.sudrf.ru",   // Одинцовский гарнизонный военный суд
        "77GV0005": "2zovs.msk.sudrf.ru",   // 235 гарнизонный военный суд
        "77GV0006": "2zovs.msk.sudrf.ru",   // Солнечногорский гарнизонный военный суд
        "77GV0008": "2zovs.msk.sudrf.ru",   // Владимирский гарнизонный военный суд
        "77GV0009": "2zovs.msk.sudrf.ru",   // Нижегородский гарнизонный военный суд
        "77GV0010": "2zovs.msk.sudrf.ru",   // Ивановский гарнизонный военный суд
        "77GV0011": "2zovs.msk.sudrf.ru",   // Тверской гарнизонный военный суд
        "77GV0012": "2zovs.msk.sudrf.ru",   // Воронежский гарнизонный военный суд
        "77GV0013": "2zovs.msk.sudrf.ru",   // Ярославский гарнизонный военный суд
        "77GV0014": "2zovs.msk.sudrf.ru",   // Калужский гарнизонный военный суд
        "77GV0015": "2zovs.msk.sudrf.ru",   // Тульский гарнизонный военный суд
        "77GV0016": "2zovs.msk.sudrf.ru",   // Тамбовский гарнизонный военный суд
        "77GV0017": "2zovs.msk.sudrf.ru",   // Наро-Фоминский гарнизонный военный суд
        "77GV0018": "2zovs.msk.sudrf.ru",   // Брянский гарнизонный военный суд
        "77GV0020": "2zovs.msk.sudrf.ru",   // Курский гарнизонный военный суд
        "77GV0021": "2zovs.msk.sudrf.ru",   // Смоленский гарнизонный военный суд
        "78GV0001": "1zovs.spb.sudrf.ru",   // Санкт-Петербургский гарнизонный военный суд
        "78GV0002": "severnyfvs.mrm.sudrf.ru",   // Архангельский гарнизонный военный суд
        "78GV0003": "1zovs.spb.sudrf.ru",   // Вологодский гарнизонный военный суд
        "78GV0004": "1zovs.spb.sudrf.ru",   // Выборгский гарнизонный военный суд
        "78GV0006": "1zovs.spb.sudrf.ru",   // Великоновгородский гарнизонный военный суд
        "78GV0007": "1zovs.spb.sudrf.ru",   // Петрозаводский гарнизонный военный суд
        "78GV0008": "1zovs.spb.sudrf.ru",   // Воркутинский гарнизонный военный суд
        "78GV0009": "1zovs.spb.sudrf.ru",   // Псковский гарнизонный военный суд
        // Зарубежные ГВС («Территории за пределами РФ», вне 466-ФЗ) —
        // апелляционная подведомственность подтверждена экспертом:
        "61GV0015": "yovs.ros.sudrf.ru",   // 5 гарнизонный военный суд (Ереван) → Южный ОВС
        "31GV0014": "2zovs.msk.sudrf.ru",  // 26 гарнизонный военный суд (Байконур) → 2-й Западный ОВС
        "31GV0015": "2zovs.msk.sudrf.ru",  // 40 гарнизонный военный суд (Приозерск) → 2-й Западный ОВС
        "77GV0022": "2zovs.msk.sudrf.ru",  // 80 гарнизонный военный суд (Тирасполь) → 2-й Западный ОВС
        "66GV0008": "covs.svd.sudrf.ru",   // 109 гарнизонный военный суд (Душанбе) → Центральный ОВС
    ]

    /// Нормализованный ключ названия гарнизонного суда: устойчив к падежу
    /// («224-го гарнизонного военного суда» и «224 гарнизонный военный суд»
    /// дают один ключ), цифры сохраняются.
    static func garrisonKey(_ title: String) -> String {
        let endings = ["ского", "ская", "ский", "ской", "ого", "его", "ий", "ый", "ая"]
        let stop = ["гарнизон", "воен", "суд"]
        // Портал добавляет регион в скобках («224 гарнизонный военный суд
        // (Город Санкт-Петербург)») — нормализуем только часть до скобки.
        let head = title.split(separator: "(").first.map(String.init) ?? title
        let tokens = head.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: " -,.()«»\u{00A0}"))
        var out: [String] = []
        for raw in tokens where !raw.isEmpty {
            if raw.allSatisfy(\.isNumber) { out.append(raw); continue }
            var t = String(raw.filter(\.isLetter))
            if t.isEmpty || stop.contains(where: { t.hasPrefix($0) }) { continue }
            for e in endings where t.hasSuffix(e) && t.count - e.count >= 4 {
                t = String(t.dropLast(e.count)); break
            }
            if t.count >= 3 { out.append(t) }
        }
        return out.joined()
    }

    internal static let garrisonOkrugDomainByKey: [String: String] = [
        "224": "1zovs.spb.sudrf.ru",   // 224 ГВС
        "235": "2zovs.msk.sudrf.ru",   // 235 ГВС
        "35": "tihookeanskyfvs.prm.sudrf.ru",   // 35 ГВС
        "абакан": "2vovs.cht.sudrf.ru",   // Абаканский ГВС
        "анадыр": "tihookeanskyfvs.prm.sudrf.ru",   // Анадырский ГВС
        "архангель": "severnyfvs.mrm.sudrf.ru",   // Архангельский ГВС
        "астрахан": "yovs.ros.sudrf.ru",   // Астраханский ГВС
        "балтий": "baltovs.kln.sudrf.ru",   // Балтийский ГВС
        "барнауль": "2vovs.cht.sudrf.ru",   // Барнаульский ГВС
        "белогор": "1vovs.hbr.sudrf.ru",   // Белогорский ГВС
        "биробиджан": "1vovs.hbr.sudrf.ru",   // Биробиджанский ГВС
        "благовещен": "1vovs.hbr.sudrf.ru",   // Благовещенский ГВС
        "борзин": "2vovs.cht.sudrf.ru",   // Борзинский ГВС
        "брян": "2zovs.msk.sudrf.ru",   // Брянский ГВС
        "буденнов": "yovs.ros.sudrf.ru",   // Буденновский ГВС
        "великоновгород": "1zovs.spb.sudrf.ru",   // Великоновгородский ГВС
        "владивосток": "tihookeanskyfvs.prm.sudrf.ru",   // Владивостокский ГВС
        "владикавказ": "yovs.ros.sudrf.ru",   // Владикавказский ГВС
        "владимир": "2zovs.msk.sudrf.ru",   // Владимирский ГВС
        "волгоград": "yovs.ros.sudrf.ru",   // Волгоградский ГВС
        "вологод": "1zovs.spb.sudrf.ru",   // Вологодский ГВС
        "воркутин": "1zovs.spb.sudrf.ru",   // Воркутинский ГВС
        "воронеж": "2zovs.msk.sudrf.ru",   // Воронежский ГВС
        "выборг": "1zovs.spb.sudrf.ru",   // Выборгский ГВС
        "гаджиев": "severnyfvs.mrm.sudrf.ru",   // Гаджиевский ГВС
        "грознен": "yovs.ros.sudrf.ru",   // Грозненский ГВС
        "донецк": "yovs.ros.sudrf.ru",   // Донецкий ГВС
        "екатеринбург": "covs.svd.sudrf.ru",   // Екатеринбургский ГВС
        "заозер": "severnyfvs.mrm.sudrf.ru",   // Заозерский ГВС
        "запорож": "yovs.ros.sudrf.ru",   // Запорожский ГВС
        "знамен": "yovs.ros.sudrf.ru",   // Знаменский ГВС
        "иванов": "2zovs.msk.sudrf.ru",   // Ивановский ГВС
        "иркут": "2vovs.cht.sudrf.ru",   // Иркутский ГВС
        "казан": "covs.svd.sudrf.ru",   // Казанский ГВС
        "калининград": "baltovs.kln.sudrf.ru",   // Калининградский ГВС
        "калуж": "2zovs.msk.sudrf.ru",   // Калужский ГВС
        "комсомольамуре": "1vovs.hbr.sudrf.ru",   // Комсомольский-на-Амуре ГВС
        "краснодар": "yovs.ros.sudrf.ru",   // Краснодарский ГВС
        "красноречен": "1vovs.hbr.sudrf.ru",   // Краснореченский ГВС
        "краснояр": "2vovs.cht.sudrf.ru",   // Красноярский ГВС
        "крым": "yovs.ros.sudrf.ru",   // Крымский ГВС
        "куриль": "1vovs.hbr.sudrf.ru",   // Курильский ГВС
        "курск": "2zovs.msk.sudrf.ru",   // Курский ГВС
        "кяхтин": "2vovs.cht.sudrf.ru",   // Кяхтинский ГВС
        "луган": "yovs.ros.sudrf.ru",   // Луганский ГВС
        "магнитогор": "covs.svd.sudrf.ru",   // Магнитогорский ГВС
        "майкоп": "yovs.ros.sudrf.ru",   // Майкопский ГВС
        "махачкалин": "yovs.ros.sudrf.ru",   // Махачкалинский ГВС
        "мирнен": "severnyfvs.mrm.sudrf.ru",   // Мирненский ГВС
        "москов": "2zovs.msk.sudrf.ru",   // Московский ГВС
        "мурман": "severnyfvs.mrm.sudrf.ru",   // Мурманский ГВС
        "нальчик": "yovs.ros.sudrf.ru",   // Нальчикский ГВС
        "нарофомин": "2zovs.msk.sudrf.ru",   // Наро-Фоминский ГВС
        "нижегород": "2zovs.msk.sudrf.ru",   // Нижегородский ГВС
        "нижнетагиль": "covs.svd.sudrf.ru",   // Нижнетагильский ГВС
        "новороссий": "yovs.ros.sudrf.ru",   // Новороссийский ГВС
        "новосибир": "2vovs.cht.sudrf.ru",   // Новосибирский ГВС
        "новочеркас": "yovs.ros.sudrf.ru",   // Новочеркасский ГВС
        "одинцов": "2zovs.msk.sudrf.ru",   // Одинцовский ГВС
        "омск": "2vovs.cht.sudrf.ru",   // Омский ГВС
        "оренбург": "covs.svd.sudrf.ru",   // Оренбургский ГВС
        "пензен": "covs.svd.sudrf.ru",   // Пензенский ГВС
        "перм": "covs.svd.sudrf.ru",   // Пермский ГВС
        "петрозавод": "1zovs.spb.sudrf.ru",   // Петрозаводский ГВС
        "полярнин": "severnyfvs.mrm.sudrf.ru",   // Полярнинский ГВС
        "псков": "1zovs.spb.sudrf.ru",   // Псковский ГВС
        "пятигор": "yovs.ros.sudrf.ru",   // Пятигорский ГВС
        "реутов": "2zovs.msk.sudrf.ru",   // Реутовский ГВС
        "ростовдону": "yovs.ros.sudrf.ru",   // Ростовский-на-Дону ГВС
        "рязан": "2zovs.msk.sudrf.ru",   // Рязанский ГВС
        "самар": "covs.svd.sudrf.ru",   // Самарский ГВС
        "санктпетербург": "1zovs.spb.sudrf.ru",   // Санкт-Петербургский ГВС
        "саратов": "covs.svd.sudrf.ru",   // Саратовский ГВС
        "свободнен": "1vovs.hbr.sudrf.ru",   // Свободненский ГВС
        "севастополь": "yovs.ros.sudrf.ru",   // Севастопольский ГВС
        "северодвин": "severnyfvs.mrm.sudrf.ru",   // Северодвинский ГВС
        "северомор": "severnyfvs.mrm.sudrf.ru",   // Североморский ГВС
        "смолен": "2zovs.msk.sudrf.ru",   // Смоленский ГВС
        "советскогаван": "1vovs.hbr.sudrf.ru",   // Советско-Гаванский ГВС
        "солнечногор": "2zovs.msk.sudrf.ru",   // Солнечногорский ГВС
        "сочин": "yovs.ros.sudrf.ru",   // Сочинский ГВС
        "спасскдальн": "tihookeanskyfvs.prm.sudrf.ru",   // Спасск-Дальнего ГВС
        "ставрополь": "yovs.ros.sudrf.ru",   // Ставропольский ГВС
        "тамбов": "2zovs.msk.sudrf.ru",   // Тамбовский ГВС
        "твер": "2zovs.msk.sudrf.ru",   // Тверской ГВС
        "томск": "2vovs.cht.sudrf.ru",   // Томский ГВС
        "туль": "2zovs.msk.sudrf.ru",   // Тульский ГВС
        "уланудэн": "2vovs.cht.sudrf.ru",   // Улан-Удэнский ГВС
        "ульянов": "covs.svd.sudrf.ru",   // Ульяновский ГВС
        "уссурий": "tihookeanskyfvs.prm.sudrf.ru",   // Уссурийский ГВС
        "уфим": "covs.svd.sudrf.ru",   // Уфимский ГВС
        "фокин": "tihookeanskyfvs.prm.sudrf.ru",   // Фокинский ГВС
        "хабаров": "1vovs.hbr.sudrf.ru",   // Хабаровский ГВС
        "херсон": "yovs.ros.sudrf.ru",   // Херсонский ГВС
        "челябин": "covs.svd.sudrf.ru",   // Челябинский ГВС
        "читин": "2vovs.cht.sudrf.ru",   // Читинский ГВС
        "южносахалин": "1vovs.hbr.sudrf.ru",   // Южно-Сахалинский ГВС
        "якут": "1vovs.hbr.sudrf.ru",   // Якутский ГВС
        "ярослав": "2zovs.msk.sudrf.ru",   // Ярославский ГВС
        // Зарубежные ГВС (вне 466-ФЗ; подведомственность — от эксперта):
        "5": "yovs.ros.sudrf.ru",     // 5 ГВС, Ереван
        "26": "2zovs.msk.sudrf.ru",   // 26 ГВС, Байконур
        "40": "2zovs.msk.sudrf.ru",   // 40 ГВС, Приозерск
        "80": "2zovs.msk.sudrf.ru",   // 80 ГВС, Тирасполь
        "109": "covs.svd.sudrf.ru",   // 109 ГВС, Душанбе
    ]
}
