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
    /// Номер производства инстанции пересмотра, из которой пришло событие.
    /// Optional сохраняет декодирование старых snapshots.
    var caseNumber: String? = nil
    var level: CaseInstance.Level { CaseInstance.Level(rawValue: levelRaw) ?? .first }
    var date: Date? { DateUtil.parse(dateRaw) }

    /// Старый snapshot не хранил номер сессии. Его отсутствие совместимо с
    /// номером, выведенным при следующем refresh, и не должно создавать badge.
    func hasSameRefreshSource(as other: StoredSession) -> Bool {
        dateRaw == other.dateRaw
            && time == other.time
            && room == other.room
            && event == other.event
            && result == other.result
            && court == other.court
            && judge == other.judge
            && levelRaw == other.levelRaw
            && (caseNumber == other.caseNumber || caseNumber == nil || other.caseNumber == nil)
    }
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
    var steps: [String]         // процессуальная цепочка: «done» | «active» | «todo»
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
            && sessions.count == other.sessions.count
            && zip(sessions, other.sessions).allSatisfy { $0.hasSameRefreshSource(as: $1) }
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
    /// Звено текущего производства. Для завершённых дел отсутствует.
    var currentTier: CourtTier?
    /// Номер текущей инстанции пересмотра для второй строки мониторинга.
    /// Не персистируется: вычисляется из `CaseLifecycleResolver.currentInstance`.
    var currentReviewNumber: String?
    /// Суд, к которому относится ближайшее событие. Держит инвариант #100:
    /// номер производства, событие и суд в строке мониторинга происходят из
    /// ОДНОЙ инстанции, иначе строка обещает заседание в суде первой
    /// инстанции, когда оно назначено в апелляции или кассации.
    /// `nil` — суд берётся из записи, как раньше.
    var nextEventCourt: String?
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
        let production = production(from: context)

        // Сессии всех инстанций.
        var sessions: [StoredSession] = []
        for inst in mv.instances {
            for s in inst.sessions {
                // CaseSession does not carry a per-session judge; use the instance judge as the closest source.
                sessions.append(StoredSession(
                    dateRaw: s.date, time: s.time, room: s.room,
                    event: s.event, result: s.result,
                    court: inst.court, judge: inst.judge, levelRaw: inst.level.rawValue,
                    caseNumber: reviewNumber(for: inst)))
            }
        }
        sessions.sort { (DateUtil.parse($0.dateRaw) ?? .distantPast)
                      < (DateUtil.parse($1.dateRaw) ?? .distantPast) }

        // Стороны (короткая строка + статьи ведущего лица + вторая строка «Списком»).
        let partiesShort = self.partiesShort(mv.parties)
        let leadCharges = mv.parties.leadCharges
        let secondPartyLine = self.partiesSecondLine(mv.parties)

        // Заседания (будущие, со временем) и сроки.
        let deadlines = self.deadlines(from: mv, prefix: prefix, production: production, today: today)
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
        let production = production(from: context)
        let resolution = CaseLifecycleResolver.resolve(movement: mv, production: production,
                                                       deadlines: deadlines, today: today)
        let prefix = context.map {
            String($0.cartotekaId.prefix(while: { $0.isLetter })).lowercased()
        } ?? ""
        let nextHearing = resolution.isCompleted ? nil : futureHearings(
            sessions.filter { $0.level != .material }, today: today).first
        let nextDeadline = deadlines
            .filter { $0.date >= today || $0 == resolution.graceDeadline }
            .sorted(by: { $0.dateRef < $1.dateRef })
            .first

        // Суд ближайшего события — только когда это событие ВЫШЕСТОЯЩЕЙ
        // инстанции. Дело, идущее в первой инстанции, подписи не меняет: issue
        // просит сохранить прежнее поведение, а суд из разобранного движения и
        // суд из записи могут отличаться формулировкой.
        //
        // Заседание авторитетнее всего: у сессии свой `court`, проставленный из
        // инстанции при сборке снимка. Иначе — суд текущего круга, и только
        // когда в строке реально показывается его номер: именно комбинацию
        // «номер апелляции + суд первой инстанции» issue и запрещает.
        let currentReviewNumber = reviewNumber(
            for: resolution.currentInstance, baseCaseNumber: mv.caseNumber)
        let reviewHearing = nextHearing.flatMap { $0.level == .first ? nil : $0 }
        let nextEventCourt = courtLabel(reviewHearing?.court)
            ?? (currentReviewNumber == nil ? nil : courtLabel(resolution.currentInstance?.court))

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
            // В буфере продолжаем показывать сам истёкший срок, а в сортировке
            // держим карточку до конца седьмого календарного дня.
            nextEventDate = deadline == resolution.graceDeadline && deadline.date < today
                ? DateUtil.addDays(deadline.date, 7) : deadline.date
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
        case .terminalFirst(let result):
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
            steps: resolution.steps,
            currentTier: resolution.isCompleted ? nil : courtTier(
                for: resolution.currentInstance, context: context)
                ?? inferredTier(stage: resolution.stage, production: production, context: context),
            currentReviewNumber: currentReviewNumber,
            nextEventCourt: nextEventCourt)
    }

    /// Стадия определяется по исходной картотеке дела, а не по номеру
    /// вышестоящего производства: одинаковые индексы на разных звеньях имеют
    /// разную отраслевую семантику.
    private static func production(from context: MovementContext?) -> ProductionType? {
        guard let cartotekaID = context?.cartotekaId,
              !cartotekaID.isEmpty,
              cartotekaID != "m" else { return nil }
        return ProductionType(cartotekaId: cartotekaID)
    }

    /// Название суда, пригодное для подписи. Отсеивает пустое значение и
    /// placeholder-прочерк карточки-заглушки — тем же набором, что и
    /// `reviewNumber`, иначе подпись «—» заменила бы верный суд записи.
    static func courtLabel(_ court: String?) -> String? {
        let value = (court ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || ["—", "–", "-"].contains(value) ? nil : value
    }

    /// Возвращает номер только реальной инстанции пересмотра. Материалы,
    /// captcha/network-заглушки и placeholder-карточки («—») исключаются.
    static func reviewNumber(for instance: CaseInstance?) -> String? {
        guard let instance,
              [.appeal, .cassation, .vsCassation, .supervisory].contains(instance.level),
              instance.captchaFormURL == nil,
              instance.transientError != true else { return nil }
        let number = CaseNumberPresentation.displayedNumber(for: instance)
        return CaseNumberPresentation.secondary(number, distinctFrom: "")
    }

    static func reviewNumber(for instance: CaseInstance?,
                             baseCaseNumber: String) -> String? {
        guard let number = reviewNumber(for: instance) else { return nil }
        return CaseNumberPresentation.secondary(number, distinctFrom: baseCaseNumber)
    }

    /// Классификация намеренно живёт в presentation: она зависит от текущего
    /// раунда и не меняет форматы `CaseSnapshot`/SwiftData.
    static func courtTier(for instance: CaseInstance?, context: MovementContext?) -> CourtTier? {
        guard let instance else { return nil }
        let text = (instance.court + " " + instance.domain).lowercased()
            .replacingOccurrences(of: "ё", with: "е")
        if instance.level == .vsCassation || instance.level == .supervisory
            || text.contains("vsrf.ru") || text.contains("верховн") && text.contains("росс") {
            return .supreme
        }
        let canonicalDomain = instance.domain.lowercased().replacingOccurrences(of: "www.", with: "")
        if CourtDirectory.subjectCourts.contains(where: {
            $0.domain.lowercased().replacingOccurrences(of: "www.", with: "") == canonicalDomain
        }) { return .subject }
        if let context, (instance.domain == context.searchDomain || instance.domain == context.displayDomain),
           context.courtLevel == .subject { return .subject }
        if text.contains("миров") || text.contains("msudrf") { return .magistrate }
        if text.contains("кассац") || text.contains("kas.sudrf") || text.contains("vkas") {
            return .cassation
        }
        if text.contains("апелляц") || text.contains("ap.sudrf") || text.contains("asoy") {
            return .appeal
        }
        if text.contains("гарнизон") { return .district }
        if text.contains("район") || text.contains("городск") { return .district }
        if text.contains("окружн") || text.contains("флотск") { return .subject }
        if text.contains("област") || text.contains("краев") || text.contains("республик") {
            return .subject
        }
        if let context, instance.domain == context.searchDomain
            || instance.domain == context.displayDomain {
            switch context.courtLevel {
            case .magistrate: return .magistrate
            case .district: return .district
            case .subject: return .subject
            case .appeal: return .appeal
            case .cassation: return .cassation
            }
        }
        switch instance.level {
        case .first: return .district
        case .appeal: return .subject
        case .cassation: return .cassation
        case .vsCassation, .supervisory: return .supreme
        case .material: return nil
        }
    }

    /// Когда портал сообщил возврат, но карточка целевого суда ещё не найдена,
    /// дело остаётся активным и получает ожидаемое звено по процессуальному пути.
    static func inferredTier(stage: CaseStageKind, production: ProductionType?,
                             context: MovementContext?) -> CourtTier? {
        guard let context else { return nil }
        switch stage {
        case .done: return nil
        case .first:
            return tier(for: context.courtLevel)
        case .appeal:
            switch context.courtLevel {
            case .magistrate: return .district
            case .district: return .subject
            case .subject: return .appeal
            case .appeal: return .cassation
            case .cassation: return .supreme
            }
        case .cassation:
            switch context.courtLevel {
            case .cassation: return .supreme
            default: return .cassation
            }
        case .supervisory:
            return production == .koap ? .cassation : .supreme
        }
    }

    /// Совместимый вход для legacy fallback без рассчитанного вида производства.
    static func inferredTier(stage: CaseStageKind, context: MovementContext?) -> CourtTier? {
        inferredTier(stage: stage, production: nil, context: context)
    }

    static func tier(for level: CourtLevel) -> CourtTier {
        switch level {
        case .magistrate: return .magistrate
        case .district: return .district
        case .subject: return .subject
        case .appeal: return .appeal
        case .cassation: return .cassation
        }
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

    /// Сравнение сырого движения для фонового бейджа. Тела актов могут
    /// отличаться только форматированием, а CAPTCHA/transient-заглушки отражают
    /// доступность портала, не новое событие дела. Публичные метаданные актов и
    /// остальные поля снимка отдельно проверяет `CaseSnapshot`.
    static func hasSameRefreshSource(_ lhs: CaseMovement, _ rhs: CaseMovement) -> Bool {
        lhs.uid == rhs.uid
            && lhs.caseNumber == rhs.caseNumber
            && lhs.inForce == rhs.inForce
            && CaseLifecycleResolver.realInstances(in: lhs)
                == CaseLifecycleResolver.realInstances(in: rhs)
            && lhs.complaints == rhs.complaints
            && lhs.executionDocuments == rhs.executionDocuments
    }

    // MARK: Заседания

    /// Сессии-заседания в будущем (включая сегодня), отсортированные по дате/времени.
    /// Время само по себе не доказывает, что строка движения является
    /// заседанием: портал ставит его и у процессуальных событий (#124).
    static func futureHearings(_ sessions: [StoredSession], today: Date) -> [StoredSession] {
        sessions.enumerated().filter { _, session in
            guard let date = DateUtil.parse(session.dateRaw),
                  DateUtil.daysBetween(today, date) >= 0 else { return false }
            return CaseLifecycleResolver.isHearing(
                event: session.event, result: session.result)
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

    /// Все датированные сессии-заседания для внутреннего календаря, включая
    /// прошедшие и уже завершённые. Срез намеренно использует только
    /// семантический предикат события: `isHearing` оставляется для
    /// future-only lifecycle-проекций.
    static func calendarHearings(_ sessions: [StoredSession]) -> [StoredSession] {
        sessions.enumerated().filter { _, session in
            guard DateUtil.parse(session.dateRaw) != nil else { return false }
            return CaseLifecycleResolver.isHearingEvent(event: session.event)
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
    private static func deadlines(from mv: CaseMovement,
                                  prefix: String, production: ProductionType?,
                                  today: Date) -> [StoredDeadline] {
        var out: [StoredDeadline] = []
        // Юридическая сила относится к текущему кругу. Старое вступление в
        // силу первой инстанции не должно порождать срок кассации, пока более
        // поздняя апелляция/кассация остаётся активной.
        let current = CaseLifecycleResolver.resolve(
            movement: mv, production: production, deadlines: [], today: today)
        // После возврата на новое рассмотрение историческая апелляция относится
        // к прежнему кругу и не должна подавлять новый расчётный срок.
        let timeline = CaseLifecycleResolver.timeline(in: mv, production: production)
        let hasAppealInCurrentRound = timeline.hasAppealInCurrentRound
        let forceState = currentLegalForceState(in: current.currentInstance?.sessions ?? [])
        let activeReview = current.completionReason == nil
            && current.currentInstance.map { isReviewLevel($0.level) } == true
        let legallyEffective = !activeReview && (forceState.effective ?? mv.inForce)
        let currentlyReactivated = forceState.effective == false

        // Срок апелляции: есть решение 1-й инстанции, дело не обжаловано в
        // апелляцию и не вступило в силу.
        if !legallyEffective, !currentlyReactivated, !hasAppealInCurrentRound {
            if let firstDecision = firstInstanceDecisionDate(mv, timeline: timeline),
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
        if legallyEffective, !timeline.hasCassationInCurrentRound,
           let days = cassationDays(prefix: prefix) {
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

    private static func firstInstanceDecisionDate(_ mv: CaseMovement,
                                                  timeline: CaseLifecycleResolver.Timeline) -> Date? {
        guard let first = timeline.latestFirst?.instance else { return nil }

        // Триггер срока — строка, которой объявлен обжалуемый итоговый акт.
        // Раньше бралась «последняя сессия с непустым результатом, иначе
        // последняя по дате»: обе ветки семантику события не проверяли, и срок
        // уезжал на произвольную строку — портал заполняет «Результат события»
        // и у промежуточных, и у канцелярских строк (#80).
        // Выбираем по ДАТЕ, а не по порядку в массиве: сессии инстанции идут
        // как их отдал парсер (по дате их сортирует только сборка снимка), а в
        // круге после возврата на новое рассмотрение итоговых актов может быть
        // несколько — срок считается от последнего.
        if let date = first.sessions
            .filter({ CaseLifecycleResolver.isFinalActAnnouncement(
                event: $0.event, result: $0.result) })
            .compactMap({ DateUtil.parse($0.date) })
            .max() {
            return date
        }

        // Итоговую строку опознать не удалось. Полностью отказаться от срока
        // нельзя: `resolveTerminalFirst` завершает дело, когда расчётного срока
        // апелляции нет, — то есть дело с нераспознанной формулировкой молча
        // уехало бы в «Завершённые» и пропало из активных списков. Это хуже
        // неточной даты, поэтому поведение остаётся прежним, но канцелярские
        // строки в кандидаты больше не попадают: именно они и перебивали
        // настоящий итог, будучи позже него по дате.
        let meaningful = first.sessions.filter {
            !CaseLifecycleResolver.isClericalEvent($0.event)
        }
        let candidates = meaningful.isEmpty ? first.sessions : meaningful
        if let withResult = candidates.last(where: { ($0.result ?? "").isEmpty == false }),
           let date = DateUtil.parse(withResult.date) {
            return date
        }
        return candidates.compactMap { DateUtil.parse($0.date) }.max()
    }
    private static func currentLegalForceState(in sessions: [CaseSession]) -> LegalForceState {
        let ordered = sessions.enumerated().sorted { left, right in
            let leftDate = DateUtil.parse(left.element.date) ?? .distantPast
            let rightDate = DateUtil.parse(right.element.date) ?? .distantPast
            return leftDate == rightDate ? left.offset < right.offset : leftDate < rightDate
        }
        var state = LegalForceState()
        for (_, session) in ordered {
            if CaseLifecycleResolver.hasLegalForceEvidence(
                event: session.event, result: session.result
            ) {
                state.effective = true
                state.date = DateUtil.parse(session.date)
            } else if CaseLifecycleResolver.isReactivation(
                event: session.event, result: session.result
            ) {
                state.effective = false
                state.date = nil
            }
        }
        return state
    }
    private static func isReviewLevel(_ level: CaseInstance.Level) -> Bool {
        switch level {
        case .appeal, .cassation, .vsCassation, .supervisory: return true
        case .first, .material: return false
        }
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
        case .supervisory: return "надзор"
        case .done:      return "завершено"
        }
    }

    /// Категория дела для карточки. Сайт суда отдаёт её разделами рубрикатора
    /// через «→» или «->», и целиком она в строку карточки не помещается.
    /// Пока помещается — отдаём как есть; длинную сворачиваем до последнего
    /// раздела: он самый конкретный. Исключение — раздел-заглушка («иные…»,
    /// «прочие…», «другие…»): он ничего не сообщает, тогда берём предыдущий.
    ///
    /// Порог — в символах, а не по фактической ширине: иначе одна и та же
    /// категория была бы свёрнута в узком окне и развёрнута в широком, и
    /// карточки в сетке перестали бы выглядеть одинаково.
    static func categoryTail(_ category: String, limit: Int = 46) -> String {
        let whole = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard whole.count > limit else { return whole }

        let trim = CharacterSet(charactersIn: " :\u{00a0}\n\t")
        let parts = whole.replacingOccurrences(of: "->", with: "→")
            .components(separatedBy: "→")
            .map { $0.trimmingCharacters(in: trim) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else { return whole }

        var i = parts.count - 1
        let stubs = ["иные", "прочие", "другие"]
        if i > 0, stubs.contains(where: { parts[i].lowercased().hasPrefix($0) }) { i -= 1 }
        return parts[i]
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
