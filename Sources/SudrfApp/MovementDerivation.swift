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
    var judge: String? = nil
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

/// Вторая строка ячейки «Списком» для УПК/КоАП: либо второй подсудимый
/// (когда их ровно двое), либо счётчик «и N других» (когда трое и больше).
struct PartiesSecondLine: Codable, Equatable {
    var name: String?      // ФИО второго подсудимого
    var articles: String?  // его статьи (для щита)
    var more: String?      // «и N других»
}

struct CaseSnapshot: Codable, Equatable {
    var uid: String
    var inForce: Bool
    var category: String?
    var partiesShort: String
    var leadCharges: String?    // статьи подсудимого/привлекаемого (для «Списком»)
    var secondPartyLine: PartiesSecondLine?   // вторая строка ячейки «Списком» (УПК/КоАП)
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
    /// Метаданные опубликованных актов для детектора фоновых обновлений.
    /// Optional сохраняет декодирование снимков, созданных до появления поля.
    var actsFingerprint: [String]?

    /// Сравнение для фонового бейджа: stage/status/steps/next пересчитываются
    /// из того же движения и текущей даты, поэтому одно лишь исправление этих
    /// производных полей не является новым событием дела.
    func hasSameRefreshSource(as other: CaseSnapshot) -> Bool {
        uid == other.uid
            && inForce == other.inForce
            && category == other.category
            && partiesShort == other.partiesShort
            && leadCharges == other.leadCharges
            && secondPartyLine == other.secondPartyLine
            && lastEvent == other.lastEvent
            && sessions == other.sessions
            && deadlines == other.deadlines
            && actsFingerprint == other.actsFingerprint
    }
}

/// Динамическая часть снимка. Пересчитывается и при сетевом обновлении, и при
/// обычном `AppRouter.reload`, чтобы наступление подтверждённого срока меняло
/// стадию без записи нового формата в SwiftData.
struct CaseLifecyclePresentation {
    var stage: CaseStageKind
    var stageTag: String
    var statusText: String
    var statusChip: Palette.Chip
    var nextEvent: String
    var nextChip: Palette.Chip
    var nextEventDate: Date?
    var steps: [String]
}

// MARK: - Движок

enum MovementDerivation {

    private struct LegalForceState {
        var effective: Bool?
        var date: Date?
    }

    /// Главная функция: движение + контекст → снимок. `today` — для расчёта
    /// «дальше», заседаний и сроков (по умолчанию системная дата).
    static func snapshot(from mv: CaseMovement, context: MovementContext,
                         today: Date = DateUtil.today) -> CaseSnapshot {

        let prefix = String(context.cartotekaId.prefix(while: { $0.isLetter })).lowercased()

        // Сессии всех инстанций.
        var sessions: [StoredSession] = []
        for inst in mv.instances {
            for s in inst.sessions {
                // CaseSession does not carry a per-session judge; use the instance judge as the closest source.
                sessions.append(StoredSession(
                    dateRaw: s.date, time: s.time, room: s.room,
                    event: s.event, result: s.result,
                    court: inst.court, judge: inst.judge, levelRaw: inst.level.rawValue))
            }
        }
        sessions.sort { (DateUtil.parse($0.dateRaw) ?? .distantPast)
                      < (DateUtil.parse($1.dateRaw) ?? .distantPast) }

        // Для стадии и сроков учитываются только реальные производства. Stub
        // нужен карточке для CAPTCHA/retry, но не доказывает наличие жалобы.
        let realInstances = CaseLifecycleResolver.realInstances(in: mv)
        let lifecycleSessions = sessions.filter { $0.level != .material }
        let hasAppeal = realInstances.contains { $0.level == .appeal }
        let hasCassation = realInstances.contains {
            $0.level == .cassation || $0.level == .vsCassation || $0.level == .supervisory
        }

        // Стороны (короткая строка + статьи ведущего лица + вторая строка «Списком»).
        let partiesShort = self.partiesShort(mv.parties)
        let leadCharges = mv.parties.leadCharges
        let secondPartyLine = self.partiesSecondLine(mv.parties)

        // Заседания (будущие, со временем) и сроки.
        let deadlines = self.deadlines(from: mv, sessions: lifecycleSessions, prefix: prefix,
                                       hasAppeal: hasAppeal, hasCassation: hasCassation,
                                       today: today)
        let presentation = lifecyclePresentation(from: mv, sessions: sessions,
                                                 deadlines: deadlines, context: context,
                                                 today: today)
        // Порядок `acts` не должен сам по себе создавать ложное уведомление.
        // Тело акта намеренно не включаем: для факта новой публикации достаточно
        // стабильных публичных метаданных, а снимок остаётся компактным.
        let actsFingerprint = mv.acts.map {
            "\($0.id)|\($0.date)|\($0.title)|\($0.courtShort)|\($0.instanceLevel.rawValue)"
        }.sorted()

        // «Последнее событие».
        let lastEvent: String
        if let last = sessions.last, let d = DateUtil.parse(last.dateRaw) {
            lastEvent = "\(DateUtil.shortDM(d)) · \(trim(last.result ?? last.event))"
        } else {
            lastEvent = "нет данных о движении"
        }

        return CaseSnapshot(
            uid: mv.uid, inForce: mv.inForce, category: mv.category,
            partiesShort: partiesShort, leadCharges: leadCharges,
            secondPartyLine: secondPartyLine,
            stageRaw: presentation.stage.rawValue, stageTag: presentation.stageTag,
            statusText: presentation.statusText,
            statusChipRaw: presentation.statusChip.rawValue,
            lastEvent: lastEvent, nextEvent: presentation.nextEvent,
            nextChipRaw: presentation.nextChip.rawValue,
            steps: presentation.steps, sessions: sessions, deadlines: deadlines,
            actsFingerprint: actsFingerprint.isEmpty ? nil : actsFingerprint)
    }

    /// Пересчёт представляемой стадии по сохранённому движению и снимку. Поля
    /// `CaseSnapshot` остаются обратно совместимыми и служат fallback, если
    /// полного движения у старой записи нет.
    static func lifecyclePresentation(from mv: CaseMovement, snapshot: CaseSnapshot,
                                      context: MovementContext?,
                                      today: Date = DateUtil.today) -> CaseLifecyclePresentation {
        lifecyclePresentation(from: mv, sessions: snapshot.sessions,
                              deadlines: snapshot.deadlines, context: context, today: today)
    }

    private static func lifecyclePresentation(from mv: CaseMovement,
                                              sessions: [StoredSession],
                                              deadlines: [StoredDeadline],
                                              context: MovementContext?,
                                              today: Date) -> CaseLifecyclePresentation {
        let resolution = CaseLifecycleResolver.resolve(movement: mv, deadlines: deadlines,
                                                       today: today)
        let prefix = context.map {
            String($0.cartotekaId.prefix(while: { $0.isLetter })).lowercased()
        } ?? ""
        let nextHearing = futureHearings(
            sessions.filter { $0.level != .material }, today: today).first
        let nextDeadline = deadlines
            .filter { $0.date >= today }
            .sorted(by: { $0.dateRef < $1.dateRef })
            .first

        var nextEvent = "—"
        var nextChip: Palette.Chip = .gray
        var nextEventDate: Date?
        if let hearing = nextHearing, let date = hearing.date {
            nextEvent = "заседание \(DateUtil.shortDM(date))"
                + (hearing.time.map { ", \($0)" } ?? "")
            nextChip = .blue
            nextEventDate = date
        } else if let deadline = nextDeadline {
            nextEvent = "срок \(deadline.kind == "cassation" ? "кассации" : "апелляции"): "
                + DateUtil.shortDM(deadline.date)
            nextChip = deadline.statusRaw == DeadlineStatus.confirmed.rawValue
                ? .confirmed : .proposed
            nextEventDate = deadline.date
        } else if resolution.isCompleted {
            nextEvent = "завершено"
        }

        let statusText: String
        let statusChip: Palette.Chip
        switch resolution.completionReason {
        case .legalForce:
            statusText = "Вступило в силу"
            statusChip = .green
        case .terminalReview(let result):
            statusText = result
            statusChip = .green
        case .confirmedDeadline:
            statusText = "Срок обжалования истёк"
            statusChip = .green
        case nil where nextHearing != nil:
            statusText = "Назначено заседание"
            statusChip = .blue
        case nil:
            if let result = resolution.currentInstance?.result, !result.isEmpty {
                statusText = result
                statusChip = .gray
            } else if let last = sessions.last(where: { $0.level != .material }) {
                statusText = last.result ?? last.event
                statusChip = .blue
            } else {
                statusText = "В производстве"
                statusChip = .blue
            }
        }

        return CaseLifecyclePresentation(
            stage: resolution.stage,
            stageTag: stageTag(stage: resolution.stage, prefix: prefix),
            statusText: statusText,
            statusChip: statusChip,
            nextEvent: nextEvent,
            nextChip: nextChip,
            nextEventDate: nextEventDate,
            steps: resolution.steps)
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
        sessions.enumerated().filter { _, session in
            guard let date = DateUtil.parse(session.dateRaw),
                  DateUtil.daysBetween(today, date) >= 0 else { return false }
            return CaseLifecycleResolver.isHearing(
                event: session.event, result: session.result, time: session.time)
        }
        .sorted {
            let d0 = DateUtil.parse($0.element.dateRaw) ?? .distantFuture
            let d1 = DateUtil.parse($1.element.dateRaw) ?? .distantFuture
            if d0 != d1 { return d0 < d1 }
            let t0 = CaseLifecycleResolver.hearingTimeKey($0.element.time)
            let t1 = CaseLifecycleResolver.hearingTimeKey($1.element.time)
            return t0 == t1 ? $0.offset < $1.offset : t0 < t1
        }
        .map(\.element)
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
        let forceState = currentLegalForceState(in: sessions)
        let legallyEffective = forceState.effective ?? mv.inForce
        let currentlyReactivated = forceState.effective == false

        // Срок апелляции: есть решение 1-й инстанции, дело не обжаловано в
        // апелляцию и не вступило в силу.
        if !legallyEffective, !currentlyReactivated, !hasAppeal {
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
        if legallyEffective, !hasCassation, let days = cassationDays(prefix: prefix) {
            guard let base = forceState.date ?? lastAppealDate(mv) else { return out }
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
    private static func currentLegalForceState(in sessions: [StoredSession]) -> LegalForceState {
        let ordered = sessions.enumerated().sorted { left, right in
            let leftDate = left.element.date ?? .distantPast
            let rightDate = right.element.date ?? .distantPast
            return leftDate == rightDate ? left.offset < right.offset : leftDate < rightDate
        }
        var state = LegalForceState()
        for (_, session) in ordered {
            if CaseLifecycleResolver.hasLegalForceEvidence(
                event: session.event, result: session.result
            ) {
                state.effective = true
                state.date = session.date
            } else if CaseLifecycleResolver.isReactivation(
                event: session.event, result: session.result
            ) {
                state.effective = false
                state.date = nil
            }
        }
        return state
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
                // Со статьями (подсудимый/привлекаемый) — только ФИО: статьи
                // рисуются отдельно значком щита в строке «Списком» (leadCharges).
                if !(m.articles?.isEmpty ?? true) { return m.name }
                return m.name + (m.sub.map { " · \($0)" } ?? " · \(col.title)")
            }
        case .civil, .administrative:
            break
        }
        let left = p.plaintiffs.isEmpty ? nil : namesShort(p.plaintiffs)
        let right = p.defendants.isEmpty ? nil : namesShort(p.defendants)
        switch (left, right) {
        case let (l?, r?): return "\(l) ⚔ \(r)"
        case let (l?, nil): return l
        case let (nil, r?): return r
        default:
            if let col = p.displayColumns.first, let m = col.members.first { return m.name }
            return "стороны не опубликованы"
        }
    }

    /// Перечисление стороны для «Списком»: «X» / «X и Y» / «X и N других».
    private static func namesShort(_ names: [String]) -> String {
        switch names.count {
        case 0:  return ""
        case 1:  return names[0]
        case 2:  return "\(names[0]) и \(names[1])"
        default:
            let others = names.count - 1
            return "\(names[0]) и \(others) "
                + DateUtil.plural(others, "другой", "других", "других")
        }
    }

    /// Вторая строка ячейки «Списком» для УПК/КоАП (второй подсудимый или «и N
    /// других»); nil, когда подсудимый один или это не уголовное/административное.
    static func partiesSecondLine(_ p: CaseParties) -> PartiesSecondLine? {
        let charged = p.chargedMembers
        switch charged.count {
        case 0, 1: return nil
        case 2:    return PartiesSecondLine(name: charged[1].name,
                                            articles: charged[1].articles, more: nil)
        default:
            let others = charged.count - 1
            return PartiesSecondLine(name: nil, articles: nil,
                                     more: "и \(others) "
                                        + DateUtil.plural(others, "другой", "других", "других"))
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
