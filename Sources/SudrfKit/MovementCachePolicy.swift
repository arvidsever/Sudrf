//  MovementCachePolicy.swift — SudrfKit
//  Правила слияния свежего движения дела с кэшированным и очистки перед
//  персистом. Чистая модельная логика — живёт в ядре, чтобы тестироваться
//  вместе с моделями; сами хранилища кэша — на стороне приложения.

import Foundation

public enum MovementCachePolicy {

    /// Слияние свежего движения с кэшированным. Заглушки и метка неполного
    /// ответа защищают ранее загруженные реальные инстанции того же
    /// канонического хоста (A14 — moduleHost dedup) от затирания
    /// частично-успешным fetch'ем:
    ///   • captchaFormURL != nil — форма суда под капчей.
    ///   • transientError == true — сетевой сбой (timeout/DNS/connection
    ///     lost) после 3 попыток (`SudrfError.transientNetworkError`).
    ///   • incompleteHigherCourtDomains — любая другая ошибка поиска или
    ///     карточки вышестоящего суда; UI-заглушки нет, но кэш сохраняется.
    /// Во всех случаях реальные инстанции из кэша (с их актами и телами)
    /// переносятся в свежие данные; заглушка удаляется. Если кэша нет —
    /// заглушка остаётся (для UI-плашки «нет связи» / captcha-form).
    /// Двухпроходный алгоритм: 1) собрать индексы stub'ов, 2) удалить в
    /// обратном порядке (A14 follow-up: `instances.remove(at:)` внутри
    /// `enumerated()` инвалидирует индексы).
    public static func merge(fresh: CaseMovement, cached: CaseMovement?) -> CaseMovement {
        guard let cached else { return fresh }
        var instances = fresh.instances
        var acts = fresh.acts
        var actBodies = fresh.actBodies
        var changed = false

        // A partial refresh can return a valid movement while its base card
        // temporarily omits the execution table. Preserve the last successful
        // documents just like cached real higher-court instances.
        var executionDocuments = fresh.executionDocuments
        if (fresh.executionDocuments?.isEmpty ?? true),
           let cachedDocuments = cached.executionDocuments,
           !cachedDocuments.isEmpty {
            executionDocuments = cachedDocuments
            changed = true
        }

        func restoreCachedRealInstances(for canonical: String) -> Bool {
            let realInstances = cached.instances.filter {
                SudrfHost.moduleHost($0.domain) == canonical
                    && $0.captchaFormURL == nil
                    && $0.transientError != true
            }
            guard !realInstances.isEmpty else { return false }
            for r in realInstances {
                if let freshIndex = instances.firstIndex(where: {
                    SudrfHost.moduleHost($0.domain) == SudrfHost.moduleHost(r.domain)
                        && MovementService.sameCaseNumber($0.caseNumber, r.caseNumber)
                }) {
                    if instances[freshIndex].actID == nil {
                        instances[freshIndex].actID = r.actID
                    }
                    var linked = instances[freshIndex].linkedActIDs
                    for id in r.linkedActIDs where !linked.contains(id) { linked.append(id) }
                    instances[freshIndex].actIDs = linked.isEmpty ? nil : linked
                    if instances[freshIndex].actURL == nil {
                        instances[freshIndex].actURL = r.actURL
                    }
                    var sourceURLs = instances[freshIndex].linkedActURLs
                    for url in r.linkedActURLs where !sourceURLs.contains(url) {
                        sourceURLs.append(url)
                    }
                    instances[freshIndex].actURLs = sourceURLs.isEmpty ? nil : sourceURLs
                } else {
                    instances.append(r)
                }
                for actID in r.linkedActIDs where !acts.contains(where: { $0.id == actID }) {
                    guard let body = cached.actBodies[actID],
                          !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let act = cached.acts.first(where: { $0.id == actID }) else {
                        continue
                    }
                    acts.append(act)
                    actBodies[actID] = body
                }
            }
            return true
        }

        func hasCachedRealInstances(for canonical: String) -> Bool {
            cached.instances.contains {
                SudrfHost.moduleHost($0.domain) == canonical
                    && $0.captchaFormURL == nil
                    && $0.transientError != true
            }
        }

        // Шаг 1: собрать индексы stub'ов (captcha + transient), НЕ удалять
        // в этом проходе — иначе при двух stub'ах `enumerated()` пропустит
        // элемент или крашится из-за инвалидации индексов.
        var stubIndices: [Int] = []
        for (i, inst) in instances.enumerated()
            where inst.captchaFormURL != nil || inst.transientError == true {
            stubIndices.append(i)
        }

        // Шаг 2: удалить stub'ы в ОБРАТНОМ порядке. Сравнение кэша со
        // stub'ом идёт по `SudrfHost.moduleHost` (A14), не по сырому
        // `inst.domain` — иначе dash+dot формы вышестоящего суда
        // (`expandedHigherDomains`) не матчатся.
        stubIndices.sort(by: >)
        for i in stubIndices {
            let inst = instances[i]
            let canonical = SudrfHost.moduleHost(inst.domain)
            guard hasCachedRealInstances(for: canonical) else {
                // Кэша нет — оставляем stub в instances, идёт в персист;
                // UI показывает captcha-form или плашку «нет связи» + retry.
                continue
            }
            instances.remove(at: i)
            _ = restoreCachedRealInstances(for: canonical)
            changed = true
        }

        // Обычная ошибка поиска раньше попадала в `catch { continue }`: в
        // свежем движении суд исчезал, а merge не видел причины восстановить
        // кэш. Метка действует и когда часть кругов этого же суда пришла —
        // тогда свежие данные сохраняются, а недостающие добираются из кэша.
        for canonical in Set((fresh.incompleteHigherCourtDomains ?? []).map(SudrfHost.moduleHost)) {
            if restoreCachedRealInstances(for: canonical) { changed = true }
        }
        // A recognized empty listing is not proof that a previously tracked
        // court round was deleted. Only an explicit tombstone may remove it.
        for canonical in Set((fresh.honestZeroDomains ?? []).map(SudrfHost.moduleHost)) {
            if restoreCachedRealInstances(for: canonical) { changed = true }
        }
        guard changed else { return fresh }

        instances.sort { MovementService.instanceOrderKey($0) < MovementService.instanceOrderKey($1) }
        acts.sort { MovementService.actOrderKey($0) < MovementService.actOrderKey($1) }
        var out = fresh
        out.instances = instances
        out.acts = acts
        out.actBodies = actBodies
        out.executionDocuments = executionDocuments
        out.incompleteHigherCourtDomains = nil
        out.honestZeroDomains = nil
        return out
    }

    /// Версия для персиста: оставшиеся заглушки капчи вырезаются — transient
    /// URL формы хранить бессмысленно, при следующем живом запросе заглушка
    /// восстановится сама. transientError-стабы НЕ вырезаются (merge на
    /// следующий fetch должен увидеть, что у домена был сетевой сбой, иначе
    /// UI увидит «дело исчезло», а не «нет связи»). Акты не трогаются
    /// (у заглушек actID == nil).
    public static func stripped(forPersist mv: CaseMovement) -> CaseMovement {
        var out = mv
        out.instances = mv.instances.filter { $0.captchaFormURL == nil }
        out.incompleteHigherCourtDomains = nil
        out.honestZeroDomains = nil
        return out
    }
}
