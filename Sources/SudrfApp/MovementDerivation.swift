//  MovementDerivation.swift — Sudrf · v15
//  Движок ПРОИЗВОДНЫХ данных: из живого движения дела (`CaseMovement`) +
//  контекста собирает компактный `CaseSnapshot` (Codable) — то, что показывают
//  разделы мониторинга и хранит SwiftData. Из снимка затем выводятся заседания
//  (сессии в будущем со временем), сроки (вступление в силу / решение → расчёт)
//  и лента (последние события). Полный `CaseMovement` кэшируется отдельно
//  (TrackedCaseRecord.movementData, см. RefreshCenter); снимок остаётся
//  источником списков и календаря без обращения к сети.

import Foundation
import SudrfKit

// MARK: - Персистентные значимые структуры (внутри снимка)

struct StoredSession: Codable, Equatable {
    var dateRaw: String        // «дд.мм.гггг»
    var time: String?
    var room: String?
    var event: String
    var result: String?
    var court: String
    var levelRaw: String       // CaseInstance.Level.rawValue
    var level: CaseInstance.Level { CaseInstance.Level(rawValue: levelRaw) ?? .first }
    var date: Date? { DateUtil.parse(dateRaw) }
}

struct StoredDeadline: Codable, Equatable {
    var kind: String           // «appeal» | «cassation»
    var what: String           // «Апелляционная жалоба»
    var basis: String          // основание расчёта
    var calLabel: String       // короткий ярлык для клетки календаря
    var dateRef: Double        // timeIntervalSinceReferenceDate (полночь дня)
    var statusRaw: String      // «proposed» | «confirmed»
    var date: Date { Date(timeIntervalSinceReferenceDate: dateRef) }
}

struct CaseSnapshot: Codable, Equatable {
    var uid: String
    var inForce: Bool
    var category: String?
    var partiesShort: String
    var stageRaw: String        // CaseStageKind.rawValue
    var stageTag: String
    var statusText: String
    var statusChipRaw: String   // Palette.Chip.rawValue
    var lastEvent: String
    var nextEvent: String
    var nextChipRaw: String
    var steps: [String]         // 3 элемента: «done» | «active» | «todo»
    var sessions: [StoredSession]
    var deadlines: [StoredDeadline]
}

// MARK: - Движок

enum MovementDerivation {

    /// Главная функция: движение + контекст → снимок. `today` — для расчёта
    /// «дальше», заседаний и сроков (по умолчанию системная дата).
    static func snapshot(from mv: CaseMovement, context: MovementContext,
                         today: Date = DateUtil.today) -> CaseSnapshot {

        let prefix = String(context.cartotekaId.prefix(while: { $0.isLetter })).lowercased()

        // Сессии всех инстанций.
        var sessions: [StoredSession] = []
        for inst in mv.instances {
            for s in inst.sessions {
                sessions.append(StoredSession(
                    dateRaw: s.date, time: s.time, room: s.room,
                    event: s.event, result: s.result,
                    court: inst.court, levelRaw: inst.level.rawValue))
            }
        }
        sessions.sort { (DateUtil.parse($0.dateRaw) ?? .distantPast)
                      < (DateUtil.parse($1.dateRaw) ?? .distantPast) }

        // Какие звенья присутствуют.
        let hasFirst     = mv.instances.contains { $0.level == .first }
        let hasAppeal    = mv.instances.contains { $0.level == .appeal }
        let hasCassation = mv.instances.contains { $0.level == .cassation || $0.level == .vsCassation }
        let present = [hasFirst, hasAppeal, hasCassation]
        let highestIdx = present.lastIndex(of: true) ?? 0

        // Стадия / ярлык.
        let stage: CaseStageKind = mv.inForce ? .done
            : (hasCassation ? .cassation : hasAppeal ? .appeal : .first)
        let stageTag = self.stageTag(stage: stage, prefix: prefix)

        // Стороны (короткая строка).
        let partiesShort = self.partiesShort(mv.parties)

        // Заседания (будущие, со временем) и сроки.
        let deadlines = self.deadlines(from: mv, sessions: sessions, prefix: prefix,
                                       hasAppeal: hasAppeal, hasCassation: hasCassation,
                                       today: today)
        let nextHearing = futureHearings(sessions, today: today).first

        // «Дальше» + цвет.
        var nextEvent = "—"
        var nextChip: Palette.Chip = .gray
        if let h = nextHearing, let d = DateUtil.parse(h.dateRaw) {
            nextEvent = "заседание \(DateUtil.shortDM(d))" + (h.time.map { ", \($0)" } ?? "")
            nextChip = .blue
        } else if let dl = deadlines.sorted(by: { $0.dateRef < $1.dateRef }).first {
            nextEvent = "срок \(dl.kind == "cassation" ? "кассации" : "апелляции"): \(DateUtil.shortDM(dl.date))"
            nextChip = dl.statusRaw == "confirmed" ? .confirmed : .proposed
        } else if mv.inForce {
            nextEvent = "завершено"; nextChip = .gray
        }

        // Статус.
        var statusText: String
        var statusChip: Palette.Chip
        if mv.inForce {
            statusText = "Вступило в силу"; statusChip = .green
        } else if nextHearing != nil {
            statusText = "Назначено заседание"; statusChip = .blue
        } else if let r = mv.instances.last?.result, !r.isEmpty {
            statusText = r; statusChip = .gray
        } else if let last = sessions.last {
            statusText = last.event; statusChip = .blue
        } else {
            statusText = "В производстве"; statusChip = .blue
        }

        // «Последнее событие».
        let lastEvent: String
        if let last = sessions.last, let d = DateUtil.parse(last.dateRaw) {
            lastEvent = "\(DateUtil.shortDM(d)) · \(trim(last.result ?? last.event))"
        } else {
            lastEvent = "нет данных о движении"
        }

        // Шаги (точки стадий).
        var steps: [String] = []
        for i in 0..<3 {
            if mv.inForce {
                steps.append(present[i] ? "done" : "todo")
            } else if present[i] {
                steps.append(i == highestIdx ? "active" : "done")
            } else {
                steps.append("todo")
            }
        }

        return CaseSnapshot(
            uid: mv.uid, inForce: mv.inForce, category: mv.category,
            partiesShort: partiesShort, stageRaw: stage.rawValue, stageTag: stageTag,
            statusText: statusText, statusChipRaw: statusChip.rawValue,
            lastEvent: lastEvent, nextEvent: nextEvent, nextChipRaw: nextChip.rawValue,
            steps: steps, sessions: sessions, deadlines: deadlines)
    }

    /// Переносит в свежий снимок пользовательские правки сроков: подтверждённый
    /// срок (statusRaw == «confirmed») не сбрасывается пересчётом — дата и статус
    /// берутся из прежнего снимка. Срок, исчезнувший из свежего расчёта (жалоба
    /// подана — считать нечего), не восстанавливается.
    static func preservingConfirmedDeadlines(_ snap: CaseSnapshot,
                                             old: CaseSnapshot?) -> CaseSnapshot {
        guard let old else { return snap }
        var out = snap
        for (i, dl) in out.deadlines.enumerated() {
            if let prev = old.deadlines.first(where: { $0.kind == dl.kind }),
               prev.statusRaw == DeadlineStatus.confirmed.rawValue {
                out.deadlines[i].dateRef = prev.dateRef
                out.deadlines[i].statusRaw = prev.statusRaw
            }
        }
        return out
    }

    // MARK: Заседания

    /// Сессии-заседания в будущем (включая сегодня), отсортированные по дате/времени.
    /// Заседанием считаем событие со словами «заседани»/«рассмотрени»/«слушани»,
    /// либо событие, у которого указано время (на портале время проставляют именно
    /// у заседаний).
    static func futureHearings(_ sessions: [StoredSession], today: Date) -> [StoredSession] {
        sessions.filter { s in
            guard let d = DateUtil.parse(s.dateRaw), DateUtil.daysBetween(today, d) >= 0 else { return false }
            let e = s.event.lowercased()
            return (s.time != nil && !(s.time ?? "").isEmpty)
                || e.contains("заседани") || e.contains("рассмотрени") || e.contains("слушани")
        }
        .sorted {
            let d0 = DateUtil.parse($0.dateRaw) ?? .distantFuture
            let d1 = DateUtil.parse($1.dateRaw) ?? .distantFuture
            if d0 != d1 { return d0 < d1 }
            return ($0.time ?? "") < ($1.time ?? "")
        }
    }

    // MARK: Сроки (ОРИЕНТИРОВОЧНЫЙ расчёт — требует подтверждения пользователем)

    /// ВНИМАНИЕ: таблица сроков — ориентир по ГПК/КАС/КоАП/УПК, не истина в
    /// последней инстанции (исчисление со дня изготовления мотивированного акта,
    /// переносы с выходных, восстановление и т. п. здесь не учитываются). Все
    /// расчётные сроки помечаются «proposed» и требуют подтверждения. Для КоАП и
    /// УПК единый срок кассации отсутствует — кассацию не считаем.
    private static func deadlines(from mv: CaseMovement, sessions: [StoredSession],
                                  prefix: String, hasAppeal: Bool, hasCassation: Bool,
                                  today: Date) -> [StoredDeadline] {
        var out: [StoredDeadline] = []

        // Срок апелляции: есть решение 1-й инстанции, дело не обжаловано в
        // апелляцию и не вступило в силу.
        if !mv.inForce, !hasAppeal {
            if let firstDecision = firstInstanceDecisionDate(mv),
               let days = appealDays(prefix: prefix) {
                let due = DateUtil.addDays(firstDecision, days)
                out.append(StoredDeadline(
                    kind: "appeal", what: "Апелляционная жалоба",
                    basis: "\(daysPhrase(days)) со дня решения (\(DateUtil.shortDM(firstDecision))) — расчётный, проверьте",
                    calLabel: "апел. жалоба \(shortNum(mv.caseNumber))",
                    dateRef: due.timeIntervalSinceReferenceDate, statusRaw: "proposed"))
            }
        }

        // Срок кассации: акт вступил в силу, в кассацию ещё не подавали.
        if mv.inForce, !hasCassation, let days = cassationDays(prefix: prefix) {
            let base = inForceDate(sessions) ?? lastAppealDate(mv) ?? today
            let due = DateUtil.addDays(base, days)
            out.append(StoredDeadline(
                kind: "cassation", what: "Кассационная жалоба",
                basis: "\(daysPhrase(days)) со вступления в силу (\(DateUtil.shortDM(base))) — расчётный, проверьте",
                calLabel: "касс. жалоба \(shortNum(mv.caseNumber))",
                dateRef: due.timeIntervalSinceReferenceDate, statusRaw: "proposed"))
        }
        return out
    }

    /// Срок апелляционного обжалования (календарные дни, ориентир).
    private static func appealDays(prefix: String) -> Int? {
        switch prefix {
        case "g", "p": return 30   // ГПК / КАС — месяц
        case "adm":    return 10   // КоАП — 10 суток (ст. 30.3)
        case "u":      return 15   // УПК — 15 суток (ст. 389.4)
        default:       return nil  // материалы и прочее — не считаем
        }
    }
    /// Срок кассационного обжалования (ориентир). КоАП/УПК — без единого срока.
    private static func cassationDays(prefix: String) -> Int? {
        switch prefix {
        case "g": return 90    // ГПК — 3 месяца
        case "p": return 180   // КАС — 6 месяцев
        default:  return nil
        }
    }

    private static func firstInstanceDecisionDate(_ mv: CaseMovement) -> Date? {
        guard let first = mv.instances.first(where: { $0.level == .first }) else { return nil }
        // Дата итогового акта 1-й инстанции: последняя сессия с результатом,
        // иначе последняя сессия.
        let dated = first.sessions.compactMap { s -> Date? in DateUtil.parse(s.date) }
        if let withResult = first.sessions.last(where: { ($0.result ?? "").isEmpty == false }),
           let d = DateUtil.parse(withResult.date) { return d }
        return dated.max()
    }
    private static func inForceDate(_ sessions: [StoredSession]) -> Date? {
        sessions.first { $0.event.lowercased().contains("силу") }.flatMap { DateUtil.parse($0.dateRaw) }
    }
    private static func lastAppealDate(_ mv: CaseMovement) -> Date? {
        mv.instances.filter { $0.level == .appeal }
            .compactMap { inst in inst.sessions.compactMap { DateUtil.parse($0.date) }.max() }
            .max()
    }

    // MARK: Ярлыки

    private static func stageTag(stage: CaseStageKind, prefix: String) -> String {
        switch stage {
        case .first:
            switch prefix {
            case "adm": return "КоАП"
            case "u":   return "УПК"
            case "p":   return "КАС"
            default:    return "1-я инст."
            }
        case .appeal:    return "апелляция"
        case .cassation: return "кассация"
        case .done:      return "завершено"
        }
    }

    /// Короткая строка сторон для карточек/таблицы.
    static func partiesShort(_ p: CaseParties) -> String {
        switch p.kind {
        case .koap, .upk, .special:
            if let col = p.displayColumns.first, let m = col.members.first {
                return m.name + (m.sub.map { " · \($0)" } ?? " · \(col.title)")
            }
        case .civil, .administrative:
            break
        }
        let left = p.plaintiffs.first
        let right = p.defendants.first
        switch (left, right) {
        case let (l?, r?): return "\(l) → \(r)"
        case let (l?, nil): return l
        case let (nil, r?): return r
        default:
            if let col = p.displayColumns.first, let m = col.members.first { return m.name }
            return "стороны не опубликованы"
        }
    }

    private static func daysPhrase(_ n: Int) -> String {
        switch n {
        case 30:  return "1 месяц"
        case 90:  return "3 месяца"
        case 180: return "6 месяцев"
        default:  return "\(n) " + DateUtil.plural(n, "сутки", "суток", "суток")
        }
    }
    private static func shortNum(_ caseNumber: String) -> String {
        caseNumber.split(separator: " ").first.map(String.init) ?? caseNumber
    }
    private static func trim(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 60 ? String(t.prefix(58)) + "…" : t
    }
}
