//  Parties.swift — Sudrf · v13 «Участники»
//  Модель участников дела + разбор:
//   • из выдачи — колонка «стороны / сведения по делу» (essence): маркеры
//     «ИСТЕЦ: … ОТВЕТЧИК: … ТРЕТЬЕ ЛИЦО: …»;
//   • из карточки — вкладка «СТОРОНЫ ПО ДЕЛУ» (см. CaseCardParser).
//
//  Роли сведены к трём корзинам интерфейса (вариант 1A из макета):
//   атакующая сторона (истец / адм. истец / заявитель / взыскатель),
//   защищающаяся (ответчик / адм. ответчик / должник / привлекаемое лицо),
//   третьи лица (третьи / заинтересованные лица).

import Foundation

// MARK: - Явная раскладка участников (КоАП / УПК / особое производство)

/// Иконка колонки участников в шапке дела.
public enum PartyIcon: String, Sendable, Equatable, Codable {
    case plaintiff   // атакующая сторона — текстовый глиф «⚔»
    case shield      // защита / ответчик
    case scales      // обвинение
    case person      // третьи / заинтересованные / заявитель
}

/// Один участник колонки. `sub` — уточнение процессуальной роли
/// («защитник», «потерпевшая», «подсудимый · ч. 2 ст. 158 УК РФ»).
public struct PartyMember: Sendable, Equatable, Codable {
    public var name: String
    public var sub: String?
    public init(name: String, sub: String? = nil) { self.name = name; self.sub = sub }
}

/// Колонка участников. Для КоАП/УПК это «Сторона защиты» / «Сторона обвинения»,
/// для особого производства — «Заявитель» / «Заинтересованное лицо», для ГПК/КАС
/// строится из корзин (истец/ответчик/третьи) с заголовками вида процесса.
public struct PartyColumn: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var title: String        // заголовок (ед. ч.)
    public var titleMany: String    // заголовок (мн. ч.)
    public var icon: PartyIcon
    public var members: [PartyMember]

    public init(id: String, title: String, titleMany: String,
                icon: PartyIcon, members: [PartyMember]) {
        self.id = id; self.title = title; self.titleMany = titleMany
        self.icon = icon; self.members = members
    }
    public var isEmpty: Bool { members.isEmpty }
    /// «ОТВЕТЧИКИ · 4» / «ЗАЩИТНИК».
    public func heading() -> String {
        let base = (members.count > 1 ? titleMany : title).uppercased()
        return members.count > 1 ? "\(base) · \(members.count)" : base
    }
}

/// Сырая пара «роль → имя» из карточки/выдачи (для пересборки сторон КоАП/УПК).
public struct RoleItem: Sendable, Equatable, Codable {
    public var role: String
    public var name: String
    public init(role: String, name: String) { self.role = role; self.name = name }
}

public struct CaseParties: Sendable, Equatable, Codable {
    public var plaintiffs: [String]     // истцы и процессуальные аналоги
    public var defendants: [String]     // ответчики и процессуальные аналоги
    public var thirdParties: [String]   // третьи / заинтересованные лица
    /// Вид процесса — от него зависят названия ролей (ГПК: истец/
    /// ответчик/третье лицо; КАС: адм. истец/адм. ответчик/заинтересованное лицо).
    /// Ставится автоматически при разборе, когда встречаются адм. роли.
    public var kind: ProcessKind
    /// Явная раскладка колонок (демо-данные и пересобранные стороны КоАП/УПК/
    /// особого). Если не пуста — полностью задаёт шапку участников.
    public var columns: [PartyColumn]
    /// Сырые (роль, имя) в порядке появления — источник для пересборки колонок
    /// уголовных/административных дел, где роль не сводится к трём корзинам.
    public var roleItems: [RoleItem]

    public init(plaintiffs: [String] = [], defendants: [String] = [],
                thirdParties: [String] = [], kind: ProcessKind = .civil,
                columns: [PartyColumn] = [], roleItems: [RoleItem] = []) {
        self.plaintiffs = plaintiffs
        self.defendants = defendants
        self.thirdParties = thirdParties
        self.kind = kind
        self.columns = columns
        self.roleItems = roleItems
    }

    public var isEmpty: Bool {
        plaintiffs.isEmpty && defendants.isEmpty && thirdParties.isEmpty
            && columns.allSatisfy { $0.isEmpty }
    }

    public var totalCount: Int {
        plaintiffs.count + defendants.count + thirdParties.count
            + columns.reduce(0) { $0 + $1.members.count }
    }

    // MARK: - Корзина по названию роли

    public enum Bucket: Sendable { case plaintiff, defendant, third }

    /// Корзина по тексту роли («ИСТЕЦ», «Адм. ответчик», «Третье лицо»…).
    /// nil — роль к сторонам не относится (судья, секретарь, представитель…).
    /// Порядок проверок важен: «заинтересованное лицо» содержит «лицо», а
    /// «административный ответчик» — «ответчик», поэтому третьи лица — первыми.
    public static func bucket(forRole role: String) -> Bucket? {
        let s = role.lowercased()
        guard !s.contains("представител") else { return nil }   // не сторона
        if s.contains("трет") || s.contains("заинтерес") { return .third }
        if s.contains("ответчик") || s.contains("должник")
            || s.contains("привлека") { return .defendant }
        if s.contains("истец") || s.contains("истц") || s.contains("заявител")
            || s.contains("взыскател") { return .plaintiff }
        return nil
    }

    public mutating func add(role: String, name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n.count > 1 else { return }
        let lower = role.lowercased()
        // Судебный состав — не участник.
        guard !lower.contains("судья") && !lower.contains("секретар")
            && !lower.contains("состав суда") else { return }

        // Поднять вид процесса по характерным ролям (КАС / УПК / КоАП).
        upgradeKind(byRole: lower)

        // Сырая пара — для пересборки сторон уголовных/административных дел.
        if !roleItems.contains(where: { $0.role == role && $0.name == n }) {
            roleItems.append(RoleItem(role: role, name: n))
        }

        // Корзины — для ГПК/КАС/особого (рендер по трём корзинам).
        guard let bucket = Self.bucket(forRole: role) else { return }
        switch bucket {
        case .plaintiff: if !plaintiffs.contains(n)   { plaintiffs.append(n) }
        case .defendant: if !defendants.contains(n)   { defendants.append(n) }
        case .third:     if !thirdParties.contains(n) { thirdParties.append(n) }
        }
    }

    /// Поднимает (не понижает) вид процесса по тексту роли.
    private mutating func upgradeKind(byRole lower: String) {
        if kind == .upk || kind == .koap { return }
        if lower.contains("подсудим") || lower.contains("обвиняем")
            || lower.contains("гособвин")
            || (lower.contains("государствен") && lower.contains("обвинит")) {
            kind = .upk; return
        }
        if lower.contains("в отношении которого ведётся")
            || lower.contains("привлека")
            || (lower.contains("составив") && lower.contains("протокол")) {
            kind = .koap; return
        }
        if lower.contains("административн") || lower.contains("заинтересован") {
            if kind == .civil || kind == .special { kind = .administrative }
        }
    }

    /// Доопределить вид процесса по номеру дела, если роли его не выдали
    /// (карточка без вкладки сторон). Не понижает уже определённый вид.
    public mutating func inferKindIfNeeded(caseNumber: String) {
        if kind == .civil || kind == .administrative {
            let byNumber = ProcessKind.detect(caseNumber: caseNumber)
            if byNumber != .civil { kind = byNumber }
        }
        // Особое производство ГПК нельзя отличить по номеру (та же серия «2-…»):
        // признаём по составу ролей — заявитель + заинтересованное лицо, при
        // этом нет ответчика и нет административных ролей (иначе это КАС).
        let lowerRoles = roleItems.map { $0.role.lowercased() }
        if (kind == .civil || kind == .administrative),
           ProcessKind.detect(caseNumber: caseNumber) == .civil,
           lowerRoles.contains(where: { $0.contains("заявител") }),
           lowerRoles.contains(where: { $0.contains("заинтересован") }),
           !lowerRoles.contains(where: { $0.contains("административн") }),
           !lowerRoles.contains(where: { $0.contains("ответчик") }) {
            kind = .special
        }
    }

    // MARK: - Колонки для шапки (единый источник отрисовки)

    /// Готовые колонки участников для шапки дела. Если задана явная раскладка
    /// (`columns`) — она и используется; иначе строится из вида процесса.
    public var displayColumns: [PartyColumn] {
        if !columns.allSatisfy({ $0.isEmpty }) { return columns.filter { !$0.isEmpty } }
        switch kind {
        case .koap, .upk:   return Self.buildSided(roleItems, kind: kind)
        case .special:      return buildSpecial()
        case .civil, .administrative: return buildBuckets()
        }
    }

    /// ГПК/КАС: три корзины с заголовками вида процесса.
    private func buildBuckets() -> [PartyColumn] {
        func col(_ id: String, _ b: Bucket, _ icon: PartyIcon, _ names: [String]) -> PartyColumn? {
            names.isEmpty ? nil :
            PartyColumn(id: id, title: kind.columnTitle(b, plural: false),
                        titleMany: kind.columnTitle(b, plural: true), icon: icon,
                        members: names.map { PartyMember(name: $0) })
        }
        return [col("ist", .plaintiff, .plaintiff, plaintiffs),
                col("otv", .defendant, .shield, defendants),
                col("tre", .third, .person, thirdParties)].compactMap { $0 }
    }

    /// Особое производство ГПК: заявитель + заинтересованное лицо.
    private func buildSpecial() -> [PartyColumn] {
        var cols: [PartyColumn] = []
        if !plaintiffs.isEmpty {
            cols.append(PartyColumn(id: "zayav", title: "Заявитель", titleMany: "Заявители",
                                    icon: .person, members: plaintiffs.map { PartyMember(name: $0) }))
        }
        let interested = thirdParties + defendants
        if !interested.isEmpty {
            cols.append(PartyColumn(id: "zint", title: "Заинтересованное лицо",
                                    titleMany: "Заинтересованные лица", icon: .person,
                                    members: interested.map { PartyMember(name: $0) }))
        }
        return cols
    }

    /// КоАП/УПК: две стороны (защита / обвинение); под-роль каждого участника —
    /// её исходный текст из карточки («защитник», «потерпевшая», «подсудимый …»).
    private static func buildSided(_ items: [RoleItem], kind: ProcessKind) -> [PartyColumn] {
        var defense: [PartyMember] = []
        var prosecution: [PartyMember] = []
        for it in items {
            let r = it.role.lowercased()
            let sub = it.role.trimmingCharacters(in: CharacterSet(charactersIn: " :·—-"))
            let isProsecution =
                r.contains("потерп") || r.contains("прокур") || r.contains("гособвин")
                || (r.contains("государствен") && r.contains("обвинит"))
                || r.contains("гражданский истец") || r.contains("гражданского истца")
                || (r.contains("составив") && r.contains("протокол"))
                || r.contains("административный орган") || r.contains("орган, состав")
            let isDefense =
                r.contains("защит") || r.contains("адвокат")
                || r.contains("подсудим") || r.contains("обвиняем")
                || r.contains("в отношении которого") || r.contains("привлека")
                || r.contains("гражданский ответчик") || r.contains("законный представит")
            if isProsecution && !isDefense {
                prosecution.append(PartyMember(name: it.name, sub: sub))
            } else if isDefense {
                defense.append(PartyMember(name: it.name, sub: sub))
            } else {
                // Неопознанная роль — к защите для КоАП/УПК (обычно само лицо).
                defense.append(PartyMember(name: it.name, sub: sub))
            }
        }
        var cols: [PartyColumn] = []
        if !defense.isEmpty {
            cols.append(PartyColumn(id: "zashita", title: "Сторона защиты",
                                    titleMany: "Сторона защиты", icon: .shield, members: defense))
        }
        if !prosecution.isEmpty {
            cols.append(PartyColumn(id: "obvinenie", title: "Сторона обвинения",
                                    titleMany: "Сторона обвинения", icon: .scales, members: prosecution))
        }
        return cols
    }

    // MARK: - Разбор колонки выдачи

    /// Маркеры ролей. Длинные альтернативы идут раньше коротких, иначе
    /// «административный истец» съелся бы как просто «истец». После роли
    /// допускается уточнение в скобках («Истец (заявитель):»).
    private static let rolePattern =
        #"(административный\s+истец|административный\s+ответчик|"#
        + #"адм\.\s*истец|адм\.\s*ответчик|истцы|истец|ответчики|ответчик|"#
        + #"третьи\s+лица|третье\s+лицо|заинтересованные\s+лица|"#
        + #"заинтересованное\s+лицо|заявители|заявитель|взыскатели|взыскатель|"#
        + #"должники|должник|привлекаемое\s+лицо)\s*(?:\([^)]{0,40}\))?\s*[:：]?"#

    /// Разбирает колонку «стороны / сведения по делу»: участники + остаток —
    /// текст ДО первого маркера роли (обычно существо иска / категория).
    /// Если маркеров нет, parties = nil, residual = исходный текст.
    public static func split(essence: String?) -> (parties: CaseParties?, residual: String?) {
        guard let essence, !essence.isEmpty else { return (nil, essence) }
        guard let re = try? NSRegularExpression(pattern: rolePattern,
                                                options: [.caseInsensitive]) else {
            return (nil, essence)
        }
        let ns = essence as NSString
        let matches = re.matches(in: essence, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (nil, essence) }

        var parties = CaseParties()
        for (i, m) in matches.enumerated() {
            let role = ns.substring(with: m.range(at: 1))
            let valueStart = m.range.location + m.range.length
            let valueEnd = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            guard valueEnd > valueStart else { continue }
            let value = ns.substring(with: NSRange(location: valueStart,
                                                   length: valueEnd - valueStart))
            for name in splitNames(value) { parties.add(role: role, name: name) }
        }

        let head = ns.substring(to: matches[0].range.location)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t·,;:—-"))
        return (parties.isEmpty ? nil : parties, head.isEmpty ? nil : head)
    }

    /// «Иванов И. И., Петров П. П.; ООО «Ромашка, и партнёры»» → имена.
    /// Запятая внутри кавычек/скобок не режет (наименования организаций).
    static func splitNames(_ value: String) -> [String] {
        var out: [String] = []
        var current = ""
        var depth = 0
        for ch in value {
            switch ch {
            case "(", "«", "“": depth += 1; current.append(ch)
            case ")", "»", "”": depth = max(0, depth - 1); current.append(ch)
            case ",", ";", "\n":
                if depth == 0 { out.append(current); current = "" }
                else { current.append(ch) }
            default:
                current.append(ch)
            }
        }
        out.append(current)
        return out
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t·:—-")) }
            .filter { $0.count > 1 }
    }
}

// MARK: - Вид процесса

/// Вид судопроизводства. От него зависят названия процессуальных ролей.
/// Реализуется по шагам: ГПК и КАС уже есть; арбитраж/УПК/КоАП — на будущее.
public enum ProcessKind: String, Sendable, Equatable, Codable {
    case civil          // ГПК РФ — истец / ответчик / третье лицо
    case administrative // КАС РФ — адм. истец / адм. ответчик / заинтересованное лицо
    case special        // ГПК РФ, особое производство — заявитель / заинтересованное лицо
    case koap           // КоАП РФ — сторона защиты / сторона обвинения
    case upk            // УПК РФ — сторона защиты / сторона обвинения

    /// Заголовок колонки в шапке дела (ед./мн. число). Для КоАП/УПК колонки
    /// строятся сторонами (см. CaseParties.buildSided) — эти значения служат
    /// запасными подписями корзин.
    public func columnTitle(_ bucket: CaseParties.Bucket, plural: Bool) -> String {
        switch (self, bucket) {
        case (.civil, .plaintiff):          return plural ? "Истцы" : "Истец"
        case (.civil, .defendant):          return plural ? "Ответчики" : "Ответчик"
        case (.civil, .third):              return plural ? "Третьи лица" : "Третье лицо"
        case (.administrative, .plaintiff): return plural ? "Административные истцы" : "Административный истец"
        case (.administrative, .defendant): return plural ? "Административные ответчики" : "Административный ответчик"
        case (.administrative, .third):     return plural ? "Заинтересованные лица" : "Заинтересованное лицо"
        case (.special, .plaintiff):        return plural ? "Заявители" : "Заявитель"
        case (.special, .defendant):        return plural ? "Заинтересованные лица" : "Заинтересованное лицо"
        case (.special, .third):            return plural ? "Заинтересованные лица" : "Заинтересованное лицо"
        case (_, .plaintiff):               return plural ? "Сторона защиты" : "Сторона защиты"
        case (_, .defendant):               return plural ? "Сторона обвинения" : "Сторона обвинения"
        case (_, .third):                   return plural ? "Иные участники" : "Иной участник"
        }
    }

    /// Счётчик третьих лиц в строке выдачи: «+ N третьих лиц» /
    /// «+ N заинтересованных лиц» — с верным русским склонением.
    public func thirdCounter(_ n: Int) -> String {
        switch self {
        case .administrative, .special:
            return "+ \(n) " + plural(n, one: "заинтересованное лицо",
                                      few: "заинтересованных лица", many: "заинтересованных лиц")
        case .civil, .koap, .upk:
            return "+ \(n) " + plural(n, one: "третье лицо",
                                      few: "третьих лица", many: "третьих лиц")
        }
    }

    private func plural(_ n: Int, one: String, few: String, many: String) -> String {
        let d10 = n % 10, d100 = n % 100
        if d10 == 1 && d100 != 11 { return one }
        if (2...4).contains(d10) && !(12...14).contains(d100) { return few }
        return many
    }

    /// Вид процесса по номеру дела: КАС кодируется буквой «а» («2а-…»/«33а-…»),
    /// уголовные — серии «1-…»/«22-…»/«10-…»/«44у-…», КоАП — «5-…»/«12-…»/«4а-…»
    /// (для КоАП «4а» — кассация). Иначе — ГПК; особое производство по номеру не
    /// отличить (та же серия «2-…»), оно распознаётся по ролям.
    public static func detect(caseNumber: String, roles: [String] = []) -> ProcessKind {
        let n = caseNumber.lowercased()
        for r in roles {
            let s = r.lowercased()
            if s.contains("подсудим") || s.contains("обвиняем") { return .upk }
            if s.contains("в отношении которого") || s.contains("привлека") { return .koap }
            if s.contains("административн") || s.contains("заинтересован") { return .administrative }
        }
        // Уголовные серии.
        for prefix in ["1-", "22-", "10-", "44у-", "44у", "22к-"] {
            if n.hasPrefix(prefix) { return .upk }
        }
        // КоАП.
        for prefix in ["5-", "12-", "4а-", "4a-", "7у-"] {
            if n.hasPrefix(prefix) { return .koap }
        }
        // КАС (кириллическая и латинская «а»).
        for prefix in ["2а-", "2a-", "3а-", "3a-", "33а-", "33a-", "9а-", "9a-"] {
            if n.hasPrefix(prefix) { return .administrative }
        }
        return .civil
    }
}
