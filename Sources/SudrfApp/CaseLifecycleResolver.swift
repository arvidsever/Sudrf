import Foundation
import SudrfKit

/// Единая интерпретация текущего процессуального положения дела.
///
/// Сетевые заглушки намеренно остаются частью `CaseMovement`, чтобы карточка
/// могла предложить CAPTCHA/retry, но не являются доказательством возбуждённого
/// производства и поэтому не участвуют в стадии, шагах и завершённости.
enum CaseLifecycleResolver {
    enum CompletionReason: Equatable {
        case legalForce
        case terminalReview(String)
        case terminalFirst(String)
        case confirmedDeadline
    }

    struct Resolution: Equatable {
        var stage: CaseStageKind
        var currentInstance: CaseInstance?
        var steps: [String]
        var completionReason: CompletionReason?
        /// Расчётный срок первой инстанции, который ещё удерживает дело в
        /// активном состоянии. Не персистируется: нужен только для UI и сортировки.
        var graceDeadline: StoredDeadline?

        var isCompleted: Bool { completionReason != nil }
    }

    struct IndexedInstance {
        var index: Int
        var instance: CaseInstance
    }

    /// Хронология не меняет сохранённое движение. Она лишь связывает
    /// производные решения с последним датированным процессуальным кругом.
    /// Недатированная карточка с итогом остаётся надёжным fallback, пока нет
    /// доказательства, что после её пересмотра начался новый круг.
    struct Timeline {
        var production: ProductionType?
        var sourceOrdered: [IndexedInstance]
        var lifecycleOrdered: [IndexedInstance]
        var hasAmbiguousAppealEffect: Bool
        var chronological: [IndexedInstance]
        var dated: [IndexedInstance]
        /// Первая датированная инстанция нового круга, созданного возвратом.
        var currentRoundStart: IndexedInstance?
        var currentRoundDate: Date?
        var currentDated: IndexedInstance?
        var currentDatedStartsNewRound: Bool { currentRoundStart != nil }

        var instances: [CaseInstance] { chronological.map(\.instance) }

        var latestFirst: IndexedInstance? {
            guard sourceOrdered.contains(where: {
                CaseLifecycleResolver.isJoinedRegistration($0.instance, production: production)
            }) else {
                return dated.last(where: { CaseLifecycleResolver.isFirstLike($0.instance) })
                    ?? chronological.last(where: { CaseLifecycleResolver.isFirstLike($0.instance) })
            }
            let eligible = Set(lifecycleOrdered.map(\.index))
            return dated.filter { eligible.contains($0.index) && CaseLifecycleResolver.isFirstLike($0.instance) }
                .max { CaseLifecycleResolver.lifecyclePrecedes($0.instance, $1.instance, production: production) }
                ?? chronological.last(where: { eligible.contains($0.index) && CaseLifecycleResolver.isFirstLike($0.instance) })
        }

        /// Trigger extraction must not reuse a refusal from before a later
        /// acceptance recorded in the same source card.
        var deadlineFirst: CaseInstance? {
            guard var first = latestFirst?.instance else { return nil }
            guard first.id == currentRoundStart?.instance.id,
                  let start = currentRoundDate,
                  let earliest = CaseLifecycleResolver.earliestDatedSessionDate(in: first), earliest < start else { return first }
            first.sessions = first.sessions.filter { DateUtil.parse($0.date).map { $0 >= start } == true }
            if (first.sourceEvidence?.decisionDate.flatMap(DateUtil.parse) ?? .distantPast) < start {
                first.result = nil
            }
            return first
        }

        /// Карточка апелляции без дат не доказывает стадию, но достаточно
        /// надёжна, чтобы не предлагать пользователю уже поданную жалобу.
        /// Датированная апелляция относится к текущему кругу только после
        /// последней первой инстанции этого круга.
        var hasAppealInCurrentRound: Bool {
            guard let latestFirst else {
                return lifecycleOrdered.contains { $0.instance.level == .appeal }
            }
            let firstDate = currentRoundDate ?? CaseLifecycleResolver.earliestDatedSessionDate(in: latestFirst.instance)
            for candidate in lifecycleOrdered where candidate.instance.level == .appeal {
                guard let appealDate = CaseLifecycleResolver.earliestDatedSessionDate(in: candidate.instance) else {
                    // Дата отсутствует, поэтому не повышаем стадию. Но реальная
                    // карточка всё равно консервативно подавляет предлагаемый
                    // срок: порядок карточек неустойчив после merge кэша.
                    if currentRoundStart == nil
                        || !CaseLifecycleResolver.isConcludedReview(candidate.instance) { return true }
                    // Авторитетный итог недатированной карточки, вытесненный
                    // подтверждённым новым кругом, относится к истории.
                    continue
                }
                if let firstDate, appealDate >= firstDate { return true }
            }
            return false
        }

        var currentAppeal: CaseInstance? {
            let firstDate = currentRoundDate ?? latestFirst.flatMap {
                CaseLifecycleResolver.earliestDatedSessionDate(in: $0.instance)
            }
            return lifecycleOrdered.filter {
                guard $0.instance.level == .appeal else { return false }
                guard let firstDate else { return true }
                return (CaseLifecycleResolver.earliestDatedSessionDate(in: $0.instance) ?? .distantPast) >= firstDate
            }.max {
                MovementService.precedesInChronology($0.instance, $1.instance)
            }?.instance
        }

        var hasUnresolvedUndatedAppeal: Bool {
            return lifecycleOrdered.contains {
                $0.instance.level == .appeal
                    && CaseLifecycleResolver.earliestDatedSessionDate(in: $0.instance) == nil
                    && !CaseLifecycleResolver.isConcludedReview($0.instance)
            }
        }

        var hasCassationInCurrentRound: Bool {
            let cassationLevels: Set<CaseInstance.Level> = [.cassation, .vsCassation, .supervisory]
            guard let roundDate = currentRoundDate else {
                return lifecycleOrdered.contains { cassationLevels.contains($0.instance.level) }
            }
            return lifecycleOrdered.contains { candidate in
                guard cassationLevels.contains(candidate.instance.level) else { return false }
                guard let date = CaseLifecycleResolver.earliestDatedSessionDate(
                    in: candidate.instance
                ) else {
                    return !CaseLifecycleResolver.isConcludedReview(candidate.instance)
                }
                return date >= roundDate
            }
        }
    }

    private enum InstanceSignal {
        case active
        case remand(CaseStageKind)
        case legalForce
        case terminal(String)
    }

    static func realInstances(in movement: CaseMovement) -> [CaseInstance] {
        movement.instances.filter {
            ($0.level != .material || isRootMaterial($0, in: movement))
                && $0.captchaFormURL == nil
                && $0.transientError != true
        }.sorted(by: MovementService.precedesInChronology)
    }

    private static func isJoinedWording(_ text: String?) -> Bool {
        guard let text else { return false }
        return normalized(text).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            == "дело присоединено к другому делу"
    }

    private static func isJoinedRow(_ session: CaseSession) -> Bool {
        let text = normalized(session.event + " " + (session.result ?? ""))
        return (isJoinedWording(session.event) || isJoinedWording(session.result))
            && !isDenied(text) && !text.contains("ходатайств") && !text.contains("жалоб")
    }

    private static func joinedEvidenceDate(in instance: CaseInstance) -> Date? {
        let rows = instance.sessions.filter(isJoinedRow)
        guard !rows.contains(where: { DateUtil.parse($0.date) == nil }) else { return nil }
        let dates = rows.compactMap { DateUtil.parse($0.date) }
        if isJoinedWording(instance.result), let date = instance.sourceEvidence?.decisionDate.flatMap(DateUtil.parse) {
            return (dates + [date]).max()
        }
        return dates.max()
    }

    private static func isIndependentContinuation(_ session: CaseSession) -> Bool {
        func wording(_ source: String) -> String {
            normalized(source).replacingOccurrences(of: #"иск\s*\(заявление,\s*жалоба\)"#,
                with: "иск", options: .regularExpression)
                .replacingOccurrences(of: #"иска\s*\(заявления,\s*жалобы\)"#,
                    with: "иска", options: .regularExpression)
        }
        let combined = wording(session.event + " " + (session.result ?? ""))
        guard !isDenied(combined), !combined.contains("ходатайств"), !combined.contains("жалоб") else { return false }
        return [session.event, session.result ?? ""].contains { source in
            let value = wording(source).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.range(of: #"^(?:иск\s+принят\s+к\s+производству|(?:административное\s+)?исковое\s+заявление\s+принято\s+к\s+производству|(?:дело\s+)?принято\s+к\s+производству|(?:производство\s+(?:по\s+делу\s+)?возобновлено|возобновление\s+производства(?:\s+по\s+делу)?|дело\s+возобновлено)|(?:дело\s+)?выделено\s+в\s+отдельное\s+производство|выделение\s+дела\s+в\s+отдельное\s+производство)"#,
                               options: .regularExpression) != nil
        }
    }

    /// Outgoing absorption is distinct from receiving a case or deciding a motion.
    static func isJoinedRegistration(_ instance: CaseInstance, production: ProductionType?) -> Bool {
        guard production == .civil || production == .kas, instance.level == .first,
              isJoinedWording(instance.result) || instance.sessions.contains(where: isJoinedRow) else { return false }
        let evidenceDate = joinedEvidenceDate(in: instance)
        let contradicted = instance.sessions.contains { session in
            let text = normalized(session.event + " " + (session.result ?? ""))
            guard text.contains("присоедин"), isDenied(text) || text.contains("ходатайств") else { return false }
            return evidenceDate == nil || DateUtil.parse(session.date) == evidenceDate
                || isJoinedWording(session.event) || isJoinedWording(session.result)
        }
        guard !contradicted else { return false }
        guard let joinedDate = joinedEvidenceDate(in: instance) else { return true }
        return !instance.sessions.contains { session in
            DateUtil.parse(session.date).map { $0 > joinedDate } == true
                && isIndependentContinuation(session)
        }
    }

    private static func provesContinuation(_ instance: CaseInstance, after date: Date) -> Bool {
        if terminalEvidenceDate(in: instance).map({ $0 > date }) == true { return true }
        guard latestSignal(for: instance).map({ signal in
            switch signal {
            case .terminal, .legalForce: return false
            case .active, .remand: return true
            }
        }) != false else { return false }
        return instance.sessions.contains { session in
            guard let sessionDate = DateUtil.parse(session.date), sessionDate >= date else { return false }
            let text = normalized(session.event + " " + (session.result ?? ""))
            let receiving = !isDenied(text) && !text.contains("ходатайств")
                && text.range(of: #"(?:к\s+делу\s+присоединено|присоединено\s+(?:другое\s+)?дело)"#,
                              options: .regularExpression) != nil
            return receiving || sessionDate > date
                && (isIndependentContinuation(session) || isHearing(event: session.event, result: session.result))
        }
    }

    /// A material participates only when it is the tracked root card itself.
    /// Materials discovered inside an ordinary case remain supporting history.
    static func isRootMaterial(_ instance: CaseInstance, in movement: CaseMovement) -> Bool {
        guard instance.level == .material else { return false }
        let rootNumber = normalizedCaseNumber(movement.caseNumber)
        guard !rootNumber.isEmpty else { return false }
        let matchingMaterials = movement.instances.filter {
            $0.level == .material && normalizedCaseNumber($0.caseNumber) == rootNumber
        }
        let hasNonMaterialRoot = movement.instances.contains {
            $0.level != .material && normalizedCaseNumber($0.caseNumber) == rootNumber
        }
        return matchingMaterials.count == 1
            && matchingMaterials[0].id == instance.id
            && !hasNonMaterialRoot
    }

    /// Reviews of separately registered materials remain visible in movement,
    /// but cannot reopen the tracked main case. Follow published case numbers
    /// through a material's appeal and subsequent review.
    private static func ancillaryReviewIndices(
        in movement: CaseMovement, among instances: [IndexedInstance]
    ) -> Set<Int> {
        let rootNumber = normalizedCaseNumber(movement.caseNumber)
        var ancillaryNumbers = Set(movement.instances.compactMap { instance -> String? in
            guard instance.level == .material,
                  !isRootMaterial(instance, in: movement) else { return nil }
            let number = normalizedCaseNumber(instance.caseNumber)
            return number.isEmpty || number == rootNumber ? nil : number
        })
        var excluded = Set<Int>()
        var changed = true
        while changed {
            changed = false
            for candidate in instances where isReview(candidate.instance.level)
                && !excluded.contains(candidate.index) {
                let review = candidate.instance
                let lower = review.sourceEvidence?.lowerCourt
                let linkedDisposition = review.linkedActIDs.compactMap {
                    movement.actBodies[$0].flatMap(operativeDisposition)
                }.joined(separator: " ")
                let targetDates = explicitTargetActDates(in: linkedDisposition)
                let matchingMaterials = movement.instances.filter { material in
                    let lowerCourt = lower?.courtTitle ?? ""
                    guard material.level == .material, !isRootMaterial(material, in: movement),
                          lowerCourt.isEmpty || courtTitlesAgree(lowerCourt, material.court, domain: material.domain)
                    else { return false }
                    return material.sessions.contains { session in
                        guard let date = DateUtil.parse(session.date), targetDates.contains(date),
                              let result = nonempty(session.result) else { return false }
                        let value = normalized(result)
                        return isReliableMaterialTerminalResult(value)
                            || value == "удовлетворено частично"
                            || isTerminalDisposition(value)
                    }
                }
                let mainDates = Set(movement.instances.filter {
                    $0.level == .first || isRootMaterial($0, in: movement)
                }.flatMap {
                    $0.sessions.filter { isFinalActAnnouncement(event: $0.event, result: $0.result) }
                        .compactMap { DateUtil.parse($0.date) }
                })
                let targetsMaterial = matchingMaterials.count == 1
                    && targetDates.isDisjoint(with: mainDates)
                let matchingReviews = instances.filter { prior in
                    prior.index != candidate.index && isReview(prior.instance.level)
                        && reviewEventDate(in: prior.instance).map(targetDates.contains) == true
                }
                let targetsAncillaryReview = matchingReviews.count == 1
                    && matchingReviews.first.map { excluded.contains($0.index) } == true
                let mainActs = movement.instances.filter {
                    $0.level == .first || isRootMaterial($0, in: movement)
                }.flatMap { instance -> [CaseSession] in
                    var sessions = instance.sessions
                    if let date = instance.sourceEvidence?.decisionDate,
                       let result = instance.result,
                       isFinalActAnnouncement(event: "", result: result) {
                        sessions.append(CaseSession(date: date, event: "Опубликованный итог первой инстанции", result: result))
                    }
                    return sessions
                }.compactMap { session -> (Date, CaseSession)? in
                    guard isFinalActAnnouncement(event: session.event, result: session.result),
                          let date = DateUtil.parse(session.date),
                          reviewEventDate(in: review).map({ date <= $0 }) != false else { return nil }
                    return (date, session)
                }
                let latestMainDate = mainActs.map(\.0).max()
                let latestMainActs = mainActs.filter { $0.0 == latestMainDate }
                let mainHasDecision = !latestMainActs.isEmpty && latestMainActs.allSatisfy { _, session in
                    let text = normalized(session.event + " " + (session.result ?? ""))
                    return text.range(of: #"(?:вынесено|вынесен|принято)\s+решение(?:\s+по\s+делу)?"#,
                                      options: .regularExpression) != nil
                        || text.contains("иск") && (text.contains("удовлетвор")
                            || text.contains("отказано"))
                            && !text.contains("заявление возвращ")
                            && !text.contains("приняти") && !text.contains("принятия")
                }
                let referencesMainRegistration = movement.instances.contains { first in
                    guard first.level == .first || isRootMaterial(first, in: movement),
                          let lowerNumber = lower?.caseNumber,
                          let lowerTitle = lower?.courtTitle, !lowerTitle.isEmpty else { return false }
                    return normalizedCaseNumber(lowerNumber) == normalizedCaseNumber(first.caseNumber)
                        && courtTitlesAgree(lowerTitle, first.court, domain: first.domain)
                }
                let separateDetermination = review.level == .appeal && referencesMainRegistration && mainHasDecision
                    && normalized(review.result ?? "").range(
                        of: #"^определение\s+(?:оставлено\s+без\s+изменения|отменено)"#,
                        options: .regularExpression) != nil
                    && !normalized(linkedDisposition).hasPrefix("решение")
                guard lower?.caseNumber.map({ ancillaryNumbers.contains(normalizedCaseNumber($0)) }) == true
                    || targetsMaterial || targetsAncillaryReview || separateDetermination else { continue }
                excluded.insert(candidate.index)
                ancillaryNumbers.insert(normalizedCaseNumber(candidate.instance.caseNumber))
                changed = true
            }
        }
        return excluded
    }

    static func timeline(in movement: CaseMovement,
                         production: ProductionType? = nil,
                         verifiedMaterialScope: Bool = false) -> Timeline {
        let sourceOrdered = lifecycleInstances(in: movement).enumerated()
            .filter { _, instance in
                (instance.level != .material || isRootMaterial(instance, in: movement))
                    && instance.captchaFormURL == nil
                    && instance.transientError != true
            }
            .map { IndexedInstance(index: $0.offset, instance: $0.element) }
        let chronological = sourceOrdered.sorted {
            MovementService.precedesInChronology($0.instance, $1.instance)
        }
        let dated = chronological.filter { hasDatedSession($0.instance) }
        let ancillaryReviews = ancillaryReviewIndices(in: movement, among: sourceOrdered)
        let nonAncillary = sourceOrdered.filter { !ancillaryReviews.contains($0.index) }
        let relevant = nonAncillary.filter { candidate in
            guard isJoinedRegistration(candidate.instance, production: production),
                  let date = joinedEvidenceDate(in: candidate.instance) else { return true }
            return !nonAncillary.contains { other in
                other.index != candidate.index
                    && !isJoinedRegistration(other.instance, production: production)
                    && provesContinuation(other.instance, after: date)
            }
        }
        let relevantIndices = Set(relevant.map(\.index))
        let relevantDated = dated.filter { relevantIndices.contains($0.index) }
        // Возврат создаёт новый процессуальный круг только когда есть отдельная
        // датированная карточка целевой инстанции. У недатированного возврата
        // порядок источника предпочтителен; однако merge кэша кладёт такие
        // карточки в хвост, поэтому повторное звено цели также подтверждает
        // границу (первая инстанция → пересмотр → новая первая инстанция).
        var roundStarts: [IndexedInstance] = []
        for remand in relevant {
            guard let target = remandTarget(from: latestSignal(for: remand.instance)) else {
                continue
            }
            let targets = relevantDated.filter {
                $0.instance != remand.instance
                    && stage(for: $0.instance, production: production) == target
            }
            guard !targets.isEmpty else { continue }
            let remandDate = remand.instance.sessions.compactMap { session -> Date? in
                guard remandTarget(from: signal(in: session.result ?? session.event)) == target else { return nil }
                return DateUtil.parse(session.date)
            }.max() ?? reviewEventDate(in: remand.instance)
                ?? { () -> Date? in
                    guard remandTarget(in: remand.instance.result ?? "") == target else { return nil }
                    let dates = Set(remand.instance.sessions.filter {
                        normalized($0.event).trimmingCharacters(in: .whitespacesAndNewlines) == "рассмотрено"
                            || isHearingEvent(event: $0.event)
                    }.compactMap { DateUtil.parse($0.date) })
                    return dates.count == 1 ? dates.first : nil
                }()
            let continuations = targets.filter { targetInstance in
                let targetDate = earliestDatedSessionDate(in: targetInstance.instance)
                let followsRemand: Bool
                if let remandDate, let targetDate {
                    followsRemand = targetDate >= remandDate
                } else {
                    followsRemand = targetInstance.index > remand.index || targets.count > 1
                }
                return followsRemand
            }
            if let continuation = continuations.min(by: {
                MovementService.precedesInChronology($0.instance, $1.instance)
            }) {
                roundStarts.append(continuation)
            }
        }
        // A published acceptance after a concluded review starts a new round
        // even when the review resolved the issue itself rather than remanding.
        for first in relevantDated where isFirstLike(first.instance) {
            guard let acceptance = continuationDate(in: first.instance, acceptanceOnly: true) else { continue }
            if relevant.contains(where: { review in
                isReview(review.instance.level)
                    && (isConcludedReview(review.instance)
                        || (nonempty(review.instance.result) != nil
                            && review.instance.sourceEvidence?.decisionDate.flatMap(DateUtil.parse) != nil))
                    && reviewEventDate(in: review.instance).map { $0 < acceptance } == true
            }) { roundStarts.append(first) }
        }
        let currentRoundStart = roundStarts.max { left, right in
            let leftKey = MovementService.instanceOrderKey(left.instance)
            let rightKey = MovementService.instanceOrderKey(right.instance)
            return leftKey == rightKey ? left.index < right.index : leftKey < rightKey
        }
        let currentRoundDate = currentRoundStart.flatMap { first in
            continuationDate(in: first.instance, acceptanceOnly: true)
                ?? earliestDatedSessionDate(in: first.instance)
        }
        let hasJoinedRegistration = nonAncillary.contains {
            isJoinedRegistration($0.instance, production: production)
        }
        let latestFirst = hasJoinedRegistration
            ? relevantDated.filter { isFirstLike($0.instance) }.max {
                lifecyclePrecedes($0.instance, $1.instance, production: production)
            }
            : dated.last(where: { isFirstLike($0.instance) })
        var excludedAppeals = Set<Int>()
        var ambiguousAppeal = false
        // A verified UPK 22К complaint is not an appeal of the main verdict.
        // Keep it in the displayed chronology; with a main first instance it
        // must not cancel that instance's hearings or drive its deadlines.
        if production == .crim, latestFirst != nil {
            for review in relevant where review.instance.level == .appeal {
                if let index = CaseIndexClassifier.classify(
                    caseNumber: review.instance.caseNumber, courtLevel: .subject),
                   index.processKind == .upk, index.cardRole == .appellateComplaint {
                    excludedAppeals.insert(review.index)
                }
            }
        }
        if !verifiedMaterialScope, production == .civil || production == .kas, let first = latestFirst {
            let kinds = first.instance.sourceEvidence?.appealKinds?.map(normalized)
            let privateOnly = kinds?.contains(where: { $0.contains("частн") }) == true
                && kinds?.contains(where: { $0.contains("апелляцион") }) != true
            let hasMainAppeal = kinds?.contains(where: { $0.contains("апелляцион") }) == true
            for review in relevant where review.instance.level == .appeal {
                guard let start = earliestDatedSessionDate(in: first.instance),
                      let reviewDate = reviewEventDate(in: review.instance), reviewDate >= start,
                      currentRoundDate.map({ reviewDate >= $0 }) != false else { continue }
                let lower = review.instance.sourceEvidence?.lowerCourt
                let differentNumber = lower?.caseNumber.map {
                    normalizedCaseNumber($0) != normalizedCaseNumber(first.instance.caseNumber)
                } ?? false
                let lowerCourtTitle = CaseOriginResolver.normalizedTitle(lower?.courtTitle ?? "")
                let firstCourtTitle = CaseOriginResolver.normalizedTitle(first.instance.court)
                let differentCourt = !lowerCourtTitle.isEmpty && !firstCourtTitle.isEmpty
                    && !courtTitlesAgree(lower?.courtTitle ?? "", first.instance.court, domain: first.instance.domain)
                if differentNumber || differentCourt {
                    // A published reference to another registration cannot
                    // conclude the current first instance just because dates overlap.
                    ambiguousAppeal = true
                    continue
                }
                let continued = continuationDate(in: first.instance).map { $0 > reviewDate } == true
                let soleJudge = review.instance.sourceEvidence?.reviewProcedure.map {
                    normalized($0).contains("единолич")
                } == true
                if continued && !hasMainAppeal && (privateOnly || soleJudge) {
                    excludedAppeals.insert(review.index)
                } else if privateOnly || continued {
                    // Neither a missing AJ nor sole-judge proceedings alone
                    // prove the role of a particular appellate card.
                    ambiguousAppeal = true
                }
            }
        }
        let lifecycleOrdered = relevant.filter { !excludedAppeals.contains($0.index) }
        let lifecycleDated = relevantDated.filter { !excludedAppeals.contains($0.index) }
        let currentDated: IndexedInstance?
        if let currentRoundStart, let startDate = currentRoundDate {
            currentDated = lifecycleDated.filter {
                guard let date = earliestDatedSessionDate(in: $0.instance) else { return false }
                return date >= startDate
            }.max(by: { lifecyclePrecedes($0.instance, $1.instance, production: production) }) ?? currentRoundStart
        } else {
            currentDated = lifecycleDated.max(by: {
                lifecyclePrecedes($0.instance, $1.instance, production: production)
            })
        }
        return Timeline(production: production, sourceOrdered: sourceOrdered, lifecycleOrdered: lifecycleOrdered,
                        hasAmbiguousAppealEffect: ambiguousAppeal, chronological: chronological, dated: dated,
                        currentRoundStart: currentRoundStart, currentRoundDate: currentRoundDate, currentDated: currentDated)
    }

    static func resolve(movement: CaseMovement, production: ProductionType? = nil,
                        deadlines: [StoredDeadline],
                        deadlineAssessments _: [DeadlineRuleAssessment] = [],
                        today: Date = DateUtil.today) -> Resolution {
        let timeline = timeline(in: movement, production: production)
        let eligible = Set(timeline.lifecycleOrdered.map(\.index))
        let instances = timeline.chronological.filter { eligible.contains($0.index) }.map(\.instance)
        // Пустая карточка вышестоящего суда, найденная по УИД, полезна как
        // доказательство подачи жалобы (в частности, подавляет расчётный срок),
        // но не должна перекрывать последний датированный круг производства.
        let latestDated = timeline.currentDated?.instance
        // Исключение — карточка с содержательным `result`: некоторые порталы
        // публикуют итог без таблицы сессий. Такой результат надёжнее пустоты и
        // не должен теряться только из-за отсутствующей даты.
        let undatedWithResult = instances.filter {
            !hasDatedSession($0) && hasAuthoritativeResult($0)
        }
        // Карточка КСОЮ по КоАП может быть уже доступна, когда портал ещё не
        // опубликовал таблицу движения. Валидный номер в точном домене КСОЮ —
        // достаточное подтверждение активного надзорного производства; CAPTCHA
        // и сетевые заглушки сюда не попадают ещё на входе в timeline.
        let undatedActiveKSOYUReviews = instances.filter {
            isActiveUndatedKSOYUReview($0, production: production)
        }
        // Недатированный итог вышестоящей инстанции всё ещё надёжнее датированной
        // базовой карточки, но не вправе переписать более поздний круг того же
        // или более высокого звена.
        let latest: CaseInstance?
        if timeline.currentDatedStartsNewRound, let dated = timeline.currentDated {
            latest = dated.instance
        } else {
            let undated = (undatedWithResult + undatedActiveKSOYUReviews).max {
                let leftRank = stageRank($0, production: production)
                let rightRank = stageRank($1, production: production)
                if leftRank != rightRank { return leftRank < rightRank }
                return instanceOrder($0, in: timeline) < instanceOrder($1, in: timeline)
            }
            if let undated, let dated = latestDated,
               stageRank(dated, production: production) >= stageRank(undated, production: production) {
                latest = dated
            } else {
                latest = undated ?? latestDated ?? instances.last
            }
        }
        let visited = Set(instances.compactMap { stage(for: $0, production: production) })

        // Будущее заседание — наиболее сильный сигнал активного производства.
        // Берём ближайшее; при одинаковой дате более поздний круг выигрывает.
        let hearingInstances = instances.filter { instance in
            if isJoinedRegistration(instance, production: production) { return false }
            if let round = timeline.currentRoundDate,
               instance.id != timeline.currentRoundStart?.instance.id,
               (earliestDatedSessionDate(in: instance) ?? .distantPast) < round { return false }
            if isFirstLike(instance),
               let reviewDate = instances.filter({ isReview($0.level) }).compactMap({ reviewEventDate(in: $0) }).max(),
               (continuationDate(in: instance) ?? .distantPast) <= reviewDate { return false }
            return true
        }
        if let hearingInstance = instanceWithNearestFutureHearing(hearingInstances, today: today) {
            let active = stage(for: hearingInstance, production: production) ?? .first
            return Resolution(stage: active, currentInstance: hearingInstance,
                              steps: steps(visited: visited, active: active, production: production),
                              completionReason: nil, graceDeadline: nil)
        }

        if let latest, isJoinedRegistration(latest, production: production) {
            return completed(current: latest, visited: visited,
                             reason: .terminalFirst("Присоединено к другому делу"), production: production)
        }

        if timeline.hasAmbiguousAppealEffect, let first = timeline.latestFirst?.instance {
            if let latest, isReview(latest.level),
               let firstDecision = terminalEvidenceDate(in: first),
               let reviewDecision = reviewEventDate(in: latest),
               reviewDecision > firstDecision,
               reviewBelongsToRoot(latest, first: first, timeline: timeline),
               let reviewSignal = latestSignal(for: latest) {
                switch reviewSignal {
                case .terminal(let result):
                    return completed(current: latest, visited: visited,
                                     reason: .terminalReview(nonempty(latest.result) ?? result),
                                     production: production)
                case .legalForce:
                    return completed(current: latest, visited: visited, reason: .legalForce,
                                     production: production)
                case .active, .remand:
                    break
                }
            }
            if let result = exactTerminalResultAfterAmbiguousAppeal(
                first: first, timeline: timeline),
               !timeline.hasUnresolvedUndatedAppeal,
               !timeline.hasCassationInCurrentRound {
                return resolveTerminalFirst(current: first, result: result,
                                            visited: visited, deadlines: deadlines,
                                            today: today, production: production)
            }
            return Resolution(stage: .first, currentInstance: first,
                              steps: steps(visited: visited, active: .first, production: production),
                              completionReason: nil, graceDeadline: nil)
        }

        let currentSignal: InstanceSignal?
        if let latest, isFirstLike(latest),
           latest.id == timeline.currentRoundStart?.instance.id,
           let start = timeline.currentRoundDate,
           continuationDate(in: latest, acceptanceOnly: true) == start,
           !(nonempty(latest.result) != nil
             && latest.sourceEvidence?.decisionDate.flatMap(DateUtil.parse).map { $0 >= start } == true),
           !latest.sessions.contains(where: { session in
               guard let date = DateUtil.parse(session.date), date >= start else { return false }
               switch signal(in: session.event + " " + (session.result ?? "")) {
               case .terminal?, .legalForce?, .remand?: return true
               default: return false
               }
           }) {
            currentSignal = .active
        } else {
            currentSignal = latest.flatMap(latestSignal)
        }
        if let latest {
            switch currentSignal {
            case .remand(let target):
                return Resolution(stage: target, currentInstance: latestInstance(
                    for: target, among: instances, excluding: latest, production: production),
                                  steps: steps(visited: visited, active: target, production: production),
                                  completionReason: nil, graceDeadline: nil)
            case .legalForce:
                return completed(current: latest, visited: visited, reason: .legalForce,
                                 production: production)
            case .terminal(let result) where isReview(latest.level):
                return completed(current: latest, visited: visited,
                                 reason: .terminalReview(nonempty(latest.result) ?? result),
                                 production: production)
            case .terminal(let result) where isFirstLike(latest):
                // Неполная карточка реального пересмотра нового круга не доказывает
                // повышение стадии, но исключает автоматическое закрытие
                // первой инстанции из-за отсутствия расчётного срока.
                if timeline.hasUnresolvedUndatedAppeal || timeline.hasCassationInCurrentRound {
                    return Resolution(stage: .first, currentInstance: latest,
                                      steps: steps(visited: visited, active: .first, production: production),
                                      completionReason: nil, graceDeadline: nil)
                }
                return resolveTerminalFirst(current: latest, result: result,
                                            visited: visited, deadlines: deadlines, today: today,
                                            production: production)
            case .active, .terminal, nil:
                break
            }
        }

        // `CaseMovement.inForce` относится к базовой карточке. Он надёжен как
        // признак завершения только пока не найдено отдельное производство
        // пересмотра: иначе вступивший в силу базовый акт ошибочно перекрывал
        // живую апелляцию/кассацию (вплоть до будущего заседания).
        let hasReview = instances.contains { isReview($0.level) }
        let explicitlyActive = if case .active? = currentSignal { true } else { false }
        if movement.inForce && !hasReview && !explicitlyActive {
            return completed(current: latest, visited: visited, reason: .legalForce,
                             production: production)
        }

        // Расчётный срок не является юридическим фактом. Автоматическое
        // завершение разрешено только после явного подтверждения пользователем
        // и только со следующего дня после указанной даты.
        let confirmedDeadlineExpired = deadlines.contains {
            $0.isActive && $0.isUserControlled && $0.date < today
        }
        let unresolvedReview = latest.map { isReview($0.level) } ?? false
        if confirmedDeadlineExpired && !unresolvedReview && !explicitlyActive {
            return completed(current: latest, visited: visited, reason: .confirmedDeadline,
                             production: production)
        }

        let active = latest.flatMap { stage(for: $0, production: production) } ?? .first
        return Resolution(stage: active, currentInstance: latest,
                          steps: steps(visited: visited, active: active, production: production),
                          completionReason: nil, graceDeadline: nil)
    }

    /// Effective legal force shown to the user. The source flag remains the
    /// fallback for other productions; КоАП additionally publishes stronger
    /// evidence in movement rows and review cards.
    static func effectiveLegalForce(in movement: CaseMovement,
                                    production: ProductionType?) -> Bool {
        guard production == .koap else { return movement.inForce }
        let timeline = timeline(in: movement, production: production)
        let direct = timeline.deadlineFirst.flatMap(explicitLegalForceState)

        if let appeal = timeline.currentAppeal {
            switch latestSignal(for: appeal) {
            case .legalForce, .terminal:
                // A later reactivation/new first-instance round wins over an
                // historical appeal result.
                if direct?.effective == false,
                   isLater(direct?.date, than: reviewEventDate(in: appeal)) {
                    return false
                }
                return true
            case .remand:
                return false
            case .active, nil:
                // An active appeal cancels older force evidence. A later
                // direct row may still settle the status before the appeal
                // card exposes its terminal result.
                guard direct?.effective == true else { return false }
                return isLater(direct?.date, than: reviewEventDate(in: appeal))
            }
        }

        if let direct { return direct.effective }
        // КСОЮ/ВС РФ review under КоАП is post-force. `Timeline` has already
        // removed CAPTCHA/transient stubs and historical reviews before a new
        // round, so a remaining card is authoritative evidence.
        if timeline.hasCassationInCurrentRound { return true }
        // Do not carry the raw flag across a proved new first-instance round.
        return timeline.currentRoundStart == nil ? movement.inForce : false
    }

    private static func completed(current: CaseInstance?, visited: Set<CaseStageKind>,
                                  reason: CompletionReason,
                                  production: ProductionType?) -> Resolution {
        Resolution(stage: .done, currentInstance: current,
                   steps: steps(visited: visited, active: nil, production: production), completionReason: reason,
                   graceDeadline: nil)
    }

    private static func resolveTerminalFirst(current: CaseInstance, result: String,
                                             visited: Set<CaseStageKind>,
                                             deadlines: [StoredDeadline], today: Date,
                                             production: ProductionType?) -> Resolution {
        guard let deadline = deadlines.first(where: { $0.kind == "appeal" && $0.isActive }) else {
            return completed(current: current, visited: visited, reason: .terminalFirst(result),
                             production: production)
        }
        if deadline.isUserControlled, deadline.date < today {
            return completed(current: current, visited: visited, reason: .confirmedDeadline,
                             production: production)
        }
        // Расчётный срок — не юридический факт, но даём порталам семь полных
        // календарных дней после него на публикацию апелляции. На восьмой день
        // производство закрывается автоматически.
        let graceEnd = DateUtil.addDays(deadline.date, 7)
        if deadline.date >= today || today <= graceEnd {
            return Resolution(stage: .first, currentInstance: current,
                              steps: steps(visited: visited, active: .first, production: production),
                              completionReason: nil, graceDeadline: deadline)
        }
        return completed(current: current, visited: visited, reason: .terminalFirst(result),
                         production: production)
    }

    private static func latestInstance(for stage: CaseStageKind, among instances: [CaseInstance],
                                       excluding current: CaseInstance,
                                       production: ProductionType?) -> CaseInstance? {
        instances.last { candidate in
            candidate != current && self.stage(for: candidate, production: production) == stage
        }
    }

    static func stage(for instance: CaseInstance,
                      production: ProductionType?) -> CaseStageKind? {
        stage(for: instance.level, production: production)
    }

    static func stage(for level: CaseInstance.Level,
                      production: ProductionType?) -> CaseStageKind? {
        switch level {
        case .first, .material: return .first
        case .appeal: return .appeal
        case .cassation, .vsCassation:
            return production == .koap ? .supervisory : .cassation
        case .supervisory: return .supervisory
        }
    }

    private static func stageRank(_ instance: CaseInstance,
                                  production: ProductionType?) -> Int {
        switch stage(for: instance, production: production) {
        case .first: return 1
        case .appeal: return 2
        case .cassation: return 3
        case .supervisory: return 4
        case .done, nil: return 0
        }
    }

    private static func instanceOrder(_ instance: CaseInstance, in timeline: Timeline) -> Int {
        timeline.sourceOrdered.lastIndex { $0.instance == instance } ?? -1
    }

    /// КоАП не имеет отдельной пользовательской кассации: КСОЮ и ВС РФ входят
    /// в надзор. Для остальных производств надзор — следующий после кассации
    /// путь Президиума ВС РФ.
    static func stagePath(for production: ProductionType?) -> [CaseStageKind] {
        production == .koap
            ? [.first, .appeal, .supervisory]
            : [.first, .appeal, .cassation, .supervisory]
    }

    private static func steps(visited: Set<CaseStageKind>,
                              active: CaseStageKind?,
                              production: ProductionType?) -> [String] {
        let stages = stagePath(for: production)
        return stages.map { stage in
            if active == stage { return "active" }
            return visited.contains(stage) ? "done" : "todo"
        }
    }

    private static func instanceWithNearestFutureHearing(_ instances: [CaseInstance],
                                                         today: Date) -> CaseInstance? {
        var best: (date: Date, time: Int, index: Int, instance: CaseInstance)?
        for (index, instance) in instances.enumerated() {
            let instanceConcluded: Bool
            switch latestSignal(for: instance) {
            case .remand, .legalForce, .terminal: instanceConcluded = true
            case .active, nil: instanceConcluded = false
            }
            for session in instance.sessions where isHearing(
                event: session.event, result: session.result
            ) {
                guard let date = DateUtil.parse(session.date),
                      DateUtil.daysBetween(today, date) >= 0 else { continue }
                if instanceConcluded && DateUtil.sameDay(date, today) { continue }
                let candidate = (date, hearingTimeKey(session.time), index, instance)
                if let current = best {
                    if candidate.0 < current.date
                        || (candidate.0 == current.date && candidate.1 < current.time)
                        || (candidate.0 == current.date && candidate.1 == current.time
                            && candidate.2 > current.index) {
                        best = candidate
                    }
                } else {
                    best = candidate
                }
            }
        }
        return best?.instance
    }

    /// Канцелярские события движения. Они не подходят как fallback для даты
    /// итогового акта (#80), даже когда портал публикует их с датой и временем.
    private static let clericalEventMarkers = [
        "сдано в отдел", "сдано в архив", "передано в экспедици",
        "передача дела", "передача материал", "регистрация",
        "изготовлено мотивированн", "направление копи",
    ]

    static func isClericalEvent(_ event: String) -> Bool {
        let value = normalized(event)
        return clericalEventMarkers.contains { value.contains($0) }
    }

    /// Событие ПО СМЫСЛУ является судебным заседанием — безотносительно того,
    /// состоялось оно или ещё предстоит. Этим предикатом пользуется лента,
    /// которая раскладывает по видам уже прошедшие события. Время и результат
    /// строки не являются доказательством заседания; словарь расширяется только
    /// фактической формулировкой из карточки суда (#124).
    static func isHearingEvent(event: String) -> Bool {
        let value = normalized(event).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("заседани")
            || value.contains("слушани")
            || value == "беседа"
            || value.hasPrefix("рассмотрение дела по существу")
            || value.hasPrefix("рассмотрение жалоб")
    }

    /// Предикат БУДУЩЕГО заседания: смысл события плюс проверка, что круг им
    /// уже не закрыт. Общий для resolver и табличного представления.
    static func isHearing(event: String, result: String?) -> Bool {
        let value = normalized(event + " " + (result ?? ""))
        // Состоявшееся сегодня заседание с уже опубликованным итогом не должно
        // считаться будущим только потому, что сравнение идёт по календарному дню.
        if remandTarget(in: value) != nil || hasLegalForceEvidence(in: value)
            || isTerminalDisposition(value) { return false }
        return isHearingEvent(event: event)
    }

    /// Строковое сравнение ставило `11:00` раньше `9:00`. Неизвестное время
    /// сортируется после корректного HH:mm в тот же день.
    static func hearingTimeKey(_ time: String?) -> Int {
        guard let time else { return Int.max }
        let canonical = time.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: ":")
            .replacingOccurrences(of: "-", with: ":")
        let parts = canonical.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...23).contains(hours), (0...59).contains(minutes) else { return Int.max }
        return hours * 60 + minutes
    }

    static func hasLegalForceEvidence(event: String, result: String?) -> Bool {
        hasLegalForceEvidence(in: event + " " + (result ?? ""))
    }

    private static func explicitLegalForceState(
        in instance: CaseInstance
    ) -> (effective: Bool, date: Date?)? {
        let ordered = instance.sessions.enumerated().sorted { left, right in
            let leftDate = DateUtil.parse(left.element.date) ?? .distantPast
            let rightDate = DateUtil.parse(right.element.date) ?? .distantPast
            return leftDate == rightDate ? left.offset < right.offset : leftDate < rightDate
        }
        var state: (effective: Bool, date: Date?)?
        for (_, session) in ordered {
            if isReactivation(event: session.event, result: session.result) {
                state = (false, DateUtil.parse(session.date))
            } else if hasLegalForceEvidence(event: session.event, result: session.result) {
                state = (true, DateUtil.parse(session.date))
            }
        }
        return state
    }

    private static func isLater(_ candidate: Date?, than reference: Date?) -> Bool {
        guard let candidate else { return false }
        guard let reference else { return true }
        return candidate > reference
    }

    static func isReactivation(event: String, result: String?) -> Bool {
        isReactivation(normalized(event + " " + (result ?? "")))
    }

    private static func isReview(_ level: CaseInstance.Level) -> Bool {
        switch level {
        case .appeal, .cassation, .vsCassation, .supervisory: return true
        case .first, .material: return false
        }
    }

    private static func hasDatedSession(_ instance: CaseInstance) -> Bool {
        instance.sessions.contains { DateUtil.parse($0.date) != nil }
    }

    /// Заголовок реальной карточки КСОЮ по КоАП сам по себе подтверждает
    /// начавшийся надзорный круг: движение там часто появляется позднее. Для
    /// этого нужны настоящий номер и точный домен КСОЮ; похожая строка или
    /// placeholder не проходят проверку.
    private static func isActiveUndatedKSOYUReview(_ instance: CaseInstance,
                                                    production: ProductionType?) -> Bool {
        guard production == .koap,
              instance.level == .cassation,
              instance.captchaFormURL == nil,
              instance.transientError != true,
              !hasDatedSession(instance),
              !isConcludedReview(instance),
              CaseNumberPresentation.secondary(instance.caseNumber, distinctFrom: "") != nil
        else { return false }
        let court = instance.court.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !court.isEmpty, !["—", "–", "-"].contains(court) else { return false }
        let domain = SudrfHost.moduleHost(instance.domain.lowercased())
        return CourtDirectory.cassationCourts.contains { $0.domain == domain }
    }

    static func earliestDatedSessionDate(in instance: CaseInstance) -> Date? {
        (instance.sessions.compactMap { DateUtil.parse($0.date) }
            + [instance.sourceEvidence?.receiptDate.flatMap(DateUtil.parse)].compactMap { $0 }).min()
    }

    /// Date of an actual published review event, never its future scheduled hearing.
    private static func reviewEventDate(in instance: CaseInstance) -> Date? {
        if let decision = instance.sourceEvidence?.decisionDate.flatMap(DateUtil.parse) { return decision }
        return instance.sessions.compactMap { session -> Date? in
            guard !isClericalEvent(session.event),
                  !isHearingEvent(event: session.event) || session.result?.isEmpty == false,
                  signal(in: session.event + " " + (session.result ?? "")) != nil else { return nil }
            return DateUtil.parse(session.date)
        }.max() ?? instance.sourceEvidence?.receiptDate.flatMap(DateUtil.parse)
    }

    /// A review registered earlier can be decided after another review.
    /// Administrative rows after a first-instance decision do not reopen it.
    private static func lifecyclePrecedes(_ lhs: CaseInstance, _ rhs: CaseInstance, production: ProductionType?) -> Bool {
        func date(_ instance: CaseInstance) -> Date {
            if isReview(instance.level) {
                return reviewEventDate(in: instance)
                    ?? earliestDatedSessionDate(in: instance) ?? .distantPast
            }
            return [terminalEvidenceDate(in: instance), continuationDate(in: instance),
                    isJoinedRegistration(instance, production: production) ? joinedEvidenceDate(in: instance) : nil,
                    earliestDatedSessionDate(in: instance)]
                .compactMap { $0 }.max() ?? .distantPast
        }
        let left = date(lhs), right = date(rhs)
        return left == right ? MovementService.precedesInChronology(lhs, rhs) : left < right
    }

    private static func continuationDate(in instance: CaseInstance, acceptanceOnly: Bool = false) -> Date? {
        instance.sessions.compactMap { session -> Date? in
            let text = normalized(session.event + " " + (session.result ?? ""))
            guard !isDenied(text) else { return nil }
            let words = text.split(whereSeparator: { !$0.isLetter })
            let namesFirstProceeding = words.contains {
                $0.hasPrefix("иск") || $0.hasPrefix("заявлен") || $0 == "дело" || $0 == "дела"
            }
            let namesMainCase = words.contains {
                $0.hasPrefix("иск") || $0 == "дело" || $0 == "дела"
            }
            let ancillary = mentionsIntermediateObject(text)
            let accepted = text.contains("принят") && text.contains("производств")
                && (!text.contains("жалоб") || namesFirstProceeding)
                && (!ancillary || namesMainCase)
            let resumed = text.contains("возобнов") && !text.contains("срок")
                && (!ancillary || text.contains("производство по делу")
                    || text.contains("дело возобнов"))
            let event = normalized(session.event)
            let explicitAssignment = event.contains("назнач") && event.contains("заседан")
            let assigned = !acceptanceOnly && text.contains("назнач") && text.contains("заседан")
                && !ancillary && (explicitAssignment || !isHearingEvent(event: session.event))
            guard accepted || resumed || assigned else { return nil }
            return DateUtil.parse(session.date)
        }.max()
    }

    private static func hasAuthoritativeResult(_ instance: CaseInstance) -> Bool {
        guard let result = nonempty(instance.result) else { return false }
        return signal(in: result) != nil
            || instance.level == .first && hasReliableHomeResult(instance)
                && isReliableFirstTerminalResult(normalized(result))
    }

    /// Возвращает последний актуальный процессуальный сигнал внутри одного
    /// круга. Итог карточки имеет приоритет; иначе сессии рассматриваются по
    /// хронологии, чтобы старое вступление в силу/возврат не побеждало более
    /// позднее возобновление или новый конечный результат.
    private static func latestSignal(for instance: CaseInstance) -> InstanceSignal? {
        let ambiguousComplaintResultDates = ambiguousKoAPKSOYUComplaintResultDates(instance)
        let ordered = instance.sessions.enumerated().sorted { left, right in
            let leftDate = DateUtil.parse(left.element.date) ?? .distantPast
            let rightDate = DateUtil.parse(right.element.date) ?? .distantPast
            return leftDate == rightDate ? left.offset < right.offset : leftDate < rightDate
        }
        var latest: InstanceSignal?
        var hasOperativeActSignal = false
        // Возобновление остаётся доминирующим состоянием через последующие
        // регистрации/принятие жалобы; сбросить его может только более поздний
        // конечный сигнал, а не очередная активная административная строка.
        var reactivationStillDominant = false
        for (_, session) in ordered {
            let event = nonempty(session.event)
            let isAmbiguousComplaintResult = normalized(session.event)
                == "результат рассмотрения жалобы"
                && ambiguousComplaintResultDates.contains(
                    complaintResultDateKey(session.date))
            let result = isAmbiguousComplaintResult ? nil : nonempty(session.result)
            let combined = [event, result].compactMap { $0 }.joined(separator: " ")
            if let current = result.flatMap({ value -> InstanceSignal? in
                if instance.level == .material,
                   isReliableMaterialTerminalResult(normalized(value)) {
                    return .terminal(value)
                }
                return signal(in: value)
            })
                ?? event.flatMap(signal)
                ?? (combined.isEmpty ? nil : signal(in: combined)) {
                if normalized(session.event) == "резолютивная часть опубликованного акта" {
                    hasOperativeActSignal = true
                }
                let previous = latest
                latest = current
                if case .active = current,
                   isReactivation(normalized(combined)) || isConcluding(previous) {
                    reactivationStillDominant = true
                } else if case .legalForce = current {
                    reactivationStillDominant = false
                } else if case .terminal = current {
                    reactivationStillDominant = false
                } else if case .remand = current {
                    reactivationStillDominant = false
                }
            }
        }
        // Итог карточки обычно не датирован и должен перебивать старые строки,
        // но опубликованное позднее вступление в силу/возобновление — более
        // сильный, явно хронологический сигнал.
        if !hasOperativeActSignal,
           let result = nonempty(instance.result), let resultSignal = signal(in: result) {
            if let latest {
                switch latest {
                case .legalForce:
                    return latest
                case .active where reactivationStillDominant:
                    return latest
                default:
                    break
                }
            }
            return resultSignal
        }
        if let latest {
            switch latest {
            case .legalForce:
                return latest
            case .active where reactivationStillDominant:
                return latest
            default:
                break
            }
        }
        if isFirstLike(instance), hasReliableHomeResult(instance),
           let result = nonempty(instance.result),
           isReliableFirstTerminalResult(normalized(result)) {
            return .terminal(result)
        }
        if instance.level == .material, hasDatedSession(instance),
           let result = nonempty(instance.result),
           isReliableMaterialTerminalResult(normalized(result)) {
            return .terminal(result)
        }
        return latest
    }

    /// #300 remains fail-closed for an ambiguous appeal unless the same root
    /// card publishes a strictly later, dated terminal outcome in this round.
    private static func exactTerminalResultAfterAmbiguousAppeal(
        first: CaseInstance, timeline: Timeline
    ) -> String? {
        guard case .terminal(let result)? = latestSignal(for: first),
              let terminalDate = terminalEvidenceDate(in: first) else { return nil }
        let latestAppealDate = timeline.lifecycleOrdered.compactMap { candidate -> Date? in
            guard candidate.instance.level == .appeal else { return nil }
            return reviewEventDate(in: candidate.instance)
        }.max()
        guard latestAppealDate.map({ terminalDate > $0 }) == true else { return nil }
        return nonempty(first.result) ?? result
    }

    static func courtTitlesAgree(_ lhs: String, _ rhs: String, domain: String) -> Bool {
        if CaseOriginResolver.normalizedTitle(lhs) == CaseOriginResolver.normalizedTitle(rhs) { return true }
        guard let region = CourtDirectory.regionSuffix(ofDomain: domain)
            .flatMap(CourtDirectory.subjectCode(forRegionSuffix:))
            .flatMap(CourtDirectory.subjectName(forSubjectCode:)) else { return false }
        if CaseOriginResolver.sameCourtTitle(lhs, rhs, region: region) { return true }

        // A review card may omit the city of its lower court. Only accept that
        // omission for a complete district-court name with a proved regional
        // suffix; presentation keys alone discard regions and are not identity.
        let left = CourtNamePresentation.display(lhs)
        let right = CourtNamePresentation.display(rhs)
        guard left.tier == .district, right.tier == .district,
              (left.locality == nil) != (right.locality == nil) else { return false }
        let bare = left.locality == nil ? left.full : right.full
        let full = left.locality == nil ? right.full : left.full
        guard let cityStart = full.range(of: #"\s+(?:г\.|города)\s+"#,
                                         options: [.regularExpression, .caseInsensitive]),
              CaseOriginResolver.normalizedTitle(String(full[..<cityStart.lowerBound]))
                == CaseOriginResolver.normalizedTitle(bare) else { return false }
        let words = full[cityStart.upperBound...].split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return false }
        for boundary in 1..<words.count {
            let suffix = "Суд " + words[boundary...].joined(separator: " ")
            guard CaseOriginResolver.sameCourtTitle(suffix, "Суд", region: region),
                  !CaseOriginResolver.sameCourtTitle(suffix, "Суд", region: "") else { continue }
            let city = words[..<boundary].joined(separator: " ")
            // Do not swallow a conflicting region or an unrecognized tail as
            // part of the city while searching for the matching suffix.
            return city.range(of: #"^(?:[\p{L}-]+\s+)*[\p{L}-]+$"#,
                              options: .regularExpression) != nil
                && city.range(of: #"\b(?:республик\p{L}*|област\p{L}*|край|края|автономн\p{L}*|округ\p{L}*)\b"#,
                              options: [.regularExpression, .caseInsensitive]) == nil
        }
        return false
    }

    private static func reviewBelongsToRoot(
        _ review: CaseInstance, first: CaseInstance, timeline: Timeline
    ) -> Bool {
        guard let lower = review.sourceEvidence?.lowerCourt else { return true }
        let lowerCourtTitle = CaseOriginResolver.normalizedTitle(lower.courtTitle ?? "")
        let rootCourtTitle = CaseOriginResolver.normalizedTitle(first.court)
        let sameOrUnknownCourt = lowerCourtTitle.isEmpty || rootCourtTitle.isEmpty
            || courtTitlesAgree(lower.courtTitle ?? "", first.court, domain: first.domain)
        guard let lowerCaseNumber = lower.caseNumber else { return sameOrUnknownCourt }
        let lowerNumber = normalizedCaseNumber(lowerCaseNumber)
        let rootNumber = normalizedCaseNumber(first.caseNumber)
        if lowerNumber == rootNumber {
            return sameOrUnknownCourt
        }
        guard review.level != .appeal else { return false }
        return timeline.lifecycleOrdered.contains { candidate in
            guard candidate.instance.level == .appeal,
                  normalizedCaseNumber(candidate.instance.caseNumber) == lowerNumber else { return false }
            return reviewBelongsToRoot(candidate.instance, first: first, timeline: timeline)
        }
    }

    private static func terminalEvidenceDate(in instance: CaseInstance) -> Date? {
        var dates = instance.sessions.compactMap { session -> Date? in
            guard isFinalActAnnouncement(event: session.event, result: session.result) else { return nil }
            return DateUtil.parse(session.date)
        }
        if let result = nonempty(instance.result),
           isReliableFirstTerminalResult(normalized(result)),
           let date = instance.sourceEvidence?.decisionDate.flatMap(DateUtil.parse) {
            dates.append(date)
        }
        return dates.max()
    }

    private static func isConcluding(_ signal: InstanceSignal?) -> Bool {
        switch signal {
        case .remand, .legalForce, .terminal: return true
        case .active, nil: return false
        }
    }

    static func hasAmbiguousKoAPKSOYUComplaintResult(_ instance: CaseInstance) -> Bool {
        !ambiguousKoAPKSOYUComplaintResultDates(instance).isEmpty
    }

    private static func ambiguousKoAPKSOYUComplaintResultDates(
        _ instance: CaseInstance
    ) -> Set<String> {
        guard instance.level == .cassation,
              CourtDirectory.cassationCourts.contains(where: {
                  SudrfHost.moduleHost($0.domain) == SudrfHost.moduleHost(instance.domain)
              }),
              let sourceURL = instance.sourceURL,
              let components = URLComponents(
                url: sourceURL, resolvingAgainstBaseURL: false),
              components.path == "/modules.php",
              SudrfHost.moduleHost(components.host ?? "")
                == SudrfHost.moduleHost(instance.domain),
              let queryItems = components.queryItems
        else { return [] }
        func exactValue(_ name: String) -> String? {
            let values = queryItems.filter { $0.name == name }.compactMap(\.value)
            return values.count == 1 ? values[0] : nil
        }
        guard exactValue("name") == "sud_delo",
              exactValue("name_op") == "case",
              exactValue("delo_id") == "2550001" else { return [] }

        let rows = instance.sessions.filter {
            normalized($0.event) == "результат рассмотрения жалобы"
        }
        let grouped = Dictionary(grouping: rows) {
            complaintResultDateKey($0.date)
        }
        return Set(grouped.compactMap { date, sessions in
            let results = Set(sessions.compactMap { nonempty($0.result).map(normalized) })
            return results.count > 1 ? date : nil
        })
    }

    private static func complaintResultDateKey(_ raw: String) -> String {
        if let date = DateUtil.parse(raw) {
            return "day:\(DateUtil.startOfDay(date).timeIntervalSinceReferenceDate)"
        }
        return "raw:\(raw.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private static func remandTarget(from signal: InstanceSignal?) -> CaseStageKind? {
        guard case .remand(let target)? = signal else { return nil }
        return target
    }

    /// После доказанного возврата лишь завершённый недатированный пересмотр
    /// можно отнести к старому кругу. Активная карточка без даты остаётся
    /// консервативным свидетельством подачи, но сама не повышает стадию.
    static func isConcludedReview(_ instance: CaseInstance) -> Bool {
        switch latestSignal(for: instance) {
        case .remand, .legalForce, .terminal:
            return true
        case .active, nil:
            return false
        }
    }

    private static func signal(in source: String) -> InstanceSignal? {
        let value = normalized(source)
        if isReactivation(value) { return .active }
        if let target = remandTarget(in: value) { return .remand(target) }
        if hasLegalForceEvidence(in: value) { return .legalForce }
        if isTerminalDisposition(value) { return .terminal(source) }
        if isActiveProceeding(value) { return .active }
        return nil
    }

    private static func remandTarget(in source: String) -> CaseStageKind? {
        let value = normalized(source)
        guard !value.contains("без направ") else { return nil }
        let returnedToAcceptance = (value.contains("возврат") || value.contains("возвращ"))
            && value.contains("рассмотр") && value.contains("стади")
            && value.contains("принят") && value.contains("производств")
        if returnedToAcceptance { return .first }
        guard value.contains("направ"), value.contains("нов"),
              value.contains("рассмотр") else { return nil }
        return value.contains("апелляцион") ? .appeal : .first
    }

    /// Датированный официальный итог пересмотра, который возвращает материал
    /// в первую инстанцию. Используется identity-repair только как независимое
    /// доказательство перед поиском следующей регистрации.
    static func confirmedFirstInstanceRemandDate(in movement: CaseMovement) -> Date? {
        lifecycleInstances(in: movement).compactMap { instance -> Date? in
            guard isReview(instance.level),
                  remandTarget(from: latestSignal(for: instance)) == .first
            else { return nil }
            return reviewEventDate(in: instance)
        }.max()
    }

    private static func hasLegalForceEvidence(in source: String) -> Bool {
        let value = normalized(source)
        return value.contains("вступ") && value.contains("законн") && value.contains("сил")
    }

    private static func isReactivation(_ value: String) -> Bool {
        guard !isDenied(value) else { return false }
        let words = Set(value.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let restorationOrdered = !words.isDisjoint(with: [
            "восстановлен", "восстановлена", "восстановлено", "восстановлены", "восстановить",
        ])
        let restoredDeadline = value.contains("срок")
            && (restorationOrdered
                || (value.contains("восстанов") && value.contains("удовлетвор")
                    && !value.contains("без удовлетвор")))
        return value.contains("возобнов")
            || restoredDeadline
            || (value.contains("пересмотр") && value.contains("обстоятель")
                && (value.contains("нов") || value.contains("вновь")))
    }

    private static func isActiveProceeding(_ value: String) -> Bool {
        guard !isDenied(value) else { return false }
        if mentionsIntermediateObject(value) {
            let words = value.split(whereSeparator: { !$0.isLetter })
            let namesMainCase = words.contains {
                $0.hasPrefix("иск") || $0 == "дело" || $0 == "дела"
            }
            let namesMainAcceptance = value.contains("принят") && value.contains("производств")
                && namesMainCase
            guard namesMainAcceptance else { return false }
        }
        return (value.contains("принят") && value.contains("производств"))
            || (value.contains("регистрац")
                && (value.contains("жалоб") || value.contains("производств")
                    || value.contains("дел")))
            || value.contains("назначено заседание")
    }

    private static func isTerminalDisposition(_ value: String) -> Bool {
        let removedFromReview = isRemovedFromReview(value)
        let unchanged = value.contains("остав")
            && (value.contains("без удовлетвор") || value.contains("без изменен"))
        let transferDenied = value.contains("отказ") && value.contains("передач")
        // Прекращение — итог само по себе. Требовать рядом слово «производство»
        // нельзя: портал пишет в результате заседания просто «Прекращено»
        // (#84). Отсекаются только прекращения промежуточных объектов вроде
        // ходатайства или запроса.
        let terminated = value.contains("прекращ") && !mentionsIntermediateObject(value)
        // Возврат жалобы ЗАЯВИТЕЛЮ завершает круг и без слов «без рассмотрения»:
        // жалоба к рассмотрению не принята, производства по ней нет (#84).
        // Адресат обязателен: без него под формулу попадал бы и возврат дела ИЗ
        // вышестоящей инстанции («возвращено из вышестоящей инстанции после
        // рассмотрения жалобы»), а это не итог, а продолжение движения.
        let complaintReturned = (value.contains("возврат") || value.contains("возвращ"))
            && (value.contains("жалоб") || value.contains("представлен"))
            && value.contains("заявител")
        // КСОЮ также публикует возврат без адресата и слов «без рассмотрения»,
        // но с точным основанием: жалоба/представление поданы с нарушением
        // правил подсудности. Все три признака обязательны, поэтому возврат
        // дела из вышестоящего суда сюда не попадает (#275).
        let wrongJurisdictionComplaintReturn =
            (value.contains("возврат") || value.contains("возвращ"))
            && (value.contains("жалоб") || value.contains("представлен"))
            && value.contains("подсудн")
        let returned = complaintReturned || wrongJurisdictionComplaintReturn
            || ((value.contains("возврат") || value.contains("возвращ"))
                && value.contains("без рассмотр"))
        let wholeProceedingSubject = isWholeProceedingSubject(value)
        let leftWithoutConsideration = value.contains("остав") && value.contains("без рассмотр")
            && wholeProceedingSubject
        let restorationDenied = isDenied(value) && value.contains("восстанов")
            && value.contains("срок")
        let acceptanceDenied = isDenied(value) && value.contains("принят")
            && (value.contains("производств")
                || value.contains("иск") || value.contains("заявлен"))
            && !mentionsIntermediateObject(value)
        let koapProtocolReturned = (value.contains("возврат") || value.contains("возвращ"))
            && value.contains("протокол") && value.contains("материал")
            && value.contains("административн") && value.contains("правонаруш")
        let judicialAct = value.contains("решен") || value.contains("приговор")
            || value.contains("постановлен") || value.contains("определен")
            || (value.contains("судебн") && value.contains("акт"))
        let changedWithoutRemand = value.contains("измен") && judicialAct
            && remandTarget(in: value) == nil
        // Узкая формула отмены без направления — итог; обычные слова вроде
        // «отмена заседания» или «отменена доверенность» сюда не попадают.
        let cancelledWithoutDirection = value.contains("отмен") && value.contains("без направ")
        let cancelledActWithNewDecision = value.contains("отмен") && judicialAct
            && (value.contains("новое решен") || value.contains("принят") && value.contains("нов")
                && value.contains("решен"))
        let meritsDecision = value.contains("вынес") && value.contains("решен")
        let satisfiedWithoutRemand = value.contains("жалоб") && value.contains("удовлетвор")
            && !value.contains("без удовлетвор")
            && !(value.contains("направ") && value.contains("рассмотр"))
        return removedFromReview
            || unchanged || transferDenied || terminated || returned || leftWithoutConsideration
            || restorationDenied || acceptanceDenied || koapProtocolReturned
            || changedWithoutRemand || cancelledWithoutDirection || cancelledActWithNewDecision
            || meritsDecision || satisfiedWithoutRemand
    }

    private static func isRemovedFromReview(_ value: String) -> Bool {
        normalized(value).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            == "снято по другим основаниям"
    }

    /// A review card may publish only a generic short result while its linked
    /// act contains the exact disposition. Add that disposition to a local
    /// lifecycle copy; the saved movement and the user-facing source wording
    /// remain untouched.
    private static func lifecycleInstances(in movement: CaseMovement) -> [CaseInstance] {
        let acts = Dictionary(movement.acts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return movement.instances.map { source in
            guard isReview(source.level) else { return source }
            var instance = source
            for actID in source.linkedActIDs {
                guard let act = acts[actID], act.instanceLevel == source.level else { continue }
                let actDate: String?
                if DateUtil.parse(act.date) != nil {
                    actDate = act.date
                } else if source.actID == actID || source.linkedActIDs.count == 1,
                          let decisionDate = source.sourceEvidence?.decisionDate,
                          DateUtil.parse(decisionDate) != nil {
                    actDate = decisionDate
                } else {
                    actDate = nil
                }
                guard let actDate,
                      let body = movement.actBodies[actID],
                      let disposition = operativeDisposition(in: body),
                      let dispositionSignal = signal(in: disposition),
                      isConcluding(dispositionSignal),
                      !instance.sessions.contains(where: {
                          $0.date == actDate && normalized($0.result ?? "") == normalized(disposition)
                      }) else { continue }
                instance.sessions.append(CaseSession(
                    date: actDate,
                    event: "Резолютивная часть опубликованного акта",
                    result: disposition))
            }
            return instance
        }
    }

    static func explicitTargetActDates(in source: String) -> Set<Date> {
        let value = normalized(source)
        let pattern = #"(?:определение|решение)\s+[^.!?]{0,250}?\sот\s+(?:\d{1,2}\.\d{1,2}\.\d{4}|\d{1,2}\s+[а-я]+\s+\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return Set(regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).flatMap { match -> [Date] in
            guard let range = Range(match.range, in: value) else { return [] }
            return Array(explicitActDates(in: String(value[range])))
        })
    }

    static func explicitActDates(in source: String) -> Set<Date> {
        let value = normalized(source)
        let months = ["января", "февраля", "марта", "апреля", "мая", "июня",
                      "июля", "августа", "сентября", "октября", "ноября", "декабря"]
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(\d{1,2})[.\s]+(\d{1,2}|"# + months.joined(separator: "|") + #")[.\s]+(\d{4})\b"#) else { return [] }
        return Set(regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            let fields = (1...3).compactMap { Range(match.range(at: $0), in: value).map { String(value[$0]) } }
            guard fields.count == 3,
                  let month = Int(fields[1]) ?? months.firstIndex(of: fields[1]).map({ $0 + 1 }) else { return nil }
            return DateUtil.parse("\(fields[0]).\(month).\(fields[2])")
        })
    }

    static func operativeDisposition(in source: String) -> String? {
        let paragraphs = ActParagraphizer.paragraphs(in: source)
        let markers = Set(["решил", "решила", "постановил", "постановила",
                           "определил", "определила", "приговорил", "приговорила"])
        var marker: (paragraph: Int, colon: String.Index)?
        for paragraphIndex in paragraphs.indices.reversed() {
            let text = paragraphs[paragraphIndex].text
            for colon in text.indices.reversed() where text[colon] == ":" {
                let prefix = normalized(String(text[..<colon])).filter(\.isLetter)
                if markers.contains(where: prefix.hasSuffix) {
                    marker = (paragraphIndex, colon)
                    break
                }
            }
            if marker != nil { break }
        }
        guard let marker else { return nil }
        let markerText = paragraphs[marker.paragraph].text
        let inline = String(markerText[markerText.index(after: marker.colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = paragraphs.dropFirst(marker.paragraph + 1).map(\.text)
        let disposition = ([inline] + trailing).filter { !$0.isEmpty }.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return disposition.isEmpty ? nil : disposition
    }

    /// Событие движения, которым объявлен обжалуемый итоговый акт первой
    /// инстанции: приговор, решение по иску, постановление по КоАП.
    ///
    /// Нужен для выбора триггера процессуального срока (#80). Само по себе
    /// заполненное поле «Результат события» триггером НЕ является: портал
    /// заполняет его и у промежуточных строк, а расчёт «от последней строки с
    /// непустым результатом» привязывал срок апелляции к произвольному
    /// событию — по уголовным делам особенно заметно.
    static func isFinalActAnnouncement(event: String, result: String?) -> Bool {
        let value = normalized(event + " " + (result ?? ""))
        guard !isRemovedFromReview(value) else { return false }
        // Два уже существующих словаря дополняют друг друга: конечные формулы
        // первой инстанции знают «приговор» и «иск удовлетворён», словарь
        // терминальных исходов — «производство прекращено», «оставлено без
        // изменения» и отмену с новым решением.
        return isReliableFirstTerminalResult(value) || isTerminalDisposition(value)
    }

    /// Stable, deliberately narrow disposition vocabulary for the semantic
    /// shadow journal. It is gated by the lifecycle predicates above so an
    /// arbitrary wording edit cannot become `resultChanged`.
    static func semanticDisposition(event: String = "", result: String?) -> String? {
        let value = normalized(event + " " + (result ?? ""))
        if let target = remandTarget(in: value) { return "remand:\(target.rawValue)" }
        if hasLegalForceEvidence(in: value) { return "legal-force" }
        guard isFinalActAnnouncement(event: event, result: result) else { return nil }
        if value.contains("остав") && (value.contains("без изменен")
            || value.contains("без удовлетвор")) { return "unchanged" }
        if value.contains("прекращ") { return "terminated" }
        if value.contains("возврат") || value.contains("возвращ") { return "returned" }
        if value.contains("отмен") && value.contains("без направ") {
            return "cancelled-no-remand"
        }
        if value.contains("измен") && (value.contains("решен")
            || value.contains("приговор") || value.contains("постановлен")
            || value.contains("определен")) { return "changed" }
        return nil
    }

    /// Конечные формулы первой инстанции. Намеренно не считаем итогом простое
    /// «рассмотрение отложено», «принято» или неоконченную карточку.
    private static func isReliableFirstTerminalResult(_ value: String) -> Bool {
        let civilOrKAS = value.contains("иск")
            && (value.contains("удовлетвор") || value.contains("отказано"))
        let criminal = value.contains("приговор")
        let koap = value.contains("постановлен")
            && (value.contains("административн") || value.contains("производств") || value.contains("наказан"))
        let wholeProceedingSubject = isWholeProceedingSubject(value)
        let proceduralReturn = (value.contains("остав") && value.contains("без рассмотрен")
            && wholeProceedingSubject)
            || (value.contains("заявлен") && value.contains("возвращ"))
        let bareDecision = value.contains("решен") && value.contains("вынес")
        return civilOrKAS || criminal || koap || proceduralReturn || bareDecision
            || isTerminalDisposition(value)
    }

    static func isMaterialAdjudication(event: String, result: String?) -> Bool {
        let value = normalized(result ?? "")
        return isReliableMaterialTerminalResult(value) || value == "удовлетворено частично"
            || isFinalActAnnouncement(event: event, result: result)
    }

    private static func isReliableMaterialTerminalResult(_ value: String) -> Bool {
        let compact = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact == "удовлетворено"
            || compact == "отказано"
            || compact == "в удовлетворении отказано"
    }

    private static func hasReliableHomeResult(_ instance: CaseInstance) -> Bool {
        guard let result = nonempty(instance.result), isReliableFirstTerminalResult(normalized(result)) else {
            return false
        }
        // Прямой акт/сессия или найденная по УИД карточка — сильный источник.
        // Для домашней карточки без УИД таким источником является опубликованный
        // акт (обычный production-путь, не произвольная строка выдачи).
        return instance.foundByUID || hasDatedSession(instance)
            || !instance.linkedActIDs.isEmpty
    }

    /// Промежуточные объекты производства: их судьба итогом дела не является.
    private static let intermediateObjects = ["ходатайств", "запрос", "доказательств", "отвод"]

    private static func mentionsIntermediateObject(_ value: String) -> Bool {
        intermediateObjects.contains(where: value.contains)
    }

    /// «Без рассмотрения» относится к исходу дела, только когда объектом
    /// является весь спор. Слово «дело» в «ходатайство по делу» этого не меняет.
    private static func isWholeProceedingSubject(_ value: String) -> Bool {
        guard !mentionsIntermediateObject(value) else { return false }
        return value.contains("иск") || value.contains("заявлен")
            || value.contains("жалоб") || value.contains("дел")
    }

    private static func isDenied(_ value: String) -> Bool {
        value.contains("отказ") || value.contains("не восстанов")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalized(_ source: String) -> String {
        source.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func isFirstLike(_ instance: CaseInstance) -> Bool {
        instance.level == .first || instance.level == .material
    }

    private static func normalizedCaseNumber(_ source: String) -> String {
        normalized(CaseNumberPresentation.primary(source))
            .filter { !$0.isWhitespace }
    }
}
