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
    /// Номер производства инстанции пересмотра или материала, из которого
    /// пришло событие.
    /// Optional сохраняет декодирование старых snapshots.
    var caseNumber: String? = nil
    /// Stable source-card identity used only by the shadow semantic journal.
    /// Optional preserves snapshots written before #155.
    var sourceCardID: String? = nil
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
    /// Versioned typed projection consumed by `CaseEventDeriver`. A missing
    /// version means legacy baseline, never "all rows are new".
    var semanticProjectionVersion: Int? = nil
    var instanceObservations: [StoredInstanceObservation]? = nil
    var actObservations: [StoredActObservation]? = nil
    var complaintObservations: [StoredComplaintObservation]? = nil

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
    var inForce: Bool
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
    var nextEventHelp: String? = nil
}

// MARK: - Движок

enum MovementDerivation {

    /// Главная функция: движение + контекст → снимок. `today` — для расчёта
    /// «дальше», заседаний и сроков (по умолчанию системная дата).
    static func classifiedParties(from movement: CaseMovement, context: MovementContext?) -> CaseParties {
        var parties = movement.parties
        let classification = MaterialProductionContext.resolve(context: context, movement: movement)
        guard classification.isMaterial else { return parties }
        switch classification.production {
        case .koap?: parties.kind = .koap
        case .kas?: parties.kind = .administrative
        case .crim?: parties.kind = .upk
        case .civil?: if parties.kind != .special { parties.kind = .civil }
        case nil: break
        }
        return parties
    }

    static func snapshot(from mv: CaseMovement, context: MovementContext,
                         today: Date = DateUtil.today) -> CaseSnapshot {

        let production = MaterialProductionContext.resolve(context: context, movement: mv).production

        // Сессии всех инстанций.
        var sessions: [StoredSession] = []
        for inst in mv.instances {
            let sourceCardID = CaseSnapshotSourceIdentity.sourceCardID(
                for: inst, context: context)
            for s in inst.sessions {
                // CaseSession does not carry a per-session judge; use the instance judge as the closest source.
                sessions.append(StoredSession(
                    dateRaw: s.date, time: s.time, room: s.room,
                    event: s.event, result: s.result,
                    court: inst.court, judge: inst.judge, levelRaw: inst.level.rawValue,
                    caseNumber: materialNumber(for: inst) ?? reviewNumber(for: inst),
                    sourceCardID: sourceCardID))
            }
        }
        sessions.sort { (DateUtil.parse($0.dateRaw) ?? .distantPast)
                      < (DateUtil.parse($1.dateRaw) ?? .distantPast) }

        // Стороны (короткая строка + статьи ведущего лица + вторая строка «Списком»).
        let parties = classifiedParties(from: mv, context: context)
        let partiesShort = self.partiesShort(parties)
        let leadCharges = parties.leadCharges
        let secondPartyLine = self.partiesSecondLine(parties)

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
        let instanceObservations = mv.instances.map { instance in
            StoredInstanceObservation(
                sourceCardID: CaseSnapshotSourceIdentity.sourceCardID(
                    for: instance, context: context),
                levelRaw: instance.level.rawValue, court: instance.court,
                caseNumber: instance.caseNumber, judge: instance.judge,
                result: instance.result)
        }.sorted {
            ($0.sourceCardID ?? "", $0.levelRaw, $0.caseNumber)
                < ($1.sourceCardID ?? "", $1.levelRaw, $1.caseNumber)
        }
        let actObservations = mv.acts.map { act -> StoredActObservation in
            let linked = mv.instances.filter { $0.linkedActIDs.contains(act.id) }
            let candidates = linked.isEmpty && act.instanceLevel != .material
                ? mv.instances.filter { $0.level == act.instanceLevel }
                : linked
            let owner = candidates.count == 1 ? candidates[0] : nil
            return StoredActObservation(
                sourceCardID: owner.flatMap {
                    CaseSnapshotSourceIdentity.sourceCardID(for: $0, context: context)
                },
                sourceActID: act.id, title: act.title, dateRaw: act.date,
                court: act.courtShort,
                levelRaw: (owner?.level ?? act.instanceLevel).rawValue)
        }.sorted { $0.sourceActID < $1.sourceActID }
        let complaintObservations = mv.complaints.values.map { complaint in
            let candidates = mv.instances.filter {
                $0.court == complaint.court && $0.caseNumber == complaint.caseNumber
            }
            let owner = candidates.count == 1 ? candidates[0] : nil
            return StoredComplaintObservation(
                sourceCardID: owner.flatMap {
                    CaseSnapshotSourceIdentity.sourceCardID(for: $0, context: context)
                },
                sourceComplaintID: complaint.id, label: complaint.label,
                court: complaint.court, caseNumber: complaint.caseNumber)
        }.sorted { $0.sourceComplaintID < $1.sourceComplaintID }

        // «Последнее событие».
        let lastEvent: String
        if let last = sessions.last, let d = DateUtil.parse(last.dateRaw) {
            lastEvent = "\(DateUtil.shortDM(d)) · \(trim(last.result ?? last.event))"
        } else {
            lastEvent = "нет данных о движении"
        }

        return CaseSnapshot(
            uid: mv.uid, inForce: presentation.inForce, category: mv.category,
            partiesShort: partiesShort, leadCharges: leadCharges,
            secondPartyLine: secondPartyLine,
            stageRaw: presentation.stage.rawValue, stageTag: presentation.stageTag,
            statusText: presentation.statusText,
            statusChipRaw: presentation.statusChip.rawValue,
            lastEvent: lastEvent, nextEvent: presentation.nextEvent,
            nextChipRaw: presentation.nextChip.rawValue,
            steps: presentation.steps, sessions: sessions, deadlines: deadlines,
            deadlineAssessments: deadlineEvaluation.assessments,
            actsFingerprint: actsFingerprint.isEmpty ? nil : actsFingerprint,
            semanticProjectionVersion: CaseEventJournal.currentDerivationVersion,
            instanceObservations: instanceObservations,
            actObservations: actObservations,
            complaintObservations: complaintObservations)
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
        let mainDeadlines = deadlines.filter { deadlineScopeKey($0) == nil }
        let production = MaterialProductionContext.resolve(context: context, movement: mv).production
        let inForce = CaseLifecycleResolver.effectiveLegalForce(
            in: mv, production: production)
        let resolution = CaseLifecycleResolver.resolve(movement: mv, production: production,
                                                       deadlines: mainDeadlines,
                                                       deadlineAssessments: assessments,
                                                       today: today)
        let prefix = context.map {
            String($0.cartotekaId.prefix(while: { $0.isLetter })).lowercased()
        } ?? ""
        let rootMaterials = mv.instances.filter {
            CaseLifecycleResolver.isRootMaterial($0, in: mv)
        }
        let rootMaterialNumbers = Set(rootMaterials.map {
            CaseNumberPresentation.primary($0.caseNumber).lowercased()
        })
        let rootMaterialIDs: Set<String>
        if let context {
            rootMaterialIDs = Set(rootMaterials.compactMap {
                CaseSnapshotSourceIdentity.sourceCardID(for: $0, context: context)
            })
        } else {
            rootMaterialIDs = []
        }
        let lifecycleSessions = sessions.filter { session in
            guard session.level == .material else { return true }
            if let id = session.sourceCardID, rootMaterialIDs.contains(id) { return true }
            guard let number = session.caseNumber else { return false }
            return rootMaterialNumbers.contains(
                CaseNumberPresentation.primary(number).lowercased())
        }
        let materialScopes = context.map { MaterialDeadlineScope.proven(in: mv, context: $0) } ?? []
        let materialCards = materialScopes.flatMap { subject in
            subject.movement.instances.map { (subject.movement.caseNumber, $0) }
        }
        func materialOwner(of session: StoredSession) -> (String, CaseInstance)? {
            let matches = materialCards.filter { _, instance in
                if let id = session.sourceCardID, let context {
                    return CaseSnapshotSourceIdentity.sourceCardID(for: instance, context: context) == id
                }
                return session.level == instance.level && session.caseNumber == instance.caseNumber
                    && CaseLifecycleResolver.courtTitlesAgree(session.court, instance.court, domain: instance.domain)
            }
            return matches.count == 1 ? matches.first : nil
        }
        let mainHearing = resolution.isCompleted ? nil
            : futureHearings(lifecycleSessions.filter { materialOwner(of: $0) == nil }, today: today).first
        let upcomingSessions = sessions.filter { session in
            if let (_, instance) = materialOwner(of: session) {
                guard !CaseLifecycleResolver.isMaterialAdjudication(event: session.event, result: session.result),
                      !CaseLifecycleResolver.isMaterialAdjudication(event: "", result: instance.result)
                else { return false }
                return CaseLifecycleResolver.isHearing(event: session.event,
                    result: [session.result, instance.result].compactMap { $0 }.joined(separator: " "))
            }
            if session.level != .material { return !resolution.isCompleted }
            let isRootMaterialSession = session.sourceCardID.map { rootMaterialIDs.contains($0) } == true
                || session.caseNumber.map {
                    rootMaterialNumbers.contains(CaseNumberPresentation.primary($0).lowercased())
                } == true
            if isRootMaterialSession { return !resolution.isCompleted }
            // Keep the existing Overview eligibility for an unprojected material card.
            let material = mv.instances.first { instance in
                guard instance.level == .material else { return false }
                if let context, let id = session.sourceCardID {
                    return CaseSnapshotSourceIdentity.sourceCardID(for: instance, context: context) == id
                }
                return session.caseNumber == instance.caseNumber
            }
            guard !CaseLifecycleResolver.isMaterialAdjudication(event: session.event, result: session.result),
                  !CaseLifecycleResolver.isMaterialAdjudication(event: "", result: material?.result)
            else { return false }
            return CaseLifecycleResolver.isHearing(event: session.event,
                result: [session.result, material?.result].compactMap { $0 }.joined(separator: " "))
        }
        let futureHearing = futureHearings(upcomingSessions, today: today).first
        let futureDeadline = deadlines.filter {
            $0.isActive && $0.date >= today
                && (deadlineScopeKey($0) == nil
                    || MaterialDeadlineScope.materialSourceCardID(in: $0.occurrenceKey) != nil)
        }
            .sorted { $0.dateRef < $1.dateRef }.first
        // Compare calendar days: a hearing wins a same-day tie.
        let nextHearing = futureHearing.flatMap { hearing in
            guard let date = hearing.date else { return nil as StoredSession? }
            if let deadline = futureDeadline {
                return Calendar.current.startOfDay(for: date) <= Calendar.current.startOfDay(for: deadline.date)
                    ? hearing : nil
            }
            return hearing
        }
        let nextDeadline = nextHearing == nil
            ? (futureDeadline ?? resolution.graceDeadline) : nil
        var diagnosticLines = assessments.filter(\.isIndeterminate).compactMap {
            deadlineAssessmentReason([$0])
        }
        var diagnosticShort = assessments.first(where: \.isIndeterminate).flatMap(compactDeadlineAssessmentReason)
        let materialEvaluations = context.map {
            materialDeadlineEvaluations(from: mv, context: $0, today: today)
        } ?? []
        for material in materialEvaluations {
                if diagnosticShort == nil,
                   let assessment = material.evaluation.assessments.first(where: \.isIndeterminate),
                   let reason = compactDeadlineAssessmentReason(assessment) {
                    diagnosticShort = "\(reason) · материал № \(CaseNumberPresentation.primary(material.caseNumber))"
                }
                diagnosticLines += material.evaluation.assessments.filter(\.isIndeterminate).compactMap {
                    deadlineAssessmentReason([$0]).map {
                        "Материал № \(CaseNumberPresentation.primary(material.caseNumber)): \($0)"
                    }
                }
        }
        var savedMaterialScopes = Set<String>()
        for deadline in deadlines where deadline.isActive {
            guard let sourceID = MaterialDeadlineScope.materialSourceCardID(in: deadline.occurrenceKey),
                  savedMaterialScopes.insert(sourceID).inserted,
                  materialEvaluations.first(where: { $0.id == sourceID })?.evaluation.deadlines.isEmpty != false
            else { continue }
            let number = deadlineDisplayNumber(deadline, movement: mv, context: context,
                sessions: sessions, defaultNumber: "")
            let subject = number.isEmpty ? "Материал" : "Материал № \(number)"
            diagnosticLines.append("\(subject): показан последний сохранённый срок; текущих данных недостаточно для повторного расчёта")
        }
        var seenDiagnostics = Set<String>()
        let nextEventHelp = diagnosticLines.isEmpty ? nil
            : diagnosticLines.filter { seenDiagnostics.insert($0).inserted }.joined(separator: "\n")

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
        let reviewHearing = mainHearing.flatMap { hearing -> StoredSession? in
            guard hearing.level != .first, hearing.level != .material else { return nil }
            return hearing
        }
        let nextEventCourt = courtLabel(reviewHearing?.court)
            ?? (currentReviewNumber == nil ? nil : courtLabel(resolution.currentInstance?.court))

        var nextEvent = "—"
        var nextChip: Palette.Chip = .gray
        var nextEventDate: Date?
        if let hearing = nextHearing, let date = hearing.date {
            nextEvent = "заседание \(DateUtil.shortDM(date))"
                + (hearing.time.map { ", \($0)" } ?? "")
            let materialNumber = materialOwner(of: hearing)?.0
                ?? (hearing.level == .material ? hearing.caseNumber : nil)
            if let materialNumber {
                nextEvent += " · материал № \(CaseNumberPresentation.primary(materialNumber))"
            }
            nextChip = .blue
            nextEventDate = date
        } else if let deadline = nextDeadline {
            let deadlineLabel = deadline.provenance?.ruleID.contains("SUPREME-COURT") == true
                || deadline.what.contains("ВС РФ") ? "ВС РФ"
                : deadline.kind == "cassation" ? "кассации"
                : deadline.what.lowercased().contains("частн") ? "частной жалобы" : "апелляции"
            nextEvent = "срок \(deadlineLabel): "
                + DateUtil.shortDM(deadline.date)
            if MaterialDeadlineScope.materialSourceCardID(in: deadline.occurrenceKey) != nil {
                let number = deadlineDisplayNumber(deadline, movement: mv, context: context,
                    sessions: sessions, defaultNumber: "")
                if !number.isEmpty { nextEvent += " · материал № \(number)" }
            }
            nextChip = deadline.isUserControlled
                ? .confirmed : .proposed
            nextEventDate = deadline.date
        } else if nextEventHelp != nil {
            nextEvent = diagnosticShort ?? "Срок не рассчитан"
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
        case nil where mainHearing != nil:
            statusText = "Назначено заседание"
            statusChip = .blue
        case nil where resolution.currentInstance.map(
            CaseLifecycleResolver.hasAmbiguousKoAPKSOYUComplaintResult) == true:
            statusText = "Итог требует проверки"
            statusChip = .gray
        case nil:
            if let result = resolution.currentInstance?.result, !result.isEmpty {
                statusText = result
                statusChip = .gray
            } else if let last = lifecycleSessions.last {
                statusText = last.result ?? last.event
                statusChip = .blue
            } else {
                statusText = "В производстве"
                statusChip = .blue
            }
        }

        return CaseLifecyclePresentation(
            inForce: inForce,
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
            nextEventCourt: nextEventCourt,
            nextEventHelp: nextEventHelp)
    }

    static func effectiveLegalForce(from movement: CaseMovement,
                                    context: MovementContext?) -> Bool {
        let production = MaterialProductionContext.resolve(
            context: context, movement: movement).production
        return CaseLifecycleResolver.effectiveLegalForce(
            in: movement, production: production)
    }

    /// Короткое, локализованное объяснение fail-closed результата. Здесь нет
    /// текста нормы или формулы: пользовательские нормативные сведения берутся
    /// только из registry/provenance popover.
    static func deadlineAssessmentReason(_ assessments: [DeadlineRuleAssessment]) -> String? {
        guard let assessment = assessments.first(where: { $0.isIndeterminate }) else { return nil }
        if assessment.status == .unsupportedCalculation {
            if assessment.missingPolicyIDs.contains("vsrfCassationCalculation") {
                return "Срок обращения в ВС РФ пока не рассчитывается"
            }
            if assessment.missingPolicyIDs.contains("historicalCassationRegime")
                || assessment.missingPolicyIDs.contains("historicalVSCassationRegime") {
                return "Срок не рассчитан: исторический порядок кассации пока не поддерживается"
            }
        }
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

    private static func compactDeadlineAssessmentReason(_ assessment: DeadlineRuleAssessment) -> String? {
        guard assessment.isIndeterminate else { return nil }
        if assessment.status == .insufficientEvidence,
           let requirement = assessment.missingEvidenceRaw.first.flatMap(DeadlineEvidenceRequirement.init(rawValue:)) {
            switch requirement {
            case .finalForm, .cassationFinalForm, .appealFinalForm, .motivatedAppealDetermination:
                return "Нет даты окончательной формы"
            case .finalAct: return "Нет итогового акта"
            case .legalForce: return "Нет даты вступления в силу"
            case .deliveryOrReceipt: return "Нет даты получения акта"
            case .firstCourtCassationReceipt: return "Нет даты подачи кассации в первую инстанцию"
            case .conflictingDates: return "Даты акта противоречат друг другу"
            default: return "Не подтверждено: " + evidenceLabel(requirement)
            }
        }
        if assessment.status == .needsLegalReview { return "Срок требует юридической проверки" }
        return "Порядок расчёта срока не поддерживается"
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
        case .firstCourtCassationReceipt: return "поступление кассационной жалобы в суд первой инстанции"
        case .cassationFinalForm: return "окончательная форма кассационного определения"
        case .appealFinalForm: return "окончательная форма апелляционного определения"
        case .conflictingDates: return "непротиворечивые собственные даты акта"
        case .cassationRoute: return "подтверждённый маршрут обращения в ВС РФ"
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

    /// Возвращает только опубликованный номер реальной карточки материала.
    /// Заглушки CAPTCHA/сети и технические значения не становятся подписью.
    static func materialNumber(for instance: CaseInstance?) -> String? {
        guard let instance,
              instance.level == .material,
              instance.captchaFormURL == nil,
              instance.transientError != true else { return nil }
        return CaseNumberPresentation.secondary(
            CaseNumberPresentation.displayedNumber(for: instance), distinctFrom: "")
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
    /// Partition before kind/legacy reconciliation: a material never lends its
    /// confirmation, manual date or closed history to the main dispute.
    static func preservingConfirmedDeadlines(_ snap: CaseSnapshot,
                                             old: CaseSnapshot?,
                                             today: Date = DateUtil.today,
                                             preserveActiveProposedWhenMissing: Bool = false,
                                             movement: CaseMovement? = nil,
                                             context: MovementContext? = nil,
                                             protectedActiveOccurrenceKeys: Set<String> = []) -> CaseSnapshot {
        guard let old else { return applyingDeadlineRetention(to: snap, today: today) }
        let scopedKeys = Set((snap.deadlines + old.deadlines).compactMap(deadlineScopeKey))
        guard !scopedKeys.isEmpty else {
            return preservingSubjectDeadlines(snap, old: old, today: today,
                preserveActiveProposedWhenMissing: preserveActiveProposedWhenMissing,
                movement: movement, context: context,
                protectedActiveOccurrenceKeys: protectedActiveOccurrenceKeys)
        }
        let subjects = movement.flatMap { mv in context.map {
            MaterialDeadlineScope.proven(in: mv, context: $0)
        }} ?? []
        var out = snap
        out.deadlines = []
        for key in [nil] + scopedKeys.sorted().map(Optional.some) {
            var freshSubject = snap
            freshSubject.deadlines = snap.deadlines.filter { deadlineScopeKey($0) == key }
            var oldSubject = old
            oldSubject.deadlines = old.deadlines.filter { deadlineScopeKey($0) == key }
            let subject = subjects.first { $0.sourceCardID == key }
            if key != nil {
                freshSubject.deadlineAssessments = []
                oldSubject.deadlineAssessments = []
            }
            let preserved = preservingSubjectDeadlines(freshSubject, old: oldSubject, today: today,
                preserveActiveProposedWhenMissing: preserveActiveProposedWhenMissing
                    || key != nil && subject == nil,
                movement: key == nil ? movement : subject?.movement,
                context: key == nil ? context : subject?.context,
                protectedActiveOccurrenceKeys: protectedActiveOccurrenceKeys)
            out.deadlines += preserved.deadlines
            if key == nil { out.deadlineAssessments = preserved.deadlineAssessments }
        }
        return out
    }

    /// Six components are the unchanged main/legacy identity. Unknown keys are
    /// kept in their own opaque partition; they cannot adopt another subject.
    static func deadlineScopeKey(_ deadline: StoredDeadline) -> String? {
        let scope = MaterialDeadlineScope.scopeKey(in: deadline.occurrenceKey)
        if scope == "main" { return nil }
        return MaterialDeadlineScope.materialSourceCardID(in: deadline.occurrenceKey) ?? scope
    }

    static func deadlineDisplayNumber(_ deadline: StoredDeadline, movement: CaseMovement?,
                                      context: MovementContext?, sessions: [StoredSession],
                                      defaultNumber: String) -> String {
        guard let scope = deadlineScopeKey(deadline) else { return defaultNumber }
        if let movement, let context, let instance = movement.instances.first(where: {
            $0.level == .material && CaseSnapshotSourceIdentity.sourceCardID(for: $0, context: context) == scope
        }) { return CaseNumberPresentation.primary(instance.caseNumber) }
        let numbers = Set(sessions.filter { $0.sourceCardID == scope }.compactMap(\.caseNumber))
        if numbers.count == 1 { return CaseNumberPresentation.primary(numbers.first!) }
        if let marker = deadline.calLabel.range(of: " · материал № ", options: .backwards) {
            return String(deadline.calLabel[marker.upperBound...])
        }
        return defaultNumber
    }

    private static func preservingSubjectDeadlines(_ snap: CaseSnapshot,
                                             old: CaseSnapshot?,
                                             today: Date = DateUtil.today,
                                             preserveActiveProposedWhenMissing: Bool = false,
                                             movement: CaseMovement? = nil,
                                             context: MovementContext? = nil,
                                             protectedActiveOccurrenceKeys: Set<String> = []) -> CaseSnapshot {
        guard let old else { return applyingDeadlineRetention(to: snap, today: today) }
        var out = snap
        var fresh = out.deadlines
        var historical: [StoredDeadline] = []
        var ambiguousPreserved: [StoredDeadline] = []
        var usedFresh = Set<Int>()
        var suppressedFresh = Set<Int>()
        let activeExactKeys = Set(old.deadlines.filter(\.isActive).compactMap(\.occurrenceKey))
            .union(protectedActiveOccurrenceKeys)

        func freshIndex(matching deadline: StoredDeadline) -> Int? {
            guard let key = deadline.occurrenceKey else { return nil }
            return fresh.indices.first { fresh[$0].occurrenceKey == key }
        }

        func issue125Matches(_ previous: StoredDeadline)
            -> (proved: Int?, ambiguous: [Int]) {
            guard let movement, let context else { return (nil, []) }
            var proved: [Int] = []
            var ambiguous: [Int] = []
            for index in fresh.indices where !usedFresh.contains(index) && fresh[index].isActive {
                switch DeadlineRuleEngine.provesIssue125Transition(
                    from: previous, to: fresh[index], movement: movement,
                    context: context, oldSnapshot: old) {
                case .proved: proved.append(index)
                case .ambiguous: ambiguous.append(index)
                case .none: break
                }
            }
            if proved.count == 1 && ambiguous.isEmpty { return (proved[0], []) }
            return (nil, proved + ambiguous)
        }

        func markAmbiguousRule(_ deadline: StoredDeadline, ruleID knownRuleID: String? = nil) {
            guard let ruleID = knownRuleID ?? deadline.provenance?.ruleID else { return }
            var assessments = out.deadlineAssessments ?? []
            if let index = assessments.firstIndex(where: { $0.ruleID == ruleID }) {
                assessments[index].statusRaw = DeadlineAssessmentStatus.needsLegalReview.rawValue
            } else {
                assessments.append(DeadlineRuleAssessment(
                    ruleID: ruleID, kind: deadline.kind,
                    statusRaw: DeadlineAssessmentStatus.needsLegalReview.rawValue))
            }
            out.deadlineAssessments = assessments
        }

        for previous in old.deadlines {
            if let movement {
                switch DeadlineRuleEngine.historicalAppealDeadlineEvidence(
                    for: previous, in: old, movement: movement, context: context) {
                case .provenFalse:
                    var invalid = previous
                    if invalid.isActive { invalid.lifecycleRaw = DeadlineLifecycle.superseded.rawValue }
                    historical.append(invalid)
                    continue
                case .ambiguous(let ruleID):
                    let candidates = fresh.indices.filter {
                        fresh[$0].kind == previous.kind && fresh[$0].isActive
                    }
                    let hasKnownActiveOccurrence = candidates.contains {
                        fresh[$0].occurrenceKey.map { activeExactKeys.contains($0) } ?? false
                    }
                    if previous.isActive, !hasKnownActiveOccurrence {
                        historical.append(previous)
                        ambiguousPreserved.append(previous)
                        suppressedFresh.formUnion(candidates)
                        if let ruleID { markAmbiguousRule(previous, ruleID: ruleID) }
                        for index in candidates { markAmbiguousRule(fresh[index]) }
                        continue
                    }
                case .none: break
                }
            }
            let exactIndex = freshIndex(matching: previous)
            let transition: (proved: Int?, ambiguous: [Int]) = exactIndex == nil
                ? issue125Matches(previous) : (proved: nil, ambiguous: [])
            if exactIndex == nil, let index = transition.proved,
               let key = fresh[index].occurrenceKey, activeExactKeys.contains(key) {
                var superseded = previous
                if superseded.isActive {
                    superseded.lifecycleRaw = DeadlineLifecycle.superseded.rawValue
                }
                historical.append(superseded)
                continue
            }
            if let index = exactIndex ?? transition.proved {
                usedFresh.insert(index)
                let changingRule = storedRuleID(previous, in: old)
                    != fresh[index].provenance?.ruleID
                // An inactive occurrence is immutable, even if a later source
                // refresh happens to expose its old trigger again.
                if !previous.isActive {
                    historical.append(previous)
                    if fresh[index].occurrenceKey.map({ !activeExactKeys.contains($0) }) ?? true {
                        suppressedFresh.insert(index)
                        if changingRule { markAmbiguousRule(fresh[index]) }
                    }
                    continue
                }
                if previous.isUserControlled {
                    if !changingRule || previous.status == .overridden {
                        fresh[index].dateRef = previous.dateRef
                        fresh[index].statusRaw = previous.statusRaw
                    } else {
                        // A confirmed month-long calculation is not confirmation
                        // of the newly applicable private-complaint deadline.
                        fresh[index].statusRaw = DeadlineStatus.proposed.rawValue
                    }
                }
                continue
            }

            if !transition.ambiguous.isEmpty {
                historical.append(previous)
                let indices = transition.ambiguous
                let exactCurrentOccurrence = indices.contains { index in
                    fresh[index].occurrenceKey.map { activeExactKeys.contains($0) } ?? false
                }
                if !exactCurrentOccurrence {
                    // Keep an opaque legacy choice visible until its source act
                    // can be recovered; do not place a competing calculated date.
                    suppressedFresh.formUnion(indices)
                    for index in indices { markAmbiguousRule(fresh[index]) }
                } else {
                    for index in indices where fresh[index].occurrenceKey.map({
                        !activeExactKeys.contains($0)
                    }) ?? true {
                        suppressedFresh.insert(index)
                        markAmbiguousRule(fresh[index])
                    }
                    if previous.isActive {
                        historical[historical.count - 1].lifecycleRaw =
                            DeadlineLifecycle.superseded.rawValue
                    }
                }
                continue
            }

            let opaqueCandidates = opaqueIssue125LegacyCandidates(
                previous, old: old, deadlines: fresh, movement: movement, today: today)
            if !opaqueCandidates.isEmpty {
                let unproven = opaqueCandidates.filter { index in
                    fresh[index].occurrenceKey.map { !activeExactKeys.contains($0) } ?? true
                }
                var preserved = previous
                if unproven.isEmpty, preserved.isActive {
                    preserved.lifecycleRaw = DeadlineLifecycle.superseded.rawValue
                }
                historical.append(preserved)
                suppressedFresh.formUnion(unproven)
                for index in unproven { markAmbiguousRule(fresh[index]) }
                continue
            }

            // Legacy snapshots have no occurrence key. A user-controlled
            // deadline migrates only when its source can be recovered uniquely.
            if let index = recoverableLegacyDeadlineIndex(
                previous, old: old, fresh: snap, deadlines: fresh,
                excluding: usedFresh) {
                usedFresh.insert(index)
                if !previous.isActive {
                    historical.append(previous)
                    if fresh[index].occurrenceKey.map({ !activeExactKeys.contains($0) }) ?? true {
                        suppressedFresh.insert(index)
                    }
                    continue
                }
                if previous.isUserControlled {
                    fresh[index].dateRef = previous.dateRef
                    fresh[index].statusRaw = previous.statusRaw
                }
                continue
            }

            // A manual decision takes precedence over an incomplete refresh.
            // It becomes superseded only when the fresh source actually
            // proves a different occurrence of the same kind. This also keeps
            // a confirmed date safe while a portal temporarily omits a row.
            if previous.isUserControlled,
               !fresh.contains(where: { $0.kind == previous.kind }) {
                historical.append(previous)
            } else if preserveActiveProposedWhenMissing,
                      previous.isActive,
                      previous.status == .proposed,
                      !fresh.contains(where: { $0.kind == previous.kind }) {
                // A partial source cannot disprove an otherwise active
                // calculated deadline. A complete refresh still supersedes it.
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
        return applyingDeadlineRetention(to: out, today: today, preserving: ambiguousPreserved)
    }

    /// The old kind-only fallback could attach an opaque manual date to a
    /// different trigger. Recover only from a unique applicable rule and the
    /// unchanged, uniquely matching source session.
    static func recoverableLegacyDeadlineIndex(
        _ previous: StoredDeadline,
        old: CaseSnapshot,
        fresh freshSnapshot: CaseSnapshot,
        deadlines: [StoredDeadline],
        excluding used: Set<Int> = []
    ) -> Int? {
        guard previous.occurrenceKey == nil,
              hasSameDeadlineSource(old, freshSnapshot),
              let index = deadlines.indices.first(where: {
                  !used.contains($0) && deadlines[$0].isActive
                      && deadlines[$0].kind == previous.kind
              }),
              deadlines.indices.filter({
                  !used.contains($0) && deadlines[$0].isActive
                      && deadlines[$0].kind == previous.kind
              }).count == 1,
              let current = deadlines[index].provenance,
              freshSnapshot.sessions.filter({ matches($0, current.trigger) }).count == 1,
              old.sessions.filter({ matches($0, current.trigger) }).count == 1
        else { return nil }

        if let provenance = previous.provenance {
            return provenance.ruleID == current.ruleID
                && provenance.trigger == current.trigger ? index : nil
        }

        let applicable = old.deadlineAssessments?.filter {
            $0.kind == previous.kind && $0.status == .applicable
        } ?? []
        return applicable.count == 1 && applicable[0].ruleID == current.ruleID ? index : nil
    }

    /// Opaque user decisions cannot be attached to a new occurrence by kind.
    /// When the same tracked case now has one private-complaint candidate and
    /// no recoverable old-rule identity, keep the decision visible and ask for
    /// review instead of silently replacing it or publishing a competing date.
    static func opaqueIssue125LegacyCandidates(
        _ previous: StoredDeadline,
        old: CaseSnapshot,
        deadlines: [StoredDeadline],
        movement: CaseMovement?,
        today: Date = DateUtil.today
    ) -> [Int] {
        let retainableProposed = previous.status == .proposed && previous.isActive
            && DateUtil.startOfDay(previous.date) >= DateUtil.startOfDay(today)
        guard previous.kind == "appeal", (previous.isUserControlled || retainableProposed),
              previous.occurrenceKey == nil, previous.provenance == nil,
              let movement,
              !CaseOriginResolver.normalizedUID(old.uid).isEmpty,
              CaseOriginResolver.normalizedUID(movement.uid)
                == CaseOriginResolver.normalizedUID(old.uid),
              !(old.deadlineAssessments ?? []).contains(where: {
                  $0.kind == previous.kind && $0.status == .applicable
                      && ["GPK-APPEAL-GENERAL", "KAS-APPEAL-GENERAL",
                          "KAS-APPEAL-ELECTION"].contains($0.ruleID)
              })
        else { return [] }

        let candidates = deadlines.indices.filter { index in
            guard deadlines[index].isActive,
                  deadlines[index].kind == previous.kind,
                  let ruleID = deadlines[index].provenance?.ruleID else { return false }
            return ["GPK-PRIVATE-COMPLAINT-GENERAL", "KAS-PRIVATE-GENERAL",
                    "KAS-PRIVATE-ELECTION"].contains(ruleID)
        }
        return candidates.count == 1 ? candidates : []
    }

    private static func storedRuleID(_ deadline: StoredDeadline,
                                     in snapshot: CaseSnapshot) -> String? {
        if let ruleID = deadline.provenance?.ruleID { return ruleID }
        if let key = deadline.occurrenceKey, let separator = key.firstIndex(of: "|") {
            return String(key[..<separator])
        }
        let applicable = snapshot.deadlineAssessments?.filter {
            $0.kind == deadline.kind && $0.status == .applicable
        } ?? []
        return applicable.count == 1 ? applicable[0].ruleID : nil
    }

    private static func hasSameDeadlineSource(_ old: CaseSnapshot,
                                              _ fresh: CaseSnapshot) -> Bool {
        (old.uid == fresh.uid && !old.uid.isEmpty
            || old.sessions.contains(where: { $0.sourceCardID != nil })
                && old.sessions.contains { oldSession in
                    fresh.sessions.contains { $0.sourceCardID == oldSession.sourceCardID }
                })
            && old.sessions.count == fresh.sessions.count
            && zip(old.sessions, fresh.sessions).allSatisfy { previous, current in
                previous.hasSameRefreshSource(as: current)
                    && (previous.sourceCardID == current.sourceCardID
                        || previous.sourceCardID == nil || current.sourceCardID == nil)
            }
    }

    private static func matches(_ session: StoredSession,
                                _ trigger: DeadlineTriggerProvenance) -> Bool {
        session.dateRaw == trigger.dateRaw && session.event == trigger.event
            && session.result == trigger.result && session.court == trigger.court
            && session.levelRaw == trigger.levelRaw
            && (session.caseNumber == trigger.caseNumber || session.caseNumber == nil)
    }

    /// Startup normally never revives inactive occurrences. The sole repair is
    /// an orphaned proposed deadline that a previous partial refresh wrongly
    /// superseded, while the cached movement still proves the exact same rule
    /// and trigger. Any uncertainty leaves the historical record untouched.
    static func repairingOrphanedSupersededProposedDeadlines(
        old: CaseSnapshot,
        fresh: CaseSnapshot,
        today: Date = DateUtil.today
    ) -> CaseSnapshot {
        var repaired = old
        for index in repaired.deadlines.indices {
            let stored = repaired.deadlines[index]
            guard deadlineScopeKey(stored) == nil,
                  stored.lifecycle == .superseded,
                  stored.status == .proposed,
                  let key = stored.occurrenceKey,
                  let provenance = stored.provenance,
                  old.deadlineAssessments?.contains(where: {
                      $0.ruleID == provenance.ruleID && $0.status == .applicable
                  }) == true,
                  repaired.deadlines.filter({ $0.kind == stored.kind && deadlineScopeKey($0) == nil }).count == 1,
                  fresh.deadlines.filter({ $0.kind == stored.kind && deadlineScopeKey($0) == nil }).count == 1,
                  let candidate = fresh.deadlines.first(where: {
                      $0.isActive
                          && $0.kind == stored.kind
                          && $0.occurrenceKey == key
                          && $0.provenance == provenance
                          && DateUtil.daysBetween($0.date, today) <= AppRouter.deadlineGraceDays
                  }),
                  fresh.deadlineAssessments?.contains(where: {
                      $0.ruleID == candidate.provenance?.ruleID && $0.status == .applicable
                  }) == true
            else { continue }
            repaired.deadlines[index].lifecycleRaw = DeadlineLifecycle.active.rawValue
        }
        return repaired
    }

    private static func applyingDeadlineRetention(to snapshot: CaseSnapshot,
                                                   today: Date,
                                                   preserving protected: [StoredDeadline] = []) -> CaseSnapshot {
        var out = snapshot
        out.deadlines = out.deadlines.map { deadline in
            guard !protected.contains(deadline), deadline.isActive,
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
        func comparableInstances(_ movement: CaseMovement) -> [CaseInstance] {
            CaseLifecycleResolver.realInstances(in: movement).map {
                var instance = $0
                instance.sourceEvidence = nil
                return instance
            }.sorted(by: MovementService.precedesInChronology)
        }
        return lhs.uid == rhs.uid
            && lhs.caseNumber == rhs.caseNumber
            && lhs.inForce == rhs.inForce
            && comparableInstances(lhs) == comparableInstances(rhs)
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

    static func deadlineEvaluation(from movement: CaseMovement,
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
        var result = DeadlineRuleEngine.evaluate(
            registry: registry, movement: movement,
            context: engineContext, timeline: timeline, today: today)
        for item in materialDeadlineEvaluations(from: movement, context: context, today: today) {
            result.deadlines += item.evaluation.deadlines.map { deadline in
                var value = deadline
                value.calLabel += " · материал № " + CaseNumberPresentation.primary(item.caseNumber)
                return value
            }
        }
        return result
    }

    struct MaterialDeadlineEvaluation: Identifiable {
        var id: String
        var caseNumber: String
        var evaluation: DeadlineRuleEngine.Evaluation
    }

    static func materialDeadlineEvaluations(from movement: CaseMovement,
                                           context: MovementContext,
                                           today: Date = DateUtil.today) -> [MaterialDeadlineEvaluation] {
        guard let registry = try? LegalDeadlineRegistry.load() else { return [] }
        return MaterialDeadlineScope.proven(in: movement, context: context).map { subject in
            let evaluation = DeadlineRuleEngine.evaluate(registry: registry,
                movement: subject.movement, context: .init(movementContext: subject.context),
                timeline: CaseLifecycleResolver.timeline(in: subject.movement,
                    production: subject.classification.production, verifiedMaterialScope: true), today: today,
                classification: subject.classification, materialSourceCardID: subject.sourceCardID)
            return MaterialDeadlineEvaluation(id: subject.sourceCardID,
                caseNumber: subject.movement.caseNumber, evaluation: evaluation)
        }
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
        case .koap:
            let principals = p.koapPrincipalMembers
            if !principals.isEmpty { return namesShort(principals.map(\.name)) }
            if let col = p.displayColumns.first, let member = col.members.first {
                return member.name + (member.sub.map { " · \($0)" } ?? " · \(col.title)")
            }
        case .upk, .special:
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

    /// Вторая строка ячейки «Списком» для УПК (второй подсудимый или «и N
    /// других»); nil, когда подсудимый один или это другой вид производства.
    static func partiesSecondLine(_ p: CaseParties) -> PartiesSecondLine? {
        guard p.kind != .koap else { return nil }
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
