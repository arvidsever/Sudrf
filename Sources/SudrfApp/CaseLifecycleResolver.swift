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
        case confirmedDeadline
    }

    struct Resolution: Equatable {
        var stage: CaseStageKind
        var currentInstance: CaseInstance?
        var steps: [String]
        var completionReason: CompletionReason?

        var isCompleted: Bool { completionReason != nil }
    }

    private struct IndexedInstance {
        var index: Int
        var instance: CaseInstance
    }

    private enum InstanceSignal {
        case active
        case remand(CaseStageKind)
        case legalForce
        case terminal(String)
    }

    static func realInstances(in movement: CaseMovement) -> [CaseInstance] {
        movement.instances.enumerated()
            .filter { _, instance in
                instance.level != .material
                    && instance.captchaFormURL == nil
                    && instance.transientError != true
            }
            .map { IndexedInstance(index: $0.offset, instance: $0.element) }
            .sorted {
                let left = MovementService.instanceOrderKey($0.instance)
                let right = MovementService.instanceOrderKey($1.instance)
                return left == right ? $0.index < $1.index : left < right
            }
            .map(\.instance)
    }

    static func resolve(movement: CaseMovement, deadlines: [StoredDeadline],
                        today: Date = DateUtil.today) -> Resolution {
        let instances = realInstances(in: movement)
        // Пустая карточка вышестоящего суда, найденная по УИД, полезна как
        // доказательство подачи жалобы (в частности, подавляет расчётный срок),
        // но не должна перекрывать последний датированный круг производства.
        let datedInstances = instances.filter(hasDatedSession)
        let latest = datedInstances.last ?? instances.last
        let visited = Set(instances.compactMap(stage(for:)))

        // Будущее заседание — наиболее сильный сигнал активного производства.
        // Берём ближайшее; при одинаковой дате более поздний круг выигрывает.
        if let hearingInstance = instanceWithNearestFutureHearing(instances, today: today) {
            let active = stage(for: hearingInstance) ?? .first
            return Resolution(stage: active, currentInstance: hearingInstance,
                              steps: steps(visited: visited, active: active),
                              completionReason: nil)
        }

        let currentSignal = latest.flatMap(latestSignal)
        if let latest {
            switch currentSignal {
            case .remand(let target):
                return Resolution(stage: target, currentInstance: latest,
                                  steps: steps(visited: visited, active: target),
                                  completionReason: nil)
            case .legalForce:
                return completed(current: latest, visited: visited, reason: .legalForce)
            case .terminal(let result) where isReview(latest.level):
                return completed(current: latest, visited: visited,
                                 reason: .terminalReview(result))
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
                          completionReason: nil)
    }

    private static func completed(current: CaseInstance?, visited: Set<CaseStageKind>,
                                  reason: CompletionReason) -> Resolution {
        Resolution(stage: .done, currentInstance: current,
                   steps: steps(visited: visited, active: nil), completionReason: reason)
    }

    private static func stage(for instance: CaseInstance) -> CaseStageKind? {
        switch instance.level {
        case .first: return .first
        case .appeal: return .appeal
        case .cassation, .vsCassation, .supervisory: return .cassation
        case .material: return nil
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
                event: session.event, result: session.result, time: session.time
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

    /// Общий для resolver и табличного представления предикат заседания.
    static func isHearing(event: String, result: String?, time: String?) -> Bool {
        let value = normalized(event + " " + (result ?? ""))
        // Состоявшееся сегодня заседание с уже опубликованным итогом не должно
        // считаться будущим только потому, что сравнение идёт по календарному дню.
        if remandTarget(in: value) != nil || isTerminalDisposition(value) { return false }
        return !(time ?? "").isEmpty
            || value.contains("заседани")
            || value.contains("рассмотрени")
            || value.contains("слушани")
    }

    /// Строковое сравнение ставило `11:00` раньше `9:00`. Неизвестное время
    /// сортируется после корректного HH:mm в тот же день.
    static func hearingTimeKey(_ time: String?) -> Int {
        guard let time else { return Int.max }
        let parts = time.split(separator: ":", maxSplits: 1)
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

    /// Возвращает последний актуальный процессуальный сигнал внутри одного
    /// круга. Итог карточки имеет приоритет; иначе сессии рассматриваются по
    /// хронологии, чтобы старое вступление в силу/возврат не побеждало более
    /// позднее возобновление или новый конечный результат.
    private static func latestSignal(for instance: CaseInstance) -> InstanceSignal? {
        if let result = nonempty(instance.result), let signal = signal(in: result) {
            return signal
        }
        let ordered = instance.sessions.enumerated().sorted { left, right in
            let leftDate = DateUtil.parse(left.element.date) ?? .distantPast
            let rightDate = DateUtil.parse(right.element.date) ?? .distantPast
            return leftDate == rightDate ? left.offset < right.offset : leftDate < rightDate
        }
        var latest: InstanceSignal?
        for (_, session) in ordered {
            let event = nonempty(session.event)
            let result = nonempty(session.result)
            let combined = [event, result].compactMap { $0 }.joined(separator: " ")
            if let current = result.flatMap(signal)
                ?? event.flatMap(signal)
                ?? (combined.isEmpty ? nil : signal(in: combined)) {
                latest = current
            }
        }
        return latest
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
        guard value.contains("направ"), value.contains("нов"),
              value.contains("рассмотр") else { return nil }
        return value.contains("апелляцион") ? .appeal : .first
    }

    private static func hasLegalForceEvidence(in source: String) -> Bool {
        let value = normalized(source)
        return value.contains("вступ") && value.contains("законн") && value.contains("сил")
    }

    private static func isReactivation(_ value: String) -> Bool {
        value.contains("возобнов")
            || (value.contains("восстанов") && value.contains("срок"))
            || (value.contains("пересмотр") && value.contains("обстоятель")
                && (value.contains("нов") || value.contains("вновь")))
    }

    private static func isActiveProceeding(_ value: String) -> Bool {
        (value.contains("принят") && value.contains("производств"))
            || (value.contains("регистрац")
                && (value.contains("жалоб") || value.contains("производств")
                    || value.contains("дел")))
            || value.contains("назначено заседание")
    }

    private static func isTerminalDisposition(_ value: String) -> Bool {
        let unchanged = value.contains("остав")
            && (value.contains("без удовлетвор") || value.contains("без изменен"))
        let transferDenied = value.contains("отказ") && value.contains("передач")
        let terminated = value.contains("производств") && value.contains("прекращ")
        let returned = (value.contains("возврат") || value.contains("возвращ"))
            && value.contains("без рассмотр")
        let judicialAct = value.contains("решен") || value.contains("приговор")
            || value.contains("постановлен") || value.contains("определен")
            || (value.contains("судебн") && value.contains("акт"))
        let changedWithoutRemand = value.contains("измен") && judicialAct
            && remandTarget(in: value) == nil
        let meritsDecision = value.contains("вынес") && value.contains("решен")
        let satisfiedWithoutRemand = value.contains("жалоб") && value.contains("удовлетвор")
            && !value.contains("без удовлетвор")
            && !(value.contains("направ") && value.contains("рассмотр"))
        return unchanged || transferDenied || terminated || returned
            || changedWithoutRemand || meritsDecision || satisfiedWithoutRemand
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
