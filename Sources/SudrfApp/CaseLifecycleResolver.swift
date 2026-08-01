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
        let latest = instances.last
        let visited = Set(instances.compactMap(stage(for:)))

        // Будущее заседание — наиболее сильный сигнал активного производства.
        // Берём ближайшее; при одинаковой дате более поздний круг выигрывает.
        if let hearingInstance = instanceWithNearestFutureHearing(instances, today: today) {
            let active = stage(for: hearingInstance) ?? .first
            return Resolution(stage: active, currentInstance: hearingInstance,
                              steps: steps(visited: visited, active: active),
                              completionReason: nil)
        }

        if let latest, let remand = remandTarget(in: text(of: latest)) {
            return Resolution(stage: remand, currentInstance: latest,
                              steps: steps(visited: visited, active: remand),
                              completionReason: nil)
        }

        if let latest, hasLegalForceEvidence(in: text(of: latest)) {
            return completed(current: latest, visited: visited, reason: .legalForce)
        }

        if let latest, isReview(latest.level), let terminal = terminalReviewText(for: latest) {
            return completed(current: latest, visited: visited,
                             reason: .terminalReview(terminal))
        }

        // `CaseMovement.inForce` относится к базовой карточке. Он надёжен как
        // признак завершения только пока не найдено отдельное производство
        // пересмотра: иначе вступивший в силу базовый акт ошибочно перекрывал
        // живую апелляцию/кассацию (вплоть до будущего заседания).
        let hasReview = instances.contains { isReview($0.level) }
        if movement.inForce && !hasReview {
            return completed(current: latest, visited: visited, reason: .legalForce)
        }

        // Расчётный срок не является юридическим фактом. Автоматическое
        // завершение разрешено только после явного подтверждения пользователем
        // и только со следующего дня после указанной даты.
        let confirmedDeadlineExpired = deadlines.contains {
            $0.statusRaw == DeadlineStatus.confirmed.rawValue && $0.date < today
        }
        let unresolvedReview = latest.map { isReview($0.level) } ?? false
        if confirmedDeadlineExpired && !unresolvedReview {
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
        var best: (date: Date, time: String, index: Int, instance: CaseInstance)?
        for (index, instance) in instances.enumerated() {
            let instanceConcluded = remandTarget(in: text(of: instance)) != nil
                || terminalReviewText(for: instance) != nil
            for session in instance.sessions where isHearing(session) {
                guard let date = DateUtil.parse(session.date),
                      DateUtil.daysBetween(today, date) >= 0 else { continue }
                if instanceConcluded && DateUtil.sameDay(date, today) { continue }
                let candidate = (date, session.time ?? "", index, instance)
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

    private static func isHearing(_ session: CaseSession) -> Bool {
        let value = normalized(session.event + " " + (session.result ?? ""))
        // Состоявшееся сегодня заседание с уже опубликованным итогом не должно
        // считаться будущим только потому, что сравнение идёт по календарному дню.
        if remandTarget(in: value) != nil || isTerminalDisposition(value) { return false }
        return !(session.time ?? "").isEmpty
            || value.contains("заседани")
            || value.contains("рассмотрени")
            || value.contains("слушани")
    }

    private static func isReview(_ level: CaseInstance.Level) -> Bool {
        switch level {
        case .appeal, .cassation, .vsCassation, .supervisory: return true
        case .first, .material: return false
        }
    }

    private static func text(of instance: CaseInstance) -> String {
        ([instance.result]
            + instance.sessions.flatMap { [$0.event, $0.result] })
            .compactMap { $0 }
            .joined(separator: " ")
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

    private static func terminalReviewText(for instance: CaseInstance) -> String? {
        let candidates = ([instance.result]
            + instance.sessions.reversed().flatMap { [$0.result, $0.event] })
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for candidate in candidates {
            let value = normalized(candidate)
            if remandTarget(in: value) != nil { return nil }
            if isTerminalDisposition(value) { return candidate }
        }
        return nil
    }

    private static func isTerminalDisposition(_ value: String) -> Bool {
        let unchanged = value.contains("остав")
            && (value.contains("без удовлетвор") || value.contains("без изменен"))
        let transferDenied = value.contains("отказ") && value.contains("передач")
        let terminated = value.contains("производств") && value.contains("прекращ")
        let returned = (value.contains("возврат") || value.contains("возвращ"))
            && value.contains("без рассмотр")
        let changedWithoutRemand = value.contains("измен")
            && value.contains("без направ") && value.contains("нов")
            && value.contains("рассмотр")
        let satisfiedWithoutRemand = value.contains("жалоб") && value.contains("удовлетвор")
            && !value.contains("без удовлетвор")
            && !(value.contains("направ") && value.contains("рассмотр"))
        return unchanged || transferDenied || terminated || returned
            || changedWithoutRemand || satisfiedWithoutRemand
    }

    private static func normalized(_ source: String) -> String {
        source.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}
