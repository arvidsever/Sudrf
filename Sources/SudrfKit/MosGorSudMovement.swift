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

/// Optional native-response capability used when a relationship depends on
/// the effective card URL after redirects. Ordinary MGS movement providers
/// keep the existing public surface.
protocol MosGorSudCardResponseProviding: Sendable {
    func fetchCardWithResponseURL(url: URL) async throws -> MosGorSudCardFetchResult
}

extension MosGorSudClient: MosGorSudProviding {}

public extension MosGorSudProviding {
    func fetchPublishedAct(url: URL) async throws -> PublishedActFile {
        throw PublishedActFileError.extractionFailed
    }
}

extension MosGorSudClient: MosGorSudCardResponseProviding {}

extension MovementService {

    /// Движение дела суда Москвы. Опорная точка — строка выдачи портала (или
    /// восстановленная из контекста отслеживания: тогда УИД добирается из карточки).
    public func moscowMovement(for base: MosGorSudResult,
                               cartoteka: Cartoteka) async throws -> CaseMovement {
        guard let mosgorsud else {
            throw SudrfError.parsing("клиент mos-gorsud не подключён — движение по делу Москвы не собрать")
        }
        let route = MosGorSudRouting.map(cartoteka: cartoteka)
        var coverage = MovementCoverageAccumulator()
        func markSharedMoscowCoverage(_ kind: SourceOutcomeKind) {
            coverage.mark(kind, sourceFamily: "mosgorsud", courtKey: MosGorSudEndpoint.host)
        }
        func markMoscowCoveragePartial(for url: URL?, cartoteka expectedCartoteka: Cartoteka? = nil) {
            if let url, let expectedCartoteka,
               let locator = SourceNativeCardLocator.mosgorsud(
                url: url, cartoteka: expectedCartoteka) {
                coverage.markPartial(sourceFamily: locator.sourceFamily,
                                     courtKey: locator.courtKey)
            } else if let url, let courtKey = SourceNativeCardLocator.mosgorsudCourtKey(url: url) {
                coverage.markPartial(sourceFamily: "mosgorsud", courtKey: courtKey)
            } else {
                markSharedMoscowCoverage(.partial)
            }
        }

        func coverageCartoteka(for instance: Int) -> Cartoteka? {
            CartotekaRegistry.sets(for: .subject).first {
                let candidate = MosGorSudRouting.map(cartoteka: $0)
                return candidate.processType == route.processType
                    && candidate.instance == instance
            }
        }

        var incompleteDomains: [String] = []
        var honestZeroDomains: [String] = []
        func appendUnique(_ domain: String, to domains: inout [String]) {
            let canonical = SudrfHost.moduleHost(domain)
            guard !domains.contains(where: { SudrfHost.moduleHost($0) == canonical }) else { return }
            domains.append(domain)
        }
        func markIncomplete(_ domain: String) { appendUnique(domain, to: &incompleteDomains) }
        func markHonestZero(_ domain: String) { appendUnique(domain, to: &honestZeroDomains) }
        func reflectCoverageInAggregateMasks() {
            for item in coverage.values {
                let domain = item.sourceFamily == "mosgorsud"
                    ? MosGorSudEndpoint.host : item.courtKey
                switch item.kind {
                case .usableSnapshot: break
                case .honestZero: markHonestZero(domain)
                default: markIncomplete(domain)
                }
            }
        }

        // 1. Карточка базовой инстанции (сессии, УИД, судья, вложения актов).
        let baseCard: MosGorSudCard?
        if let url = base.cardURL {
            guard let locator = SourceNativeCardLocator.mosgorsud(url: url, cartoteka: cartoteka) else {
                throw SudrfError.parsing("ссылка базовой карточки Мосгорсуда не соответствует картотеке")
            }
            if let title = base.court {
                let expectedCourtKey = Self.mosGorSudCourtKey(for: title)
                guard expectedCourtKey == locator.courtKey else {
                    throw SudrfError.parsing("ссылка базовой карточки Мосгорсуда относится к другому суду")
                }
            }
            baseCard = try await mosgorsud.fetchCard(url: url)
            guard let publishedNumber = baseCard?.caseNumber,
                  MosGorSudRouting.sameRegistrationNumber(base.caseNumber, publishedNumber) else {
                throw SudrfError.parsing("номер карточки Мосгорсуда не совпадает с базовой записью")
            }
            coverage.recordLoaded(locator)
        } else {
            baseCard = nil
            markSharedMoscowCoverage(.partial)
            markIncomplete(MosGorSudEndpoint.host)
        }
        let uid = base.uid ?? baseCard?.uid

        func nonempty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        func knownCardLocator(_ known: KnownCard, url: URL?) -> SourceNativeCardLocator? {
            let level = Self.courtLevel(forDomain: known.domain)
            let cart = known.cartotekaID.flatMap {
                CartotekaRegistry.find(level: level, id: $0)
            } ?? CartotekaRegistry.resolve(level: level, deloID: known.deloID,
                                           new: known.new,
                                           caseNumber: known.caseNumber ?? "")
            guard let cart else { return nil }
            if let url {
                return SourceNativeCardLocator.sudrf(url: url, cartoteka: cart)
            }
            return SourceNativeCardLocator.sudrf(
                court: Court(domain: known.domain, title: known.courtTitle, level: level),
                cartoteka: cart, caseID: known.caseID)
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

        let baseLevel: CaseInstance.Level = cartoteka.id == "adm33" && route.processType == .admin
            ? .supervisory
            : route.instance >= 3 ? .cassation
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
                let upCartoteka = coverageCartoteka(for: up.instance)
                let rows: [MosGorSudResult]
                do {
                    rows = try await mosgorsud.search(courtAlias: nil, uid: uid,
                                                      caseNumber: nil, participant: nil,
                                                      instance: up.instance,
                                                      processType: route.processType)
                    if rows.isEmpty {
                        markHonestZero(MosGorSudEndpoint.host)
                        markSharedMoscowCoverage(.honestZero)
                        if coverageCartoteka(for: up.instance) != nil {
                            coverage.mark(.honestZero, sourceFamily: "mosgorsud",
                                          courtKey: MosGorSudCourtDirectory.mgsAlias)
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                    throw error
                } catch {
                    markIncomplete(MosGorSudEndpoint.host)
                    markSharedMoscowCoverage(.partial)
                    continue
                }
                for r in rows {
                    if instances.contains(where: {
                        $0.domain == MosGorSudEndpoint.host
                            && MosGorSudRouting.sameRegistrationNumber($0.caseNumber, r.caseNumber)
                    }) { continue }
                    guard let rowURL = r.cardURL else {
                        markSharedMoscowCoverage(.partial)
                        markIncomplete(MosGorSudEndpoint.host)
                        continue
                    }
                    guard let rowLocator = upCartoteka.flatMap({
                        SourceNativeCardLocator.mosgorsud(url: rowURL, cartoteka: $0)
                    }) else {
                        markMoscowCoveragePartial(for: rowURL, cartoteka: upCartoteka)
                        markIncomplete(MosGorSudEndpoint.host)
                        continue
                    }
                    let card: MosGorSudCard
                    do {
                        card = try await mosgorsud.fetchCard(url: rowURL)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                        throw error
                    } catch {
                        markIncomplete(MosGorSudEndpoint.host)
                        markMoscowCoveragePartial(for: rowURL, cartoteka: upCartoteka)
                        continue
                    }
                    let hasOwnNumber = card.caseNumber.map {
                        MosGorSudRouting.sameRegistrationNumber(r.caseNumber, $0)
                    } == true
                    let matchingUIDs = [r.uid, card.uid].compactMap { $0 }.allSatisfy { $0 == uid }
                    guard hasOwnNumber, matchingUIDs else {
                        markMoscowCoveragePartial(for: rowURL, cartoteka: upCartoteka)
                        markIncomplete(MosGorSudEndpoint.host)
                        continue
                    }
                    coverage.recordLoaded(rowLocator)
                    let locatorCourt = rowLocator.courtKey == MosGorSudCourtDirectory.mgsAlias
                        ? "Московский городской суд"
                        : MosGorSudCourtDirectory.title(forAlias: rowLocator.courtKey)
                    guard let court = r.court ?? card.court ?? locatorCourt else {
                        markMoscowCoveragePartial(for: rowURL, cartoteka: upCartoteka)
                        markIncomplete(MosGorSudEndpoint.host)
                        continue
                    }
                    let actURLs = card.actFiles.compactMap {
                        PublishedActURLPolicy.safeMosGorSudURL($0.url)
                    }
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
                        judge: r.judge ?? card.judge,
                        domain: MosGorSudEndpoint.host,
                        foundByUID: true,
                        result: r.result ?? card.result,
                        sessions: card.sessions,
                        actID: published.ids.first,
                        actIDs: published.ids.isEmpty ? nil : published.ids,
                        actURL: actURLs.first,
                        actURLs: actURLs.isEmpty ? nil : actURLs,
                        actFileError: published.error,
                        sourceURL: r.cardURL))
                }
            }
        }

        // 3–4. Existing federal stages use the original first-instance court
        //      and number, even when this source anchor is a later Moscow card.
        let federal = try await moscowFederalStages(
            uid: uid, firstInstanceCourt: instances[0].court,
            firstInstanceCaseNumber: base.caseNumber,
            baseCartotekaID: cartoteka.id)
        instances.append(contentsOf: federal.instances)
        acts.append(contentsOf: federal.acts)
        actBodies.merge(federal.bodies) { a, _ in a }
        federal.incompleteDomains.forEach(markIncomplete)
        federal.honestZeroDomains.forEach(markHonestZero)
        coverage.merge(federal.sourceRefreshCoverage)

        // Some old Moscow cases link to an appellate court only through a
        // saved card. Restrict this refresh to official ASOYu hosts; the shared
        // KnownCard loader validates the exact SUDRF URL and effective host.
        let appellateDomains = Set(CourtDirectory.appealCourts.map {
            SudrfHost.moduleHost($0.domain)
        })
        for knownCard in knownCards
            where knownCard.level == .appeal
                && appellateDomains.contains(SudrfHost.moduleHost(knownCard.domain)) {
            if let number = knownCard.caseNumber,
               Self.containsInstance(instances, domain: knownCard.domain,
                                     caseNumber: number,
                                     sourceURL: Self.sourceURL(for: knownCard),
                                     preferSourceIdentity: knownCard.sourceURL != nil,
                                     usingCanonicalHost: true) {
                continue
            }
            let entry: (inst: CaseInstance, act: CaseAct?, body: String?)
            do {
                entry = try await instanceFromKnownCard(knownCard)
                _ = Self.appendIfNew(entry.inst, act: entry.act, body: entry.body,
                                     preferSourceIdentity: knownCard.sourceURL != nil,
                                     to: &instances, acts: &acts,
                                     actBodies: &actBodies)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                throw error
            } catch {
                markIncomplete(knownCard.domain)
                coverage.markPartial(sourceFamily: "sudrf",
                                     courtKey: SudrfHost.moduleHost(knownCard.domain))
                continue
            }
            if let locator = knownCardLocator(knownCard, url: entry.inst.sourceURL) {
                coverage.recordLoaded(locator)
            } else {
                coverage.markPartial(sourceFamily: "sudrf",
                                     courtKey: SudrfHost.moduleHost(knownCard.domain))
            }
        }

        reflectCoverageInAggregateMasks()
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
                            honestZeroDomains: honestZeroDomains.isEmpty ? nil : honestZeroDomains,
                            sourceRefreshCoverage: coverage.values.isEmpty ? nil : coverage.values)
    }

    private static func mosGorSudCourtKey(for title: String) -> String? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "ё", with: "е")
        if normalized == "московский городской суд" { return MosGorSudCourtDirectory.mgsAlias }
        return MosGorSudCourtDirectory.districtCourts.first {
            $0.title.lowercased().replacingOccurrences(of: "ё", with: "е") == normalized
        }?.alias
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
                                         baseCartotekaID: String,
                                         domains: [String]? = nil,
                                         using provider: (any CaseProviding)? = nil) async throws
        -> (instances: [CaseInstance], acts: [CaseAct], bodies: [String: String],
            incompleteDomains: [String], honestZeroDomains: [String],
            sourceRefreshCoverage: [MovementCourtCoverage]) {
        var instances: [CaseInstance] = []
        var acts: [CaseAct] = []
        var bodies: [String: String] = [:]
        var incompleteDomains: [String] = []
        var honestZeroDomains: [String] = []
        var coverage = MovementCoverageAccumulator()

        for domain in domains ?? higherCourtDomains {
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
                    let outcome = try await discoveryRowsOutcome(court: court, cartoteka: cart,
                                                                 field: .uid, value: uid,
                                                                 using: provider)
                    if outcome.kind == .partial {
                        domainIncomplete = true
                        coverage.markPartial(sourceFamily: "sudrf",
                                             courtKey: SudrfHost.moduleHost(domain))
                    } else if outcome.kind == .honestZero {
                        coverage.mark(.honestZero, sourceFamily: "sudrf",
                                      courtKey: SudrfHost.moduleHost(domain))
                    }
                    let rows = outcome.rows.filter { Self.hasCardAccess($0) }
                    if rows.count != outcome.rows.count {
                        domainIncomplete = true
                        coverage.markPartial(sourceFamily: "sudrf",
                                             courtKey: SudrfHost.moduleHost(domain))
                    }
                    guard !rows.isEmpty else { continue }
                    for r in rows {
                        let card = try await fetchCard(row: r, court: court,
                                                       cartoteka: cart, using: provider)
                        let locator: SourceNativeCardLocator?
                        if let url = r.cardURL {
                            locator = SourceNativeCardLocator.sudrf(url: url, cartoteka: cart)
                        } else if let caseID = r.caseID {
                            locator = SourceNativeCardLocator.sudrf(
                                court: court, cartoteka: cart, caseID: caseID)
                        } else {
                            locator = nil
                        }
                        if let locator {
                            coverage.recordLoaded(locator)
                        } else {
                            domainIncomplete = true
                            coverage.markPartial(sourceFamily: "sudrf",
                                                 courtKey: SudrfHost.moduleHost(domain))
                        }
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
                    coverage.markPartial(sourceFamily: "sudrf",
                                         courtKey: SudrfHost.moduleHost(domain))
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
                    coverage.markPartial(sourceFamily: "sudrf",
                                         courtKey: SudrfHost.moduleHost(domain))
                    continue
                }
            }
            if domainIncomplete { incompleteDomains.append(domain) }
            if instances.count == countBefore, !domainIncomplete {
                honestZeroDomains.append(domain)
                coverage.mark(.honestZero, sourceFamily: "sudrf",
                              courtKey: SudrfHost.moduleHost(domain))
            }
        }
        return (instances, acts, bodies, incompleteDomains, honestZeroDomains, coverage.values)
    }

    /// Existing federal discovery shared by ordinary Moscow cases and the
    /// verified Moscow magistrate KoAP chain. The first-instance details are
    /// passed explicitly so a later 4а card cannot become the VS comparison
    /// anchor by accident.
    func moscowFederalStages(uid: String?, firstInstanceCourt: String,
                             firstInstanceCaseNumber: String,
                             baseCartotekaID: String,
                             cassationDomains: [String]? = nil) async throws
        -> (instances: [CaseInstance], acts: [CaseAct], bodies: [String: String],
            incompleteDomains: [String], honestZeroDomains: [String],
            sourceRefreshCoverage: [MovementCourtCoverage]) {
        guard let uid, !uid.isEmpty else {
            return ([], [], [:], [], [], [])
        }
        var instances: [CaseInstance] = []
        var acts: [CaseAct] = []
        var bodies: [String: String] = [:]
        var incompleteDomains: [String] = []
        var honestZeroDomains: [String] = []
        var coverage = MovementCoverageAccumulator()

        // MagistrateClient is the existing provider router: it handles
        // *.msudrf.ru itself and forwards federal sudrf.ru requests to the
        // injected SudrfClient. The Moscow KoAP anchor client is unsuitable
        // for these higher-court calls.
        let federalProvider = magistrate ?? client
        let cassation = try await sudrfCassationInstances(
            uid: uid, baseCartotekaID: baseCartotekaID,
            domains: cassationDomains, using: federalProvider)
        instances.append(contentsOf: cassation.instances)
        acts.append(contentsOf: cassation.acts)
        bodies.merge(cassation.bodies) { current, _ in current }
        incompleteDomains.append(contentsOf: cassation.incompleteDomains)
        honestZeroDomains.append(contentsOf: cassation.honestZeroDomains)
        coverage.merge(cassation.sourceRefreshCoverage)

        if let vsrf {
            let result = try await Self.vsrfInstancesOutcome(
                vsrf: vsrf, uid: uid,
                firstInstanceCourt: firstInstanceCourt,
                firstInstanceCaseNumber: firstInstanceCaseNumber,
                partySurnames: [])
            instances.append(contentsOf: result.instances)
            acts.append(contentsOf: result.acts)
            for identity in result.loadedCardIdentities { coverage.recordLoaded(identity) }
            if result.incomplete {
                incompleteDomains.append("vsrf.ru")
                coverage.markPartial(sourceFamily: "vsrf", courtKey: "vsrf.ru")
            }
            if result.instances.isEmpty, !result.incomplete {
                honestZeroDomains.append("vsrf.ru")
                coverage.mark(.honestZero, sourceFamily: "vsrf", courtKey: "vsrf.ru")
            }
        }
        return (instances, acts, bodies, incompleteDomains, honestZeroDomains, coverage.values)
    }
}
