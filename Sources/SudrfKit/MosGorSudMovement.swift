//  MosGorSudMovement.swift — Sudrf
//  Московская ветка сервиса движения. Дела судов Москвы живут на mos-gorsud.ru:
//  1-я инстанция и апелляция/кассация в Мосгорсуде ищутся по УИД на самом
//  портале (параметры instance=2/3), дальше дело уходит на общую платформу —
//  2-й КСОЮ (sudrf.ru) и ВС РФ, как у любого другого региона.

import CryptoKit
import Foundation

/// Часть интерфейса `MosGorSudClient`, нужная сервису движения (подменяется в тестах).
public protocol MosGorSudProviding: Sendable {
    func search(courtAlias: String?, uid: String?, caseNumber: String?,
                participant: String?, instance: Int,
                processType: MosGorSudProcessType) async throws -> [MosGorSudResult]
    func fetchCard(url: URL) async throws -> MosGorSudCard
    func fetchPublishedAct(url: URL) async throws -> PublishedActFile
}

extension MosGorSudClient: MosGorSudProviding {}

public extension MosGorSudProviding {
    func fetchPublishedAct(url: URL) async throws -> PublishedActFile {
        throw PublishedActFileError.extractionFailed
    }
}

extension MovementService {

    /// Движение дела суда Москвы. Опорная точка — строка выдачи портала (или
    /// восстановленная из контекста отслеживания: тогда УИД добирается из карточки).
    public func moscowMovement(for base: MosGorSudResult,
                               cartoteka: Cartoteka) async throws -> CaseMovement {
        guard let mosgorsud else {
            throw SudrfError.parsing("клиент mos-gorsud не подключён — движение по делу Москвы не собрать")
        }
        let route = MosGorSudRouting.map(cartoteka: cartoteka)

        // 1. Карточка базовой инстанции (сессии, УИД, судья, вложения актов).
        let baseCard: MosGorSudCard?
        if let url = base.cardURL {
            baseCard = try await mosgorsud.fetchCard(url: url)
        } else {
            baseCard = nil
        }
        let uid = base.uid ?? baseCard?.uid

        var incompleteDomains: [String] = []
        var honestZeroDomains: [String] = []
        func appendUnique(_ domain: String, to domains: inout [String]) {
            let canonical = SudrfHost.moduleHost(domain)
            guard !domains.contains(where: { SudrfHost.moduleHost($0) == canonical }) else { return }
            domains.append(domain)
        }
        func markIncomplete(_ domain: String) { appendUnique(domain, to: &incompleteDomains) }
        func markHonestZero(_ domain: String) { appendUnique(domain, to: &honestZeroDomains) }

        func nonempty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        func publishedActs(from card: MosGorSudCard?, caseNumber: String,
                           level: CaseInstance.Level, court: String) async throws
            -> (acts: [CaseAct], bodies: [String: String], ids: [String], error: String?) {
            guard let card, !card.actFiles.isEmpty else { return ([], [:], [], nil) }
            var loadedActs: [CaseAct] = []
            var bodies: [String: String] = [:]
            var ids: [String] = []
            var failures: [String] = []
            for attachment in card.actFiles {
                guard PublishedActURLPolicy.isAllowedMosGorSud(attachment.url) else {
                    failures.append("Ссылка на опубликованный акт ведёт за пределы портала суда.")
                    continue
                }
                do {
                    let file = try await mosgorsud.fetchPublishedAct(url: attachment.url)
                    let id = Self.moscowPublishedActID(url: file.provenance.sourceURL,
                                                       caseNumber: caseNumber)
                    guard !ids.contains(id) else { continue }
                    ids.append(id)
                    loadedActs.append(CaseAct(
                        id: id,
                        title: nonempty(attachment.title) ?? "Судебный акт",
                        date: nonempty(attachment.date) ?? "—",
                        courtShort: court,
                        instanceLevel: level,
                        fileProvenance: file.provenance))
                    bodies[id] = file.text
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                    throw error
                } catch let error as PublishedActFileError {
                    failures.append(error.errorDescription
                        ?? "Не удалось прочитать опубликованный файл судебного акта.")
                } catch {
                    failures.append("Не удалось загрузить опубликованный файл судебного акта.")
                }
            }
            let error: String?
            if failures.isEmpty {
                error = nil
            } else if failures.count == 1 {
                error = failures[0]
            } else {
                error = "Не удалось прочитать опубликованные файлы судебных актов: \(failures.count)."
            }
            return (loadedActs, bodies, ids, error)
        }

        let baseLevel: CaseInstance.Level = route.instance >= 3 ? .cassation
                                          : route.instance == 2 ? .appeal : .first
        let baseCourt = base.court ?? baseCard?.court ?? "Суд Москвы (mos-gorsud.ru)"
        let baseActURLs = baseCard?.actFiles.compactMap {
            PublishedActURLPolicy.safeMosGorSudURL($0.url)
        } ?? []
        let basePublished = try await publishedActs(from: baseCard,
                                                    caseNumber: base.caseNumber,
                                                    level: baseLevel,
                                                    court: baseCourt)
        if basePublished.error != nil { markIncomplete(MosGorSudEndpoint.host) }
        var instances: [CaseInstance] = [CaseInstance(
            level: baseLevel,
            court: baseCourt,
            caseNumber: base.caseNumber,
            judge: base.judge ?? baseCard?.judge,
            domain: MosGorSudEndpoint.host,
            foundByUID: false,
            result: base.result ?? baseCard?.result,
            sessions: baseCard?.sessions ?? [],
            actID: basePublished.ids.first,
            actIDs: basePublished.ids.isEmpty ? nil : basePublished.ids,
            actURL: baseActURLs.first,
            actURLs: baseActURLs.isEmpty ? nil : baseActURLs,
            actFileError: basePublished.error,
            sourceURL: base.cardURL)]

        var acts: [CaseAct] = basePublished.acts
        var actBodies: [String: String] = basePublished.bodies

        // 2. Вышестоящие инстанции на самом портале: апелляция (instance=2) и
        //    кассация Мосгорсуда (instance=4 — «Кассационная»; `3` на портале
        //    это «Второй пересмотр»/надзор, не кассация) — по УИД.
        if let uid, !uid.isEmpty {
            let ups: [(instance: Int, level: CaseInstance.Level)] =
                [(MosGorSudInstance.appeal, .appeal),
                 (MosGorSudInstance.cassation, .cassation)].filter { $0.instance > route.instance }
            for up in ups {
                let rows: [MosGorSudResult]
                do {
                    rows = try await mosgorsud.search(courtAlias: nil, uid: uid,
                                                      caseNumber: nil, participant: nil,
                                                      instance: up.instance,
                                                      processType: route.processType)
                    if rows.isEmpty { markHonestZero(MosGorSudEndpoint.host) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                    throw error
                } catch {
                    markIncomplete(MosGorSudEndpoint.host)
                    continue
                }
                for r in rows {
                    if instances.contains(where: {
                        $0.domain == MosGorSudEndpoint.host
                            && Self.sameCaseNumber($0.caseNumber, r.caseNumber)
                    }) { continue }
                    let card: MosGorSudCard?
                    do {
                        if let url = r.cardURL {
                            card = try await mosgorsud.fetchCard(url: url)
                        } else {
                            card = nil
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                        throw error
                    } catch {
                        markIncomplete(MosGorSudEndpoint.host)
                        continue
                    }
                    let court = r.court ?? card?.court ?? "Московский городской суд"
                    let actURLs = card?.actFiles.compactMap {
                        PublishedActURLPolicy.safeMosGorSudURL($0.url)
                    } ?? []
                    let published = try await publishedActs(from: card,
                                                             caseNumber: r.caseNumber,
                                                             level: up.level,
                                                             court: court)
                    if published.error != nil { markIncomplete(MosGorSudEndpoint.host) }
                    acts.append(contentsOf: published.acts)
                    actBodies.merge(published.bodies) { current, _ in current }
                    instances.append(CaseInstance(
                        level: up.level,
                        court: court,
                        caseNumber: r.caseNumber,
                        judge: r.judge ?? card?.judge,
                        domain: MosGorSudEndpoint.host,
                        foundByUID: true,
                        result: r.result ?? card?.result,
                        sessions: card?.sessions ?? [],
                        actID: published.ids.first,
                        actIDs: published.ids.isEmpty ? nil : published.ids,
                        actURL: actURLs.first,
                        actURLs: actURLs.isEmpty ? nil : actURLs,
                        actFileError: published.error,
                        sourceURL: r.cardURL))
                }
            }
        }

        // 3. Кассация на общей платформе (2-й КСОЮ, sudrf.ru) — тем же УИД-циклом,
        //    что и у остальных регионов; домены приходят из MovementContext
        //    (суд субъекта Москвы вне платформы — в списке его нет, КСОЮ есть).
        if let uid, !uid.isEmpty {
            let result = try await sudrfCassationInstances(uid: uid,
                                                            baseCartotekaID: cartoteka.id)
            instances.append(contentsOf: result.instances)
            acts.append(contentsOf: result.acts)
            actBodies.merge(result.bodies) { a, _ in a }
            result.incompleteDomains.forEach(markIncomplete)
            result.honestZeroDomains.forEach(markHonestZero)
        }

        // 4. Вторая кассация — ВС РФ (по УИД; тройка без фамилий не собирается —
        //    стороны на портале не размечены по ролям).
        if let vsrf, let uid, !uid.isEmpty {
            let result = try await Self.vsrfInstancesOutcome(
                vsrf: vsrf, uid: uid,
                firstInstanceCourt: instances[0].court,
                firstInstanceCaseNumber: base.caseNumber,
                partySurnames: [])
            instances.append(contentsOf: result.instances)
            if result.incomplete { markIncomplete("vsrf.ru") }
            if result.instances.isEmpty, !result.incomplete { markHonestZero("vsrf.ru") }
        }

        let sortedInst = instances.sorted { Self.instanceOrderKey($0) < Self.instanceOrderKey($1) }
        let sortedActs = acts.sorted { Self.actOrderKey($0) < Self.actOrderKey($1) }

        var parties = CaseParties.split(essence: base.participants).parties ?? CaseParties()
        parties.inferKindIfNeeded(caseNumber: base.caseNumber)

        return CaseMovement(uid: uid ?? "",
                            caseNumber: base.caseNumber,
                            inForce: baseCard?.legalForceDate?.isEmpty == false,
                            instances: sortedInst,
                            complaints: [:],
                            acts: sortedActs,
                            actBodies: actBodies,
                            category: baseCard?.category,
                            parties: parties,
                            incompleteHigherCourtDomains: incompleteDomains.isEmpty
                                ? nil : incompleteDomains,
                            honestZeroDomains: honestZeroDomains.isEmpty ? nil : honestZeroDomains)
    }

    private static func moscowPublishedActID(url: URL, caseNumber: String) -> String {
        let sanitized = ActFileLoader.sanitizedURL(url)
        let identity = "\(sanitized.host?.lowercased() ?? MosGorSudEndpoint.host)\(sanitized.path)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        return "act_\(MosGorSudEndpoint.host)#\(caseNumber)#file-\(digest)"
    }

    /// УИД-поиск в кассационных судах платформы sudrf (для Москвы — 2-й КСОЮ).
    /// Упрощённый вариант основного цикла movement(for:): без классификации
    /// кругов апелляции (в кассации все найденные записи — кассационные) и без
    /// добора по known cards.
    private func sudrfCassationInstances(uid: String,
                                         baseCartotekaID: String) async throws
        -> (instances: [CaseInstance], acts: [CaseAct], bodies: [String: String],
            incompleteDomains: [String], honestZeroDomains: [String]) {
        var instances: [CaseInstance] = []
        var acts: [CaseAct] = []
        var bodies: [String: String] = [:]
        var incompleteDomains: [String] = []
        var honestZeroDomains: [String] = []

        for domain in higherCourtDomains {
            let level = Self.courtLevel(forDomain: domain)
            guard level == .cassation else { continue }
            let court = Court(domain: domain,
                              title: Self.shortCourtName(forDomain: domain),
                              level: level)
            let ids = Self.higherCartotekaIDs(baseID: baseCartotekaID, level: level,
                                              judicialUID: uid)
            let toTry = CartotekaRegistry.sets(for: level).filter { ids.contains($0.id) }
            var domainIncomplete = false
            let countBefore = instances.count

            for cart in toTry {
                do {
                    let rows = try await discoveryRows(court: court, cartoteka: cart,
                                                       field: .uid, value: uid)
                        .filter { Self.hasCardAccess($0) }
                    guard !rows.isEmpty else { continue }
                    for r in rows {
                        let card = try await fetchCard(row: r, court: court, cartoteka: cart)
                        let actID = "act_\(domain)#\(r.caseNumber)"
                        if let text = card.actText {
                            acts.append(CaseAct(
                                id: actID,
                                title: Self.actTitle(cartotekaID: cart.id, level: .cassation),
                                date: r.decisionDate ?? r.receiptDate ?? "—",
                                courtShort: Self.shortCourtName(forDomain: domain),
                                instanceLevel: .cassation))
                            bodies[actID] = text
                        }
                        instances.append(CaseInstance(
                            level: .cassation,
                            court: court.title,
                            caseNumber: r.caseNumber,
                            judge: r.judge ?? card.judge,
                            domain: domain,
                            foundByUID: true,
                            result: r.result ?? card.result,
                            sessions: card.sessions,
                            actID: card.actText != nil ? actID : nil,
                            sourceURL: Self.sourceURL(for: r, court: court,
                                                      cartoteka: cart)))
                    }
                    break   // найдено в этой картотеке — к следующему суду
                } catch SudrfError.captchaRequired(let formURL) {
                    domainIncomplete = true
                    if !instances.contains(where: { $0.domain == domain }) {
                        instances.append(CaseInstance(
                            level: .cassation, court: court.title, caseNumber: "—",
                            judge: nil, domain: domain, foundByUID: false,
                            result: nil, sessions: [], actID: nil,
                            captchaFormURL: formURL))
                    }
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                    throw error
                } catch {
                    domainIncomplete = true
                    continue
                }
            }
            if domainIncomplete { incompleteDomains.append(domain) }
            if instances.count == countBefore, !domainIncomplete { honestZeroDomains.append(domain) }
        }
        return (instances, acts, bodies, incompleteDomains, honestZeroDomains)
    }
}
