//  MonitoringModels.swift
//  Sudrf
//
//  Независимые типы представления и данные разделов мониторинга.

import Foundation
import SwiftUI
import SudrfKit

// MARK: - Палитра разделов

enum Palette {
    static let blue      = Color.accentColor
    static let confirmed = Color(red: 0.788, green: 0.184, blue: 0.149)   // #c92f26 — срок подтверждён
    static let proposed  = Color(red: 0.627, green: 0.388, blue: 0.0)     // #a06400 — срок расчётный
    static let green     = Color(red: 0.114, green: 0.478, blue: 0.239)   // #1d7a3d — завершено / в силе

    // RawRepresentable — чтобы цвет чипа сериализовался в снимок дела.
    enum Chip: String { case blue, gray, green, proposed, confirmed }

    static func chipFg(_ c: Chip) -> Color {
        switch c {
        case .blue:      return .accentColor
        case .gray:      return .secondary
        case .green:     return green
        case .proposed:  return proposed
        case .confirmed: return confirmed
        }
    }
    static func chipBg(_ c: Chip) -> Color {
        switch c {
        case .blue:      return Color.accentColor.opacity(0.13)
        case .gray:      return Color.primary.opacity(0.06)
        case .green:     return green.opacity(0.16)
        case .proposed:  return Color.orange.opacity(0.16)
        case .confirmed: return confirmed.opacity(0.13)
        }
    }
}

// MARK: - Модели раздела мониторинга

enum AppSection: String, CaseIterable, Hashable { case overview, cases, search, calendar
    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .cases:    return "Мои дела"
        case .search:   return "Поиск"
        case .calendar: return "Календарь"
        }
    }
}

enum MyCasesMode: String, CaseIterable { case list, stages, prods, clients
    var title: String {
        switch self {
        case .list:    return "Списком"
        case .stages:  return "По стадиям"
        case .prods:   return "По производствам"
        case .clients: return "По подборкам"
        }
    }
}

// MARK: - Вид производства

/// Вид производства дела. Если известно звено суда — определяется ТОЧНО по
/// картотеке (`CartotekaRegistry.matches`): один и тот же префикс на разных
/// звеньях значит разное («2-…»: район — гражданское, суд субъекта — уголовное).
/// Без звена — эвристика по номеру через канонический `ProcessKind.detect`.
enum ProductionType: String, CaseIterable {
    case civil, kas, crim, koap

    /// Категория по ключу картотеки (`Cartoteka.id`): `u*` — уголовное,
    /// `p*` — КАС, `adm*` — КоАП, `g*`/`m`/прочее — гражданское/материалы.
    init(cartotekaId id: String) {
        if id.hasPrefix("adm")     { self = .koap }
        else if id.hasPrefix("u")  { self = .crim }
        else if id.hasPrefix("p")  { self = .kas }
        else                       { self = .civil }
    }

    /// Вид производства по номеру и (если известно) звену суда. При заданном
    /// `level` номер разбирается по картотекам этого звена — тогда «12-…» →
    /// КоАП, а «2-…» суда субъекта → уголовное. Иначе — фолбэк по номеру.
    static func of(_ caseNumber: String, level: CourtLevel? = nil) -> ProductionType {
        if let level,
           let cart = CartotekaRegistry.matches(caseNumber: caseNumber, level: level).first {
            return ProductionType(cartotekaId: cart.id)
        }
        switch ProcessKind.detect(caseNumber: caseNumber) {
        case .upk:             return .crim
        case .koap:            return .koap
        case .administrative:  return .kas
        case .civil, .special: return .civil
        }
    }

    /// Безопасная классификация для «Моих дел». Картотека является главным
    /// источником, кроме общей картотеки материалов `m`: внутри неё отрасль
    /// определяется индексом, а неопределённые `М`, `15` и неизвестные номера
    /// намеренно остаются без производственной группы.
    static func classified(caseNumber: String, level: CourtLevel,
                           branch: CourtBranch, cartotekaID: String?) -> ProductionType? {
        let info = CaseIndexClassifier.classify(
            caseNumber: caseNumber, courtLevel: level, branch: branch)
        if info?.processKind == nil,
           info?.cardRole == .preliminaryIntakeMaterial
            || info?.cardRole == .otherMaterial {
            return nil
        }
        if cartotekaID == "m" {
            return info?.processKind.flatMap(ProductionType.init(processKind:))
        }
        if let cartotekaID, !cartotekaID.isEmpty {
            return ProductionType(cartotekaId: cartotekaID)
        }
        return info?.processKind.flatMap(ProductionType.init(processKind:))
    }

    private init?(processKind: ProcessKind) {
        switch processKind {
        case .upk: self = .crim
        case .koap: self = .koap
        case .administrative: self = .kas
        case .civil, .special: self = .civil
        }
    }

    /// Название группы/фильтра (сайдбар, группировка «По производствам»).
    var side: String {
        switch self {
        case .civil: return "Гражданские"
        case .kas:   return "Административные (КАС)"
        case .crim:  return "Уголовные"
        case .koap:  return "Адм. правонарушения"
        }
    }
    /// Подпись под номером дела в строке таблицы.
    var row: String {
        switch self {
        case .civil: return "гражданское"
        case .kas:   return "административное (КАС)"
        case .crim:  return "уголовное"
        case .koap:  return "адм. правонарушение"
        }
    }
    /// Буква-бейдж в сайдбаре.
    var abbr: String {
        switch self {
        case .civil: return "Г"; case .kas: return "А"
        case .crim:  return "У"; case .koap: return "АП"
        }
    }
    /// Палитра «шкала тяжести»: один тёплый градиент от нейтрального к
    /// тёмно-красному — цвет кодирует серьёзность производства, а не «тип».
    var color: Color {
        switch self {
        case .civil: return Color(red: 0.38, green: 0.47, blue: 0.56)  // #607890 — нейтральный
        case .kas:   return Color(red: 0.64, green: 0.47, blue: 0.16)  // #a3782a — охра
        case .crim:  return Color(red: 0.62, green: 0.17, blue: 0.17)  // #9e2b2b — тёмно-красный
        case .koap:  return Color(red: 0.75, green: 0.36, blue: 0.16)  // #c05c2a — оранжевый
        }
    }
}

// MARK: - Сортировка таблицы «Списком»

enum CaseSort: CaseIterable {
    case activity, nextEvent, number
    var label: String {
        switch self {
        case .activity:  return "по активности"
        case .nextEvent: return "по ближайшему событию"
        case .number:    return "по номеру дела"
        }
    }
    var hint: String {
        switch self {
        case .activity:  return "свежие изменения в деле — сверху"
        case .nextEvent: return "ближайшее заседание или срок — сверху"
        case .number:    return "по возрастанию номера"
        }
    }
}

enum CalMode: CaseIterable { case month, week, agenda
    var title: String {
        switch self {
        case .month:  return "Месяц"
        case .week:   return "Неделя"
        case .agenda: return "Повестка"
        }
    }
}

enum OverviewRoute { case dashboard, fullFeed }

enum FeedEntryKind: String, CaseIterable, Hashable {
    case hearing, act, movement

    var title: String {
        switch self {
        case .hearing:  return "Заседания"
        case .act:      return "Судебные акты"
        case .movement: return "Движение дела"
        }
    }

    var tag: String {
        switch self {
        case .hearing:  return "заседание"
        case .act:      return "акт"
        case .movement: return "движение"
        }
    }
}

enum FeedTypeFilter: CaseIterable, Hashable {
    case all, hearing, act, movement

    var title: String {
        switch self {
        case .all:      return "Все"
        case .hearing:  return FeedEntryKind.hearing.title
        case .act:      return FeedEntryKind.act.title
        case .movement: return FeedEntryKind.movement.title
        }
    }

    var kind: FeedEntryKind? {
        switch self {
        case .all:      return nil
        case .hearing:  return .hearing
        case .act:      return .act
        case .movement: return .movement
        }
    }
}

enum CaseStageKind: String { case first, appeal, cassation, done
    var label: String {
        switch self {
        case .first:     return "Первая инстанция"
        case .appeal:    return "Апелляция"
        case .cassation: return "Кассация"
        case .done:      return "Завершённые"
        }
    }
    var dot: Color {
        switch self {
        case .first:     return Color(red: 0.04, green: 0.48, blue: 1.0)
        case .appeal:    return Color(red: 0.37, green: 0.36, blue: 0.90)
        case .cassation: return Color(red: 0.69, green: 0.32, blue: 0.87)
        case .done:      return Color.primary.opacity(0.25)
        }
    }
}

enum DeadlineStatus: String { case proposed, confirmed }

struct TrackedDeadline: Identifiable {
    let id: String            // «<ключ записи>#<kind>»
    var recordKey: String
    var what: String
    var caseNumber: String
    var basis: String
    var calLabel: String
    var date: Date
    var status: DeadlineStatus
}

struct TrackedHearing: Identifiable {
    var id: String { "\(recordKey)#hearing#\(Int(date.timeIntervalSinceReferenceDate))#\(time)#\(court)#\(identitySuffix)" }
    var recordKey: String
    var date: Date
    var time: String
    var caseNumber: String
    var parties: String
    var court: String
    var room: String
    var dateLabel: String
    var judge: String = ""
    /// При времени «—» несколько событий одного дня иначе имеют одинаковый id.
    /// Источник сохраняется только в UI-идентификаторе, формат снимка не меняется.
    var identitySuffix: String = ""
}

struct FeedEntry: Identifiable {
    var id: String
    var dayHead: String?
    var date: Date
    var time: String
    var recordKey: String
    var caseNumber: String
    var client: String
    var kind: FeedEntryKind
    var text: String
    var actID: String?
    var isUnread: Bool

    var hasAct: Bool { actID != nil }
}

struct OverviewHearingBuckets {
    var next7Days: [TrackedHearing]
    var later: [TrackedHearing]
    var firstLaterDays: Int?
}

struct StepState { let label: String; let kind: Kind; enum Kind { case done, active, todo } }

struct TrackedCase: Identifiable {
    var id: String { recordKey }
    var recordKey: String
    var caseNumber: String
    /// Очищенный номер текущей апелляции/кассации/надзора для UI. Сырой
    /// `caseNumber` остаётся источником навигации и поиска.
    var currentReviewNumber: String? = nil
    /// Подборки, в которых состоит дело (доверитель, тема — что угодно).
    var collections: [String]
    var stage: CaseStageKind
    var stageTag: String
    var subject: String
    var court: String
    /// Вычисляется из активного круга, не хранится в SwiftData.
    var courtTier: CourtTier?
    /// Вид производства, вычисленный при сборке строки с учётом звена суда
    /// (см. `productionType(for:)`). Читатели фильтров/счётчиков берут готовое.
    var production: ProductionType?
    var partiesShort: String
    /// Статьи подсудимого/привлекаемого — для строки «Списком» (ФИО ⟨щит⟩ статьи).
    var leadCharges: String?
    /// Вторая строка ячейки «Списком» (второй подсудимый / «и N других»).
    var secondPartyLine: PartiesSecondLine?
    var statusText: String
    var statusChip: Palette.Chip
    var last: String
    var next: String
    var nextChip: Palette.Chip
    var isNew: Bool
    var steps: [StepState]
    var newDot: Bool
    /// Дата последнего состоявшегося события (для сортировки «по активности»).
    var lastEventDate: Date?
    /// Дата ближайшего будущего заседания/срока (для «по ближайшему событию»).
    var nextEventDate: Date?
}
