import Foundation

/// Результат разбора произвольного названия суда для карточки календаря.
public struct CourtNameDisplay: Equatable, Sendable {
    public let full: String      // вход, обрезанный по пробелам
    public let short: String     // текст для карточки
    public let tier: CourtTier?  // nil = не распознано
    /// Нормализованная идентичность суда: одинакова для всех написаний
    /// ОДНОГО суда, различна для РАЗНЫХ судов. Строится из звена, короткого
    /// имени и — только когда хвост назвал город («г. Тверь», «города
    /// Барнаула») — этого города: такой хвост различает два разных суда с
    /// одинаковым коротким именем (два «Центральных районных суда» в разных
    /// городах). Хвост-регион («Республики Коми», «Воронежской области»)
    /// в ключ не входит: это лишь уточнение подсудности того же суда.
    public let key: String
    /// Хвост, снятый при нормализации (город или регион) — используется
    /// `disambiguatedShortNames` для различения коллизий.
    public let locality: String?
}

/// Определяет звено и короткое имя суда ПРАВИЛАМИ по названию — без
/// справочника конкретных судов, чтобы работать и с судами, которых ещё нет
/// в `CourtDirectory`. `TrackedHearing.court` — свободная строка с портала,
/// поэтому только разбор названия способен дать месяцу календаря звено и
/// цвет.
public enum CourtNamePresentation {

    public static func display(_ raw: String) -> CourtNameDisplay {
        let full = collapse(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !full.isEmpty, let c = classify(full) else {
            return CourtNameDisplay(full: full, short: full, tier: nil,
                                     key: "?|" + full.lowercased(), locality: nil)
        }
        let key = makeKey(tier: c.tier, short: c.short, locality: c.locality, cityTail: c.cityTail)
        return CourtNameDisplay(full: full, short: c.short, tier: c.tier, key: key, locality: c.locality)
    }

    /// Единая идентичность суда для ЦЕЛОГО набора (в отличие от одиночного
    /// `display(_:).key`): внутри группы с одинаковым «звено|short» бесхвостая
    /// запись («Эжвинский районный суд») сливается с городским хвостом
    /// («…г. Сыктывкара»), если в группе встретился РОВНО один город — это тот
    /// же суд, портал просто не всегда пишет город. Если городов два и
    /// больше (Тверь и Барнаул для «Центральный…»), угадывать нельзя:
    /// бесхвостая запись остаётся при своём (отдельном) ключе.
    public static func canonicalKeys(_ raws: [String]) -> [String: String] {
        let entries = raws.map { (raw: $0, d: display($0)) }
        var byBase: [String: [(raw: String, d: CourtNameDisplay)]] = [:]
        for e in entries {
            let base = "\(e.d.tier?.rawValue ?? "?")|\(e.d.short.lowercased())"
            byBase[base, default: []].append(e)
        }
        var result: [String: String] = [:]
        for (base, group) in byBase {
            let cityKeys = Set(group.filter { $0.d.key != base }.map(\.d.key))
            let mergeInto = cityKeys.count == 1 ? cityKeys.first : nil
            for e in group { result[e.raw] = mergeInto ?? e.d.key }
        }
        return result
    }

    /// Короткие названия для набора судов календаря: если у разных судов
    /// (разных `canonicalKeys`) совпал `short`, к ним добавляется уточнение.
    /// Для районных/городских/межрайонных судов — «<short> <р/с|г/с|м/с>
    /// <город>» (например «Центральный р/с г. Твери»); для прочих звеньев —
    /// «<short> <хвост>».
    public static func disambiguatedShortNames(_ raws: [String]) -> [String: String] {
        let entries = raws.map { (raw: $0, d: display($0)) }
        let canonical = canonicalKeys(raws)
        var byShort: [String: [(raw: String, d: CourtNameDisplay)]] = [:]
        for e in entries { byShort[e.d.short, default: []].append(e) }

        var result: [String: String] = [:]
        for (short, group) in byShort {
            let keys = Set(group.map { canonical[$0.raw] ?? $0.d.key })
            if keys.count <= 1 {
                for e in group { result[e.raw] = short }
                continue
            }
            for e in group {
                guard let locality = e.d.locality else { result[e.raw] = short; continue }
                if e.d.tier == .district, let kind = districtKindAbbrev(e.raw) {
                    result[e.raw] = "\(short) \(kind) \(locality)"
                } else {
                    result[e.raw] = "\(short) \(locality)"
                }
            }
        }
        return result
    }

    // MARK: - классификация

    private typealias Classified = (short: String, tier: CourtTier, locality: String?, cityTail: Bool)

    private static let ordinalWords = "Первый|Второй|Третий|Четвертый|Четвёртый|Пятый|Шестой|Седьмой|Восьмой|Девятый"
    private static let ordinalToNumber: [String: Int] = [
        "первый": 1, "второй": 2, "третий": 3, "четвертый": 4, "пятый": 5,
        "шестой": 6, "седьмой": 7, "восьмой": 8, "девятый": 9
    ]

    private static func classify(_ input: String) -> Classified? {
        let lower = yo2ye(input).lowercased()

        // Верховный Суд РФ.
        if lower == "верховный суд российской федерации" || lower == "верховный суд рф"
            || lower == "вс рф" {
            return ("ВС РФ", .supreme, nil, false)
        }

        // Единственный распространённый алиас-исключение.
        if lower == "мосгорсуд" {
            return ("Московский горсуд", .subject, nil, false)
        }

        // Городские суды трёх городов федерального значения — звено subject,
        // а не district (в отличие от прочих «городских судов»).
        if let g = firstMatch(#"^(Московский|Санкт-Петербургский|Севастопольский)\s+(?:городской\s+суд|горсуд)$"#, input) {
            return ("\(g[0]) горсуд", .subject, nil, false)
        }

        // АСОЮ / КСОЮ — полное название.
        if let g = firstMatch(#"^(\#(ordinalWords))\s+(апелляционный|кассационный)\s+суд(?:\s+общей\s+юрисдикции)?$"#, input) {
            let n = ordinalToNumber[yo2ye(g[0]).lowercased()] ?? 0
            let kind = g[1].lowercased() == "апелляционный" ? "АСОЮ" : "КСОЮ"
            return ("\(n) \(kind)", kind == "АСОЮ" ? .appeal : .cassation, nil, false)
        }
        // АСОЮ / КСОЮ — «Третий КСОЮ».
        if let g = firstMatch(#"^(\#(ordinalWords))\s+(АСОЮ|КСОЮ)$"#, input) {
            let n = ordinalToNumber[yo2ye(g[0]).lowercased()] ?? 0
            let kind = g[1].uppercased()
            return ("\(n) \(kind)", kind == "АСОЮ" ? .appeal : .cassation, nil, false)
        }
        // АСОЮ / КСОЮ — короткая цифровая форма («3 КСОЮ»), идемпотентность.
        if let g = firstMatch(#"^(\d)\s*(АСОЮ|КСОЮ)$"#, input) {
            let kind = g[1].uppercased()
            return ("\(g[0]) \(kind)", kind == "АСОЮ" ? .appeal : .cassation, nil, false)
        }

        // Военные апелляция/кассация.
        if lower == "апелляционный военный суд" || lower == "авс" {
            return ("АВС", .appeal, nil, false)
        }
        if lower == "кассационный военный суд" || lower == "квс" {
            return ("КВС", .cassation, nil, false)
        }

        // Окружной (флотский) военный суд.
        if let g = firstMatch(#"^(.+?)\s+(?:окружной|флотский)\s+военный\s+суд$"#, input) {
            return ("\(g[0]) ОВС", .subject, nil, false)
        }
        if let g = firstMatch(#"^(.+?)\s+ОВС$"#, input) {
            return ("\(g[0]) ОВС", .subject, nil, false)
        }

        // Гарнизонный военный суд.
        if let g = firstMatch(#"^(.+?)\s+гарнизонный\s+военный\s+суд$"#, input) {
            return ("\(g[0]) ГВС", .district, nil, false)
        }
        if let g = firstMatch(#"^(.+?)\s+ГВС$"#, input) {
            return ("\(g[0]) ГВС", .district, nil, false)
        }

        // Верховный суд республики — «Республики X» либо «X Республики».
        if let g = firstMatch(#"^Верховный\s+[Сс]уд\s+Республики\s+(.+)$"#, input) {
            return ("ВС \(g[0])", .subject, nil, false)
        }
        if let g = firstMatch(#"^Верховный\s+[Сс]уд\s+(.+\s+Республики)$"#, input) {
            return ("ВС \(g[0])", .subject, nil, false)
        }
        // Идемпотентность: уже краткая форма «ВС X» (кроме «ВС РФ», отсеян выше).
        if let g = firstMatch(#"^ВС\s+(.+)$"#, input), yo2ye(g[0]).lowercased() != "рф" {
            return ("ВС \(g[0])", .subject, nil, false)
        }

        // Мировой судья / судебный участок.
        if lower.contains("мировой") || lower.contains("участ") || lower.contains("уч.") {
            if let g = firstMatch(#"(?:уч\.?|участ[а-я]*)\s*№?\s*(\d+)"#, input) {
                return ("Мировой, уч. \(g[0])", .magistrate, nil, false)
            }
        }

        // Суд автономного округа / автономной области.
        if let g = firstMatch(#"^Суд\s+(.+?)\s+(?:автономного\s+округа|автономной\s+области)\b.*$"#, input) {
            return ("Суд \(g[0]) АО", .subject, nil, false)
        }
        if let g = firstMatch(#"^Суд\s+(.+?)\s+АО$"#, input) {
            return ("Суд \(g[0]) АО", .subject, nil, false)
        }

        // Областной / краевой суд.
        if let g = firstMatch(#"^(.+?)\s+областной\s+суд$"#, input) {
            return ("\(g[0]) облсуд", .subject, nil, false)
        }
        if let g = firstMatch(#"^(.+?)\s+облсуд$"#, input) {
            return ("\(g[0]) облсуд", .subject, nil, false)
        }
        if let g = firstMatch(#"^(.+?)\s+краевой\s+суд$"#, input) {
            return ("\(g[0]) крайсуд", .subject, nil, false)
        }
        if let g = firstMatch(#"^(.+?)\s+крайсуд$"#, input) {
            return ("\(g[0]) крайсуд", .subject, nil, false)
        }

        // Районный / городской / межрайонный суд — общий случай (district).
        if let g = firstMatch(#"^(.+?)\s+(районный|городской|межрайонный)\s+суд(.*)$"#, input) {
            let (locality, cityTail) = districtTail(g[2])
            return (g[0], .district, locality, cityTail)
        }
        // «горсуд» как идемпотентная/краткая форма (кроме трёх городов
        // федерального значения — те уже отсеяны выше).
        if let g = firstMatch(#"^(.+?)\s+горсуд(.*)$"#, input) {
            let (locality, cityTail) = districtTail(g[1])
            return (g[0], .district, locality, cityTail)
        }
        // Голое прилагательное («Сыктывкарский») — это ровно та форма, которую
        // сама функция производит как short для районного/городского суда,
        // поэтому без неё нарушалась бы идемпотентность на собственных
        // коротких именах (проверено на всех 101 судах VNKODCourts.json).
        // Риск ложных срабатываний невелик: единственное слово, целиком
        // состоящее из букв, с типичным для относительных прилагательных
        // окончанием -ский/-цкий.
        if lower != "мировой", let g = firstMatch(#"^([А-ЯЁ][а-яё-]*(?:ый|ий|ой))$"#, input) {
            return (g[0], .district, nil, false)
        }

        return nil
    }

    /// Разбирает хвост после слова «суд» у районного/городского суда:
    /// «города Твери» / «г. Барнаула» → город (входит в `key`, различает
    /// одноимённые суды разных городов); «Республики Коми» / «(Республика
    /// Коми)» → регион (в `key` не входит — это тот же суд).
    private static func districtTail(_ rawTail: String) -> (locality: String?, cityTail: Bool) {
        var tail = rawTail.trimmingCharacters(in: .whitespaces)
        if tail.hasPrefix("("), tail.hasSuffix(")") {
            tail = String(tail.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !tail.isEmpty else { return (nil, false) }
        if let g = firstMatch(#"^города\s+(\S+)"#, tail) {
            return ("г. \(g[0])", true)
        }
        if let g = firstMatch(#"^г\.\s*(\S+)"#, tail) {
            return ("г. \(g[0])", true)
        }
        return (tail, false)
    }

    private static func districtKindAbbrev(_ raw: String) -> String? {
        let s = yo2ye(raw).lowercased()
        if s.contains("межрайонный") { return "м/с" }
        if s.contains("городской") || s.contains("горсуд") { return "г/с" }
        if s.contains("районный") { return "р/с" }
        return nil
    }

    private static func makeKey(tier: CourtTier?, short: String, locality: String?, cityTail: Bool) -> String {
        guard let tier else { return "?|" + short.lowercased() }
        var key = "\(tier.rawValue)|\(short.lowercased())"
        if cityTail, let locality { key += "|\(locality.lowercased())" }
        return key
    }

    // MARK: - утилиты

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func yo2ye(_ s: String) -> String {
        s.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
    }

    /// Компиляция `NSRegularExpression` не бесплатна, а классификация суда
    /// вызывается на каждый рендер карточки — кэшируем скомпилированные
    /// регулярки по тексту паттерна (список паттернов фиксирован в коде,
    /// так что кэш ограничен). Само сопоставление у `NSRegularExpression`
    /// потокобезопасно, поэтому лока достаточно только вокруг словаря.
    private static let regexCacheLock = NSLock()
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]

    private static func compiledRegex(_ pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        if let cached = regexCache[pattern] {
            regexCacheLock.unlock()
            return cached
        }
        regexCacheLock.unlock()
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        regexCacheLock.lock()
        regexCache[pattern] = compiled
        regexCacheLock.unlock()
        return compiled
    }

    /// Первое совпадение `pattern` (регистронезависимо) в `text`; результат —
    /// захваченные группы (без группы 0), либо nil при отсутствии совпадения.
    private static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let re = compiledRegex(pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for i in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append("")
            }
        }
        return groups
    }
}
