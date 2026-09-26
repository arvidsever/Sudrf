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
        guard !full.isEmpty else {
            return CourtNameDisplay(full: full, short: full, tier: nil, key: "?|", locality: nil)
        }
        if let c = classify(full) {
            return displayResult(full: full, c: c)
        }
        // Не распознали как есть — часто мешает хвост в скобках, не входящий
        // в устройство самого имени («Республика Саха (Якутия)» ловится ещё
        // на первом проходе, потому что там «(Якутия)» — часть захватываемой
        // группы; а вот «...суд (г. Санкт-Петербург)» ломает регэксп с «$»
        // сразу после ключевого слова). Пробуем без хвоста в скобках.
        if let g = firstMatch(#"^(.+?)\s*\((.*)\)$"#, full), let c = classify(g[0]) {
            let locality = c.locality ?? (g[1].isEmpty ? nil : g[1])
            return displayResult(full: full, c: (c.short, c.tier, locality, c.cityTail, c.districtKind))
        }
        return CourtNameDisplay(full: full, short: full, tier: nil,
                                 key: "?|" + yo2ye(full).lowercased(), locality: nil)
    }

    private static func displayResult(full: String, c: Classified) -> CourtNameDisplay {
        let key = makeKey(tier: c.tier, short: c.short, locality: c.locality,
                           cityTail: c.cityTail, districtKind: c.districtKind)
        return CourtNameDisplay(full: full, short: c.short, tier: c.tier, key: key, locality: c.locality)
    }

    /// Единая идентичность суда для ЦЕЛОГО набора (в отличие от одиночного
    /// `display(_:).key`) — два уровня слияния «недосказанных» записей:
    ///
    /// 1. Вид (р/с/г/с/м/с): внутри «звено|short» запись без вида в тексте
    ///    («Благовещенский» само по себе) наследует ЕДИНСТВЕННЫЙ встретившийся
    ///    в группе вид — угадывать между городским и районным при двух видах
    ///    нельзя, тогда она остаётся при базовом ключе.
    /// 2. Город: внутри «звено|short|вид» запись БЕЗ ЛЮБОГО хвоста
    ///    («Эжвинский районный суд») сливается с городским хвостом
    ///    («…г. Сыктывкара»), если в подгруппе встретился РОВНО один город.
    ///    Запись с РЕГИОНАЛЬНЫМ хвостом («Тверской области») в это слияние
    ///    не участвует — регион не «недосказанность», это просто другое
    ///    уточнение подсудности того же (или другого) суда, и подменять его
    ///    городом нельзя.
    public static func canonicalKeys(_ raws: [String]) -> [String: String] {
        struct Info { let raw: String; let short: String; let tier: CourtTier?
            let locality: String?; let cityTail: Bool; let kind: String? }
        let infos: [Info] = raws.map { raw in
            let full = collapse(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !full.isEmpty, let c = classify(full) else {
                return Info(raw: raw, short: full, tier: nil, locality: nil, cityTail: false, kind: nil)
            }
            return Info(raw: raw, short: c.short, tier: c.tier, locality: c.locality,
                        cityTail: c.cityTail, kind: c.districtKind)
        }

        var byBase: [String: [Info]] = [:]
        for i in infos {
            let base = "\(i.tier?.rawValue ?? "?")|\(yo2ye(i.short).lowercased())"
            byBase[base, default: []].append(i)
        }
        var kindBucket: [String: String] = [:]
        for (base, group) in byBase {
            let kinds = Set(group.compactMap(\.kind))
            let onlyKind = kinds.count == 1 ? kinds.first : nil
            for i in group {
                let k = i.kind ?? onlyKind
                kindBucket[i.raw] = k.map { "\(base)|\($0)" } ?? base
            }
        }

        var byBucket: [String: [Info]] = [:]
        for i in infos { byBucket[kindBucket[i.raw]!, default: []].append(i) }
        var result: [String: String] = [:]
        for (bucket, group) in byBucket {
            let cities = Set(group.compactMap { $0.cityTail ? $0.locality.map { yo2ye($0).lowercased() } : nil })
            let onlyCity = cities.count == 1 ? cities.first : nil
            for i in group {
                if i.cityTail, let locality = i.locality {
                    result[i.raw] = "\(bucket)|\(yo2ye(locality).lowercased())"
                } else if i.locality == nil, let onlyCity {
                    result[i.raw] = "\(bucket)|\(onlyCity)"
                } else {
                    result[i.raw] = bucket
                }
            }
        }
        return result
    }

    /// Короткие названия для набора судов календаря: если у разных судов
    /// (разных `canonicalKeys`) совпал `short`, к ним добавляется уточнение —
    /// сперва вид (р/с/г/с/м/с), если он реально различает записи внутри
    /// коллизии («Благовещенский г/с» / «Благовещенский р/с»); если вида
    /// достаточно — на этом останавливаемся, иначе (тот же вид, разные
    /// города/участки) добавляем ещё и хвост («Центральный р/с г. Твери»,
    /// «Мировой, уч. 1 Эжвинского судебного района г. Сыктывкара»).
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
                let kind = districtKindAbbrev(e.raw)
                var label = short
                if let kind { label += " \(kind)" }
                let peers = group.filter { districtKindAbbrev($0.raw) == kind }
                let peerKeys = Set(peers.map { canonical[$0.raw] ?? $0.d.key })
                if peerKeys.count > 1, let locality = e.d.locality {
                    label += " \(locality)"
                }
                result[e.raw] = label
            }
        }
        return result
    }

    // MARK: - классификация

    private typealias Classified = (short: String, tier: CourtTier, locality: String?, cityTail: Bool, districtKind: String?)

    private static let ordinalWords = "Первый|Второй|Третий|Четвертый|Четвёртый|Пятый|Шестой|Седьмой|Восьмой|Девятый"
    private static let ordinalToNumber: [String: Int] = [
        "первый": 1, "второй": 2, "третий": 3, "четвертый": 4, "пятый": 5,
        "шестой": 6, "седьмой": 7, "восьмой": 8, "девятый": 9
    ]

    private static func classify(_ rawInput: String) -> Classified? {
        // Латинские двойники («Cуд» с латинской C) — реальные опечатки с
        // порталов; фолдим их в кириллицу СРАЗУ, до любых регулярок, иначе
        // «[Сс]уд» и другие ключевые слова просто не совпадут.
        let input = foldLatinLookalikes(rawInput)
        let lower = yo2ye(input).lowercased()

        // Верховный Суд РФ.
        if lower == "верховный суд российской федерации" || lower == "верховный суд рф"
            || lower == "вс рф" {
            return ("ВС РФ", .supreme, nil, false, nil)
        }

        // Единственный распространённый алиас-исключение.
        if lower == "мосгорсуд" {
            return ("Московский горсуд", .subject, nil, false, nil)
        }

        // Городские суды трёх городов федерального значения — звено subject,
        // а не district (в отличие от прочих «городских судов»). Хвост в
        // скобках допускаем прямо тут: иначе он проваливается в общий
        // районный/городской разбор ниже и портит звено (defect #6).
        if let g = firstMatch(#"^(Московский|Санкт-Петербургский|Севастопольский)\s+(?:городской\s+суд|горсуд)(?:\s*\((.*)\))?$"#, input) {
            let locality = g[1].isEmpty ? nil : g[1]
            return ("\(g[0]) горсуд", .subject, locality, false, nil)
        }

        // АСОЮ / КСОЮ — полное название.
        if let g = firstMatch(#"^(\#(ordinalWords))\s+(апелляционный|кассационный)\s+суд(?:\s+общей\s+юрисдикции)?$"#, input) {
            let n = ordinalToNumber[yo2ye(g[0]).lowercased()] ?? 0
            let kind = g[1].lowercased() == "апелляционный" ? "АСОЮ" : "КСОЮ"
            return ("\(n) \(kind)", kind == "АСОЮ" ? .appeal : .cassation, nil, false, nil)
        }
        // АСОЮ / КСОЮ — «Третий КСОЮ».
        if let g = firstMatch(#"^(\#(ordinalWords))\s+(АСОЮ|КСОЮ)$"#, input) {
            let n = ordinalToNumber[yo2ye(g[0]).lowercased()] ?? 0
            let kind = g[1].uppercased()
            return ("\(n) \(kind)", kind == "АСОЮ" ? .appeal : .cassation, nil, false, nil)
        }
        // АСОЮ / КСОЮ — короткая цифровая форма («3 КСОЮ»), идемпотентность.
        if let g = firstMatch(#"^(\d)\s*(АСОЮ|КСОЮ)$"#, input) {
            let kind = g[1].uppercased()
            return ("\(g[0]) \(kind)", kind == "АСОЮ" ? .appeal : .cassation, nil, false, nil)
        }

        // Военные апелляция/кассация.
        if lower == "апелляционный военный суд" || lower == "авс" {
            return ("АВС", .appeal, nil, false, nil)
        }
        if lower == "кассационный военный суд" || lower == "квс" {
            return ("КВС", .cassation, nil, false, nil)
        }

        // Окружной (флотский) военный суд.
        if let g = firstMatch(#"^(.+?)\s+(?:окружной|флотский)\s+военный\s+суд$"#, input) {
            return ("\(g[0]) ОВС", .subject, nil, false, nil)
        }
        if let g = firstMatch(#"^(.+?)\s+ОВС$"#, input) {
            return ("\(g[0]) ОВС", .subject, nil, false, nil)
        }

        // Гарнизонный военный суд.
        if let g = firstMatch(#"^(.+?)\s+гарнизонный\s+военный\s+суд$"#, input) {
            return ("\(g[0]) ГВС", .district, nil, false, nil)
        }
        if let g = firstMatch(#"^(.+?)\s+ГВС$"#, input) {
            return ("\(g[0]) ГВС", .district, nil, false, nil)
        }

        // Верховный суд республики — «Республики X» либо «X Республики».
        if let g = firstMatch(#"^Верховный\s+[Сс]уд\s+Республики\s+(.+)$"#, input) {
            return ("ВС \(g[0])", .subject, nil, false, nil)
        }
        if let g = firstMatch(#"^Верховный\s+[Сс]уд\s+(.+\s+Республики)$"#, input) {
            return ("ВС \(g[0])", .subject, nil, false, nil)
        }
        // Верховный суд субъекта без слова «Республики» («Верховный суд Коми»).
        if let g = firstMatch(#"^Верховный\s+[Сс]уд\s+(.+)$"#, input) {
            return ("ВС \(g[0])", .subject, nil, false, nil)
        }
        // Идемпотентность: уже краткая форма «ВС X» (кроме «ВС РФ», отсеян выше).
        if let g = firstMatch(#"^ВС\s+(.+)$"#, input), yo2ye(g[0]).lowercased() != "рф" {
            return ("ВС \(g[0])", .subject, nil, false, nil)
        }

        // Мировой судья / судебный участок. Хвост после номера («…судебного
        // района г. Сыктывкара») — часть идентичности участка: без него
        // разные участки с одним номером в разных районах ложно совпадают.
        if lower.contains("мировой") || lower.contains("участ") || lower.contains("уч.") {
            if let g = firstMatch(#"(?:уч\.?|участ[а-я]*)\s*№?\s*(\d+)\s*(.*)$"#, input) {
                let tail = g[1].trimmingCharacters(in: .whitespaces)
                let locality = tail.isEmpty ? nil : tail
                return ("Мировой, уч. \(g[0])", .magistrate, locality, locality != nil, nil)
            }
        }

        // Суд автономного округа / автономной области.
        if let g = firstMatch(#"^Суд\s+(.+?)\s+(?:автономного\s+округа|автономной\s+области)\b.*$"#, input) {
            return ("Суд \(g[0]) АО", .subject, nil, false, nil)
        }
        if let g = firstMatch(#"^Суд\s+(.+?)\s+АО$"#, input) {
            return ("Суд \(g[0]) АО", .subject, nil, false, nil)
        }

        // Областной / краевой суд.
        if let g = firstMatch(#"^(.+?)\s+областной\s+суд$"#, input) {
            return ("\(g[0]) облсуд", .subject, nil, false, nil)
        }
        if let g = firstMatch(#"^(.+?)\s+облсуд$"#, input) {
            return ("\(g[0]) облсуд", .subject, nil, false, nil)
        }
        if let g = firstMatch(#"^(.+?)\s+краевой\s+суд$"#, input) {
            return ("\(g[0]) крайсуд", .subject, nil, false, nil)
        }
        if let g = firstMatch(#"^(.+?)\s+крайсуд$"#, input) {
            return ("\(g[0]) крайсуд", .subject, nil, false, nil)
        }

        // Районный / городской / межрайонный суд — общий случай (district).
        // Вид (р/с/г/с/м/с) — часть идентичности: «Благовещенский городской»
        // и «Благовещенский районный» — два РАЗНЫХ суда одного города.
        if let g = firstMatch(#"^(.+?)\s+(районный|городской|межрайонный)\s+суд(.*)$"#, input) {
            let (locality, cityTail) = districtTail(g[2])
            return (g[0], .district, locality, cityTail, districtKindAbbrev(input))
        }
        // «горсуд» как идемпотентная/краткая форма (кроме трёх городов
        // федерального значения — те уже отсеяны выше).
        if let g = firstMatch(#"^(.+?)\s+горсуд(.*)$"#, input) {
            let (locality, cityTail) = districtTail(g[1])
            return (g[0], .district, locality, cityTail, districtKindAbbrev(input))
        }
        // Голое прилагательное («Сыктывкарский») — это ровно та форма, которую
        // сама функция производит как short для районного/городского суда,
        // поэтому без неё нарушалась бы идемпотентность на собственных
        // коротких именах (проверено на всех 101 судах VNKODCourts.json).
        // Риск ложных срабатываний невелик: единственное слово, целиком
        // состоящее из букв, с типичным для относительных прилагательных
        // окончанием -ский/-цкий. Вид тут неизвестен (nil) — `canonicalKeys`
        // сам подберёт его, если в наборе он единственный.
        if lower != "мировой", let g = firstMatch(#"^([А-ЯЁ][а-яё-]*(?:ый|ий|ой))$"#, input) {
            return (g[0], .district, nil, false, nil)
        }

        return nil
    }

    /// Разбирает хвост после слова «суд» у районного/городского суда:
    /// «города Твери» / «г. Барнаула» → город (входит в `key`, различает
    /// одноимённые суды разных городов; берём все слова вплоть до
    /// регионального слова или конца — «г. Нижнего Новгорода» целиком, а не
    /// только «Нижнего»); «Республики Коми» / «(Республика Коми)» → регион
    /// (в `key` не входит — это тот же суд).
    private static func districtTail(_ rawTail: String) -> (locality: String?, cityTail: Bool) {
        var tail = rawTail.trimmingCharacters(in: .whitespaces)
        if tail.hasPrefix("("), tail.hasSuffix(")") {
            tail = String(tail.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !tail.isEmpty else { return (nil, false) }
        if let g = firstMatch(#"^(?:города|г\.)\s*(.+?)(?=\s+(?:Республики|области|края|автономного)\b|\s*\(|$)"#, tail) {
            return ("г. \(g[0].trimmingCharacters(in: .whitespaces))", true)
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

    private static func makeKey(tier: CourtTier?, short: String, locality: String?,
                                 cityTail: Bool, districtKind: String?) -> String {
        guard let tier else { return "?|" + yo2ye(short).lowercased() }
        var key = "\(tier.rawValue)|\(yo2ye(short).lowercased())"
        if let districtKind { key += "|\(districtKind)" }
        if cityTail, let locality { key += "|\(yo2ye(locality).lowercased())" }
        return key
    }

    // MARK: - утилиты

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func yo2ye(_ s: String) -> String {
        s.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
    }

    /// Латинские двойники кириллических букв (реальные опечатки с сайтов
    /// судов — «Cуд» с латинской C) → кириллица, только для СРАВНЕНИЯ
    /// (см. `Cartoteka.normalizedNumber` — тот же приём для номеров дел).
    private static let latinLookalikes: [Character: Character] = [
        "c": "с", "a": "а", "o": "о", "e": "е", "p": "р", "x": "х",
        "k": "к", "m": "м", "h": "н", "t": "т", "b": "в",
        "C": "С", "A": "А", "O": "О", "E": "Е", "P": "Р", "X": "Х",
        "K": "К", "M": "М", "H": "Н", "T": "Т", "B": "В"
    ]

    private static func foldLatinLookalikes(_ s: String) -> String {
        String(s.map { latinLookalikes[$0] ?? $0 })
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
