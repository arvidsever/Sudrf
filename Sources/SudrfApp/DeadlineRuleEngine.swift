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

    /// Только эти результаты удерживают terminal first-instance case активным:
    /// rule распознан, но честный ответ невозможен без недостающего факта или
    /// политики. Простое `notApplicable` сохраняет старое завершение дела.
    var isIndeterminate: Bool {
        switch status {
        case .insufficientEvidence, .unsupportedCalculation, .needsLegalReview:
            true
        case .applicable, .notApplicable:
            false
        }
    }

    var blocksTerminalFirst: Bool { kind == "appeal" && isIndeterminate }
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
        case finalForm
        case finalAct
        case deliveryOrReceipt
        case gpkCassation
        case legalForce
    }

    private struct Binding {
        var ruleID: String
        var kind: String
        var production: ProductionType
        var trigger: TriggerMode
    }

    private enum TriggerExtraction {
        case found(DeadlineTriggerProvenance)
        case missing([DeadlineEvidenceRequirement])
    }

    private enum DateCalculation {
        case calculated(Calculation)
        case unsupported([String])
    }

    /// The first production layer intentionally activates only the six Docs
    /// rules approved for #70. The full catalog remains available in the
    /// registry for #222 without a second hand-maintained list.
    private static let bindings = [
        Binding(ruleID: "GPK-APPEAL-GENERAL", kind: "appeal", production: .civil,
                trigger: .finalForm),
        Binding(ruleID: "KAS-APPEAL-GENERAL", kind: "appeal", production: .kas,
                trigger: .finalForm),
        Binding(ruleID: "UPK-APPEAL-GENERAL", kind: "appeal", production: .crim,
                trigger: .finalAct),
        Binding(ruleID: "KOAP-APPEAL-INITIAL-GENERAL", kind: "appeal", production: .koap,
                trigger: .deliveryOrReceipt),
        Binding(ruleID: "GPK-CASSATION-CSOY", kind: "cassation", production: .civil,
                trigger: .gpkCassation),
        Binding(ruleID: "KAS-CASSATION-KSOYU", kind: "cassation", production: .kas,
                trigger: .legalForce),
    ]

    static func evaluate(registry: LegalDeadlineRegistry, movement: CaseMovement,
                         context: Context, timeline: CaseLifecycleResolver.Timeline,
                         today: Date) -> Evaluation {
        guard let production = production(from: context.movementContext) else {
            return Evaluation(deadlines: [], assessments: [])
        }

        var deadlines: [StoredDeadline] = []
        var assessments: [DeadlineRuleAssessment] = []
        for binding in bindings where binding.production == production {
            guard let rule = registry.rule(id: binding.ruleID) else {
                assessments.append(assessment(ruleID: binding.ruleID, kind: binding.kind,
                                               status: .needsLegalReview))
                continue
            }

            let result = evaluate(binding: binding, rule: rule, registry: registry,
                                  movement: movement, context: context, timeline: timeline,
                                  today: today)
            assessments.append(result.assessment)
            if let deadline = result.deadline { deadlines.append(deadline) }
        }
        return Evaluation(deadlines: deadlines, assessments: assessments)
    }

    /// A missing packaged registry must not silently restore the historical
    /// fallback or close a terminal case. The known typed candidates remain
    /// visible as requiring review until the resource is restored.
    static func unavailable(context: Context) -> Evaluation {
        guard let production = production(from: context.movementContext) else {
            return Evaluation(deadlines: [], assessments: [])
        }
        return Evaluation(deadlines: [], assessments: bindings
            .filter { $0.production == production }
            .map { assessment(ruleID: $0.ruleID, kind: $0.kind,
                              status: .needsLegalReview) })
    }

    private static func evaluate(binding: Binding, rule: LegalDeadlineRule,
                                 registry: LegalDeadlineRegistry, movement: CaseMovement,
                                 context: Context, timeline: CaseLifecycleResolver.Timeline,
                                 today: Date) -> (deadline: StoredDeadline?, assessment: DeadlineRuleAssessment) {
        switch binding.kind {
        case "appeal":
            // A real higher-court card in the current round proves that this
            // appeal deadline is no longer an actionable candidate.
            guard !timeline.hasAppealInCurrentRound, !timeline.hasCassationInCurrentRound else {
                return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                        status: .notApplicable))
            }
        case "cassation":
            if timeline.hasCassationInCurrentRound,
               needsLegalReview(rule: rule, registry: registry, timeline: timeline) {
                return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                        status: .needsLegalReview))
            }
            guard !timeline.hasCassationInCurrentRound else {
                return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                        status: .notApplicable))
            }
        default:
            return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                    status: .notApplicable))
        }

        if binding.kind == "appeal", requiresKnownCategory(for: rule.code),
           normalized(movement.category).isEmpty {
            return insufficient(rule, binding: binding, [.caseCategory])
        }
        if binding.kind == "appeal", categorySelectsSpecialRule(movement.category, code: rule.code) {
            // A known special category displaces the general rule. Its typed
            // activation belongs to #222; do not calculate the general one.
            return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                    status: .notApplicable))
        }

        let triggerResult: TriggerExtraction
        switch binding.trigger {
        case .finalForm:
            guard let first = timeline.latestFirst?.instance else {
                return insufficient(rule, binding: binding, [.finalAct, .finalForm])
            }
            let act = finalAct(in: first)
            let form = finalForm(in: first)
            if let form, act != nil {
                triggerResult = .found(form)
            } else if act == nil, form == nil {
                triggerResult = .missing([.finalAct, .finalForm])
            } else if act == nil {
                triggerResult = .missing([.finalAct])
            } else {
                triggerResult = .missing([.finalForm])
            }
        case .finalAct:
            guard let first = timeline.latestFirst?.instance else {
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
        case .deliveryOrReceipt:
            guard let first = timeline.latestFirst?.instance,
                  finalAct(in: first) != nil else {
                return insufficient(rule, binding: binding, [.finalAct])
            }
            guard let receipt = context.deliveryOrReceipt else {
                return insufficient(rule, binding: binding, [.deliveryOrReceipt])
            }
            triggerResult = .found(receipt)
        case .gpkCassation:
            guard routeSupportsCSOY(context.movementContext) else {
                return insufficient(rule, binding: binding, [.production])
            }
            if timeline.hasAppealInCurrentRound {
                guard let appeal = currentAppeal(in: timeline),
                      let motivated = motivatedAppealDetermination(in: appeal) else {
                    return insufficient(rule, binding: binding, [.motivatedAppealDetermination])
                }
                triggerResult = .found(motivated)
            } else {
                guard let first = timeline.latestFirst?.instance,
                      let legalForce = legalForce(in: first) else {
                    return insufficient(rule, binding: binding, [.legalForce])
                }
                triggerResult = .found(legalForce)
            }
        case .legalForce:
            guard routeSupportsCSOY(context.movementContext) else {
                return insufficient(rule, binding: binding, [.production])
            }
            guard let first = timeline.latestFirst?.instance,
                  let legalForce = legalForce(in: first) else {
                return insufficient(rule, binding: binding, [.legalForce])
            }
            triggerResult = .found(legalForce)
        }

        switch triggerResult {
        case .missing(let requirements):
            return insufficient(rule, binding: binding, requirements)
        case .found:
            break
        }
        guard case let .found(trigger) = triggerResult else {
            return insufficient(rule, binding: binding, [])
        }

        if needsLegalReview(rule: rule, registry: registry, timeline: timeline) {
            return (nil, assessment(ruleID: rule.ruleID, kind: binding.kind,
                                    status: .needsLegalReview))
        }

        switch calculate(rule: rule, triggerDate: DateUtil.parse(trigger.dateRaw), registry: registry) {
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
                calculatedDateRef: calculation.date.timeIntervalSinceReferenceDate)
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
    }

    /// `failure` means the registry requires a policy that this app does not
    /// implement yet. It never falls back to a day count for months or working
    /// days.
    private static func calculate(rule: LegalDeadlineRule, triggerDate: Date?,
                                  registry: LegalDeadlineRegistry)
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
        let result: Date
        let policyIDs: [String]
        let endNonworking: String?
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
                            policy(["DAYS", "CALENDAR"]))
            endNonworking = policy(["END", "NONWORKING"])
        case .calendarSutki:
            result = DateUtil.addDays(triggerDate, value)
            policyIDs = ids(policy(["COUNTING", "UNITS"]),
                            policy(["END", "DAY", "24H"]))
            endNonworking = policy(["END", "NONWORKING"])
        case .workingDays:
            return .unsupported(ids(policy(["COUNTING", "DAY"])))
        case .relative, .none:
            return .unsupported([])
        }

        // A future LegalCalendar (#224) is required only when the observable
        // endpoint needs a non-working-day rollover. Weekday endpoints retain
        // calendar-unit arithmetic without pretending that months are 30 days.
        if DateUtil.cal.isDateInWeekend(result) {
            return .unsupported(ids(endNonworking))
        }
        return .calculated(Calculation(date: result, policyIDs: policyIDs + ids(endNonworking)))
    }

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

    private static func production(from context: MovementContext?) -> ProductionType? {
        guard let id = context?.cartotekaId, !id.isEmpty, id != "m" else { return nil }
        return ProductionType(cartotekaId: id)
    }

    private static func requiresKnownCategory(for code: String) -> Bool {
        code == "GPK" || code == "KAS" || code == "KOAP"
    }

    /// The binding needs only enough case taxonomy to avoid applying a general
    /// rule where Docs declares a special one. Activation of the selected
    /// special rule remains intentionally deferred to #222.
    private static func categorySelectsSpecialRule(_ category: String?, code: String) -> Bool {
        let value = normalized(category)
        switch code {
        case "GPK":
            return ["упрощенн", "возвращени ребен", "доступ к ребен", "усынов",
                    "заочн", "иностранн государств"].contains { value.contains($0) }
        case "KAS":
            return ["избират", "муниципальн", "иностранн граждан", "административн надзор",
                    "недобровольн", "психиатр"].contains { value.contains($0) }
        case "KOAP":
            return value.contains("избират")
        default:
            return false
        }
    }

    private static func finalAct(in instance: CaseInstance) -> DeadlineTriggerProvenance? {
        instance.sessions.enumerated().compactMap { index, session -> (Date, Int, DeadlineTriggerProvenance)? in
            guard CaseLifecycleResolver.isFinalActAnnouncement(event: session.event, result: session.result),
                  let date = DateUtil.parse(session.date) else { return nil }
            return (date, index, provenance(for: session, in: instance))
        }
        .max { left, right in left.0 == right.0 ? left.1 < right.1 : left.0 < right.0 }?.2
    }

    private static func finalForm(in instance: CaseInstance) -> DeadlineTriggerProvenance? {
        latestSession(in: instance) { session in
            let value = normalized(session.event + " " + (session.result ?? ""))
            return value.contains("окончательн") && value.contains("форм")
                || value.contains("изготов") && value.contains("мотивирован")
                    && value.contains("решен")
        }
    }

    private static func motivatedAppealDetermination(in instance: CaseInstance)
        -> DeadlineTriggerProvenance? {
        latestSession(in: instance) { session in
            let value = normalized(session.event + " " + (session.result ?? ""))
            return value.contains("апелляцион") && value.contains("определен")
                && (value.contains("мотивирован") || value.contains("окончательн"))
        }
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
        guard let first = timeline.latestFirst,
              let firstDate = CaseLifecycleResolver.earliestDatedSessionDate(in: first.instance) else {
            return timeline.sourceOrdered.last(where: { $0.instance.level == .appeal })?.instance
        }
        return timeline.sourceOrdered.filter { candidate in
            candidate.instance.level == .appeal
                && (CaseLifecycleResolver.earliestDatedSessionDate(in: candidate.instance) ?? .distantPast)
                    >= firstDate
        }
        .max { left, right in
            (CaseLifecycleResolver.earliestDatedSessionDate(in: left.instance) ?? .distantPast)
                < (CaseLifecycleResolver.earliestDatedSessionDate(in: right.instance) ?? .distantPast)
        }?.instance
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
            ?? timeline.latestFirst?.instance.id ?? movement.uid
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
