import Foundation

/// Сокращает `partiesShort` (см. `MovementDerivation.partiesShort` в
/// SudrfApp) для узкой карточки месяца календаря. Level 1 применяется всегда;
/// level 2 — запасной вариант, если level 1 не помещается.
public enum PartyNamePresentation {

    public static func level1(_ parties: String) -> String {
        format(parties, entity: entity1)
    }

    public static func level2(_ parties: String) -> String {
        format(parties, entity: entity2)
    }

    // MARK: - общий разбор сторон

    private static func format(_ parties: String, entity: (String) -> String) -> String {
        splitSides(parties).map { side(from: $0, entity: entity) }.joined(separator: " ⚔ ")
    }

    /// Старые снимки разделяли стороны « → », новые — « ⚔ »; на выходе всегда « ⚔ ».
    private static func splitSides(_ parties: String) -> [String] {
        parties.replacingOccurrences(of: " → ", with: " ⚔ ")
            .components(separatedBy: " ⚔ ")
            .map(dropRole)
    }

    /// «ФИО · роль» (КоАП/УПК) → «ФИО»: роль рисуется отдельным значком.
    private static func dropRole(_ side: String) -> String {
        guard let range = side.range(of: " · ") else { return side }
        return String(side[..<range.lowerBound])
    }

    /// Одна сторона: «X», «X и Y» или «X и N других/другой».
    private static func side(from text: String, entity: (String) -> String) -> String {
        if let g = firstMatch(#"^(.+?)\s+и\s+(\d+)\s+(?:других|другой)$"#, text) {
            return "\(entity(g[0])) +\(g[1])"
        }
        // Разбиваем по первому « и » только если левая часть САМА ПО СЕБЕ —
        // законченное распознанное лицо/организация (иначе это «и» внутри
        // одной стороны: «Комитет имущественных и земельных отношений»,
        // «пенсионного и социального страхования», «Рога и копыта» в
        // кавычках — такие ни в коем случае не режем).
        if let g = firstMatch(#"^(.+?)\s+и\s+(.+)$"#, text), isCompleteEntity(g[0]) {
            return "\(entity(g[0])) и \(entity(g[1]))"
        }
        return entity(text)
    }

    /// true, если текст сам по себе — законченное ФИО, «ИП ФИО» или
    /// организация закрытой формы с полностью закрытыми кавычками (без
    /// повисшего «Рога» без закрывающей «»).
    private static func isCompleteEntity(_ text: String) -> Bool {
        if personInitials(text) != nil { return true }
        if let g = firstMatch(#"^Индивидуальный\s+предприниматель\s+(.+)$"#, text) {
            return personInitials(g[0]) != nil
        }
        if let (_, rest) = orgForm(text) { return isBalancedQuoted(rest) }
        if frequentBody(text) != nil { return true }
        return false
    }

    private static func isBalancedQuoted(_ s: String) -> Bool {
        guard s.hasPrefix("«"), s.hasSuffix("»") else { return false }
        let opens = s.filter { $0 == "«" }.count
        let closes = s.filter { $0 == "»" }.count
        return opens > 0 && opens == closes
    }

    // MARK: - level 1 (ФИО с инициалами, ООО «Название»)

    private static func entity1(_ text: String) -> String {
        if let body = frequentBody(text) { return body.level1 }
        if let g = firstMatch(#"^Индивидуальный\s+предприниматель\s+(.+)$"#, text) {
            return "ИП \(personInitials(g[0]) ?? g[0])"
        }
        if let (abbrev, rest) = orgForm(text) {
            return rest.isEmpty ? abbrev : "\(abbrev) \(rest)"
        }
        return personInitials(text) ?? text
    }

    // MARK: - level 2 (только фамилия, только «ядро» организации)

    private static func entity2(_ text: String) -> String {
        if let body = frequentBody(text) { return body.level2 }
        if let g = firstMatch(#"^Индивидуальный\s+предприниматель\s+(.+)$"#, text) {
            return "ИП \(surname(g[0]) ?? g[0])"
        }
        if let (_, rest) = orgForm(text) {
            return rest
        }
        return surname(text) ?? text
    }

    // MARK: - ФИО

    /// «Фамилия Имя Отчество» → «Фамилия И. О.» (и «Фамилия Имя» → «Фамилия И.»).
    /// Поддерживает двойные (дефисные) фамилии и «ё»/«е».
    private static func personInitials(_ text: String) -> String? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count == 2 || words.count == 3, words.allSatisfy(isNameWord) else { return nil }
        let initials = words.dropFirst().map { "\(String($0.first!))." }.joined(separator: " ")
        return "\(words[0]) \(initials)"
    }

    /// Только фамилия — для level 2.
    private static func surname(_ text: String) -> String? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count == 2 || words.count == 3, words.allSatisfy(isNameWord) else { return nil }
        return words[0]
    }

    /// Слово похоже на элемент ФИО: с заглавной буквы, остальное — строчные,
    /// кроме буквы сразу после дефиса (двойные фамилии типа «Петрова-Иванова»).
    private static func isNameWord(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        var afterHyphen = false
        for ch in word.dropFirst() {
            if ch == "-" { afterHyphen = true; continue }
            if afterHyphen { afterHyphen = false; continue }
            if ch.isUppercase { return false }
        }
        return true
    }

    // MARK: - организационно-правовые формы (ГК РФ), закрытый список

    private static let orgForms: [(phrase: String, abbrev: String)] = [
        ("Публичное акционерное общество", "ПАО"),
        ("Непубличное акционерное общество", "НАО"),
        ("Открытое акционерное общество", "ОАО"),
        ("Закрытое акционерное общество", "ЗАО"),
        ("Акционерное общество", "АО"),
        ("Общество с ограниченной ответственностью", "ООО"),
        ("Автономная некоммерческая организация", "АНО"),
        ("Некоммерческая организация", "НКО"),
        ("Товарищество собственников жилья", "ТСЖ"),
        ("Садоводческое некоммерческое товарищество", "СНТ"),
        ("Федеральное государственное унитарное предприятие", "ФГУП"),
        ("Государственное унитарное предприятие", "ГУП"),
        ("Муниципальное унитарное предприятие", "МУП"),
        ("Государственное бюджетное учреждение", "ГБУ"),
        ("Муниципальное бюджетное учреждение", "МБУ"),
        ("Федеральное казенное учреждение", "ФКУ"),
        ("Федеральное казённое учреждение", "ФКУ")
    ]

    private static func orgForm(_ text: String) -> (abbrev: String, rest: String)? {
        let lower = text.lowercased()
        for form in orgForms where lower.hasPrefix(form.phrase.lowercased()) {
            let rest = String(text.dropFirst(form.phrase.count)).trimmingCharacters(in: .whitespaces)
            return (form.abbrev, rest)
        }
        return nil
    }

    // MARK: - частые органы/ведомства — правило по региону, не список судов

    private static func frequentBody(_ text: String) -> (level1: String, level2: String)? {
        if let g = firstMatch(#"^Министерство\s+юстиции\s+(.+)$"#, text) {
            return ("Минюст \(regionTail(g[0]))", "Минюст")
        }
        if let g = firstMatch(#"^Министерство\s+внутренних\s+дел\s+по\s+(.+)$"#, text) {
            return ("МВД по \(regionTail(g[0]))", "МВД")
        }
        if let g = firstMatch(#"^Отделение\s+Фонда\s+пенсионного\s+и\s+социального\s+страхования\s+Российской\s+Федерации\s+по\s+(.+)$"#, text) {
            return ("ОСФР по \(regionTail(g[0]))", "ОСФР")
        }
        if let g = firstMatch(#"^Управление\s+Федеральной\s+службы\s+государственной\s+регистрации,?\s+кадастра\s+и\s+картографии\s+по\s+(.+)$"#, text) {
            return ("Управление Росреестра по \(g[0])", "Росреестр")
        }
        if let g = firstMatch(#"^Министерство\s+природных\s+ресурсов\s+и\s+охраны\s+окружающей\s+среды\s+(.+)$"#, text) {
            return ("Минприроды \(regionTail(g[0]))", "Минприроды")
        }
        if let g = firstMatch(#"^Государственный\s+Совет\s+(.+)$"#, text) {
            return ("Госсовет \(regionTail(g[0]))", "Госсовет")
        }
        if let g = firstMatch(#"^Правительство\s+(.+)$"#, text) {
            let ab = regionTail(g[0])
            return ("Правительство \(ab)", "Правительство \(ab)")
        }
        if let g = firstMatch(#"^Администрация\s+муниципального\s+образования\s+городского\s+округа\s+(«.+»)$"#, text) {
            return ("Администрация МО ГО \(g[0])", "адм. \(g[0])")
        }
        return nil
    }

    /// «Республике/Республики X» → «РX» (первая буква региона); «Российской
    /// Федерации» → «России»; иное — без изменений (правило по региону, а не
    /// список регионов).
    private static func regionTail(_ tail: String) -> String {
        let t = tail.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("российской федерации") { return "России" }
        if let g = firstMatch(#"^Республик[а-я]*\s+(\S+)"#, t), let letter = g[0].first {
            return "Р\(String(letter).uppercased())"
        }
        return t
    }

    // MARK: - утилиты

    /// Кэш скомпилированных регулярок (см. `CourtNamePresentation` — тот же
    /// приём и по той же причине: разбор сторон идёт на каждый рендер карточки).
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
