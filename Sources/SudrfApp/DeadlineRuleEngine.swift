import Foundation
import SudrfKit

// MARK: - Registry-to-case evidence contract

/// Поля движения, которые может потребовать typed binding. Норма, формула и
/// источник намеренно здесь не дублируются: они всегда принадлежат registry.
enum DeadlineEvidenceRequirement: String, Codable, CaseIterable, Equatable {
    case production
    case caseCategory
    case actType
    case finalAct
    case finalForm
    case deliveryOrReceipt
    case legalForce
    case motivatedAppealDetermination
}

typealias DeadlineAssessmentStatus = DeadlineRuleSupport

/// Точная строка движения, на которой основан trigger. Это не новый event ID:
/// identity намеренно остаётся локальной provenance срока до #155.
struct DeadlineTriggerProvenance: Codable, Equatable {
    var event: String
    var result: String?
    var dateRaw: String
    var court: String
    var levelRaw: String
    var caseNumber: String
}

/// Данные, которые были использованы для рассчитанной даты. Все текстовые
/// нормативные поля сюда копируются из runtime registry при расчёте, а не из
/// typed binding.
struct DeadlineProvenance: Codable, Equatable {
    var ruleID: String
    var registryRevision: Int
    /// Hash of the Docs source represented by this registry revision. Optional
    /// keeps previously persisted #70 snapshots decodable if this field grows.
    var sourceHash: String? = nil
    var trigger: DeadlineTriggerProvenance
    var policyIDs: [String]
    var formula: String
    var source: String
    var calculatedDateRef: Double
    /// Версии производственного календаря и точный путь календарной
    /// арифметики. Optional сохраняет декодирование уже сохранённых сроков.
    var calendarTrace: LegalCalendarTrace? = nil
}

/// Результат рассмотрения известного registry rule. Он сохраняется в snapshot,
/// чтобы lifecycle и будущая UI-проекция видели разницу между отсутствующим
/// сроком и отсутствующим доказательством.
struct DeadlineRuleAssessment: Codable, Equatable, Identifiable {
    var id: String { ruleID }
    var ruleID: String
    /// Пользовательский вид срока (`appeal` / `cassation`), заданный binding.
    /// Нужен lifecycle только для различения terminal first-instance case.
    var kind: String = "appeal"
    var statusRaw: String
    var missingEvidenceRaw: [String] = []
    var missingPolicyIDs: [String] = []

    var status: DeadlineAssessmentStatus {
        DeadlineAssessmentStatus(rawValue: statusRaw) ?? .notApplicable
    }

    /// Rule распознан, но честный расчёт невозможен без недостающего факта или
    /// политики. Lifecycle показывает это предупреждение, но не считает его
    /// бессрочным доказательством активного производства.
    var isIndeterminate: Bool {
        switch status {
        case .insufficientEvidence, .unsupportedCalculation, .needsLegalReview:
            true
        case .applicable, .notApplicable:
            false
        }
    }
}

// MARK: - Rules engine

/// Registry-backed calculation. `Binding` contains only the connection between
/// a source rule ID and evidence available in `CaseMovement`; it intentionally
/// owns no normative title, formula, source, or note.
enum DeadlineRuleEngine {
    struct Context {
        var movementContext: MovementContext?
        /// A manually evidenced delivery/receipt date. The regular card model
        /// does not yet expose this fact, so the normal refresh path leaves it
        /// nil and produces `insufficientEvidence` for the KoAP rule.
        var deliveryOrReceipt: DeadlineTriggerProvenance?

        init(movementContext: MovementContext?,
             deliveryOrReceipt: DeadlineTriggerProvenance? = nil) {
            self.movementContext = movementContext
            self.deliveryOrReceipt = deliveryOrReceipt
        }
    }

    struct Evaluation {
        var deadlines: [StoredDeadline]
        var assessments: [DeadlineRuleAssessment]
    }

    private enum TriggerMode {
        case decisionFinalForm
        case decision
        case blockingDetermination
        case finalAct
        case koapInitialReceipt
        case koapSubsequentReceipt
        case koapReturnReceipt
        case gpkCassation
        case legalForce
    }

    private enum CategoryScope {
        case general
        case election
    }

    private struct Binding {
        var ruleID: String
        var kind: String
        var production: ProductionType
        var trigger: TriggerMode
        var categoryScope: CategoryScope = .general
    }

    private enum TriggerExtraction {
        case found(DeadlineTriggerProvenance)
        case missing([DeadlineEvidenceRequirement])
        case notApplicable
    }

    private enum CurrentFirstInstanceAct {
        case missing
        case unsupported
        case decision(DeadlineTriggerProvenance)
        case blockingDetermination(DeadlineTriggerProvenance)
        case ambiguous
    }

    private enum BlockingDisposition: Equatable {
        case claimReturned
        case refusalToAccept
        case leftWithoutConsideration
        case proceedingTerminated
    }

    enum Issue125TransitionProof {
        case proved
        case ambiguous
        case none
    }

    private enum DateCalculation {
        case calculated(Calculation)
        case unsupported([String])
    }

    /// Only explicitly approved Docs rules are activated here. The full catalog
    /// remains available in the registry for #222 without a second maintained list.
    private static let bindings = [
        Binding(ruleID: "GPK-APPEAL-GENERAL", kind: "appeal", production: .civil,
                trigger: .decisionFinalForm),
        Binding(ruleID: "GPK-PRIVATE-COMPLAINT-GENERAL", kind: "appeal", production: .civil,
                trigger: .blockingDetermination),
        Binding(ruleID: "KAS-APPEAL-GENERAL", kind: "appeal", production: .kas,
                trigger: .decisionFinalForm),
        Binding(ruleID: "KAS-APPEAL-ELECTION", kind: "appeal", production: .kas,
                trigger: .decision, categoryScope: .election),
        Binding(ruleID: "KAS-PRIVATE-GENERAL", kind: "appeal", production: .kas,
                trigger: .blockingDetermination),
        Binding(ruleID: "KAS-PRIVATE-ELECTION", kind: "appeal", production: .kas,
                trigger: .blockingDetermination, categoryScope: .election),
        Binding(ruleID: "UPK-APPEAL-GENERAL", kind: "appeal", production: .crim,
                trigger: .finalAct),
        Binding(ruleID: "KOAP-APPEAL-INITIAL-GENERAL", kind: "appeal", production: .koap,
                trigger: .koapInitialReceipt),
        Binding(ruleID: "KOAP-APPEAL-INITIAL-ELECTION", kind: "appeal", production: .koap,
                trigger: .koapInitialReceipt, categoryScope: .election),
        Binding(ruleID: "KOAP-APPEAL-SUBSEQUENT-GENERAL", kind: "appeal", production: .koap,
                trigger: .koapSubsequentReceipt),
        Binding(ruleID: "KOAP-APPEAL-SUBSEQUENT-ELECTION", kind: "appeal", production: .koap,
                trigger: .koapSubsequentReceipt, categoryScope: .election),
        Binding(ruleID: "KOAP-APPEAL-RETURN-DETERMINATION-ONE-SUTKI", kind: "appeal",
                production: .koap, trigger: .koapReturnReceipt),
        Binding(ruleID: "GPK-CASSATION-CSOY", kind: "cassation", production: .civil,
                trigger: .gpkCassation),
        Binding(ruleID: "KAS-CASSATION-KSOYU", kind: "cassation", production: .kas,
                trigger: .legalForce),
    ]

    static func evaluate(registry: LegalDeadlineRegistry, movement: CaseMovement,
                         context: Context, timeline: CaseLifecycleResolver.Timeline,
                         today: Date) -> Evaluation {
        let classification = MaterialProductionContext.resolve(
            context: context.movementContext, movement: movement)
        guard let production = classification.production else {
            return Evaluation(deadlines: [], assessments: [])
        }

        var deadlines: [StoredDeadline] = []
        var assessments: [DeadlineRuleAssessment] = []
        // Bundled calendar is immutable for a running app. Decode it once:
        // store preparation may re-evaluate hundreds of cached dossiers.
        // Its absence blocks only rules needing calendar arithmetic.
        let calendar = packagedCalendar
        for binding in bindings where binding.production == production
            && (!classification.isMaterial || supportsMaterial(binding)) {
            if classification.isMaterial,
               !materialDispositionApplies(binding, timeline: timeline) { continue }
            guard let rule = registry.rule(id: binding.ruleID) else {
                assessments.append(assessment(ruleID: binding.ruleID, kind: binding.kind,
                                               status: .needsLegalReview))
                continue
            }

            let result = evaluate(binding: binding, rule: rule, registry: registry,
                                  movement: movement, context: context, timeline: timeline,
                                  today: today, calendar: calendar)
            assessments.append(result.assessment)
            if let deadline = result.deadline { deadlines.append(deadline) }
        }
        return Evaluation(deadlines: deadlines, assessments: assessments)
    }

    /// A missing packaged registry must not silently restore the historical
    /// fallback or close a terminal case. The known typed candidates remain
    /// visible as requiring review until the resource is restored.
    static func unavailable(context: Context) -> Evaluation {
        let classification = MaterialProductionContext.resolve(
            context: context.movementContext, movement: nil)
        guard !classification.isMaterial, let production = classification.production else {
            return Evaluation(deadlines: [], assessments: [])
        }
        return Evaluation(deadlines: [], assessments: bindings
            .filter { $0.production == production
                && (!classification.isMaterial || supportsMaterial($0)) }
            .map { assessment(ruleID: $0.ruleID, kind: $0.kind,
                              status: .needsLegalReview) })
    }

    static func provesIssue125Transition(
        from previous: StoredDeadline, to fresh: StoredDeadline,
        movement: CaseMovement, context: MovementContext?, oldSnapshot: CaseSnapshot
    ) -> Issue125TransitionProof {
        guard previous.kind == "appeal", fresh.kind == "appeal" else { return .none }
        guard let freshProvenance = fresh.provenance else {
            guard previous.status == .proposed else { return .none }
            let warnings = (oldSnapshot.deadlineAssessments ?? []).filter {
                $0.kind == "appeal" && $0.status == .needsLegalReview
                    && ["GPK-PRIVATE-COMPLAINT-GENERAL", "KAS-PRIVATE-GENERAL",
                        "KAS-PRIVATE-ELECTION"].contains($0.ruleID)
            }
            guard !warnings.isEmpty else { return .none }
            let classification = MaterialProductionContext.resolve(context: context, movement: movement)
            let timeline = CaseLifecycleResolver.timeline(
                in: movement, production: classification.production)
            guard let first = timeline.deadlineFirst,
                  case .blockingDetermination = currentFirstInstanceAct(in: first) else { return .none }
            let matchingWarning = warnings.contains { warning in
                let isGPK = warning.ruleID == "GPK-PRIVATE-COMPLAINT-GENERAL"
                guard classification.production == (isGPK ? .civil : .kas) else { return false }
                if warning.ruleID == "KAS-PRIVATE-ELECTION" {
                    return isElectionCategory(movement.category)
                }
                return !categorySelectsSpecialRule(movement.category,
                                                   code: isGPK ? "GPK" : "KAS",
                                                   forRule: warning.ruleID)
            }
            return matchingWarning ? .ambiguous : .none
        }
        let oldUID = CaseOriginResolver.normalizedUID(oldSnapshot.uid)
        let currentUID = CaseOriginResolver.normalizedUID(movement.uid)
        guard oldUID.isEmpty || currentUID.isEmpty || oldUID == currentUID else { return .none }
        let classification = MaterialProductionContext.resolve(context: context, movement: movement)
        let code = freshProvenance.ruleID.hasPrefix("GPK-") ? "GPK" : "KAS"
        let expectedProduction: ProductionType = code == "GPK" ? .civil : .kas
        guard classification.production == expectedProduction else { return .none }
        let category = normalized(movement.category)
        guard !category.isEmpty else { return .none }
        let categoryAllowsTarget = freshProvenance.ruleID == "KAS-PRIVATE-ELECTION"
            ? code == "KAS" && isElectionCategory(category)
            : !categorySelectsSpecialRule(category, code: code,
                                          forRule: freshProvenance.ruleID)
        guard categoryAllowsTarget else { return .none }

        let timeline = CaseLifecycleResolver.timeline(in: movement, production: expectedProduction)
        guard let first = timeline.deadlineFirst else { return .ambiguous }
        guard case .blockingDetermination(let currentTrigger) = currentFirstInstanceAct(in: first)
        else { return .none }
        guard freshProvenance.trigger == currentTrigger,
              fresh.occurrenceKey == occurrenceKey(
                ruleID: freshProvenance.ruleID, timeline: timeline,
                movement: movement, trigger: currentTrigger) else { return .none }

        let applicableOldRules = (oldSnapshot.deadlineAssessments ?? []).filter {
            $0.kind == previous.kind && $0.status == .applicable
                && ["GPK-APPEAL-GENERAL", "KAS-APPEAL-GENERAL",
                    "KAS-APPEAL-ELECTION"].contains($0.ruleID)
        }
        let oldRuleID = previous.provenance?.ruleID
            ?? previous.occurrenceKey.flatMap(occurrenceRule)
            ?? (applicableOldRules.count == 1 ? applicableOldRules[0].ruleID : nil)
        guard let oldRuleID,
              isIssue125RulePair(oldRuleID, freshProvenance.ruleID),
              oldRuleID.hasPrefix(code) else {
            let targetWarningRemains = (oldSnapshot.deadlineAssessments ?? []).contains {
                $0.ruleID == freshProvenance.ruleID && $0.kind == previous.kind
                    && $0.status == .needsLegalReview
            }
            if previous.status == .proposed && targetWarningRemains { return .ambiguous }
            return previous.isUserControlled ? .ambiguous : .none
        }

        let oldTrigger: DeadlineTriggerProvenance?
        if let trigger = previous.provenance?.trigger {
            oldTrigger = trigger
        } else if let oldKey = previous.occurrenceKey {
            oldTrigger = storedTrigger(oldKey, ruleID: oldRuleID, snapshot: oldSnapshot,
                                       matching: first, context: context)
        } else {
            oldTrigger = recoveredLegacyTrigger(ruleID: oldRuleID, snapshot: oldSnapshot,
                                                matching: first, current: currentTrigger,
                                                context: context)
        }
        guard let oldTrigger else { return .ambiguous }
        guard sameTriggerCard(oldTrigger, currentTrigger, instance: first) else { return .none }
        guard sameDay(oldTrigger.dateRaw, currentTrigger.dateRaw) else { return .ambiguous }
        guard storedSessions(oldSnapshot, contain: oldTrigger, matching: first,
                             context: context) else { return .ambiguous }
        if let oldKey = previous.occurrenceKey {
            guard let oldRound = occurrenceRound(oldKey, ruleID: oldRuleID) else { return .ambiguous }
            let currentRound = timeline.currentRoundStart?.instance.id
                ?? timeline.deadlineFirst?.id ?? movement.uid
            guard oldRound == currentRound else { return .none }
            guard oldKey == occurrenceKey(ruleID: oldRuleID, timeline: timeline,
                                          movement: movement, trigger: oldTrigger) else {
                return .ambiguous
            }
        }
        return oldTrigger == currentTrigger ? .proved : .ambiguous
    }

    enum HistoricalAppealDeadlineEvidence {
        case provenFalse(ruleID: String)
        case ambiguous(ruleID: String?)
        case none
    }

    /// A missing fresh act is not proof. Only a uniquely identified saved
    /// procedural row can disprove the old month-long appeal calculation.
    static func historicalAppealDeadlineEvidence(
        for previous: StoredDeadline, in snapshot: CaseSnapshot,
        movement: CaseMovement, context: MovementContext?
    ) -> HistoricalAppealDeadlineEvidence {
        guard previous.kind == "appeal" else { return .none }
        let production = MaterialProductionContext.resolve(context: context, movement: movement).production
        guard production == .civil || production == .kas else { return .none }
        let expectedRule = production == .civil ? "GPK-APPEAL-GENERAL" : "KAS-APPEAL-GENERAL"
        let legacyPattern = #"^1 месяц со дня решения \((\d{2}\.\d{2})\) — расчётный, проверьте$"#
        let legacyDate = previous.basis.range(of: legacyPattern, options: .regularExpression)
            .map { _ in String(previous.basis.dropFirst("1 месяц со дня решения (".count).prefix(5)) }
        let applicable = (snapshot.deadlineAssessments ?? []).filter {
            $0.kind == previous.kind && $0.status == .applicable
        }
        let ruleID = previous.provenance?.ruleID
            ?? previous.occurrenceKey.flatMap(occurrenceRule)
            ?? (legacyDate == nil && applicable.count == 1 ? applicable[0].ruleID : nil)
        if let ruleID, ruleID != expectedRule { return .none }
        guard ruleID != nil || legacyDate != nil else {
            return previous.isUserControlled ? .ambiguous(ruleID: expectedRule) : .none
        }
        let oldUID = CaseOriginResolver.normalizedUID(snapshot.uid)
        let newUID = CaseOriginResolver.normalizedUID(movement.uid)
        guard oldUID.isEmpty || newUID.isEmpty || oldUID == newUID else { return .none }
        let timeline = CaseLifecycleResolver.timeline(in: movement, production: production)
        guard let first = timeline.deadlineFirst else { return .ambiguous(ruleID: expectedRule) }
        let currentCard = context.map { CaseSnapshotSourceIdentity.sourceCardID(for: first, context: $0) }
        let savedRows = snapshot.sessions.filter { session in
            guard session.levelRaw == first.level.rawValue,
                  CaseOriginResolver.normalizedTitle(session.court)
                    == CaseOriginResolver.normalizedTitle(first.court),
                  session.sourceCardID == nil || currentCard == nil || session.sourceCardID == currentCard,
                  DateUtil.parse(session.dateRaw) != nil else { return false }
            if let number = session.caseNumber {
                return CaseOriginResolver.sameCaseNumber(number, first.caseNumber)
            }
            return currentCard != nil && session.sourceCardID == currentCard
        }
        let trigger: DeadlineTriggerProvenance?
        if let provenance = previous.provenance {
            trigger = provenance.trigger
        } else if let key = previous.occurrenceKey {
            trigger = storedTrigger(key, ruleID: expectedRule, snapshot: snapshot,
                                    matching: first, context: context)
        } else if let legacyDate {
            let rows = savedRows.filter { session in
                guard let date = DateUtil.parse(session.dateRaw) else { return false }
                return DateUtil.shortDM(date) == legacyDate
            }
            if rows.count == 1, let row = rows.first {
                trigger = DeadlineTriggerProvenance(event: row.event, result: row.result,
                    dateRaw: row.dateRaw, court: row.court, levelRaw: row.levelRaw,
                    caseNumber: row.caseNumber ?? first.caseNumber)
            } else { trigger = nil }
        } else {
            switch currentFirstInstanceAct(in: first) {
            case .decision(let current), .blockingDetermination(let current):
                trigger = recoveredLegacyTrigger(ruleID: expectedRule, snapshot: snapshot,
                                                 matching: first, current: current, context: context)
            default: trigger = nil
            }
        }
        guard let trigger, let triggerDate = DateUtil.parse(trigger.dateRaw),
              sameTriggerCard(trigger, trigger, instance: first),
              !previous.isActive || (timeline.currentRoundDate.map({ triggerDate >= $0 }) ?? true),
              storedSessions(snapshot, contain: trigger, matching: first, context: context)
        else { return .ambiguous(ruleID: expectedRule) }
        if let key = previous.occurrenceKey {
            guard storedTrigger(key, ruleID: expectedRule, snapshot: snapshot,
                                matching: first, context: context) == trigger else {
                return .ambiguous(ruleID: expectedRule)
            }
        }
        if previous.isActive, let key = previous.occurrenceKey {
            let round = timeline.currentRoundStart?.instance.id ?? first.id
            guard occurrenceRound(key, ruleID: expectedRule) == round else { return .none }
            guard key == occurrenceKey(ruleID: expectedRule, timeline: timeline,
                                       movement: movement, trigger: trigger) else {
                return .ambiguous(ruleID: expectedRule)
            }
        }
        if CaseLifecycleResolver.isFinalActAnnouncement(event: trigger.event, result: trigger.result)
            || blockingDisposition(normalized(trigger.event + " " + (trigger.result ?? ""))) != nil {
            return .none
        }
        if previous.isActive, first.sessions.contains(where: { session in
            sameDay(session.date, trigger.dateRaw)
                && (CaseLifecycleResolver.isFinalActAnnouncement(event: session.event, result: session.result)
                    || blockingDisposition(normalized(session.event + " " + (session.result ?? ""))) != nil)
        }) {
            return .ambiguous(ruleID: expectedRule)
        }
        guard !savedRows.contains(where: {
            sameDay($0.dateRaw, trigger.dateRaw)
                && (CaseLifecycleResolver.isFinalActAnnouncement(event: $0.event, result: $0.result)
                    || blockingDisposition(normalized($0.event + " " + ($0.result ?? ""))) != nil)
        }), !(previous.isActive
              && (first.sourceEvidence?.decisionDate.map { sameDay($0, trigger.dateRaw) } ?? false)),
              isKnownNonfinalStep(event: trigger.event, result: trigger.result) else {
            return .ambiguous(ruleID: expectedRule)
        }
        return .provenFalse(ruleID: expectedRule)
    }

    private static func isKnownNonfinalStep(event: String, result: String?) -> Bool {
        let heading = normalized(event).trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = normalized(result).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = heading + " " + outcome
        guard !CaseLifecycleResolver.isFinalActAnnouncement(event: event, result: result),
              blockingDisposition(value) == nil, !isFinalDecisionWording(value) else { return false }
        let positivePattern = #"^(?:иск принят к производству|иск \(заявление, жалоба\) принят к производству|оставление иска без движения|вынесено определение о подготовке дела к судебному разбирательству|вынесено определение о назначении дела к судебному разбирательству|(?:недостатки устранены;\s*)?(?:административное )?исковое заявление (?:принято к производству|оставлено без движения)|(?:дело|материалы) передан[оы] судье|передача материалов судье|рассмотрение исправленных материалов(?:, поступивших в суд)?|(?:определение о )?подготовк[аи] дела к судебному разбирательству|назначено судебное заседание|судебное заседание назначено|(?:судебное заседание|заседание|судебное разбирательство|административное дело|дело) отложено|отложено)[.!]?$"#
        func isPositive(_ text: String) -> Bool {
            text.range(of: positivePattern, options: .regularExpression) != nil
        }
        if outcome.isEmpty { return isPositive(heading) }
        guard isPositive(outcome) else { return false }
        return isPositive(heading) || ["определение", "судебное заседание",
            "судебное разбирательство", "решение вопроса о принятии иска к рассмотрению"].contains(heading)
            || heading.range(of: #"^решение вопроса о принятии (?:административного )?искового заявления(?: к производству| к рассмотрению)?$"#,
                             options: .regularExpression) != nil
    }

    private static func isIssue125RulePair(_ old: String, _ new: String) -> Bool {
        (old == "GPK-APPEAL-GENERAL" && new == "GPK-PRIVATE-COMPLAINT-GENERAL")
            || (old == "KAS-APPEAL-GENERAL"
                && ["KAS-PRIVATE-GENERAL", "KAS-PRIVATE-ELECTION"].contains(new))
            || (old == "KAS-APPEAL-ELECTION" && new == "KAS-PRIVATE-ELECTION")
    }

    private static func sameTriggerCard(_ lhs: DeadlineTriggerProvenance,
                                        _ rhs: DeadlineTriggerProvenance,
                                        instance: CaseInstance) -> Bool {
        lhs.levelRaw == rhs.levelRaw && lhs.levelRaw == instance.level.rawValue
            && CaseOriginResolver.sameCaseNumber(lhs.caseNumber, rhs.caseNumber)
            && CaseOriginResolver.sameCaseNumber(lhs.caseNumber, instance.caseNumber)
            && CaseOriginResolver.normalizedTitle(lhs.court)
                == CaseOriginResolver.normalizedTitle(rhs.court)
            && CaseOriginResolver.normalizedTitle(lhs.court)
                == CaseOriginResolver.normalizedTitle(instance.court)
    }

    private static func sameDay(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = DateUtil.parse(lhs), let right = DateUtil.parse(rhs) else { return false }
        return DateUtil.startOfDay(left) == DateUtil.startOfDay(right)
    }

    private static func storedSessions(_ snapshot: CaseSnapshot,
                                       contain trigger: DeadlineTriggerProvenance,
                                       matching instance: CaseInstance,
                                       context: MovementContext?) -> Bool {
        let currentCard = context.map { CaseSnapshotSourceIdentity.sourceCardID(for: instance, context: $0) }
        let matches = snapshot.sessions.filter { session in
            let cardMatches: Bool
            if let number = session.caseNumber {
                cardMatches = CaseOriginResolver.sameCaseNumber(number, trigger.caseNumber)
            } else if let sourceCardID = session.sourceCardID, let currentCard {
                cardMatches = sourceCardID == currentCard
            } else {
                cardMatches = false
            }
            return session.dateRaw == trigger.dateRaw && session.event == trigger.event
                && session.result == trigger.result && session.court == trigger.court
                && session.levelRaw == trigger.levelRaw
                && cardMatches
                && (session.sourceCardID == nil || currentCard == nil
                    || session.sourceCardID == currentCard)
        }
        return matches.count == 1
    }

    private static func storedTrigger(_ key: String, ruleID: String, snapshot: CaseSnapshot,
                                      matching instance: CaseInstance,
                                      context: MovementContext?) -> DeadlineTriggerProvenance? {
        guard let values = occurrenceIdentity(key, ruleID: ruleID), values.count == 6 else { return nil }
        let currentCard = context.map { CaseSnapshotSourceIdentity.sourceCardID(for: instance, context: $0) }
        let sessions = snapshot.sessions.filter { session in
            let cardMatches: Bool
            if let number = session.caseNumber {
                cardMatches = CaseOriginResolver.sameCaseNumber(number, values[2])
            } else if let sourceCardID = session.sourceCardID, let currentCard {
                cardMatches = sourceCardID == currentCard
            } else {
                cardMatches = false
            }
            return session.levelRaw == values[1] && cardMatches
                && session.dateRaw == values[3] && session.event == values[4]
                && (session.result ?? "") == values[5]
                && (session.sourceCardID == nil || currentCard == nil
                    || session.sourceCardID == currentCard)
        }
        guard sessions.count == 1, let session = sessions.first else { return nil }
        let trigger = DeadlineTriggerProvenance(
            event: session.event, result: session.result, dateRaw: session.dateRaw,
            court: session.court, levelRaw: session.levelRaw,
            caseNumber: session.caseNumber ?? values[2])
        return trigger
    }

    private static func recoveredLegacyTrigger(ruleID: String, snapshot: CaseSnapshot,
                                               matching instance: CaseInstance,
                                               current: DeadlineTriggerProvenance,
                                               context: MovementContext?) -> DeadlineTriggerProvenance? {
        let oldRuleAssessments = snapshot.deadlineAssessments?.filter {
            $0.ruleID == ruleID && $0.status == .applicable
        } ?? []
        guard oldRuleAssessments.count == 1 else { return nil }
        let currentCard = context.map { CaseSnapshotSourceIdentity.sourceCardID(for: instance, context: $0) }
        let cardSessions = snapshot.sessions.filter { session in
            guard session.levelRaw == instance.level.rawValue,
                  CaseOriginResolver.normalizedTitle(session.court)
                    == CaseOriginResolver.normalizedTitle(instance.court),
                  session.sourceCardID == nil || currentCard == nil
                    || session.sourceCardID == currentCard else { return false }
            if let number = session.caseNumber {
                return CaseOriginResolver.sameCaseNumber(number, instance.caseNumber)
            }
            return session.sourceCardID != nil && session.sourceCardID == currentCard
        }
        let possibleActs = cardSessions.filter { session in
            guard DateUtil.parse(session.dateRaw) != nil else { return false }
            let value = normalized(session.event + " " + (session.result ?? ""))
            return !isUnsupportedActWording(value)
                && (blockingDisposition(value) != nil
                    || CaseLifecycleResolver.isFinalActAnnouncement(
                        event: session.event, result: session.result))
        }
        guard possibleActs.count == 1, let session = possibleActs.first else { return nil }
        let savedTrigger = DeadlineTriggerProvenance(
            event: session.event, result: session.result, dateRaw: session.dateRaw,
            court: session.court, levelRaw: session.levelRaw,
            caseNumber: session.caseNumber ?? instance.caseNumber)
        guard savedTrigger == current,
              storedSessions(snapshot, contain: current, matching: instance, context: context) else {
            return nil
        }
        // The old assessment identifies the only candidate rule; the exact
        // source row must also be the sole dated final/blocking act for this card.
        return current
    }

    private static func occurrenceRule(_ key: String) -> String? {
        guard let separator = key.firstIndex(of: "|") else { return nil }
        return String(key[..<separator])
    }

    private static func occurrenceRound(_ key: String, ruleID: String) -> String? {
        occurrenceIdentity(key, ruleID: ruleID)?.first
    }

    private static func occurrenceIdentity(_ key: String, ruleID: String) -> [String]? {
        guard let separator = key.firstIndex(of: "|"),
              String(key[..<separator]) == ruleID,
              let data = Data(base64Encoded: String(key[key.index(after: separator)...])),
              let identity = String(data: data, encoding: .utf8) else { return nil }
        return identity.components(separatedBy: "\u{1F}")
    }

    private static func evaluate(binding: Binding, rule: LegalDeadlineRule,
                                 registry: LegalDeadlineRegistry, movement: CaseMovement,
                                 context: Context, timeline: CaseLifecycleResolver.Timeline,
                                 today: Date, calendar: LegalCalendar?)
        -> (deadline: StoredDeadline?, assessment: DeadlineRuleAssessment) {
        var rule = rule
        switch binding.kind {
        case "appeal":
            // A real higher-court card in the current round proves that this
            // appeal deadline is no longer an actionable candidate.
            guard !timeline.hasAppealInCurrentRound, !timeline.hasCassationInCurrentRound else {
                return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                        status: .notApplicable))
            }
        case "cassation":
            let reviews = timeline.lifecycleOrdered.map(\.instance)
            let provedVSRoute = reviews.contains { instance in
                if let start = timeline.currentRoundDate,
                   instance.sessions.compactMap({ DateUtil.parse($0.date) }).min().map({ $0 >= start }) != true {
                    return false
                }
                return instance.level == .cassation
                    && CaseLifecycleResolver.isConcludedReview(instance)
                    && !instance.sessions.contains {
                        CaseLifecycleResolver.semanticDisposition(event: $0.event, result: $0.result)?.hasPrefix("remand:") == true
                            || CaseLifecycleResolver.semanticDisposition(event: $0.event, result: $0.result) == "returned"
                    }
                    || instance.level == .appeal && instance.linkedActIDs.contains { id in
                        let tail = movement.actBodies[id].flatMap(CaseLifecycleResolver.operativeDisposition) ?? ""
                        let value = normalized(tail)
                        return value.contains("судебную коллегию")
                            && value.contains("верховного суда российской федерации")
                    }
            }
            if provedVSRoute, !reviews.contains(where: { instance in
                guard instance.level == .vsCassation || instance.level == .supervisory else { return false }
                guard let start = timeline.currentRoundDate else { return true }
                return instance.sessions.compactMap { DateUtil.parse($0.date) }.min().map { $0 >= start } == true
            }) {
                return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                        status: .unsupportedCalculation,
                                        missingPolicyIDs: ["vsrfCassationCalculation"]))
            }
            guard !timeline.hasCassationInCurrentRound else {
                return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                        status: .notApplicable))
            }
        default:
            return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                    status: .notApplicable))
        }

        guard routeApplies(binding, movement: movement, context: context.movementContext,
                           timeline: timeline) else {
            return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                    status: .notApplicable))
        }

        if binding.kind == "appeal", requiresKnownCategory(for: binding),
           normalized(movement.category).isEmpty {
            return insufficient(rule, binding: binding, [.caseCategory])
        }
        if binding.kind == "appeal" {
            switch binding.categoryScope {
            case .general where categorySelectsSpecialRule(
                movement.category, code: rule.code, forRule: rule.ruleID):
                // A known special category displaces the general rule.
                return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                        status: .notApplicable))
            case .election where !isElectionCategory(movement.category):
                return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                        status: .notApplicable))
            case .general, .election:
                break
            }
        }

        let triggerResult: TriggerExtraction
        switch binding.trigger {
        case .decisionFinalForm:
            guard let first = timeline.deadlineFirst else {
                return insufficient(rule, binding: binding, [.finalAct, .actType, .finalForm])
            }
            switch currentFirstInstanceAct(in: first) {
            case .decision:
                triggerResult = finalForm(in: first).map(TriggerExtraction.found)
                    ?? .missing([.finalForm])
            case .missing:
                triggerResult = .missing([.finalAct, .actType, .finalForm])
            case .unsupported, .blockingDetermination:
                triggerResult = .notApplicable
            case .ambiguous:
                triggerResult = .missing([.finalAct, .actType])
            }
        case .decision:
            guard let first = timeline.deadlineFirst else {
                return insufficient(rule, binding: binding, [.finalAct, .actType])
            }
            switch currentFirstInstanceAct(in: first) {
            case .decision(let act):
                triggerResult = .found(act)
            case .missing:
                triggerResult = .missing([.finalAct, .actType])
            case .unsupported, .blockingDetermination:
                triggerResult = .notApplicable
            case .ambiguous:
                triggerResult = .missing([.finalAct, .actType])
            }
        case .blockingDetermination:
            guard let first = timeline.deadlineFirst else {
                return insufficient(rule, binding: binding, [.finalAct, .actType])
            }
            switch currentFirstInstanceAct(in: first) {
            case .blockingDetermination(let act):
                triggerResult = .found(act)
            case .missing:
                triggerResult = .missing([.finalAct, .actType])
            case .unsupported, .decision:
                triggerResult = .notApplicable
            case .ambiguous:
                triggerResult = .missing([.finalAct, .actType])
            }
        case .finalAct:
            guard let first = timeline.deadlineFirst else {
                return insufficient(rule, binding: binding, [.finalAct, .actType])
            }
            guard let act = finalAct(in: first) else {
                return insufficient(rule, binding: binding, [.finalAct])
            }
            guard isGeneralCriminalAct(act) else {
                return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                        status: .notApplicable))
            }
            triggerResult = .found(act)
        case .koapInitialReceipt:
            guard let first = timeline.deadlineFirst else {
                return insufficient(rule, binding: binding, [.finalAct])
            }
            guard let act = koapInitialDecision(in: first) else {
                if koapReturnDetermination(in: first) != nil {
                    triggerResult = .notApplicable
                    break
                }
                triggerResult = finalAct(in: first) == nil
                    ? .missing([.finalAct, .actType]) : .notApplicable
                break
            }
            guard let receipt = explicitReceipt(in: first, supplied: context.deliveryOrReceipt,
                                                act: .initial, after: act) else {
                return insufficient(rule, binding: binding, [.deliveryOrReceipt])
            }
            triggerResult = .found(receipt)
        case .koapSubsequentReceipt:
            guard let first = timeline.deadlineFirst else {
                return insufficient(rule, binding: binding, [.finalAct])
            }
            guard let act = koapSubsequentDecision(in: first) else {
                triggerResult = finalAct(in: first) == nil
                    ? .missing([.finalAct, .actType]) : .notApplicable
                break
            }
            guard let receipt = explicitReceipt(in: first, supplied: context.deliveryOrReceipt,
                                                act: .subsequent, after: act) else {
                return insufficient(rule, binding: binding, [.deliveryOrReceipt])
            }
            triggerResult = .found(receipt)
        case .koapReturnReceipt:
            guard let first = timeline.deadlineFirst else {
                return insufficient(rule, binding: binding, [.finalAct])
            }
            guard let act = koapReturnDetermination(in: first) else {
                triggerResult = finalAct(in: first) == nil
                    ? .missing([.finalAct, .actType]) : .notApplicable
                break
            }
            guard let receipt = explicitReceipt(in: first, supplied: context.deliveryOrReceipt,
                                                act: .returnDetermination, after: act,
                                                exactMoment: true) else {
                return insufficient(rule, binding: binding, [.deliveryOrReceipt])
            }
            triggerResult = .found(receipt)
        case .gpkCassation:
            guard routeSupportsCSOY(context.movementContext) else {
                return insufficient(rule, binding: binding, [.production])
            }
            let appeal = currentAppeal(in: timeline)
            let appealAct = appeal.flatMap { instance in
                latestSession(in: instance) {
                    let value = normalized($0.event + " " + ($0.result ?? ""))
                    return CaseLifecycleResolver.isFinalActAnnouncement(event: $0.event, result: $0.result)
                        && !value.contains("возвращ") && !value.contains("возврат")
                        && !value.contains("без рассмотр")
                }
            }
            if let appeal {
                var announcedDates = Set(appeal.sessions.filter {
                    CaseLifecycleResolver.isFinalActAnnouncement(event: $0.event, result: $0.result)
                }.compactMap { DateUtil.parse($0.date) })
                if let date = appeal.sourceEvidence?.decisionDate.flatMap(DateUtil.parse) {
                    announcedDates.insert(date)
                }
                let linkedIDs = Set(appeal.linkedActIDs)
                announcedDates.formUnion(movement.acts.filter {
                    linkedIDs.contains($0.id) && $0.instanceLevel == appeal.level
                }.compactMap { DateUtil.parse($0.date) })
                if announcedDates.count > 1 {
                    return insufficient(rule, binding: binding, [.finalAct])
                }
            }
            let ownDatedResult = appeal.flatMap { instance -> DeadlineTriggerProvenance? in
                guard CaseLifecycleResolver.isConcludedReview(instance),
                      let result = instance.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      CaseLifecycleResolver.semanticDisposition(result: result) != "returned",
                      !instance.sessions.contains(where: {
                          CaseLifecycleResolver.semanticDisposition(event: $0.event, result: $0.result) == "returned"
                      }) else { return nil }
                let linkedIDs = Set(instance.linkedActIDs)
                let ownActDates = movement.acts.filter {
                    linkedIDs.contains($0.id) && $0.instanceLevel == instance.level
                        && DateUtil.parse($0.date) != nil
                }.map(\.date)
                guard let dateRaw = instance.sourceEvidence?.decisionDate
                    ?? (Set(ownActDates.compactMap(DateUtil.parse)).count == 1 ? ownActDates.first : nil),
                      DateUtil.parse(dateRaw) != nil else { return nil }
                return DeadlineTriggerProvenance(event: "Опубликованная дата принятия апелляционного определения",
                    result: result, dateRaw: dateRaw, court: instance.court,
                    levelRaw: instance.level.rawValue, caseNumber: instance.caseNumber)
            }
            let ownModernMotivated = appeal.flatMap { instance -> DeadlineTriggerProvenance? in
                guard CaseLifecycleResolver.isConcludedReview(instance),
                      !instance.sessions.contains(where: {
                          CaseLifecycleResolver.semanticDisposition(event: $0.event, result: $0.result) == "returned"
                      }),
                      CaseLifecycleResolver.semanticDisposition(result: instance.result) != "returned",
                      let motivated = motivatedAppealDetermination(in: instance, movement: movement),
                      DateUtil.parse(motivated.dateRaw).map({ $0 >= DateUtil.parse("01.09.2024")! }) == true
                else { return nil }
                return motivated
            }
            if timeline.hasAppealInCurrentRound, appealAct == nil, ownDatedResult == nil, ownModernMotivated == nil {
                return insufficient(rule, binding: binding, [.finalAct])
            }
            let force = timeline.deadlineFirst.flatMap(legalForce)
            guard let reference = appealAct ?? ownDatedResult ?? ownModernMotivated ?? force else {
                if let date = timeline.deadlineFirst?.sourceEvidence?.decisionDate.flatMap(DateUtil.parse),
                   date < DateUtil.parse("01.10.2019")! {
                    return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                            status: .unsupportedCalculation,
                                            missingPolicyIDs: ["historicalCassationRegime"]))
                }
                return insufficient(rule, binding: binding, [.legalForce])
            }
            guard let date = DateUtil.parse(reference.dateRaw) else {
                return insufficient(rule, binding: binding, [.legalForce])
            }
            if date < DateUtil.parse("01.10.2019")! {
                return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                        status: .unsupportedCalculation,
                                        missingPolicyIDs: ["historicalCassationRegime"]))
            }
            if date < DateUtil.parse("01.09.2024")! {
                guard let historical = registry.rule(id: "GPK-CASSATION-CSOY-2019") else {
                    return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                            status: .unsupportedCalculation,
                                            missingPolicyIDs: ["historicalCassationRegime"]))
                }
                rule = historical
                triggerResult = .found(reference)
            } else if appeal == nil {
                triggerResult = .found(reference)
            } else if let appeal, let motivated = motivatedAppealDetermination(in: appeal, movement: movement),
                      DateUtil.parse(motivated.dateRaw).map({ $0 >= date }) == true {
                triggerResult = .found(motivated)
            } else {
                return insufficient(rule, binding: binding, [.motivatedAppealDetermination])
            }
        case .legalForce:
            guard routeSupportsCSOY(context.movementContext) else {
                return insufficient(rule, binding: binding, [.production])
            }
            guard let first = timeline.deadlineFirst,
                  let legalForce = legalForce(in: first) else {
                return insufficient(rule, binding: binding, [.legalForce])
            }
            triggerResult = .found(legalForce)
        }

        switch triggerResult {
        case .notApplicable:
            return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                    status: .notApplicable))
        case .found, .missing:
            break
        }
        if timeline.hasAmbiguousAppealEffect {
            return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                    status: .needsLegalReview))
        }
        if case .missing(let requirements) = triggerResult {
            return insufficient(rule, binding: binding, requirements)
        }
        guard case let .found(trigger) = triggerResult else {
            return insufficient(rule, binding: binding, [])
        }

        if needsLegalReview(rule: rule, registry: registry, timeline: timeline) {
            return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                    status: .needsLegalReview))
        }

        switch calculate(rule: rule, triggerDate: triggerDate(for: rule, trigger: trigger),
                         registry: registry, calendar: calendar) {
        case .unsupported(let missingPolicies):
            return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                    status: .unsupportedCalculation,
                                    missingPolicyIDs: missingPolicies))
        case .calculated(let calculation):
            let formula = rule.duration.raw ?? rule.durationText ?? rule.duration.kind.rawValue
            let provenance = DeadlineProvenance(
                ruleID: rule.ruleID, registryRevision: rule.revision,
                sourceHash: rule.sourceHash, trigger: trigger,
                policyIDs: calculation.policyIDs, formula: formula, source: rule.source,
                calculatedDateRef: calculation.date.timeIntervalSinceReferenceDate,
                calendarTrace: calculation.calendarTrace)
            let deadline = StoredDeadline(
                kind: binding.kind, what: rule.stage,
                basis: "\(formula) · \(rule.trigger)",
                calLabel: "\(rule.stage.lowercased()) \(shortCaseNumber(movement.caseNumber))",
                dateRef: calculation.date.timeIntervalSinceReferenceDate,
                statusRaw: DeadlineStatus.proposed.rawValue,
                occurrenceKey: occurrenceKey(ruleID: rule.ruleID, timeline: timeline,
                                             movement: movement, trigger: trigger),
                provenance: provenance, lifecycleRaw: DeadlineLifecycle.active.rawValue)
            return (deadline, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                         status: .applicable))
        }
    }

    private struct Calculation {
        var date: Date
        var policyIDs: [String]
        var calendarTrace: LegalCalendarTrace?
    }

    /// `failure` means the registry requires a policy that this app does not
    /// implement yet. It never falls back to a weekday-only approximation.
    private static func calculate(rule: LegalDeadlineRule, triggerDate: Date?,
                                  registry: LegalDeadlineRegistry,
                                  calendar: LegalCalendar?)
        -> DateCalculation {
        guard let triggerDate, let value = rule.duration.value, value >= 0 else {
            return .unsupported([])
        }
        let codePolicies = registry.policies.filter { $0.code == rule.code }
        func policy(_ fragments: [String]) -> String? {
            codePolicies.first { candidate in
                fragments.allSatisfy { candidate.policyID.contains($0) }
            }?.policyID
        }
        func ids(_ values: String?...) -> [String] { values.compactMap { $0 } }
        let isElectionRule = rule.ruleID == "KAS-APPEAL-ELECTION"
            || rule.ruleID == "KAS-PRIVATE-ELECTION"
        let filingPolicyIDs: [String]
        if isElectionRule {
            filingPolicyIDs = ids(policy(["END", "POST", "NO", "SAFE", "HARBOR", "ELECTION"]))
        } else if rule.ruleID == "KAS-PRIVATE-GENERAL" {
            filingPolicyIDs = ids(policy(["END", "POST", "24H", "GENERAL"]))
        } else {
            filingPolicyIDs = []
        }
        let result: Date
        let policyIDs: [String]
        let endNonworking: String?
        var calendarTrace: LegalCalendarTrace?
        switch rule.duration.kind {
        case .months:
            guard let date = DateUtil.cal.date(byAdding: .month, value: value, to: triggerDate) else {
                return .unsupported([])
            }
            result = DateUtil.startOfDay(date)
            policyIDs = ids(policy(["START", "NEXT", "DAY"]),
                            policy(["MONTH", "CALENDAR"]))
            endNonworking = policy(["END", "NONWORKING"])
        case .years:
            guard let date = DateUtil.cal.date(byAdding: .year, value: value, to: triggerDate) else {
                return .unsupported([])
            }
            result = DateUtil.startOfDay(date)
            policyIDs = ids(policy(["START", "NEXT", "DAY"]),
                            policy(["MONTH", "CALENDAR"]))
            endNonworking = policy(["END", "NONWORKING"])
        case .calendarDays:
            result = DateUtil.addDays(triggerDate, value)
            policyIDs = ids(policy(["START", "NEXT", "DAY"]),
                            policy(["COUNTING", "DAY", "CALENDAR"])) + filingPolicyIDs
            endNonworking = isElectionRule ? nil : policy(["END", "NONWORKING"])
        case .calendarSutki:
            if rule.ruleID == "KOAP-APPEAL-RETURN-DETERMINATION-ONE-SUTKI" {
                result = triggerDate.addingTimeInterval(TimeInterval(value * 24 * 60 * 60))
                policyIDs = ids(policy(["COUNTING", "UNITS"]),
                                policy(["COUNTING", "SUTKI", "END"]),
                                policy(["NO", "NONWORKING", "ROLL", "SUTKI"]))
                endNonworking = nil
            } else {
                result = DateUtil.addDays(triggerDate, value)
                policyIDs = ids(policy(["COUNTING", "UNITS"]),
                                policy(["COUNTING", "SUTKI", "END"]))
                endNonworking = policy(["END", "NONWORKING"])
            }
        case .workingDays:
            guard let calendar,
                  let start = LegalCalendarDate(date: triggerDate,
                                                timeZone: proceduralTimeZone),
                  let calculated = calendar.addingWorkingDays(value, to: start,
                                                              forCode: rule.code),
                  let date = calculated.date.date(timeZone: proceduralTimeZone)
            else {
                return .unsupported(ids(policy(["COUNTING", "DAY"])))
            }
            return .calculated(Calculation(
                date: date,
                policyIDs: ids(policy(["COUNTING", "START", "NEXT", "DAY"]),
                               policy(["COUNTING", "DAY"]))
                    + filingPolicyIDs + calculated.trace.proceduralPolicyIDs,
                calendarTrace: calculated.trace))
        case .relative, .none:
            return .unsupported([])
        }

        // Перенос конца срока применяется только когда его требует policy
        // конкретного правила. Без покрытого календаря не подменяем праздники
        // проверкой выходных.
        if let endNonworking {
            guard let calendar,
                  let start = LegalCalendarDate(date: triggerDate,
                                                timeZone: proceduralTimeZone),
                  let endpoint = LegalCalendarDate(date: result,
                                                   timeZone: proceduralTimeZone),
                  calendar.day(on: start) != nil,
                  calendar.day(on: endpoint) != nil,
                  let moved = calendar.movingToNextWorkingDay(endpoint, forCode: rule.code),
                  let date = moved.date.date(timeZone: proceduralTimeZone)
            else {
                return .unsupported([endNonworking])
            }
            calendarTrace = moved.trace
            return .calculated(Calculation(date: date,
                                           policyIDs: policyIDs + [endNonworking]
                                               + moved.trace.proceduralPolicyIDs,
                                           calendarTrace: calendarTrace))
        }
        return .calculated(Calculation(date: result, policyIDs: policyIDs,
                                       calendarTrace: calendarTrace))
    }

    /// Одна и та же явно переданная зона используется для разбора даты суда и
    /// преобразования date-only результата обратно в `Date`.
    private static var proceduralTimeZone: TimeZone { DateUtil.cal.timeZone }

    private static let packagedCalendar: LegalCalendar? = try? LegalCalendar.load()

    private static func insufficient(_ rule: LegalDeadlineRule, binding: Binding,
                                     _ requirements: [DeadlineEvidenceRequirement])
        -> (deadline: StoredDeadline?, assessment: DeadlineRuleAssessment) {
        (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                         status: .insufficientEvidence, missingEvidence: requirements))
    }

    private static func assessment(ruleID: String, kind: String,
                                   status: DeadlineAssessmentStatus,
                                   missingEvidence: [DeadlineEvidenceRequirement] = [],
                                   missingPolicyIDs: [String] = []) -> DeadlineRuleAssessment {
        DeadlineRuleAssessment(ruleID: ruleID, kind: kind, statusRaw: status.rawValue,
                               missingEvidenceRaw: missingEvidence.map(\.rawValue),
                               missingPolicyIDs: missingPolicyIDs)
    }

    private static func requiresKnownCategory(for binding: Binding) -> Bool {
        binding.ruleID != "KOAP-APPEAL-RETURN-DETERMINATION-ONE-SUTKI"
            && (binding.production == .civil || binding.production == .kas
                || binding.production == .koap)
    }

    private static func supportsMaterial(_ binding: Binding) -> Bool {
        binding.ruleID == "GPK-PRIVATE-COMPLAINT-GENERAL"
            || binding.ruleID.hasPrefix("KAS-PRIVATE-")
            || binding.ruleID == "KOAP-APPEAL-RETURN-DETERMINATION-ONE-SUTKI"
    }

    private static func materialDispositionApplies(
        _ binding: Binding, timeline: CaseLifecycleResolver.Timeline
    ) -> Bool {
        guard let instance = timeline.deadlineFirst else { return false }
        if binding.ruleID == "GPK-PRIVATE-COMPLAINT-GENERAL"
            || binding.ruleID.hasPrefix("KAS-PRIVATE-") {
            switch currentFirstInstanceAct(in: instance) {
            case .blockingDetermination, .ambiguous: return true
            case .missing, .unsupported, .decision: return false
            }
        }
        return binding.ruleID == "KOAP-APPEAL-RETURN-DETERMINATION-ONE-SUTKI"
            && koapReturnDetermination(in: instance) != nil
    }

    private static func routeApplies(_ binding: Binding, movement: CaseMovement,
                                     context: MovementContext?,
                                     timeline: CaseLifecycleResolver.Timeline) -> Bool {
        guard binding.production == .koap else { return true }
        guard let context else { return false }
        let uid = [movement.uid, context.judicialUID ?? ""].compactMap { candidate -> String? in
            guard candidate.range(
                of: #"^\d{2}[A-ZА-Я]{2}\d{4}-\d{2}-\d{4}-\d{6}-\d{2}$"#,
                options: .regularExpression) != nil else { return nil }
            return candidate
        }.first
        let role = KoAPProceduralRole.resolve(
            courtLevel: context.courtLevel, cartotekaID: context.cartotekaId,
            judicialUID: uid,
            lowerCourtTitle: timeline.deadlineFirst?.sourceEvidence?.lowerCourt?.courtTitle)
        switch binding.trigger {
        case .koapInitialReceipt:
            return role == .firstInstance
                && latestKoAPFirstAct(in: timeline.deadlineFirst) != .returnDetermination
        case .koapReturnReceipt:
            return role == .firstInstance
                && latestKoAPFirstAct(in: timeline.deadlineFirst) == .returnDetermination
        case .koapSubsequentReceipt:
            return role == .authorityJudicialReview
        default:
            return true
        }
    }

    /// The binding needs only enough case taxonomy to avoid applying a general
    /// rule where Docs declares a special one. Activation of the selected
    /// special rule remains intentionally deferred to #222.
    private static func categorySelectsSpecialRule(_ category: String?, code: String,
                                                   forRule ruleID: String? = nil) -> Bool {
        let value = normalized(category)
        switch code {
        case "GPK":
            return ["упрощенн", "возвращени ребен", "доступ к ребен", "усынов",
                    "заочн", "иностранн государств"].contains { value.contains($0) }
        case "KAS":
            // Municipal subject matter displaces the monthly decision-appeal
            // rule, but does not displace the general private-complaint rule
            // under KAS Article 314. Keep all other known special-category
            // exclusions fail-closed until their dedicated rules are approved.
            let fragments = ["избират", "референдум", "иностранн граждан",
                             "административн надзор", "недобровольн", "психиатр"]
            if ruleID == "KAS-PRIVATE-GENERAL", value.contains("муниципальн") {
                return fragments.contains { value.contains($0) }
            }
            return fragments.contains { value.contains($0) }
                || value.contains("муниципальн")
        case "KOAP":
            return isElectionCategory(category)
        default:
            return false
        }
    }

    private static func isElectionCategory(_ category: String?) -> Bool {
        let value = normalized(category)
        return value.contains("избират") || value.contains("референдум")
    }

    private static func finalAct(in instance: CaseInstance) -> DeadlineTriggerProvenance? {
        instance.sessions.enumerated().compactMap { index, session -> (Date, Int, DeadlineTriggerProvenance)? in
            guard CaseLifecycleResolver.isFinalActAnnouncement(event: session.event, result: session.result),
                  let date = DateUtil.parse(session.date) else { return nil }
            return (date, index, provenance(for: session, in: instance))
        }
        .max { left, right in left.0 == right.0 ? left.1 < right.1 : left.0 < right.0 }?.2
    }

    private static func currentFirstInstanceAct(in instance: CaseInstance) -> CurrentFirstInstanceAct {
        let sourceOutcome = normalized(instance.result)
        let sourceDate = instance.sourceEvidence?.decisionDate.flatMap(DateUtil.parse)
        let sourceDisposition = cardOutcomeDisposition(sourceOutcome)
        let sourceSupportsBlocking = sourceDisposition != nil
            && !isUnsupportedActWording(sourceOutcome)
        let acts = instance.sessions.enumerated().compactMap { index, session
            -> (Date, Int, DeadlineTriggerProvenance, CurrentFirstInstanceAct)? in
            guard let date = DateUtil.parse(session.date) else { return nil }
            var trigger = provenance(for: session, in: instance)
            let value = normalized(session.event + " " + (session.result ?? ""))
            let sessionDisposition = blockingDisposition(value)
            let sourceOutcomeOnThisDate = sourceSupportsBlocking
                && sourceDate.map { DateUtil.startOfDay($0) == DateUtil.startOfDay(date) } == true
            let sourceOutcomeConflict = sourceOutcomeOnThisDate
                && isFinalDecisionWording(value)
            let contradictoryBlocking = sourceOutcomeOnThisDate
                && sessionDisposition != nil && sessionDisposition != sourceDisposition
            let cardOutcomeOnThisDate = sourceOutcomeOnThisDate
                && isCardOutcomeCorroboratingSession(session)
            guard CaseLifecycleResolver.isFinalActAnnouncement(
                    event: session.event, result: session.result)
                    || sessionDisposition != nil && value.contains("определен")
                    || cardOutcomeOnThisDate || sourceOutcomeConflict else {
                return nil
            }
            let classification: CurrentFirstInstanceAct
            if isUnsupportedActWording(value) {
                classification = .unsupported
            } else if sourceOutcomeConflict || contradictoryBlocking {
                classification = .ambiguous
            } else if sessionDisposition != nil {
                classification = .blockingDetermination(trigger)
            } else if cardOutcomeOnThisDate {
                trigger.result = instance.result
                classification = .blockingDetermination(trigger)
            } else if isFinalDecisionWording(value) {
                classification = .decision(trigger)
            } else {
                classification = .unsupported
            }
            return (date, index, trigger, classification)
        }
        guard let latestDate = acts.map(\.0).max() else { return .missing }
        let latest = acts.filter { $0.0 == latestDate }
        var unique = [(DeadlineTriggerProvenance, CurrentFirstInstanceAct)]()
        for (_, _, trigger, classification) in latest where !unique.contains(where: { $0.0 == trigger }) {
            unique.append((trigger, classification))
        }
        guard unique.count == 1 else { return .ambiguous }
        return unique[0].1
    }

    /// A card's own dated decision result may supply the disposition when its
    /// chronology row names only the procedural step (for example, materials
    /// returned after the correction period). Keep the session as the dated
    /// trigger and require it to match the card's published decision date.
    private static func isCardOutcomeCorroboratingSession(_ session: CaseSession) -> Bool {
        let value = normalized(session.event + " " + (session.result ?? ""))
        guard !value.isEmpty, !isUnsupportedActWording(value) else { return false }
        let returnedMaterials = value.contains("материал")
            && (value.contains("возвращ") || value.contains("возврат"))
        let acceptanceStep = value.contains("решен") && value.contains("вопрос")
            && value.contains("принят") && value.contains("производств")
        let determinationHeading = value.contains("определен")
            && !isFinalDecisionWording(value)
            && blockingDisposition(value) == nil
        return returnedMaterials || acceptanceStep || determinationHeading
    }

    private static func isSupportedBlockingDetermination(_ value: String) -> Bool {
        blockingDisposition(value) != nil
    }

    private static func blockingDisposition(_ value: String) -> BlockingDisposition? {
        guard !isRefusalToTerminateProceeding(value), !isPartialProceedingTermination(value),
              !isRefusalOfAncillaryApplication(value) else {
            return nil
        }
        let claimApplication = value.range(
            of: #"иск\w*\s+заявлен\w*"#,
            options: .regularExpression) != nil
        let returnedClaim = claimApplication
            && (value.contains("возврат") || value.contains("возвращ"))
        let refusedAcceptance = claimApplication && value.range(
            of: #"отказ(?:ано|е|а|ать)?\s+(?:в\s+)?принят"#,
            options: .regularExpression) != nil
        let leftClaimWithoutConsideration = (value.contains("иск") || value.contains("дел"))
            && value.contains("остав") && value.contains("без рассмотр")
        let wholeProceedingTerminated = value.contains("прекращ")
            && value.contains("производств")
            && (value.contains("дел") || value.contains("иск"))
        if returnedClaim { return .claimReturned }
        if refusedAcceptance { return .refusalToAccept }
        if leftClaimWithoutConsideration { return .leftWithoutConsideration }
        if wholeProceedingTerminated { return .proceedingTerminated }
        return nil
    }

    /// The card's own result may abbreviate the object to «Заявление возвращено
    /// заявителю». Accept that only as a dated card outcome paired with a same-day
    /// corroborating chronology row; a session phrase alone must identify a claim.
    private static func cardOutcomeDisposition(_ value: String) -> BlockingDisposition? {
        if let disposition = blockingDisposition(value) { return disposition }
        guard !isUnsupportedActWording(value),
              value.range(of: #"заявлен\w*\s+возвращ\w*\s+заявител\w*"#,
                          options: .regularExpression) != nil else { return nil }
        return .claimReturned
    }

    private static func isFinalDecisionWording(_ value: String) -> Bool {
        value.contains("иск") && (value.contains("удовлетвор")
            || value.range(of: #"отказ(?:ано|е|а|ать)?\s+(?:в\s+)?удовлетвор"#,
                           options: .regularExpression) != nil)
            || value.contains("решен") && !value.contains("вопрос")
                && CaseLifecycleResolver.isFinalActAnnouncement(event: value, result: nil)
    }

    private static func isRefusalToTerminateProceeding(_ value: String) -> Bool {
        value.range(
            of: #"отказ(?:ано|е)\s+в\s+прекращ\w*|в\s+прекращ\w*[^.!?]{0,60}\s+отказано"#,
            options: .regularExpression) != nil
    }

    private static func isPartialProceedingTermination(_ value: String) -> Bool {
        guard value.contains("прекращ") && value.contains("производств") else { return false }
        return value.contains("в части") || value.contains("частичн")
    }

    private static func isRefusalOfAncillaryApplication(_ value: String) -> Bool {
        value.range(
            of: #"отказ(?:ано|е)?\s+в\s+удовлетворении\s+заявлен\w*[^.!?]{0,60}\s+об?\s+(?:возврат|оставлен|прекращ)\w*|в\s+удовлетворении\s+заявлен\w*[^.!?]{0,60}\s+об?\s+(?:возврат|оставлен|прекращ)\w*[^.!?]{0,60}\s+отказано|отказ(?:ано|е)?\s+в\s+(?:возврат|оставлен|прекращ)\w*|в\s+(?:возврат|оставлен|прекращ)\w*[^.!?]{0,100}\s+отказано"#,
            options: .regularExpression) != nil
    }

    private static func isUnsupportedActWording(_ value: String) -> Bool {
        let intermediate = ["ходатайств", "доказательств", "отвод", "запрос",
                            "подготов", "отлож", "перенес", "без движен",
                            "обеспеч", "восстановлен", "рассроч", "отсроч",
                            "замен стороны", "правопреем", "вступлен треть",
                            "соединен иск", "выделен иск", "передач дела",
                            "назначено заседан", "назначении заседан"]
        guard !intermediate.contains(where: value.contains),
              !isRefusalOfAncillaryApplication(value) else {
            return true
        }
        if isRefusalToTerminateProceeding(value) { return true }
        let tokens = value.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let dispositions = ["отказ", "принят", "возвращ", "остав", "прекращ", "удовлетвор"]
        if tokens.indices.contains(where: { index in
            tokens[index] == "не" && tokens[(index + 1)..<min(index + 4, tokens.count)]
                .contains(where: { word in dispositions.contains(where: word.hasPrefix) })
        }) { return true }
        let historical = ["предыдущ", "ранее", "первоначальн", "нижестоящ",
                          "обжалованного", "отменен", "отменено", "без изменен"]
        return historical.contains(where: value.contains)
            && (value.contains("решен") || value.contains("определен"))
    }

    private static func koapInitialDecision(in instance: CaseInstance)
        -> DeadlineTriggerProvenance? {
        latestSession(in: instance) { session in
            let value = normalized(session.event + " " + (session.result ?? ""))
            return CaseLifecycleResolver.isFinalActAnnouncement(
                event: session.event, result: session.result)
                && value.contains("постановлен")
        }
    }

    private static func koapSubsequentDecision(in instance: CaseInstance)
        -> DeadlineTriggerProvenance? {
        latestSession(in: instance) { session in
            let value = normalized(session.event + " " + (session.result ?? ""))
            return CaseLifecycleResolver.isFinalActAnnouncement(
                event: session.event, result: session.result)
                && value.contains("решен") && value.contains("жалоб")
        }
    }

    private static func koapReturnDetermination(in instance: CaseInstance)
        -> DeadlineTriggerProvenance? {
        latestSession(in: instance) {
            isKoAPReturnDetermination($0.event + " " + ($0.result ?? ""))
        }
    }

    private static func isKoAPReturnDetermination(_ source: String) -> Bool {
        let value = normalized(source)
        return (value.contains("возврат") || value.contains("возвращ"))
            && value.contains("протокол") && value.contains("материал")
    }

    private enum KoAPFirstAct: Equatable { case initial, returnDetermination }

    private static func latestKoAPFirstAct(in instance: CaseInstance?) -> KoAPFirstAct? {
        instance?.sessions.enumerated().compactMap { index, session
            -> (Date, Int, KoAPFirstAct)? in
            guard let date = DateUtil.parse(session.date) else { return nil }
            let value = normalized(session.event + " " + (session.result ?? ""))
            if isKoAPReturnDetermination(value) {
                return (date, index, .returnDetermination)
            }
            if CaseLifecycleResolver.isFinalActAnnouncement(
                event: session.event, result: session.result),
                value.contains("постановлен") {
                return (date, index, .initial)
            }
            return nil
        }
        .max { left, right in left.0 == right.0 ? left.1 < right.1 : left.0 < right.0 }?.2
    }

    private enum KoAPReceiptAct { case initial, subsequent, returnDetermination }

    private static func explicitReceipt(in instance: CaseInstance,
                                        supplied: DeadlineTriggerProvenance?,
                                        act: KoAPReceiptAct,
                                        after finalAct: DeadlineTriggerProvenance,
                                        exactMoment: Bool = false)
        -> DeadlineTriggerProvenance? {
        var candidates = instance.sessions.compactMap { session -> DeadlineTriggerProvenance? in
            var candidate = provenance(for: session, in: instance)
            if exactMoment, let time = session.time {
                candidate.dateRaw = "\(session.date) \(time)"
            }
            return isExplicitReceipt(candidate, act: act) ? candidate : nil
        }
        if let supplied, isExplicitReceipt(supplied, act: act) { candidates.append(supplied) }
        let actDate = DateUtil.parse(finalAct.dateRaw) ?? .distantFuture
        let dated = candidates.compactMap { candidate -> (DeadlineTriggerProvenance, Date)? in
            let date = exactMoment ? exactMomentDate(candidate.dateRaw) : DateUtil.parse(candidate.dateRaw)
            guard let date, date >= actDate else { return nil }
            return (candidate, date)
        }
        guard Set(dated.map { $0.1.timeIntervalSinceReferenceDate }).count == 1 else { return nil }
        return dated.first?.0
    }

    private static func isExplicitReceipt(_ trigger: DeadlineTriggerProvenance,
                                          act: KoAPReceiptAct) -> Bool {
        let value = normalized(trigger.event + " " + (trigger.result ?? ""))
        guard !value.contains("направ"),
              !containsNegatedReceipt(in: value),
              value.contains("вручен") || value.contains("получ")
                || value.contains("поступлен") else { return false }
        switch act {
        case .initial:
            return value.contains("копи") && value.contains("постановлен")
        case .subsequent:
            return value.contains("копи") && value.contains("решен")
        case .returnDetermination:
            return value.contains("определен")
        }
    }

    private static func containsNegatedReceipt(in value: String) -> Bool {
        let words = value.split(whereSeparator: \.isWhitespace).map {
            String($0).trimmingCharacters(in: .punctuationCharacters)
        }
        for index in words.indices where words[index] == "не" {
            let upperBound = min(words.count, index + 4)
            if words[(index + 1)..<upperBound].contains(where: {
                $0.hasPrefix("вручен") || $0.hasPrefix("получ") || $0.hasPrefix("поступ")
            }) {
                return true
            }
        }
        for index in words.indices where words[index].hasPrefix("вручен")
            || words[index].hasPrefix("получ") || words[index].hasPrefix("поступ") {
            let upperBound = min(words.count, index + 4)
            let tail = words[(index + 1)..<upperBound]
            if let negative = tail.firstIndex(of: "не"),
               words[words.index(after: negative)..<upperBound].contains(where: {
                   $0.hasPrefix("был")
               }) {
                return true
            }
        }
        return false
    }

    private static func triggerDate(for rule: LegalDeadlineRule,
                                    trigger: DeadlineTriggerProvenance) -> Date? {
        rule.ruleID == "KOAP-APPEAL-RETURN-DETERMINATION-ONE-SUTKI"
            ? exactMomentDate(trigger.dateRaw) : DateUtil.parse(trigger.dateRaw)
    }

    private static func exactMomentDate(_ raw: String) -> Date? {
        let components = raw.split(whereSeparator: \.isWhitespace)
        guard components.count == 2, let day = DateUtil.parse(String(components[0])) else {
            return nil
        }
        let time = components[1].split(separator: ":")
        guard time.count == 2, time[0].count == 2, time[1].count == 2,
              let hour = Int(time[0]), let minute = Int(time[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return DateUtil.cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private static func finalForm(in instance: CaseInstance) -> DeadlineTriggerProvenance? {
        latestSession(in: instance) { session in
            let value = normalized(session.event + " " + (session.result ?? ""))
            return value.contains("окончательн") && value.contains("форм")
                || value.contains("изготов") && value.contains("мотивирован")
                    && value.contains("решен")
        }
    }

    private static func motivatedAppealDetermination(in instance: CaseInstance, movement: CaseMovement)
        -> DeadlineTriggerProvenance? {
        let sessions = instance.sessions.filter { session in
            // The synthetic operative row is dated by announcement and may
            // contain a later final-form statement in its tail.
            guard session.event != "Резолютивная часть опубликованного акта" else { return false }
            let value = normalized(session.event + " " + (session.result ?? ""))
            return value.contains("апелляцион") && value.contains("определен")
                && (value.contains("мотивирован") || value.contains("окончательн"))
                && (value.contains("изготов") || value.contains("составлен") || value.contains("составлено"))
        }
        var candidates = sessions.map { provenance(for: $0, in: instance) }
        for id in instance.linkedActIDs {
            guard let body = movement.actBodies[id],
                  let tail = CaseLifecycleResolver.operativeDisposition(in: body) else { continue }
            for paragraph in ActParagraphizer.paragraphs(in: tail) {
                let value = normalized(paragraph.text)
                guard (value.hasPrefix("мотивированное определение")
                    || value.hasPrefix("мотивированное апелляционное определение")
                    || value.hasPrefix("апелляционное определение")),
                      value.contains("изготов") || value.contains("составлен"),
                      value.contains("мотивирован") || value.contains("окончательн") else { continue }
                let dates = CaseLifecycleResolver.explicitActDates(in: paragraph.text)
                guard dates.count == 1, let date = dates.first else { continue }
                let components = DateUtil.cal.dateComponents([.day, .month, .year], from: date)
                candidates.append(DeadlineTriggerProvenance(event: paragraph.text, result: nil,
                    dateRaw: "\(components.day!).\(components.month!).\(components.year!)",
                    court: instance.court, levelRaw: instance.level.rawValue, caseNumber: instance.caseNumber))
            }
        }
        let dates = Set(candidates.compactMap { DateUtil.parse($0.dateRaw) })
        guard dates.count == 1 else { return nil }
        return candidates.first
    }

    private static func legalForce(in instance: CaseInstance) -> DeadlineTriggerProvenance? {
        let ordered = instance.sessions.enumerated().sorted { left, right in
            let leftDate = DateUtil.parse(left.element.date) ?? .distantPast
            let rightDate = DateUtil.parse(right.element.date) ?? .distantPast
            return leftDate == rightDate ? left.offset < right.offset : leftDate < rightDate
        }
        var latest: DeadlineTriggerProvenance?
        for entry in ordered {
            if CaseLifecycleResolver.isReactivation(event: entry.element.event,
                                                    result: entry.element.result) {
                latest = nil
            } else if CaseLifecycleResolver.hasLegalForceEvidence(event: entry.element.event,
                                                                    result: entry.element.result),
                      DateUtil.parse(entry.element.date) != nil {
                latest = provenance(for: entry.element, in: instance)
            }
        }
        return latest
    }

    private static func currentAppeal(in timeline: CaseLifecycleResolver.Timeline) -> CaseInstance? {
        timeline.currentAppeal
    }

    private static func latestSession(in instance: CaseInstance,
                                      where predicate: (CaseSession) -> Bool)
        -> DeadlineTriggerProvenance? {
        instance.sessions.enumerated().compactMap { index, session -> (Date, Int, DeadlineTriggerProvenance)? in
            guard predicate(session), let date = DateUtil.parse(session.date) else { return nil }
            return (date, index, provenance(for: session, in: instance))
        }
        .max { left, right in left.0 == right.0 ? left.1 < right.1 : left.0 < right.0 }?.2
    }

    private static func provenance(for session: CaseSession, in instance: CaseInstance)
        -> DeadlineTriggerProvenance {
        DeadlineTriggerProvenance(event: session.event, result: session.result, dateRaw: session.date,
                                  court: instance.court, levelRaw: instance.level.rawValue,
                                  caseNumber: instance.caseNumber)
    }

    private static func routeSupportsCSOY(_ context: MovementContext?) -> Bool {
        guard let level = context?.courtLevel else { return false }
        return level != .magistrate
    }

    private static func isGeneralCriminalAct(_ trigger: DeadlineTriggerProvenance) -> Bool {
        let value = normalized(trigger.event + " " + (trigger.result ?? ""))
        let special = ["заключен под страж", "домашн арест", "запрет определенных",
                       "продлени", "психиатрическ"]
        guard !special.contains(where: value.contains) else { return false }
        return value.contains("приговор") || value.contains("решен")
            || value.contains("производств") && value.contains("прекращ")
    }

    private static func needsLegalReview(rule: LegalDeadlineRule,
                                         registry: LegalDeadlineRegistry,
                                         timeline: CaseLifecycleResolver.Timeline) -> Bool {
        // The KAS open question applies to a repeated/shared cassation window,
        // not an initial KSOYU filing from a proved legal-force trigger.
        guard rule.ruleID == "KAS-CASSATION-KSOYU",
              timeline.hasCassationInCurrentRound else { return false }
        return registry.openQuestions.contains {
            $0.questionID == "KAS-CASSATION-SIX-MONTH-SHARED-WINDOW"
        }
    }

    private static func occurrenceKey(ruleID: String, timeline: CaseLifecycleResolver.Timeline,
                                      movement: CaseMovement,
                                      trigger: DeadlineTriggerProvenance) -> String {
        let round = timeline.currentRoundStart?.instance.id
            ?? timeline.deadlineFirst?.id ?? movement.uid
        let identity = [round, trigger.levelRaw, trigger.caseNumber, trigger.dateRaw,
                        trigger.event, trigger.result ?? ""].joined(separator: "\u{1F}")
        return ruleID + "|" + Data(identity.utf8).base64EncodedString()
    }

    private static func shortCaseNumber(_ value: String) -> String {
        value.split(separator: " ").first.map(String.init) ?? value
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}
