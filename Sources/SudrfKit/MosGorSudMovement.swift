//  MosGorSudMovement.swift — Sudrf
//  Московская ветка сервиса движения. Дела судов Москвы живут на mos-gorsud.ru:
//  1-я инстанция и апелляция/кассация в Мосгорсуде ищутся по УИД на самом
//  портале (параметры instance=2/3), дальше дело уходит на общую платформу —
//  2-й КСОЮ (sudrf.ru) и ВС РФ, как у любого другого региона.

import Foundation

/// Часть интерфейса `MosGorSudClient`, нужная сервису движения (подменяется в тестах).
public protocol MosGorSudProviding: Sendable {
    func search(courtAlias: String?, uid: String?, caseNumber: String?,
                participant: String?, instance: Int,
                processType: MosGorSudProcessType) async throws -> [MosGorSudResult]
    func fetchCard(url: URL) async throws -> MosGorSudCard
}

extension MosGorSudClient: MosGorSudProviding {}

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
        var baseCard: MosGorSudCard? = nil
        if let url = base.cardURL {
            baseCard = try? await mosgorsud.fetchCard(url: url)
        }
        let uid = base.uid ?? baseCard?.uid

        let baseLevel: CaseInstance.Level = route.instance >= 3 ? .cassation
                                          : route.instance == 2 ? .appeal : .first
        var instances: [CaseInstance] = [CaseInstance(
            level: baseLevel,
            court: base.court ?? baseCard?.court ?? "Суд Москвы (mos-gorsud.ru)",
            caseNumber: base.caseNumber,
            judge: base.judge ?? baseCard?.judge,
            domain: MosGorSudEndpoint.host,
            foundByUID: false,
            result: base.result ?? baseCard?.result,
            sessions: baseCard?.sessions ?? [],
            actID: nil,
            actURL: baseCard?.actLinks.first)]

        var acts: [CaseAct] = []
        var actBodies: [String: String] = [:]

        // 2. Вышестоящие инстанции на самом портале: апелляция (instance=2) и
        //    кассация Мосгорсуда (instance=4 — «Кассационная»; `3` на портале
        //    это «Второй пересмотр»/надзор, не кассация) — по УИД.
        if let uid, !uid.isEmpty {
            let ups: [(instance: Int, level: CaseInstance.Level)] =
                [(MosGorSudInstance.appeal, .appeal),
                 (MosGorSudInstance.cassation, .cassation)].filter { $0.instance > route.instance }
            for up in ups {
                let rows = (try? await mosgorsud.search(courtAlias: nil, uid: uid,
                                                        caseNumber: nil, participant: nil,
                                                        instance: up.instance,
                                                        processType: route.processType)) ?? []
                for r in rows {
                    if instances.contains(where: {
                        $0.domain == MosGorSudEndpoint.host
                            && Self.sameCaseNumber($0.caseNumber, r.caseNumber)
                    }) { continue }
                    var card: MosGorSudCard? = nil
                    if let url = r.cardURL { card = try? await mosgorsud.fetchCard(url: url) }
                    instances.append(CaseInstance(
                        level: up.level,
                        court: r.court ?? card?.court ?? "Московский городской суд",
                        caseNumber: r.caseNumber,
                        judge: r.judge ?? card?.judge,
                        domain: MosGorSudEndpoint.host,
                        foundByUID: true,
                        result: r.result ?? card?.result,
                        sessions: card?.sessions ?? [],
                        actID: nil,
                        actURL: card?.actLinks.first))
                }
            }
        }

        // 3. Кассация на общей платформе (2-й КСОЮ, sudrf.ru) — тем же УИД-циклом,
        //    что и у остальных регионов; домены приходят из MovementContext
        //    (суд субъекта Москвы вне платформы — в списке его нет, КСОЮ есть).
        if let uid, !uid.isEmpty {
            let (kInst, kActs, kBodies) = await sudrfCassationInstances(uid: uid,
                                                                        baseCartotekaID: cartoteka.id)
            instances.append(contentsOf: kInst)
            acts.append(contentsOf: kActs)
            actBodies.merge(kBodies) { a, _ in a }
        }

        // 4. Вторая кассация — ВС РФ (по УИД; тройка без фамилий не собирается —
        //    стороны на портале не размечены по ролям).
        if let vsrf, let uid, !uid.isEmpty {
            let vs = await Self.vsrfInstances(vsrf: vsrf, uid: uid,
                                              firstInstanceCourt: instances[0].court,
                                              firstInstanceCaseNumber: base.caseNumber,
                                              partySurnames: [])
            instances.append(contentsOf: vs)
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
                            parties: parties)
    }

    /// УИД-поиск в кассационных судах платформы sudrf (для Москвы — 2-й КСОЮ).
    /// Упрощённый вариант основного цикла movement(for:): без классификации
    /// кругов апелляции (в кассации все найденные записи — кассационные) и без
    /// добора по known cards.
    private func sudrfCassationInstances(uid: String,
                                         baseCartotekaID: String)
        async -> ([CaseInstance], [CaseAct], [String: String]) {
        var instances: [CaseInstance] = []
        var acts: [CaseAct] = []
        var bodies: [String: String] = [:]

        for domain in higherCourtDomains {
            let level = Self.courtLevel(forDomain: domain)
            guard level == .cassation else { continue }
            let court = Court(domain: domain,
                              title: Self.shortCourtName(forDomain: domain),
                              level: level)
            let ids = Self.higherCartotekaIDs(baseID: baseCartotekaID, level: level,
                                              judicialUID: uid)
            let toTry = CartotekaRegistry.sets(for: level).filter { ids.contains($0.id) }

            for cart in toTry {
                do {
                    let rows = try await client.search(court: court, cartoteka: cart,
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
                            actID: card.actText != nil ? actID : nil))
                    }
                    break   // найдено в этой картотеке — к следующему суду
                } catch SudrfError.captchaRequired(let formURL) {
                    if !instances.contains(where: { $0.domain == domain }) {
                        instances.append(CaseInstance(
                            level: .cassation, court: court.title, caseNumber: "—",
                            judge: nil, domain: domain, foundByUID: false,
                            result: nil, sessions: [], actID: nil,
                            captchaFormURL: formURL))
                    }
                    break
                } catch { continue }
            }
        }
        return (instances, acts, bodies)
    }
}
