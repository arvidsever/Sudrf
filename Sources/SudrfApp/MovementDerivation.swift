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
    var statusRaw: String      // «proposed» | «confirmed» | «overridden»
    /// Устойчивая identity occurrence: rule + процессуальный круг + trigger.
    /// Старые snapshots не имели ключа и декодируются с nil.
    var occurrenceKey: String? = nil
    /// Нормативная provenance рассчитанного срока. Optional сохраняет старые
    /// snapshots и вручную созданные legacy deadlines.
    var provenance: DeadlineProvenance? = nil
    /// `nil` в snapshot до #70 эквивалентен active.
    var lifecycleRaw: String? = nil
    var date: Date { Date(timeIntervalSinceReferenceDate: dateRef) }
    var status: DeadlineStatus { DeadlineStatus(rawValue: statusRaw) ?? .proposed }
    var lifecycle: DeadlineLifecycle {
        DeadlineLifecycle(rawValue: lifecycleRaw ?? "") ?? .active
    }
    var isActive: Bool { lifecycle == .active }
    var isUserControlled: Bool { status.isUserControlled }
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
    /// Известные rules, которые не создали дату без догадки. Optional для
    /// безопасного чтения JSON snapshots, созданных до #70.
    var deadlineAssessments: [DeadlineRuleAssessment]? = nil
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
            && deadlineAssessments == other.deadlineAssessments
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

    /// Главная функция: движение + контекст → снимок. `today` — для расчёта
    /// «дальше», заседаний и сроков (по умолчанию системная дата).
    static func snapshot(from mv: CaseMovement, context: MovementContext,
                         today: Date = DateUtil.today) -> CaseSnapshot {

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

        // Заседания (будущие, со временем) и сроки. Registry is the single
        // source of normative wording; a missing resource fails closed.
        let deadlineEvaluation = self.deadlineEvaluation(
            from: mv, context: context, production: production, today: today)
        let deadlines = deadlineEvaluation.deadlines
        let presentation = lifecyclePresentation(from: mv, sessions: sessions,
                                                 deadlines: deadlines,
                                                 assessments: deadlineEvaluation.assessments,
                                                 context: context,
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
            deadlineAssessments: deadlineEvaluation.assessments,
            actsFingerprint: actsFingerprint.isEmpty ? nil : actsFingerprint)
    }

    /// Пересчёт представляемой стадии по сохранённому движению и снимку. Поля
    /// `CaseSnapshot` остаются обратно совместимыми и служат fallback, если
    /// полного движения у старой записи нет.
    static func lifecyclePresentation(from mv: CaseMovement, snapshot: CaseSnapshot,
                                      context: MovementContext?,
                                      today: Date = DateUtil.today) -> CaseLifecyclePresentation {
        lifecyclePresentation(from: mv, sessions: snapshot.sessions,
                              deadlines: snapshot.deadlines,
                              assessments: snapshot.deadlineAssessments ?? [],
                              context: context, today: today)
    }

    private static func lifecyclePresentation(from mv: CaseMovement,
                                              sessions: [StoredSession],
                                              deadlines: [StoredDeadline],
                                              assessments: [DeadlineRuleAssessment],
                                              context: MovementContext?,
                                              today: Date) -> CaseLifecyclePresentation {
        let production = production(from: context)
        let resolution = CaseLifecycleResolver.resolve(movement: mv, production: production,
                                                       deadlines: deadlines,
                                                       deadlineAssessments: assessments,
                                                       today: today)
        let prefix = context.map {
            String($0.cartotekaId.prefix(while: { $0.isLetter })).lowercased()
        } ?? ""
        let nextHearing = resolution.isCompleted ? nil : futureHearings(
            sessions.filter { $0.level != .material }, today: today).first
        let nextDeadline = deadlines
            .filter(\.isActive)
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
            nextChip = deadline.isUserControlled
                ? .confirmed : .proposed
            // В буфере продолжаем показывать сам истёкший срок, а в сортировке
            // держим карточку до конца седьмого календарного дня.
            nextEventDate = deadline == resolution.graceDeadline && deadline.date < today
                ? DateUtil.addDays(deadline.date, 7) : deadline.date
        } else if !resolution.isCompleted, let reason = deadlineAssessmentReason(assessments) {
            // Норма и формула остаются в registry. В проекции показываем лишь
            // ID рассмотренного правила и отсутствующее поле/политику, чтобы
            // активная карточка не выглядела как беспричинное «—».
            nextEvent = reason
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

    /// Короткое, локализованное объяснение fail-closed результата. Здесь нет
    /// текста нормы или формулы: пользовательские нормативные сведения берутся
    /// только из registry/provenance popover.
    static func deadlineAssessmentReason(_ assessments: [DeadlineRuleAssessment]) -> String? {
        guard let assessment = assessments.first(where: { $0.isIndeterminate }) else { return nil }
        let detail: String
        switch assessment.status {
        case .insufficientEvidence:
            let evidence = assessment.missingEvidenceRaw.compactMap {
                DeadlineEvidenceRequirement(rawValue: $0)
            }.map(evidenceLabel)
            detail = evidence.isEmpty
                ? "не хватает подтверждённого факта"
                : "нет: \(evidence.joined(separator: ", "))"
        case .unsupportedCalculation:
            let policies = assessment.missingPolicyIDs.map(policyLabel)
            detail = policies.isEmpty
                ? "не реализована политика исчисления"
                : "не реализована политика: \(policies.joined(separator: ", "))"
        case .needsLegalReview:
            detail = "требуется юридическая проверка"
        case .applicable, .notApplicable:
            return nil
        }
        return "срок не рассчитан · \(assessment.ruleID) · \(detail)"
    }

    private static func evidenceLabel(_ requirement: DeadlineEvidenceRequirement) -> String {
        switch requirement {
        case .production: return "вид производства"
        case .caseCategory: return "категория дела"
        case .actType: return "вид судебного акта"
        case .finalAct: return "итоговый судебный акт"
        case .finalForm: return "окончательная форма акта"
        case .deliveryOrReceipt: return "вручение или получение акта"
        case .legalForce: return "вступление акта в силу"
        case .motivatedAppealDetermination: return "мотивированное апелляционное определение"
        }
    }

    private static func policyLabel(_ id: String) -> String {
        let value = id.uppercased()
        if value.contains("NONWORKING") { return "перенос с нерабочего дня" }
        if value.contains("WORKING") { return "производственный календарь" }
        return id
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

    /// Совмещает свежий расчёт с сохранёнными occurrences. Ручное решение
    /// переносится только на тот же rule/round/trigger; старые и просроченные
    /// occurrences остаются историей и не могут возродиться при refresh.
    static func preservingConfirmedDeadlines(_ snap: CaseSnapshot,
                                             old: CaseSnapshot?,
                                             today: Date = DateUtil.today) -> CaseSnapshot {
        guard let old else { return applyingDeadlineRetention(to: snap, today: today) }
        var out = snap
        var fresh = out.deadlines
        var historical: [StoredDeadline] = []
        var usedFresh = Set<Int>()
        var suppressedFresh = Set<Int>()

        func freshIndex(matching deadline: StoredDeadline) -> Int? {
            guard let key = deadline.occurrenceKey else { return nil }
            return fresh.indices.first { fresh[$0].occurrenceKey == key }
        }

        for previous in old.deadlines {
            if let index = freshIndex(matching: previous) {
                usedFresh.insert(index)
                // An inactive occurrence is immutable, even if a later source
                // refresh happens to expose its old trigger again.
                if !previous.isActive {
                    historical.append(previous)
                    suppressedFresh.insert(index)
                    continue
                }
                if previous.isUserControlled {
                    fresh[index].dateRef = previous.dateRef
                    fresh[index].statusRaw = previous.statusRaw
                }
                continue
            }

            // Legacy snapshots have no occurrence key. A user-controlled
            // deadline may safely migrate to the sole fresh deadline of its
            // kind; proposed legacy values are replaced by the registry result.
            if previous.occurrenceKey == nil,
               previous.isUserControlled,
               let index = fresh.indices.first(where: {
                   !usedFresh.contains($0) && fresh[$0].kind == previous.kind
               }) {
                usedFresh.insert(index)
                fresh[index].dateRef = previous.dateRef
                fresh[index].statusRaw = previous.statusRaw
                continue
            }

            // A manual decision takes precedence over an incomplete refresh.
            // It becomes superseded only when the fresh source actually
            // proves a different occurrence of the same kind. This also keeps
            // a confirmed date safe while a portal temporarily omits a row.
            if previous.isUserControlled,
               !fresh.contains(where: { $0.kind == previous.kind }) {
                historical.append(previous)
            } else {
                var superseded = previous
                if superseded.isActive {
                    superseded.lifecycleRaw = DeadlineLifecycle.superseded.rawValue
                }
                historical.append(superseded)
            }
        }
        out.deadlines = fresh.enumerated()
            .filter { !suppressedFresh.contains($0.offset) }
            .map(\.element) + historical
        return applyingDeadlineRetention(to: out, today: today)
    }

    private static func applyingDeadlineRetention(to snapshot: CaseSnapshot,
                                                   today: Date) -> CaseSnapshot {
        var out = snapshot
        out.deadlines = out.deadlines.map { deadline in
            guard deadline.isActive,
                  deadline.status == .proposed,
                  DateUtil.daysBetween(deadline.date, today) > AppRouter.deadlineGraceDays
            else { return deadline }
            var expired = deadline
            expired.lifecycleRaw = DeadlineLifecycle.expiredUnconfirmed.rawValue
            return expired
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

    // MARK: Сроки

    private static func deadlineEvaluation(from movement: CaseMovement,
                                           context: MovementContext,
                                           production: ProductionType?,
                                           today: Date) -> DeadlineRuleEngine.Evaluation {
        let engineContext = DeadlineRuleEngine.Context(movementContext: context)
        guard production != nil else {
            return DeadlineRuleEngine.Evaluation(deadlines: [], assessments: [])
        }
        guard let registry = try? LegalDeadlineRegistry.load() else {
            return DeadlineRuleEngine.unavailable(context: engineContext)
        }
        let timeline = CaseLifecycleResolver.timeline(in: movement, production: production)
        return DeadlineRuleEngine.evaluate(
            registry: registry, movement: movement,
            context: engineContext,
            timeline: timeline, today: today)
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

    private static func trim(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 60 ? String(t.prefix(58)) + "…" : t
    }
}
