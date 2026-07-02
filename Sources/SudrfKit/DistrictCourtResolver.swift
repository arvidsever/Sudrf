import Foundation
import SwiftSoup

/// Тип суда по классификационному коду (3-4 символы кода, напр. 11**RS**0001).
/// Буквы AJ/KJ и подтверждение GV/OV сняты с живой выдачи портала по СПб
/// (см. ИЗМЕНЕНИЯ-v12, диагностика --debug): 78AJ0002 — Второй
/// апелляционный суд ОЮ, 78KJ0003 — Третий кассационный суд ОЮ,
/// 78OV0000 — 1-й Западный окружной военный суд, 78OS0000 — горсуд СПб.
public enum CourtKind: String, Sendable, Codable {
    case district    // RS — районный/городской/межрайонный
    case military    // GV/OV — гарнизонные/окружные; KV/AV — предположительно КВС/АВС
    case subject     // OS/VS — суд субъекта / ВС РФ
    case appeal      // AJ — апелляционный суд общей юрисдикции (АСОЮ)
    case cassation   // KJ — кассационный суд общей юрисдикции (КСОЮ)
    case other

    public init(classificationCode code: String) {
        let t = code.count >= 4
            ? String(Array(code)[2..<4]).uppercased()
            : ""
        switch t {
        case "RS":                       self = .district
        case "GV", "OV", "KV", "AV":     self = .military
        case "OS", "VS", "UD":           self = .subject
        case "AJ":                       self = .appeal
        case "KJ":                       self = .cassation
        default:                          self = .other
        }
    }
}

/// Суд, добытый резолвером с портала ГАС «Правосудие».
public struct DistrictCourt: Sendable, Equatable, Codable {
    public var title: String
    public var domain: String
    public var code: String?         // классификационный код, напр. "11RS0001"
    public var regionCode: String?   // буквенный код из домена (komi) — справочно
    public var kind: CourtKind
    /// Портальный код субъекта (court_subj), которым суд был добыт. Надёжнее
    /// первых двух цифр классификационного кода: не зависит от формата кода
    /// и его наличия в выдаче портала.
    public var portalSubject: String?

    public init(title: String, domain: String, code: String?,
                regionCode: String?, kind: CourtKind, portalSubject: String? = nil) {
        self.title = title; self.domain = domain; self.code = code
        self.regionCode = regionCode; self.kind = kind
        self.portalSubject = portalSubject
    }

    /// Числовой код субъекта (первые 2 символа классификационного кода).
    public var subjectNum: String? {
        guard let code, code.count >= 2 else { return nil }
        return String(code.prefix(2))
    }

    /// Буквенный тип из классификационного кода: 11RS0001 → «RS»,
    /// 54GV0011 → «GV». RS — районный/городской, GV — гарнизонный военный,
    /// OV — окружной (флотский) военный, AV/KV — Апелляционный/Кассационный
    /// военный суд, OS — суд субъекта.
    public var codeLetters: String? {
        guard let code else { return nil }
        let letters = code.filter(\.isLetter)
        return letters.isEmpty ? nil : letters.uppercased()
    }

    public var court: Court { Court(domain: domain, title: title, level: .district) }
}

// MARK: - коды субъектов и регионов

public extension CourtDirectory {

    /// Числовой код субъекта по человекочитаемому региону (для запроса к порталу).
    static func subjectNumericCode(forRegion query: String) -> String? {
        // Точное имя из таблицы (пикер региона передаёт ровно их) — без эвристик.
        // Закрывает ничьи корневого скоринга: «Республика Алтай» ≠ Алтайский край.
        let q = lettersOnly(query)
        if let exact = subjectCodeTable.first(where: { lettersOnly($0.name) == q }) {
            return exact.code
        }
        let qRoots = significantRoots(query)
        guard !qRoots.isEmpty else { return nil }
        var best: (score: Int, code: String)?
        for (name, code) in subjectCodeTable {
            let tRoots = significantRoots(name)
            // Точное совпадение корня весит больше префиксного пересечения:
            // «сахалин» должен выбирать Сахалинскую область, а не Республику
            // Саха, хотя «сахалин».hasPrefix(«саха»).
            let score = qRoots.reduce(0) { acc, qr in
                if tRoots.contains(qr) { return acc + 3 }
                if tRoots.contains(where: { $0.hasPrefix(qr) || qr.hasPrefix($0) }) { return acc + 1 }
                return acc
            }
            if score > (best?.score ?? 0) { best = (score, code) }
        }
        return best?.code
    }

    /// Буквенный код субъекта из домена суда: syktsud.komi.sudrf.ru / x--komi.sudrf.ru -> "komi".
    static func regionCode(forDomain raw: String) -> String? {
        var host = raw.lowercased()
        for p in ["https://", "http://"] where host.hasPrefix(p) { host.removeFirst(p.count) }
        host = host.split(separator: "/").first.map(String.init) ?? host
        if let r = host.range(of: "--") {
            return host[r.upperBound...].split(separator: ".").first.map(String.init)
        }
        let labels = host.split(separator: ".").map(String.init)
        if labels.count >= 4, Array(labels.suffix(2)) == ["sudrf", "ru"] {
            return labels[labels.count - 3]
        }
        return nil
    }

    /// Буквенный код субъекта по региону (через справочник судов субъектов).
    static func regionCode(forRegion query: String) -> String? {
        let key = lettersOnly(query)
        for (alias, code) in regionAliases where key.contains(alias) { return code }
        let qRoots = significantRoots(query)
        guard !qRoots.isEmpty else { return nil }
        var best: (score: Int, code: String)?
        for s in subjectCourts {
            let tRoots = significantRoots(s.title)
            let score = qRoots.reduce(0) { acc, q in
                acc + (tRoots.contains { $0.hasPrefix(q) || q.hasPrefix($0) } ? 1 : 0)
            }
            guard score > (best?.score ?? 0),
                  let code = regionCode(forDomain: s.domain) ?? nonSudrfRegionCodes[s.domain]
            else { continue }
            best = (score, code)
        }
        return best?.code
    }

    /// Суд субъекта по человекочитаемому региону. Идёт через ту же машинерию,
    /// что и `regionCode(forRegion:)` (корни слов + алиасы «Москва»/«Петербург»),
    /// поэтому «Республика Коми» → ВС Республики Коми, «город Москва» →
    /// Мосгорсуд (вне платформы sudrf — см. `isSudrfPlatform`).
    static func subjectCourt(forRegion query: String) -> DirectoryCourt? {
        if let code = regionCode(forRegion: query),
           let c = subjectCourts.first(where: {
               regionCode(forDomain: $0.domain) == code || nonSudrfRegionCodes[$0.domain] == code
           }) {
            return c
        }
        return subjectCourt(matching: query)
    }

    static let nonSudrfRegionCodes: [String: String] = [
        "nnoblsud.ru": "nnov", "www.oblsud.penza.ru": "pnz",
        "www.uloblsud.ru": "uln", "www.mos-gorsud.ru": "msk"
    ]
    static let regionAliases: [String: String] = [
        "санктпетербург": "spb", "петербург": "spb", "москва": "msk"
    ]
    static let stopRoots: Set<String> = [
        "суд", "верхов", "областн", "краев", "город", "городск",
        "автоном", "округ", "област", "край", "республик", "народн", "территор"
    ]

    static func lettersOnly(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) })
    }
    static func wordRoot(_ s: String) -> String {
        let t = lettersOnly(s)
        // Стрижём окончание, только если остаётся содержательный корень (≥4):
        // «Курская» → «кур» съедался бы фильтром длины в significantRoots,
        // и регион оставался без корней (молчаливый ноль судов). Теперь
        // короткие слова остаются целиком: «курская», «томская», «марий».
        for e in ["ского", "ская", "ский", "ской", "областной", "ный", "ная", "ной",
                  "ий", "ая", "ой", "ый", "ое"]
        where t.hasSuffix(e) && t.count - e.count >= 4 {
            return String(t.dropLast(e.count))
        }
        return t
    }
    static func significantRoots(_ phrase: String) -> [String] {
        phrase.split { " -,.()".contains($0) }
            .map { wordRoot(String($0)) }
            .filter { r in r.count >= 4 && !stopRoots.contains(where: { r.hasPrefix($0) }) }
    }

    /// Имена субъектов для выпадающего списка (без псевдо-записей), по алфавиту.
    static var subjectRegionNames: [String] {
        subjectCodeTable.map { $0.name }
            .filter { !$0.contains("Территории за пределами") && !$0.contains("Организации центрального") }
            .sorted()
    }

    static let subjectCodeTable: [(name: String, code: String)] = [
        ("Алтайский край", "22"),
        ("Амурская область", "28"),
        ("Архангельская область", "29"),
        ("Астраханская область", "30"),
        ("Белгородская область", "31"),
        ("Брянская область", "32"),
        ("Владимирская область", "33"),
        ("Волгоградская область", "34"),
        ("Вологодская область", "35"),
        ("Воронежская область", "36"),
        ("Город Москва", "77"),
        ("Город Санкт-Петербург", "78"),
        ("Город Севастополь", "92"),
        ("Донецкая Народная Республика", "93"),
        ("Еврейская автономная область", "79"),
        ("Забайкальский край", "75"),
        ("Запорожская область", "90"),
        ("Ивановская область", "37"),
        ("Иркутская область", "38"),
        ("Кабардино-Балкарская Республика", "07"),
        ("Калининградская область", "39"),
        ("Калужская область", "40"),
        ("Камчатский край", "41"),
        ("Карачаево-Черкесская Республика", "09"),
        ("Кемеровская область - Кузбасс", "42"),
        ("Кировская область", "43"),
        ("Костромская область", "44"),
        ("Краснодарский край", "23"),
        ("Красноярский край", "24"),
        ("Курганская область", "45"),
        ("Курская область", "46"),
        ("Ленинградская область", "47"),
        ("Липецкая область", "48"),
        ("Луганская Народная Республика", "94"),
        ("Магаданская область", "49"),
        ("Московская область", "50"),
        ("Мурманская область", "51"),
        ("Ненецкий автономный округ", "83"),
        ("Нижегородская область", "52"),
        ("Новгородская область", "53"),
        ("Новосибирская область", "54"),
        ("Омская область", "55"),
        ("Организации центрального подчинения", "97"),
        ("Оренбургская область", "56"),
        ("Орловская область", "57"),
        ("Пензенская область", "58"),
        ("Пермский край", "59"),
        ("Приморский край", "25"),
        ("Псковская область", "60"),
        ("Республика Адыгея", "01"),
        ("Республика Алтай", "02"),
        ("Республика Башкортостан", "03"),
        ("Республика Бурятия", "04"),
        ("Республика Дагестан", "05"),
        ("Республика Ингушетия", "06"),
        ("Республика Калмыкия", "08"),
        ("Республика Карелия", "10"),
        ("Республика Коми", "11"),
        ("Республика Крым", "91"),
        ("Республика Марий Эл", "12"),
        ("Республика Мордовия", "13"),
        ("Республика Саха (Якутия)", "14"),
        ("Республика Северная Осетия-Алания", "15"),
        ("Республика Татарстан", "16"),
        ("Республика Тыва", "17"),
        ("Республика Хакасия", "19"),
        ("Ростовская область", "61"),
        ("Рязанская область", "62"),
        ("Самарская область", "63"),
        ("Саратовская область", "64"),
        ("Сахалинская область", "65"),
        ("Свердловская область", "66"),
        ("Смоленская область", "67"),
        ("Ставропольский край", "26"),
        ("Тамбовская область", "68"),
        ("Тверская область", "69"),
        ("Томская область", "70"),
        ("Тульская область", "71"),
        ("Тюменская область", "72"),
        ("Удмуртская Республика", "18"),
        ("Ульяновская область", "73"),
        ("Хабаровский край", "27"),
        ("Ханты-Мансийский автономный округ - Югра (Тюменская область)", "86"),
        ("Херсонская область", "96"),
        ("Челябинская область", "74"),
        ("Чеченская Республика", "20"),
        ("Чувашская Республика - Чувашия", "21"),
        ("Чукотский автономный округ", "87"),
        ("Ямало-Ненецкий автономный округ", "89"),
        ("Ярославская область", "76"),
        ("Территории за пределами РФ", "95"),
    ]
}

// MARK: - парсер страницы портала (id=300, выбран субъект)

/// Разбор блока <ul class='search-results'> на портале: из каждого <li> берём
/// классификационный код (из onclick listcontrol), название и домен офиц. сайта.
public enum DistrictCourtParser {

    /// Статистика разбора страницы портала — для диагностики случаев
    /// «регион есть, а суды не подсасываются».
    public struct ParseStats: Sendable {
        public var anchors = 0          // якорей <a class="court-result"> на странице
        public var droppedNoCode = 0    // из onclick не извлёкся классификационный код
        public var droppedNoSite = 0    // в карточке не нашлось sudrf/mos-gorsud домена
        public var kept = 0             // судов в итоге
        public var byKind: [String: Int] = [:]   // распределение по типам кода
        public var codes: [String] = []          // встреченные классификационные коды
    }

    public static func parse(html: String, portalSubject: String? = nil) -> [DistrictCourt] {
        parseDetailed(html: html, portalSubject: portalSubject).courts
    }

    public static func parseDetailed(html: String, portalSubject: String? = nil)
        -> (courts: [DistrictCourt], stats: ParseStats) {
        var stats = ParseStats()
        guard let doc = try? SwiftSoup.parse(html) else { return ([], stats) }
        let anchors = (try? doc.select("a.court-result").array()) ?? []
        stats.anchors = anchors.count

        var byDomain: [String: DistrictCourt] = [:]
        for a in anchors {
            let onclick = (try? a.attr("onclick")) ?? ""
            guard let code = captureCode(onclick) else { stats.droppedNoCode += 1; continue }
            stats.codes.append(code)
            let title = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let domain = officialSite(near: a) else { stats.droppedNoSite += 1; continue }

            let kind = CourtKind(classificationCode: code)
            stats.byKind[kind.rawValue, default: 0] += 1
            byDomain[domain] = DistrictCourt(
                title: title, domain: domain, code: code,
                regionCode: CourtDirectory.regionCode(forDomain: domain),
                kind: kind,
                portalSubject: portalSubject
            )
        }
        stats.kept = byDomain.count
        return (byDomain.values.sorted { $0.title < $1.title }, stats)
    }

    static func captureCode(_ onclick: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "listcontrol\\('[^']*','([^']+)'\\)") else { return nil }
        let ns = onclick as NSString
        guard let m = re.firstMatch(in: onclick, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func officialSite(near anchor: Element) -> String? {
        guard let li = anchor.parents().array().first(where: { $0.tagName() == "li" }) else { return nil }
        let links = (try? li.select("a[href]").array()) ?? []
        for l in links {
            if let host = sudrfHost(from: (try? l.attr("href")) ?? "") { return host }
        }
        return nil
    }

    static func sudrfHost(from href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host?.lowercased() else { return nil }
        return (host.hasSuffix("sudrf.ru") || host.hasSuffix("mos-gorsud.ru")) ? host : nil
    }
}

// MARK: - резолвер с кэшем (по субъектам, постепенно пополняется)

public actor DistrictCourtResolver {

    private let client: SudrfClient
    private let cacheURL: URL?
    private var cache: [String: DistrictCourt] = [:]   // ключ — домен
    private var loadedSubjects: Set<String> = []
    private var loadedTypes: Set<String> = []
    private var diskLoaded = false

    public init(client: SudrfClient = SudrfClient(),
                cacheURL: URL? = DistrictCourtResolver.defaultCacheURL()) {
        self.client = client
        self.cacheURL = cacheURL
    }

    public static func defaultCacheURL() -> URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("SudrfKit-districts-v2.json")
    }

    /// Районные/городские суды региона.
    public func courts(forRegion region: String) async throws -> [DistrictCourt] {
        let all = try await load(region: region)
        let rs = all.filter { $0.kind == .district }
        if !rs.isEmpty { return rs }
        // Код нераспознанного формата (.other) — лучше показать суды, чем
        // молча спрятать: военные и субъектные отсеяны своими типами.
        return all.filter { $0.kind == .other }
    }

    /// Военные суды региона (любые: гарнизонные/окружные/АВС/КВС).
    public func militaryCourts(forRegion region: String) async throws -> [DistrictCourt] {
        try await load(region: region).filter { $0.kind == .military }
    }

    /// Все суды заданного типа по стране ОДНИМ запросом портала
    /// (`court_subj=0&court_type=…`): GV — гарнизонные (включая зарубежные —
    /// они не относятся ни к одному субъекту), OV — окружные (флотские),
    /// RS — районные и т.д. Результат кэшируется в памяти по типу на время
    /// жизни резолвера; суды также докладываются в общий доменный кэш.
    public func courtsNationwide(type rawType: String) async throws -> [DistrictCourt] {
        let type = rawType.uppercased()
        if loadedTypes.contains(type) {
            return cache.values.filter { $0.codeLetters == type }
                .sorted { $0.title < $1.title }
        }
        let html = try await client.fetchHTML(typedURL(type))
        let parsed = DistrictCourtParser.parse(html: html)
        for c in parsed where !c.domain.isEmpty { cache[c.domain] = c }
        if !parsed.isEmpty { loadedTypes.insert(type) }
        persist()
        return parsed.filter { $0.codeLetters == type }.sorted { $0.title < $1.title }
    }

    /// Все гарнизонные военные суды страны (включая «Территории за пределами
    /// РФ») — один типовой запрос.
    public func garrisonCourts() async throws -> [DistrictCourt] {
        try await courtsNationwide(type: "GV")
    }


    /// Все суды региона (любого типа).
    public func allCourts(forRegion region: String) async throws -> [DistrictCourt] {
        try await load(region: region)
    }

    @discardableResult
    public func refresh(forRegion region: String) async throws -> Int {
        guard let num = CourtDirectory.subjectNumericCode(forRegion: region) else { return 0 }
        return try await fetchSubject(num)
    }

    /// Диагностика «суды региона не подсасываются»: тянет страницу субъекта
    /// с портала (кэш не трогает) и возвращает текстовый отчёт — URL запроса,
    /// размер ответа, статистику парсинга и итог фильтрации. Доступна из CLI:
    /// `sudrf-cli district --region "…" --debug`.
    public func diagnose(region: String) async -> String {
        var out: [String] = []
        guard let num = CourtDirectory.subjectNumericCode(forRegion: region) else {
            return "Регион «\(region)» не сопоставился с портальным кодом субъекта "
                 + "(subjectCodeTable) — проверьте написание."
        }
        let url = subjectURL(num)
        out.append("Регион: «\(region)» → court_subj=\(num)")
        out.append("URL: \(url.absoluteString)")
        let html: String
        do { html = try await client.fetchHTML(url) }
        catch { return (out + ["Запрос не удался: \(error)"]).joined(separator: "\n") }
        out.append("HTML: \(html.count) символов")

        let (courts, st) = DistrictCourtParser.parseDetailed(html: html, portalSubject: num)
        out.append("Якорей a.court-result: \(st.anchors); без кода: \(st.droppedNoCode); "
                 + "без sudrf-домена: \(st.droppedNoSite); итог: \(st.kept)")
        if st.anchors == 0 {
            out.append("⚠ На странице нет ни одного a.court-result — портал сменил "
                     + "разметку выдачи либо отдал страницу-заглушку.")
        }
        if st.anchors > 0, st.anchors % 20 == 0 {
            out.append("⚠ Якорей ровно \(st.anchors) — возможна пагинация выдачи "
                     + "(вторые страницы не читаются).")
        }
        if !st.byKind.isEmpty {
            let kinds = st.byKind.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            out.append("По типам кода: \(kinds)")
        }
        let foreign = courts.filter { $0.subjectNum != num }
        if !foreign.isEmpty {
            out.append("⚠ У \(foreign.count) судов первые цифры классификационного кода "
                     + "≠ \(num) (например, \(foreign.first!.code ?? "—")) — прежние версии "
                     + "теряли их на фильтрации; теперь фильтр идёт по метке портала.")
        }
        if !st.codes.isEmpty {
            out.append("Коды (до 10): " + st.codes.prefix(10).joined(separator: ", "))
        }
        for c in courts.prefix(30) {
            out.append("  \(c.title) — \(c.domain)  [\(c.code ?? "—"), \(c.kind.rawValue)]")
        }
        if courts.count > 30 { out.append("  … и ещё \(courts.count - 30)") }
        return out.joined(separator: "\n")
    }

    private func typedURL(_ type: String) -> URL {
        URL(string: "https://sudrf.ru/index.php?id=300&act=go_search&searchtype=fs"
                  + "&court_name=&court_subj=0&court_type=\(type)&court_okrug=0&vcourt_okrug=0")!
    }

    private func subjectURL(_ code: String) -> URL {
        URL(string: "https://sudrf.ru/index.php?id=300&act=go_search&searchtype=fs&court_subj=\(code)")!
    }

    private func load(region: String) async throws -> [DistrictCourt] {
        guard let num = CourtDirectory.subjectNumericCode(forRegion: region) else { return [] }
        try await ensureDiskLoaded()
        if !loadedSubjects.contains(num) { _ = try await fetchSubject(num) }
        var found = subjectCourts(num)
        if found.isEmpty, loadedSubjects.contains(num) {
            // Субъект помечен загруженным (например, старым кэшем прежней
            // версии, где пустой/неудачный запрос «залипал»), а судов нет —
            // однократно перечитываем портал.
            loadedSubjects.remove(num)
            _ = try await fetchSubject(num)
            found = subjectCourts(num)
        }
        return found
    }

    /// Суды кэша, относящиеся к портальному субъекту: в первую очередь по
    /// метке `portalSubject`, для записей старых кэшей — по первым двум
    /// цифрам классификационного кода.
    private func subjectCourts(_ num: String) -> [DistrictCourt] {
        cache.values
            .filter { ($0.portalSubject ?? $0.subjectNum) == num }
            .sorted { $0.title < $1.title }
    }

    @discardableResult
    private func fetchSubject(_ num: String) async throws -> Int {
        let html = try await client.fetchHTML(subjectURL(num))
        let parsed = DistrictCourtParser.parse(html: html, portalSubject: num)
        for c in parsed where !c.domain.isEmpty { cache[c.domain] = c }
        // Пустой ответ субъект «загруженным» не делает — иначе временный сбой
        // портала навсегда оставлял регион без судов (до чистки кэша).
        if !parsed.isEmpty { loadedSubjects.insert(num) }
        persist()
        return parsed.count
    }

    private func ensureDiskLoaded() async throws {
        if diskLoaded { return }
        diskLoaded = true
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([DistrictCourt].self, from: data) else { return }
        for c in arr {
            cache[c.domain] = c
            if let s = c.subjectNum { loadedSubjects.insert(s) }
        }
    }

    private func persist() {
        guard let url = cacheURL else { return }
        if let data = try? JSONEncoder().encode(Array(cache.values)) {
            try? data.write(to: url)
        }
    }
}
