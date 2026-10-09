//  MovementCachePolicy.swift — SudrfKit
//  Правила слияния свежего движения дела с кэшированным и очистки перед
//  персистом. Чистая модельная логика — живёт в ядре, чтобы тестироваться
//  вместе с моделями; сами хранилища кэша — на стороне приложения.

import Foundation

public enum MovementCachePolicy {
    private static func canonicalHost(_ host: String) -> String {
        let host = SudrfHost.moduleHost(host)
        return host == "www.vsrf.ru" ? "vsrf.ru" : host
    }

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
        let fresh = MovementTargetBuilder.normalizeCriminalCassationRoute(in: fresh)
        guard let cached else { return fresh }
        var instances = fresh.instances
        var acts = fresh.acts
        var actBodies = fresh.actBodies
        var changed = false

        func comparablePublicationURL(_ url: URL) -> URL {
            PublishedActURLPolicy.safePublishedURL(url) ?? url
        }

        func hasConflictingPublication(_ freshAct: CaseAct, _ cachedAct: CaseAct) -> Bool {
            let freshURL = freshAct.sourceFileURL ?? freshAct.fileProvenance?.sourceURL
            let cachedURL = cachedAct.sourceFileURL ?? cachedAct.fileProvenance?.sourceURL
            if let freshURL, let cachedURL {
                if comparablePublicationURL(freshURL) != comparablePublicationURL(cachedURL) {
                    return true
                }
            }
            if let freshNumber = freshAct.productionNumber?.trimmingCharacters(
                in: .whitespacesAndNewlines), !freshNumber.isEmpty,
               let cachedNumber = cachedAct.productionNumber?.trimmingCharacters(
                in: .whitespacesAndNewlines), !cachedNumber.isEmpty,
               freshNumber != cachedNumber {
                return true
            }
            if let freshHash = freshAct.fileProvenance?.contentHash,
               let cachedHash = cachedAct.fileProvenance?.contentHash,
               freshHash != cachedHash {
                return true
            }
            return false
        }

        func conflictingCachedPublicationURLs(for cachedInstance: CaseInstance) -> Set<URL> {
            Set(cachedInstance.linkedActIDs.compactMap { actID in
                guard let freshAct = acts.first(where: { $0.id == actID }),
                      let cachedAct = cached.acts.first(where: { $0.id == actID }),
                      hasConflictingPublication(freshAct, cachedAct),
                      let sourceURL = cachedAct.sourceFileURL ?? cachedAct.fileProvenance?.sourceURL
                else { return nil }
                return comparablePublicationURL(sourceURL)
            })
        }

        // Complete cards discover file metadata, not the downloaded document.
        // Overlay only files still present under the same verified publication;
        // missing productions are restored solely by the partial-source rules.
        for index in acts.indices {
            guard let freshURL = acts[index].sourceFileURL,
                  PublishedActURLPolicy.isAllowedVSRFPublishedAct(freshURL),
                  let old = cached.acts.first(where: { $0.id == acts[index].id }),
                  let oldURL = old.sourceFileURL ?? old.fileProvenance?.sourceURL,
                  PublishedActURLPolicy.isAllowedVSRFPublishedAct(oldURL),
                  freshURL.path == oldURL.path,
                  acts[index].productionNumber == old.productionNumber,
                  acts[index].fileProvenance == nil
                    || acts[index].fileProvenance?.contentHash == old.fileProvenance?.contentHash
            else { continue }
            if acts[index].fileProvenance == nil, let provenance = old.fileProvenance {
                acts[index].fileProvenance = provenance
                changed = true
            }
            if (actBodies[old.id]?.isEmpty ?? true), let text = cached.actBodies[old.id], !text.isEmpty {
                actBodies[old.id] = text
                changed = true
            }
        }

        let incompleteDomains = Set(
            (fresh.incompleteHigherCourtDomains ?? []).map(canonicalHost))
        let freshBaseDomain = fresh.instances.first {
            MovementService.sameCaseNumber($0.caseNumber, fresh.caseNumber)
        }?.domain
        let freshBaseCanonicalDomain = freshBaseDomain.map(canonicalHost)
        let baseIsIncomplete = freshBaseDomain.map {
            incompleteDomains.contains(canonicalHost($0))
        } ?? false

        // A saved-UID fallback deliberately returns a sparse base movement.
        // Keep authoritative fields from the last complete base card while
        // retaining any fresh higher-court instances.
        var category = fresh.category
        if baseIsIncomplete,
           (category?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let cachedCategory = cached.category,
           !cachedCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            category = cachedCategory
            changed = true
        }
        var parties = fresh.parties
        if baseIsIncomplete, parties.isEmpty, !cached.parties.isEmpty {
            parties = cached.parties
            changed = true
        }
        var uid = fresh.uid
        if baseIsIncomplete,
           uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !cached.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            uid = cached.uid
            changed = true
        }
        var inForce = fresh.inForce
        if baseIsIncomplete, !inForce, cached.inForce {
            inForce = true
            changed = true
        }

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

        func restoreCachedLinkedActs(from cachedInstance: CaseInstance, into freshIndex: Int) {
            let conflictingURLs = conflictingCachedPublicationURLs(for: cachedInstance)
            if instances[freshIndex].actID == nil, let actID = cachedInstance.actID {
                instances[freshIndex].actID = actID
                changed = true
            }
            let priorLinkedIDs = instances[freshIndex].linkedActIDs
            var linkedIDs = priorLinkedIDs
            for id in cachedInstance.linkedActIDs where !linkedIDs.contains(id) {
                linkedIDs.append(id)
            }
            if linkedIDs != priorLinkedIDs {
                instances[freshIndex].actIDs = linkedIDs
                changed = true
            }

            if instances[freshIndex].actURL == nil, let actURL = cachedInstance.actURL,
               !conflictingURLs.contains(comparablePublicationURL(actURL)) {
                instances[freshIndex].actURL = actURL
                changed = true
            }
            let priorActURLs = instances[freshIndex].linkedActURLs
            var actURLs = priorActURLs
            for url in cachedInstance.linkedActURLs
            where !conflictingURLs.contains(comparablePublicationURL(url)) {
                if !actURLs.contains(url) { actURLs.append(url) }
            }
            if actURLs != priorActURLs {
                instances[freshIndex].actURLs = actURLs
                changed = true
            }

            for actID in cachedInstance.linkedActIDs {
                guard let cachedAct = cached.acts.first(where: { $0.id == actID }) else { continue }
                let cachedBody = cached.actBodies[actID]?.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if let index = acts.firstIndex(where: { $0.id == actID }) {
                    var act = acts[index]
                    guard !hasConflictingPublication(act, cachedAct) else { continue }
                    if act.sourceFileURL == nil, let url = cachedAct.sourceFileURL {
                        act.sourceFileURL = url
                    }
                    if act.productionNumber == nil, let number = cachedAct.productionNumber {
                        act.productionNumber = number
                    }
                    if act.fileProvenance == nil, let provenance = cachedAct.fileProvenance {
                        act.fileProvenance = provenance
                    }
                    if act.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        act.title = cachedAct.title
                    }
                    if act.date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        act.date = cachedAct.date
                    }
                    if act.courtShort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        act.courtShort = cachedAct.courtShort
                    }
                    if acts[index] != act {
                        acts[index] = act
                        changed = true
                    }
                    if (actBodies[actID]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                       let cachedBody, !cachedBody.isEmpty {
                        actBodies[actID] = cachedBody
                        changed = true
                    }
                } else {
                    // A published PDF is a real act even before it has text.
                    guard !(cachedBody?.isEmpty ?? true)
                            || cachedAct.sourceFileURL != nil
                            || cachedAct.fileProvenance != nil else { continue }
                    acts.append(cachedAct)
                    if let cachedBody, !cachedBody.isEmpty {
                        actBodies[actID] = cachedBody
                    }
                    changed = true
                }
            }
        }

        // A fresh complete card can omit old acts while keeping the same native card.
        for cachedInstance in cached.instances where cachedInstance.captchaFormURL == nil
            && cachedInstance.transientError != true {
            guard let freshIndex = instances.firstIndex(where: { freshInstance in
                guard freshInstance.captchaFormURL == nil,
                      freshInstance.transientError != true,
                      canonicalHost(freshInstance.domain) == canonicalHost(cachedInstance.domain),
                      freshInstance.level == cachedInstance.level,
                      let freshURL = freshInstance.sourceURL,
                      let cachedURL = cachedInstance.sourceURL,
                      canonicalHost(freshURL.host?.lowercased() ?? "")
                        == canonicalHost(freshInstance.domain),
                      canonicalHost(cachedURL.host?.lowercased() ?? "")
                        == canonicalHost(cachedInstance.domain),
                      MovementService.sameCaseNumber(
                        freshInstance.caseNumber, cachedInstance.caseNumber),
                      MovementService.sameSourceCard(freshURL, cachedURL) == true
                else { return false }
                let freshCartotekaID = (freshInstance.sourceEvidence?.cartotekaID ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cachedCartotekaID = (cachedInstance.sourceEvidence?.cartotekaID ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return freshCartotekaID.isEmpty || cachedCartotekaID.isEmpty
                    || freshCartotekaID == cachedCartotekaID
            }) else { continue }
            restoreCachedLinkedActs(from: cachedInstance, into: freshIndex)
        }

        func restoreCachedRealInstances(for canonical: String) -> Bool {
            let overlaysSparseBase = baseIsIncomplete && canonical == freshBaseCanonicalDomain
            let realInstances = cached.instances.filter {
                canonicalHost($0.domain) == canonical
                    && $0.captchaFormURL == nil
                    && $0.transientError != true
            }
            guard !realInstances.isEmpty else { return false }
            for r in realInstances {
                let freshIndex: Int
                if let existingIndex = instances.firstIndex(where: {
                    canonicalHost($0.domain) == canonicalHost(r.domain)
                        && (canonical == "vsrf.ru"
                            ? MovementService.sameVSRFCard($0.sourceURL, r.sourceURL)
                            : MovementService.sameCaseNumber($0.caseNumber, r.caseNumber))
                }) {
                    freshIndex = existingIndex
                    if canonical == "vsrf.ru",
                       incompleteDomains.contains(canonical),
                       instances[freshIndex].note == "Движение временно недоступно" {
                        // A valid search summary must not replace the last full card.
                        instances[freshIndex] = r
                        changed = true
                    }
                    if canonical == "vsrf.ru", incompleteDomains.contains(canonical) {
                        let ownUnavailable = instances[freshIndex].note
                            == "Движение временно недоступно · жалоба проверена"
                        let intakeUnavailable = instances[freshIndex].note
                            == "Движение жалобы временно недоступно"
                        if ownUnavailable || intakeUnavailable {
                            let freshInstance = instances[freshIndex]
                            var preferred = ownUnavailable ? r : freshInstance
                            // All fresh rows here are verified. Prefer their
                            // details even when the own-card header comes from cache.
                            var sessions = freshInstance.sessions
                            for session in r.sessions where !sessions.contains(where: {
                                $0.date == session.date && $0.time == session.time
                                    && $0.room == session.room && $0.event == session.event
                            }) {
                                sessions.append(session)
                            }
                            preferred.sessions = sessions.enumerated().sorted {
                                let lhs = MovementService.dateSortKey($0.element.date)
                                let rhs = MovementService.dateSortKey($1.element.date)
                                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
                            }.map(\.element)
                            preferred.note = freshInstance.note
                            instances[freshIndex] = preferred
                            changed = true
                        }
                    }
                    // A material row/known card can be identified by its
                    // published header even when its card is temporarily
                    // unavailable. Keep the cached movement for that exact
                    // placeholder independently of the sparse-base overlay.
                    let overlaysUnavailableMaterial =
                        incompleteDomains.contains(canonical)
                        && instances[freshIndex].level == .material
                        && instances[freshIndex].note == "Движение временно недоступно"
                    let overlaysPartialFields = overlaysSparseBase || overlaysUnavailableMaterial
                    if overlaysPartialFields,
                       instances[freshIndex].sessions.isEmpty, !r.sessions.isEmpty {
                        instances[freshIndex].sessions = r.sessions
                        changed = true
                    }
                    if overlaysPartialFields,
                       instances[freshIndex].judge == nil, let judge = r.judge {
                        instances[freshIndex].judge = judge
                        changed = true
                    }
                    if overlaysPartialFields,
                       instances[freshIndex].result == nil, let result = r.result {
                        instances[freshIndex].result = result
                        changed = true
                    }
                    if overlaysPartialFields,
                       instances[freshIndex].sourceURL == nil, let sourceURL = r.sourceURL {
                        instances[freshIndex].sourceURL = sourceURL
                        changed = true
                    }
                    if overlaysPartialFields, let cachedEvidence = r.sourceEvidence {
                        let freshEvidence = instances[freshIndex].sourceEvidence
                        let evidence = CaseInstance.SourceEvidence(
                            appealKinds: freshEvidence?.appealKinds ?? cachedEvidence.appealKinds,
                            reviewProcedure: freshEvidence?.reviewProcedure ?? cachedEvidence.reviewProcedure,
                            lowerCourt: freshEvidence?.lowerCourt ?? cachedEvidence.lowerCourt,
                            receiptDate: freshEvidence?.receiptDate ?? cachedEvidence.receiptDate,
                            decisionDate: freshEvidence?.decisionDate ?? cachedEvidence.decisionDate,
                            judicialUID: freshEvidence?.judicialUID ?? cachedEvidence.judicialUID,
                            cartotekaID: freshEvidence?.cartotekaID ?? cachedEvidence.cartotekaID,
                            sourceCourtLevel: freshEvidence?.sourceCourtLevel ?? cachedEvidence.sourceCourtLevel,
                            sourceBranch: freshEvidence?.sourceBranch ?? cachedEvidence.sourceBranch,
                            category: freshEvidence?.category ?? cachedEvidence.category,
                            ownProcessKind: freshEvidence?.ownProcessKind ?? cachedEvidence.ownProcessKind,
                            ownProcessKindConflict: freshEvidence?.ownProcessKindConflict ?? cachedEvidence.ownProcessKindConflict)
                        if freshEvidence != evidence {
                            instances[freshIndex].sourceEvidence = evidence
                            changed = true
                        }
                    }
                    if overlaysPartialFields,
                       instances[freshIndex].previousRegistration == nil,
                       let previousRegistration = r.previousRegistration {
                        instances[freshIndex].previousRegistration = previousRegistration
                        changed = true
                    }
                    if overlaysPartialFields,
                       instances[freshIndex].note == nil, let note = r.note {
                        instances[freshIndex].note = note
                        changed = true
                    }
                } else {
                    instances.append(r)
                    freshIndex = instances.count - 1
                    changed = true
                }
                restoreCachedLinkedActs(from: r, into: freshIndex)
            }
            return true
        }

        func hasCachedRealInstances(for canonical: String) -> Bool {
            cached.instances.contains {
                canonicalHost($0.domain) == canonical
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
            let canonical = canonicalHost(inst.domain)
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
        for canonical in incompleteDomains {
            if restoreCachedRealInstances(for: canonical) { changed = true }
        }
        // A recognized empty listing is not proof that a previously tracked
        // court round was deleted. Only an explicit tombstone may remove it.
        for canonical in Set((fresh.honestZeroDomains ?? []).map(canonicalHost)) {
            if restoreCachedRealInstances(for: canonical) { changed = true }
        }
        guard changed else { return fresh }

        instances = MovementService.registrationOrder(instances)
        let registrationGroups = Set(instances.compactMap { instance -> String? in
            guard instance.previousRegistration != nil
                    || instance.note == "Предыдущая регистрация" else { return nil }
            return "\(canonicalHost(instance.domain))|\(instance.level.rawValue)"
        })
        for group in registrationGroups {
            guard let sample = instances.first(where: {
                "\(canonicalHost($0.domain))|\($0.level.rawValue)" == group
            }) else { continue }
            instances = MovementService.labelRegistrationRounds(
                instances, domain: sample.domain, level: sample.level)
        }
        acts.sort { MovementService.actOrderKey($0) < MovementService.actOrderKey($1) }
        var out = fresh
        out.instances = instances
        out.acts = acts
        out.actBodies = actBodies
        out.uid = uid
        out.inForce = inForce
        out.category = category
        out.parties = parties
        out.executionDocuments = executionDocuments
        out.incompleteHigherCourtDomains = nil
        out.honestZeroDomains = nil
        return MovementTargetBuilder.normalizeCriminalCassationRoute(in: out)
    }

    /// Версия для персиста: оставшиеся заглушки капчи вырезаются — transient
    /// URL формы хранить бессмысленно, при следующем живом запросе заглушка
    /// восстановится сама. transientError-стабы НЕ вырезаются (merge на
    /// следующий fetch должен увидеть, что у домена был сетевой сбой, иначе
    /// UI увидит «дело исчезло», а не «нет связи»). Акты не трогаются
    /// (у заглушек actID == nil).
    public static func stripped(forPersist mv: CaseMovement) -> CaseMovement {
        var out = MovementTargetBuilder.normalizeCriminalCassationRoute(in: mv)
        out.instances.removeAll { $0.captchaFormURL != nil }
        out.incompleteHigherCourtDomains = nil
        out.honestZeroDomains = nil
        out.sourceRefreshCoverage = nil
        return out
    }
}
