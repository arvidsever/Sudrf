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
        var sourceOrdered: [IndexedInstance]
        var chronological: [IndexedInstance]
        var dated: [IndexedInstance]
        /// Первая датированная инстанция нового круга, созданного возвратом.
        var currentRoundStart: IndexedInstance?
        var currentDated: IndexedInstance?
        var currentDatedStartsNewRound: Bool { currentRoundStart != nil }

        var instances: [CaseInstance] { chronological.map(\.instance) }

        var latestFirst: IndexedInstance? {
            dated.last(where: { $0.instance.level == .first })
                ?? chronological.last(where: { $0.instance.level == .first })
        }

        /// Карточка апелляции без дат не доказывает стадию, но достаточно
        /// надёжна, чтобы не предлагать пользователю уже поданную жалобу.
        /// Датированная апелляция относится к текущему кругу только после
        /// последней первой инстанции этого круга.
        var hasAppealInCurrentRound: Bool {
            guard let latestFirst else {
                return sourceOrdered.contains { $0.instance.level == .appeal }
            }
            let firstDate = CaseLifecycleResolver.earliestDatedSessionDate(in: latestFirst.instance)
            for candidate in sourceOrdered where candidate.instance.level == .appeal {
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

        var hasUnresolvedUndatedAppeal: Bool {
            return sourceOrdered.contains {
                $0.instance.level == .appeal
                    && CaseLifecycleResolver.earliestDatedSessionDate(in: $0.instance) == nil
                    && !CaseLifecycleResolver.isConcludedReview($0.instance)
            }
        }

        var hasCassationInCurrentRound: Bool {
            let cassationLevels: Set<CaseInstance.Level> = [.cassation, .vsCassation, .supervisory]
            guard let currentRoundStart,
                  let roundDate = CaseLifecycleResolver.earliestDatedSessionDate(
                    in: currentRoundStart.instance
                  ) else {
                return sourceOrdered.contains { cassationLevels.contains($0.instance.level) }
            }
            return sourceOrdered.contains { candidate in
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
        timeline(in: movement).instances
    }

    static func timeline(in movement: CaseMovement) -> Timeline {
        let sourceOrdered = movement.instances.enumerated()
            .filter { _, instance in
                instance.level != .material
                    && instance.captchaFormURL == nil
                    && instance.transientError != true
            }
            .map { IndexedInstance(index: $0.offset, instance: $0.element) }
        let chronological = sourceOrdered.sorted {
                let left = MovementService.instanceOrderKey($0.instance)
                let right = MovementService.instanceOrderKey($1.instance)
                return left == right ? $0.index < $1.index : left < right
            }
        let dated = chronological.filter { hasDatedSession($0.instance) }
        // Возврат создаёт новый процессуальный круг только когда есть отдельная
        // датированная карточка целевой инстанции. У недатированного возврата
        // порядок источника предпочтителен; однако merge кэша кладёт такие
        // карточки в хвост, поэтому повторное звено цели также подтверждает
        // границу (первая инстанция → пересмотр → новая первая инстанция).
        var roundStarts: [IndexedInstance] = []
        for remand in sourceOrdered {
            guard let target = remandTarget(from: latestSignal(for: remand.instance)) else {
                continue
            }
            let targets = dated.filter {
                $0.instance != remand.instance && stage(for: $0.instance) == target
            }
            guard !targets.isEmpty else { continue }
            let remandDate = earliestDatedSessionDate(in: remand.instance)
            for targetInstance in targets {
                let targetDate = earliestDatedSessionDate(in: targetInstance.instance)
                let followsRemand: Bool
                if let remandDate, let targetDate {
                    followsRemand = targetDate >= remandDate
                } else {
                    followsRemand = targetInstance.index > remand.index || targets.count > 1
                }
                if followsRemand { roundStarts.append(targetInstance) }
            }
        }
        let currentRoundStart = roundStarts.max { left, right in
            let leftKey = MovementService.instanceOrderKey(left.instance)
            let rightKey = MovementService.instanceOrderKey(right.instance)
            return leftKey == rightKey ? left.index < right.index : leftKey < rightKey
        }
        let currentDated: IndexedInstance?
        if let currentRoundStart, let startDate = earliestDatedSessionDate(in: currentRoundStart.instance) {
            currentDated = dated.last(where: {
                guard let date = earliestDatedSessionDate(in: $0.instance) else { return false }
                return date >= startDate
            })
        } else {
            currentDated = dated.last
        }
        return Timeline(sourceOrdered: sourceOrdered, chronological: chronological, dated: dated,
                        currentRoundStart: currentRoundStart, currentDated: currentDated)
    }

    static func resolve(movement: CaseMovement, deadlines: [StoredDeadline],
                        today: Date = DateUtil.today) -> Resolution {
        let timeline = timeline(in: movement)
        let instances = timeline.instances
        // Пустая карточка вышестоящего суда, найденная по УИД, полезна как
        // доказательство подачи жалобы (в частности, подавляет расчётный срок),
        // но не должна перекрывать последний датированный круг производства.
        let datedInstances = instances.filter(hasDatedSession)
        // Исключение — карточка с содержательным `result`: некоторые порталы
        // публикуют итог без таблицы сессий. Такой результат надёжнее пустоты и
        // не должен теряться только из-за отсутствующей даты.
        let undatedWithResult = instances.filter {
            !hasDatedSession($0) && hasAuthoritativeResult($0)
        }
        // Недатированный итог вышестоящей инстанции всё ещё надёжнее датированной
        // базовой карточки, но не вправе переписать более поздний круг того же
        // или более высокого звена.
        let latest: CaseInstance?
        if timeline.currentDatedStartsNewRound, let dated = timeline.currentDated {
            latest = dated.instance
        } else if let undated = undatedWithResult.last, let dated = datedInstances.last,
           stageRank(dated) >= stageRank(undated) {
            latest = dated
        } else {
            latest = undatedWithResult.last ?? datedInstances.last ?? instances.last
        }
        let visited = Set(instances.compactMap(stage(for:)))

        // Будущее заседание — наиболее сильный сигнал активного производства.
        // Берём ближайшее; при одинаковой дате более поздний круг выигрывает.
        if let hearingInstance = instanceWithNearestFutureHearing(instances, today: today) {
            let active = stage(for: hearingInstance) ?? .first
            return Resolution(stage: active, currentInstance: hearingInstance,
                              steps: steps(visited: visited, active: active),
                              completionReason: nil, graceDeadline: nil)
        }

        let currentSignal = latest.flatMap(latestSignal)
        if let latest {
            switch currentSignal {
            case .remand(let target):
                return Resolution(stage: target, currentInstance: latestInstance(
                    for: target, among: instances, excluding: latest),
                                  steps: steps(visited: visited, active: target),
                                  completionReason: nil, graceDeadline: nil)
            case .legalForce:
                return completed(current: latest, visited: visited, reason: .legalForce)
            case .terminal(let result) where isReview(latest.level):
                return completed(current: latest, visited: visited,
                                 reason: .terminalReview(result))
            case .terminal(let result) where latest.level == .first:
                // Неполная карточка апелляции нового круга не доказывает
                // повышение стадии, но исключает автоматическое закрытие
                // первой инстанции из-за отсутствия расчётного срока.
                if timeline.hasUnresolvedUndatedAppeal {
                    return Resolution(stage: .first, currentInstance: latest,
                                      steps: steps(visited: visited, active: .first),
                                      completionReason: nil, graceDeadline: nil)
                }
                return resolveTerminalFirst(current: latest, result: result,
                                            visited: visited, deadlines: deadlines, today: today)
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
            return completed(current: latest, visited: visited, reason: .legalForce)
        }

        // Расчётный срок не является юридическим фактом. Автоматическое
        // завершение разрешено только после явного подтверждения пользователем
        // и только со следующего дня после указанной даты.
        let confirmedDeadlineExpired = deadlines.contains {
            $0.statusRaw == DeadlineStatus.confirmed.rawValue && $0.date < today
        }
        let unresolvedReview = latest.map { isReview($0.level) } ?? false
        if confirmedDeadlineExpired && !unresolvedReview && !explicitlyActive {
            return completed(current: latest, visited: visited, reason: .confirmedDeadline)
        }

        let active = latest.flatMap(stage(for:)) ?? .first
            return Resolution(stage: active, currentInstance: latest,
                              steps: steps(visited: visited, active: active),
                              completionReason: nil, graceDeadline: nil)
    }

    private static func completed(current: CaseInstance?, visited: Set<CaseStageKind>,
                                  reason: CompletionReason) -> Resolution {
        Resolution(stage: .done, currentInstance: current,
                   steps: steps(visited: visited, active: nil), completionReason: reason,
                   graceDeadline: nil)
    }

    private static func resolveTerminalFirst(current: CaseInstance, result: String,
                                             visited: Set<CaseStageKind>,
                                             deadlines: [StoredDeadline], today: Date) -> Resolution {
        guard let deadline = deadlines.first(where: { $0.kind == "appeal" }) else {
            return completed(current: current, visited: visited, reason: .terminalFirst(result))
        }
        if deadline.statusRaw == DeadlineStatus.confirmed.rawValue, deadline.date < today {
            return completed(current: current, visited: visited, reason: .confirmedDeadline)
        }
        // Расчётный срок — не юридический факт, но даём порталам семь полных
        // календарных дней после него на публикацию апелляции. На восьмой день
        // производство закрывается автоматически.
        let graceEnd = DateUtil.addDays(deadline.date, 7)
        if deadline.date >= today || today <= graceEnd {
            return Resolution(stage: .first, currentInstance: current,
                              steps: steps(visited: visited, active: .first),
                              completionReason: nil, graceDeadline: deadline)
        }
        return completed(current: current, visited: visited, reason: .terminalFirst(result))
    }

    private static func latestInstance(for stage: CaseStageKind, among instances: [CaseInstance],
                                       excluding current: CaseInstance) -> CaseInstance? {
        instances.last { candidate in
            candidate != current && self.stage(for: candidate) == stage
        }
    }

    private static func stage(for instance: CaseInstance) -> CaseStageKind? {
        switch instance.level {
        case .first: return .first
        case .appeal: return .appeal
        case .cassation, .vsCassation, .supervisory: return .cassation
        case .material: return nil
        }
    }

    private static func stageRank(_ instance: CaseInstance) -> Int {
        switch stage(for: instance) {
        case .first: return 1
        case .appeal: return 2
        case .cassation: return 3
        case .done, nil: return 0
        }
    }

    private static func steps(visited: Set<CaseStageKind>,
                              active: CaseStageKind?) -> [String] {
        let stages: [CaseStageKind] = [.first, .appeal, .cassation]
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

    static func earliestDatedSessionDate(in instance: CaseInstance) -> Date? {
        instance.sessions.compactMap { DateUtil.parse($0.date) }.min()
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
        let ordered = instance.sessions.enumerated().sorted { left, right in
            let leftDate = DateUtil.parse(left.element.date) ?? .distantPast
            let rightDate = DateUtil.parse(right.element.date) ?? .distantPast
            return leftDate == rightDate ? left.offset < right.offset : leftDate < rightDate
        }
        var latest: InstanceSignal?
        // Возобновление остаётся доминирующим состоянием через последующие
        // регистрации/принятие жалобы; сбросить его может только более поздний
        // конечный сигнал, а не очередная активная административная строка.
        var reactivationStillDominant = false
        for (_, session) in ordered {
            let event = nonempty(session.event)
            let result = nonempty(session.result)
            let combined = [event, result].compactMap { $0 }.joined(separator: " ")
            if let current = result.flatMap(signal)
                ?? event.flatMap(signal)
                ?? (combined.isEmpty ? nil : signal(in: combined)) {
                latest = current
                if isReactivation(normalized(combined)) {
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
        if let result = nonempty(instance.result), let resultSignal = signal(in: result) {
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
        if instance.level == .first, hasReliableHomeResult(instance),
           let result = nonempty(instance.result),
           isReliableFirstTerminalResult(normalized(result)) {
            return .terminal(result)
        }
        return latest
    }

    private static func remandTarget(from signal: InstanceSignal?) -> CaseStageKind? {
        guard case .remand(let target)? = signal else { return nil }
        return target
    }

    /// После доказанного возврата лишь завершённый недатированный пересмотр
    /// можно отнести к старому кругу. Активная карточка без даты остаётся
    /// консервативным свидетельством подачи, но сама не повышает стадию.
    private static func isConcludedReview(_ instance: CaseInstance) -> Bool {
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
        guard value.contains("направ"), value.contains("нов"),
              value.contains("рассмотр") else { return nil }
        return value.contains("апелляцион") ? .appeal : .first
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
        return (value.contains("принят") && value.contains("производств"))
            || (value.contains("регистрац")
                && (value.contains("жалоб") || value.contains("производств")
                    || value.contains("дел")))
            || value.contains("назначено заседание")
    }

    private static func isTerminalDisposition(_ value: String) -> Bool {
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
        let returned = complaintReturned
            || ((value.contains("возврат") || value.contains("возвращ"))
                && value.contains("без рассмотр"))
        let wholeProceedingSubject = isWholeProceedingSubject(value)
        let leftWithoutConsideration = value.contains("остав") && value.contains("без рассмотр")
            && wholeProceedingSubject
        let restorationDenied = isDenied(value) && value.contains("восстанов")
            && value.contains("срок")
        let acceptanceDenied = isDenied(value) && value.contains("принят")
            && value.contains("производств")
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
        return unchanged || transferDenied || terminated || returned || leftWithoutConsideration
            || restorationDenied || acceptanceDenied
            || changedWithoutRemand || cancelledWithoutDirection || cancelledActWithNewDecision
            || meritsDecision || satisfiedWithoutRemand
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
        // Два уже существующих словаря дополняют друг друга: конечные формулы
        // первой инстанции знают «приговор» и «иск удовлетворён», словарь
        // терминальных исходов — «производство прекращено», «оставлено без
        // изменения» и отмену с новым решением.
        return isReliableFirstTerminalResult(value) || isTerminalDisposition(value)
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
}
