import Foundation

/// Звено судебной системы — определяет, какой набор картотек применять.
public enum CourtLevel: String, Sendable, CaseIterable, Codable {
    case district   // районный / городской суд
    case subject    // суд субъекта РФ (областной / верховный респ. / краевой)
    case appeal     // апелляционный суд ОСЮ (АСОЮ)
    case cassation  // кассационный суд ОСЮ (КСОЮ)
}

/// Ветвь системы судов общей юрисдикции.
public enum CourtBranch: String, Sendable, CaseIterable, Codable, Hashable {
    case general    // территориальные («общие») суды
    case military   // военные суды
    public var title: String { self == .general ? "Общие" : "Военные" }
}

/// Звено в пользовательском выборе: пять ступеней каждой ветви, сверху вниз.
/// Военные суды работают на той же платформе sud_delo и используют ту же
/// номенклатуру дел, поэтому наборы картотек берутся по соответствующему
/// `CourtLevel`: гарнизонные ≈ районные, окружные (флотские) ≈ суды субъектов,
/// Апелляционный военный суд ≈ АСОЮ, Кассационный военный суд ≈ КСОЮ.
public enum CourtTier: String, Sendable, CaseIterable, Codable, Hashable, Identifiable {
    case supreme     // Верховный Суд РФ — задел: отдельный портал (vsrf.ru), парсинг не подключён
    case cassation   // КСОЮ / Кассационный военный суд
    case appeal      // АСОЮ / Апелляционный военный суд
    case subject     // областные и приравненные / окружные (флотские) военные
    case district    // районные и городские / гарнизонные военные

    public var id: String { rawValue }

    /// Звено платформы sud_delo (ключ к наборам картотек); ВС РФ — вне платформы.
    public var level: CourtLevel? {
        switch self {
        case .supreme:   return nil
        case .cassation: return .cassation
        case .appeal:    return .appeal
        case .subject:   return .subject
        case .district:  return .district
        }
    }

    /// Название ступени для выбранной ветви.
    public func title(branch: CourtBranch) -> String {
        switch (self, branch) {
        case (.supreme, _):           return "Верховный Суд РФ"
        case (.cassation, .general):  return "Кассационные суды ОЮ"
        case (.appeal, .general):     return "Апелляционные суды ОЮ"
        case (.subject, .general):    return "Областные и приравненные"
        case (.district, .general):   return "Районные и городские"
        case (.cassation, .military): return "Кассационный военный суд"
        case (.appeal, .military):    return "Апелляционный военный суд"
        case (.subject, .military):   return "Окружные (флотские)"
        case (.district, .military):  return "Гарнизонные"
        }
    }
}

/// Конкретный суд: домен на sudrf.ru + звено.
public struct Court: Sendable {
    public var domain: String      // напр. "syktsud--komi.sudrf.ru"
    public var title: String
    public var level: CourtLevel

    public init(domain: String, title: String, level: CourtLevel) {
        self.domain = domain
        self.title = title
        self.level = level
    }
}

public extension Court {
    /// Рабочий пример из навыка (капчи нет — прямой GET работает).
    static let syktyvkarskiy = Court(
        domain: "syktsud--komi.sudrf.ru",
        title: "Сыктывкарский городской суд",
        level: .district
    )
}
