import Foundation
import SudrfKit

/// Однозначно восстановленная карточка нижестоящего производства.
struct ResolvedCaseOrigin: Sendable {
    var court: Court
    var branch: CourtBranch
    var region: String
    var courtCode: String?
    var cartoteka: Cartoteka
    var result: CaseSearchResult
    var card: CaseCard
    /// Карточки, пройденные между исходным якорем и канонической карточкой
    /// (например, 22К → 3/12-материал → 7У/основное дело). Их нельзя терять:
    /// MovementService использует точные known links для полной цепочки.
    var intermediateCards: [ResolvedOriginCard] = []
    /// Районные суды региона для поиска необязательной апелляции на акт
    /// мирового судьи после переякоривания.
    var districtAppealCourts: [OriginTargetCourt] = []
}

struct ResolvedOriginCard: Sendable {
    var court: Court
    var cartoteka: Cartoteka
    var result: CaseSearchResult
    var card: CaseCard
}

struct OriginTargetCourt: Sendable, Equatable {
    var domain: String
    var title: String
}

enum CaseOriginResolutionError: Error, Equatable {
    case noReference
    case unsupportedCourt
    case notFound
    case ambiguous
    /// A matching search row existed, but its source/card could not be fully
    /// verified, so the result set is not exhaustive enough for uniqueness.
    case incompleteCandidates
}

protocol CaseOriginResolving: Sendable {
    func resolve(anchorContext: MovementContext,
                 anchorCard: CaseCard) async throws -> ResolvedCaseOrigin
    /// Предварительный материал (`М-`, `9-`, `9а-`, `9у-`) может стать
    /// самостоятельным основным делом только после точного подтверждения УИД.
    func resolveMainCase(anchorContext: MovementContext,
                         anchorCard: CaseCard) async throws -> ResolvedCaseOrigin
}

extension CaseOriginResolving {
    func resolveMainCase(anchorContext: MovementContext,
                         anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        throw CaseOriginResolutionError.noReference
    }
}

struct OriginCourtResolution: Sendable {
    var court: Court
    var branch: CourtBranch
    var code: String?
}

/// Восстанавливает первую инстанцию по УИД и вкладке
/// «РАССМОТРЕНИЕ В НИЖЕСТОЯЩЕМ СУДЕ». Никогда не сопоставляет по сторонам.
actor CaseOriginResolver {
    private let districtResolver: DistrictCourtResolver
    private let magistrateResolver: MagistrateCourtResolver
    private let regularProvider: any CaseProviding
    private let magistrateProvider: any CaseProviding
    private let courtOverride: OriginCourtResolution?

    init(client: SudrfClient,
         districtResolver: DistrictCourtResolver? = nil,
         magistrateResolver: MagistrateCourtResolver? = nil,
         regularProvider: (any CaseProviding)? = nil,
         magistrateProvider: (any CaseProviding)? = nil,
         courtOverride: OriginCourtResolution? = nil) {
        self.districtResolver = districtResolver ?? DistrictCourtResolver(client: client)
        self.magistrateResolver = magistrateResolver ?? MagistrateCourtResolver(client: client)
        self.regularProvider = regularProvider ?? client
        self.magistrateProvider = magistrateProvider ?? MagistrateClient(sudrfClient: client)
        self.courtOverride = courtOverride
    }

    func resolve(anchorContext: MovementContext, anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        if anchorContext.baseInstanceLevel == .material {
            return try await resolveVerifiedMaterialParent(context: anchorContext, card: anchorCard)
        }
        guard anchorContext.baseInstanceLevel == .appeal
                || anchorContext.baseInstanceLevel == .cassation else {
            throw CaseOriginResolutionError.noReference
        }
        guard let ref = anchorCard.lowerCourt,
              let lowerNumber = ref.caseNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lowerNumber.isEmpty else {
            throw CaseOriginResolutionError.noReference
        }

        let judicialUID = Self.nonEmpty(anchorCard.uid) ?? Self.nonEmpty(anchorContext.judicialUID)
        if anchorContext.courtLevel == .subject,
           anchorContext.cartotekaId == "adm33",
           KoAPProceduralRole.uidCourtKind(judicialUID) == .district,
           !Self.isHistoricalSubjectReview(context: anchorContext, card: anchorCard) {
            // Современная adm33-компетенция суда субъекта охватывает MS-цепочки.
            // RS допустим только для исторических производств до реформы 2019 г.
            throw CaseOriginResolutionError.unsupportedCourt
        }
        let code = Self.classificationCode(from: judicialUID)
        let region = Self.cleanRegion(ref.region)
            ?? code.flatMap { CourtDirectory.subjectName(forSubjectCode: $0) }
            ?? anchorContext.region
        // УИД сквозной для всей процессуальной цепочки. Код суда внутри него
        // указывает место первоначального присвоения УИД, но не обязан
        // совпадать с судом из текущей ссылки вниз. Поэтому опубликованное
        // название нижестоящего суда всегда маршрутизирует раньше UID-кода.
        let resolved = try await resolveCourt(code: code, title: ref.courtTitle, region: region)
        let cart = try Self.firstCartoteka(anchorID: anchorContext.cartotekaId,
                                           lowerNumber: lowerNumber,
                                           level: resolved.court.level)
        let provider: any CaseProviding = resolved.court.level == .magistrate
            ? magistrateProvider : regularProvider

        var rows: [CaseSearchResult] = []
        if resolved.court.level != .magistrate, let judicialUID, !judicialUID.isEmpty {
            do {
                rows = try await provider.search(court: resolved.court, cartoteka: cart,
                                                 field: .uid, value: judicialUID)
            } catch let error as SudrfError {
                if case .captchaRequired = error { throw error }
                if case .transientNetworkError = error { throw error }
                rows = []
            }
        }
        // Некоторые формы игнорируют выбранную картотеку при поиске по УИД и
        // возвращают связанную строку с другим номером. Это не «не найдено»:
        // выполняем предусмотренный второй поиск по опубликованному точному №,
        // а затем всё равно проверяем сквозной УИД загруженной карточки.
        if !rows.contains(where: { Self.sameCaseNumber($0.caseNumber, lowerNumber) }) {
            rows = try await provider.search(court: resolved.court, cartoteka: cart,
                                             field: .caseNumber, value: lowerNumber)
        }
        let matched = try await uniqueMatch(rows: rows, number: lowerNumber, uid: judicialUID,
                                            court: resolved.court, cartoteka: cart,
                                            provider: provider)
        var canonical = ResolvedOriginCard(court: resolved.court, cartoteka: cart,
                                           result: matched.0, card: matched.1)
        var intermediate: [ResolvedOriginCard] = []

        // Материал остаётся самостоятельной карточкой, кроме производства,
        // для которого внешний УИД подтверждает родительское дело. Для 13/13а
        // такая связь также допускается только по точному УИД, никогда по №.
        if cart.id == "m", CaseIndexClassifier.requiresVerifiedParent(caseNumber: lowerNumber,
                                                                        courtLevel: resolved.court.level),
           let parentCart = Self.verifiedParentCartoteka(for: lowerNumber,
                                                         level: resolved.court.level),
           let judicialUID, !judicialUID.isEmpty {
            let parentRows = try await provider.search(court: resolved.court, cartoteka: parentCart,
                                                       field: .uid, value: judicialUID)
            if let parentMatch = try await uniqueUIDMatch(rows: parentRows, uid: judicialUID,
                                                          court: resolved.court, cartoteka: parentCart,
                                                          provider: provider) {
                intermediate.append(canonical)
                canonical = ResolvedOriginCard(court: resolved.court, cartoteka: parentCart,
                                               result: parentMatch.0, card: parentMatch.1)
            }
        }
        let districtAppealCourts: [OriginTargetCourt]
        if resolved.court.level == .magistrate {
            districtAppealCourts = ((try? await districtResolver.allCourts(forRegion: region)) ?? [])
                .filter { $0.kind == .district && $0.domain.hasSuffix("sudrf.ru") }
                .map { OriginTargetCourt(domain: $0.domain, title: $0.title) }
        } else {
            districtAppealCourts = []
        }
        return ResolvedCaseOrigin(court: canonical.court, branch: resolved.branch,
                                  region: region, courtCode: resolved.code,
                                  cartoteka: canonical.cartoteka, result: canonical.result,
                                  card: canonical.card, intermediateCards: intermediate,
                                  districtAppealCourts: districtAppealCourts)
    }

    /// Ищет принятое к производству основное дело в том же суде и по тому же
    /// УИД. Предварительный номер не участвует в выборе: он лишь повод выполнить
    /// проверку, а совпадение допускается ровно одно.
    func resolveMainCase(anchorContext: MovementContext,
                         anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        guard let preliminary = CaseIndexClassifier.classify(
            caseNumber: anchorContext.caseNumber, courtLevel: anchorContext.courtLevel,
            branch: anchorContext.branch),
              preliminary.materialLinkPolicy == .mayBecomeMainCase
        else { throw CaseOriginResolutionError.noReference }

        let court = anchorContext.searchCourt
        guard let cart = anchorContext.cartoteka else {
            throw CaseOriginResolutionError.noReference
        }
        // Площадки мировых судей не поддерживают поиск по УИД. Без него нельзя
        // выполнить обязательную точную проверку перехода предварительного
        // номера, поэтому не превращаем отсутствие подтверждения в parsing-
        // ошибку и постоянное исключение из repair-прохода.
        guard court.level != .magistrate else {
            throw CaseOriginResolutionError.noReference
        }

        let cartotekas = Self.firstInstanceCartotekas(
            court: court, anchor: cart, branch: anchorContext.branch)
        guard !cartotekas.isEmpty else { throw CaseOriginResolutionError.noReference }
        let anchorSRV = Self.sourceSRV(anchorContext.baseResult.cardURL) ?? "1"

        // Ряд судов меняет номер прямо на той же карточке: например,
        // `3а-685/2026 ~ М-662/2026`. Это сильнее поисковой эвристики:
        // карточка уже загружена по точному исходному адресу.
        if Self.validatedSourceKey(row: anchorContext.baseResult, court: court,
                                   cartoteka: cart, expectedSRV: anchorSRV) != nil,
           Self.judicialUIDsDoNotContradict(card: anchorCard, context: anchorContext),
           let current = Self.mainRegistration(
            in: anchorCard.caseNumber, preliminaryNumber: anchorContext.caseNumber,
            preliminary: preliminary, courtLevel: court.level,
            branch: anchorContext.branch, allowedCartotekas: cartotekas),
           current.cartoteka.id == cart.id {
            var result = anchorContext.baseResult
            result.caseNumber = anchorCard.caseNumber ?? current.number
            return ResolvedCaseOrigin(
                court: court, branch: anchorContext.branch, region: anchorContext.region,
                courtCode: anchorContext.courtCode, cartoteka: current.cartoteka,
                result: result, card: anchorCard)
        }

        guard let uid = Self.verifiedJudicialUID(card: anchorCard, context: anchorContext)
        else { throw CaseOriginResolutionError.noReference }

        var matches: [String: ResolvedOriginCard] = [:]
        var incomplete = false
        for candidateCart in cartotekas {
            try Task.checkCancellation()
            let rows = try await regularProvider.search(
                court: court, cartoteka: candidateCart, field: .uid, value: uid)
            for row in rows {
                try Task.checkCancellation()
                guard let rowRegistration = Self.mainRegistration(
                    in: row.caseNumber, preliminaryNumber: anchorContext.caseNumber,
                    preliminary: preliminary, courtLevel: court.level,
                    branch: anchorContext.branch, allowedCartotekas: cartotekas),
                      rowRegistration.cartoteka.id == candidateCart.id else { continue }
                guard let sourceKey = Self.validatedSourceKey(
                    row: row, court: court, cartoteka: candidateCart,
                    expectedSRV: anchorSRV) else {
                    incomplete = true
                    continue
                }

                let foundCard: CaseCard
                do {
                    foundCard = try await fetchCard(
                        row: row, court: court, cartoteka: candidateCart,
                        provider: regularProvider)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw error
                } catch let error as SudrfError {
                    switch error {
                    case .captchaRequired, .transientNetworkError,
                         .caseCardTemporarilyUnavailable, .sourceMaintenance:
                        throw error
                    default:
                        incomplete = true
                        continue
                    }
                } catch {
                    // Пока хотя бы одну подходящую строку нельзя прочитать,
                    // единственность другой карточки не доказана.
                    incomplete = true
                    continue
                }
                guard Self.matchesVerifiedJudicialUID(foundCard.uid, expected: uid),
                      let cardRegistration = Self.mainRegistration(
                        in: foundCard.caseNumber, preliminaryNumber: anchorContext.caseNumber,
                        preliminary: preliminary, courtLevel: court.level,
                        branch: anchorContext.branch, allowedCartotekas: cartotekas),
                      cardRegistration.cartoteka.id == candidateCart.id,
                      Self.samePublishedCaseNumber(
                        rowRegistration.number, cardRegistration.number),
                      Self.previousRegistrationDoesNotContradict(
                        foundCard.previousRegistration, anchor: anchorContext,
                        court: court, anchorCartoteka: cart,
                        expectedSRV: anchorSRV)
                else { continue }
                let match = ResolvedOriginCard(
                    court: court, cartoteka: candidateCart,
                    result: row, card: foundCard)
                if let existing = matches[sourceKey],
                   !Self.samePublishedCaseNumber(
                    existing.card.caseNumber, match.card.caseNumber) {
                    throw CaseOriginResolutionError.ambiguous
                }
                matches[sourceKey] = match
            }
        }
        if incomplete { throw CaseOriginResolutionError.incompleteCandidates }
        guard matches.count == 1, let match = matches.values.first else {
            throw matches.isEmpty ? CaseOriginResolutionError.notFound
                                  : CaseOriginResolutionError.ambiguous
        }
        return ResolvedCaseOrigin(court: court, branch: anchorContext.branch,
                                  region: anchorContext.region, courtCode: anchorContext.courtCode,
                                  cartoteka: match.cartoteka, result: match.result,
                                  card: match.card)
    }

    private struct MainRegistration {
        var number: String
        var cartoteka: Cartoteka
    }

    private static func mainRegistration(
        in publishedNumber: String?, preliminaryNumber: String,
        preliminary: CaseIndexInfo, courtLevel: CourtLevel, branch: CourtBranch,
        allowedCartotekas: [Cartoteka]
    ) -> MainRegistration? {
        guard let publishedNumber = nonEmpty(publishedNumber) else { return nil }
        let parts = publishedNumber
            .split(omittingEmptySubsequences: false) { $0 == "~" || $0 == "∼" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 1 || parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        if parts.count == 2,
           !samePublishedCaseNumber(parts[1], preliminaryNumber) { return nil }

        let currentNumber = parts[0]
        guard isCompletePublishedNumber(currentNumber),
              parts.count == 1 || isCompletePublishedNumber(parts[1]) else { return nil }
        guard let current = CaseIndexClassifier.classify(
            caseNumber: currentNumber, courtLevel: courtLevel, branch: branch),
              current.cardRole == .firstInstanceCase,
              courtLevel != .subject || current.processKind == .administrative,
              preliminary.processKind == nil || current.processKind == preliminary.processKind
        else { return nil }
        let carts = CartotekaRegistry.matches(caseNumber: currentNumber, level: courtLevel)
            .filter { cart in allowedCartotekas.contains { $0.id == cart.id } }
        guard carts.count == 1, let cart = carts.first else { return nil }
        return MainRegistration(number: currentNumber, cartoteka: cart)
    }

    private static func firstInstanceCartotekas(
        court: Court, anchor: Cartoteka, branch: CourtBranch
    ) -> [Cartoteka] {
        guard branch == .general else { return [anchor] }
        let ids: [String]
        switch anchor.id.lowercased() {
        case "g1": ids = ["g1", "p1"]
        case "p1": ids = ["p1", "g1"]
        default: ids = [anchor.id]
        }
        return ids.compactMap { CartotekaRegistry.find(level: court.level, id: $0) }
    }

    private static func verifiedJudicialUID(
        card: CaseCard, context: MovementContext
    ) -> String? {
        let rawValues = [card.uid, context.judicialUID].compactMap(nonEmpty)
        guard !rawValues.isEmpty,
              rawValues.allSatisfy({ JudicialUIDObservation.validity(of: $0) == .valid })
        else { return nil }
        let normalized = Set(rawValues.map(JudicialUIDObservation.normalize))
        guard normalized.count == 1 else { return nil }
        return rawValues[0]
    }

    private static func judicialUIDsDoNotContradict(
        card: CaseCard, context: MovementContext
    ) -> Bool {
        let rawValues = [card.uid, context.judicialUID].compactMap(nonEmpty)
        guard rawValues.allSatisfy({ JudicialUIDObservation.validity(of: $0) == .valid })
        else { return false }
        return Set(rawValues.map(JudicialUIDObservation.normalize)).count <= 1
    }

    private static func matchesVerifiedJudicialUID(
        _ candidate: String?, expected: String
    ) -> Bool {
        guard JudicialUIDObservation.validity(of: candidate) == .valid,
              let candidate else { return false }
        return JudicialUIDObservation.normalize(candidate)
            == JudicialUIDObservation.normalize(expected)
    }

    private static func validatedSourceKey(
        row: CaseSearchResult, court: Court, cartoteka: Cartoteka,
        expectedSRV: String?
    ) -> String? {
        if let url = row.cardURL {
            guard let link = try? SudrfCaseCardLink(url: url),
                  link.moduleHost == SudrfHost.moduleHost(court.domain),
                  let linkedCart = CartotekaRegistry.resolve(
                    level: court.level, deloID: link.deloID, new: link.new,
                    caseNumber: row.caseNumber),
                  linkedCart.id == cartoteka.id,
                  expectedSRV == nil || (link.srvNum ?? "1") == expectedSRV,
                  row.caseID == nil || row.caseID == link.caseID,
                  row.caseUID == nil || row.caseUID == link.caseUID
            else { return nil }
            let sourceID = link.caseID.map { "id:\($0)" }
                ?? link.caseUID.map { "uid:\($0)" }
            guard let sourceID else { return nil }
            return "\(cartoteka.id)|srv:\(link.srvNum ?? "1")|\(sourceID)"
        }
        guard let caseID = nonEmpty(row.caseID), nonEmpty(row.caseUID) != nil else { return nil }
        guard expectedSRV == nil || expectedSRV == "1" else { return nil }
        return "\(cartoteka.id)|srv:1|id:\(caseID)"
    }

    private static func previousRegistrationDoesNotContradict(
        _ reference: PreviousRegistrationReference?, anchor: MovementContext,
        court: Court, anchorCartoteka: Cartoteka, expectedSRV: String
    ) -> Bool {
        guard let reference else { return true }
        guard samePublishedCaseNumber(reference.caseNumber, anchor.caseNumber),
              let link = try? SudrfCaseCardLink(url: reference.url),
              link.moduleHost == SudrfHost.moduleHost(court.domain),
              let linkedCart = CartotekaRegistry.resolve(
                level: court.level, deloID: link.deloID, new: link.new,
                caseNumber: reference.caseNumber),
              linkedCart.id == anchorCartoteka.id,
              (link.srvNum ?? "1") == expectedSRV,
              (anchor.caseID != nil && anchor.caseID == link.caseID)
                || (anchor.caseID == nil && anchor.caseUID != nil
                    && anchor.caseUID == link.caseUID),
              anchor.caseUID == nil || link.caseUID == nil || anchor.caseUID == link.caseUID
        else { return false }
        return true
    }

    private static func samePublishedCaseNumber(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalizedPublishedCaseNumber(lhs),
              let rhs = normalizedPublishedCaseNumber(rhs) else { return false }
        return lhs == rhs
    }

    private static func normalizedPublishedCaseNumber(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        let latin: [Character: Character] = ["a": "а", "g": "г", "k": "к",
                                             "m": "м", "y": "у", "u": "у"]
        var compact = String(value.lowercased().replacingOccurrences(of: "ё", with: "е")
            .filter { !$0.isWhitespace }.map { latin[$0] ?? $0 })
        if compact.hasPrefix("№") { compact.removeFirst() }
        return compact.isEmpty ? nil : compact
    }

    private static func isCompletePublishedNumber(_ value: String) -> Bool {
        guard let normalized = normalizedPublishedCaseNumber(value),
              let regex = try? NSRegularExpression(
                pattern: #"^[0-9а-яё/]+-[0-9]+/[0-9]{4}(?:\([0-9]+\))?$"#)
        else { return false }
        let range = NSRange(normalized.startIndex..., in: normalized)
        return regex.firstMatch(in: normalized, range: range)?.range == range
    }

    private static func sourceSRV(_ url: URL?) -> String? {
        guard let url, let link = try? SudrfCaseCardLink(url: url) else { return nil }
        return link.srvNum ?? "1"
    }

    private func resolveVerifiedMaterialParent(context: MovementContext, card: CaseCard) async throws
        -> ResolvedCaseOrigin {
        guard CaseIndexClassifier.requiresVerifiedParent(caseNumber: context.caseNumber,
                                                          courtLevel: context.courtLevel),
              let uid = Self.nonEmpty(card.uid) ?? Self.nonEmpty(context.judicialUID),
              let cart = Self.verifiedParentCartoteka(for: context.caseNumber, level: context.courtLevel)
        else { throw CaseOriginResolutionError.noReference }
        let court = context.searchCourt
        let provider: any CaseProviding = court.level == .magistrate ? magistrateProvider : regularProvider
        let rows = try await provider.search(court: court, cartoteka: cart, field: .uid, value: uid)
        guard let parent = try await uniqueUIDMatch(rows: rows, uid: uid, court: court,
                                                    cartoteka: cart, provider: provider) else {
            throw CaseOriginResolutionError.notFound
        }
        guard let materialCart = context.cartoteka else { throw CaseOriginResolutionError.noReference }
        let material = ResolvedOriginCard(court: court, cartoteka: materialCart,
                                          result: context.baseResult, card: card)
        return ResolvedCaseOrigin(court: court, branch: context.branch, region: context.region,
                                  courtCode: context.courtCode, cartoteka: cart,
                                  result: parent.0, card: parent.1, intermediateCards: [material])
    }

    private func uniqueMatch(rows: [CaseSearchResult], number: String, uid: String?,
                             court: Court, cartoteka: Cartoteka,
                             provider: any CaseProviding) async throws -> (CaseSearchResult, CaseCard) {
        let exact = rows.filter { Self.sameCaseNumber($0.caseNumber, number) }
        guard !exact.isEmpty else { throw CaseOriginResolutionError.notFound }
        var matches: [(CaseSearchResult, CaseCard)] = []
        for row in exact {
            let card: CaseCard
            do {
                card = try await fetchCard(row: row, court: court,
                                           cartoteka: cartoteka, provider: provider)
            } catch let error as SudrfError {
                if case .captchaRequired = error { throw error }
                if case .transientNetworkError = error { throw error }
                continue
            } catch {
                continue
            }
            if let uid = Self.nonEmpty(uid) {
                guard let found = Self.nonEmpty(card.uid),
                      Self.normalizedUID(found) == Self.normalizedUID(uid) else { continue }
            }
            matches.append((row, card))
        }
        guard matches.count == 1, let match = matches.first else {
            throw matches.isEmpty ? CaseOriginResolutionError.notFound
                                  : CaseOriginResolutionError.ambiguous
        }
        return match
    }

    private func uniqueUIDMatch(rows: [CaseSearchResult], uid: String, court: Court,
                                cartoteka: Cartoteka,
                                provider: any CaseProviding) async throws -> (CaseSearchResult, CaseCard)? {
        var matches: [(CaseSearchResult, CaseCard)] = []
        for row in rows {
            do {
                let card = try await fetchCard(row: row, court: court, cartoteka: cartoteka,
                                               provider: provider)
                guard let found = card.uid, !found.isEmpty,
                      Self.normalizedUID(found) == Self.normalizedUID(uid) else { continue }
                matches.append((row, card))
            } catch let error as SudrfError {
                if case .captchaRequired = error { throw error }
                if case .transientNetworkError = error { throw error }
            } catch { continue }
        }
        if matches.count > 1 { throw CaseOriginResolutionError.ambiguous }
        return matches.first
    }

    private func resolveCourt(code: String?, title: String?, region: String) async throws
        -> OriginCourtResolution {
        if let courtOverride { return courtOverride }

        // Официальная вкладка «Рассмотрение в нижестоящем суде» — основной
        // источник маршрута. В справочнике портал часто дописывает субъект
        // («… Республики Коми»), которого нет в карточке вышестоящего суда.
        if let title, !title.isEmpty {
            let normalized = title.lowercased().replacingOccurrences(of: "ё", with: "е")
            let isMagistrateTitle = normalized.contains("судебн") && normalized.contains("участ")
                || normalized.contains("миров") && normalized.contains("суд")
            if isMagistrateTitle {
                let matches = try await magistrateResolver.courts(forRegion: region)
                    .filter { Self.sameCourtTitle($0.title, title, region: region) && $0.isSupported }
                if matches.count > 1 { throw CaseOriginResolutionError.ambiguous }
                if let found = matches.first {
                    return OriginCourtResolution(court: found.court, branch: .general,
                                                 code: found.code)
                }
            } else {
                let matches = try await districtResolver.allCourts(forRegion: region)
                    .filter { Self.sameCourtTitle($0.title, title, region: region) }
                if matches.count > 1 { throw CaseOriginResolutionError.ambiguous }
                if let found = matches.first {
                    return OriginCourtResolution(
                        court: Court(domain: SudrfHost.moduleHost(found.domain), title: found.title,
                                     level: found.kind == .subject ? .subject : .district),
                        branch: found.kind == .military ? .military : .general, code: found.code)
                }
            }
        }

        // Запасной маршрут для карточек, где название суда не опубликовано.
        if let code {
            let kind = CourtKind(classificationCode: code)
            switch kind {
            case .magistrate:
                let courts = try await magistrateResolver.courts(forRegion: region)
                if let found = courts.first(where: { $0.code.uppercased() == code.uppercased() }),
                   found.isSupported {
                    return OriginCourtResolution(court: found.court, branch: .general,
                                                 code: found.code)
                }
            case .district, .military:
                let courts = try await districtResolver.allCourts(forRegion: region)
                if let found = courts.first(where: { $0.code?.uppercased() == code.uppercased() }) {
                    // Гарнизонный военный суд — тот же районный уровень;
                    // военная вертикаль передаётся через branch.
                    return OriginCourtResolution(
                        court: Court(domain: SudrfHost.moduleHost(found.domain), title: found.title,
                                     level: .district),
                        branch: kind == .military ? .military : .general, code: found.code)
                }
            case .subject:
                if let found = CourtDirectory.subjectCourt(forSubjectCode: code), found.isSudrfPlatform {
                    return OriginCourtResolution(
                        court: Court(domain: SudrfHost.moduleHost(found.domain), title: found.title,
                                     level: .subject), branch: .general, code: code)
                }
            default:
                break
            }
        }

        throw CaseOriginResolutionError.unsupportedCourt
    }

    private func fetchCard(row: CaseSearchResult, court: Court, cartoteka: Cartoteka,
                           provider: any CaseProviding) async throws -> CaseCard {
        if let id = row.caseID, let uid = row.caseUID {
            return try await provider.fetchCard(court: court, caseID: id, caseUID: uid,
                                                deloID: cartoteka.deloID, new: cartoteka.new)
        }
        guard let url = row.cardURL else { throw CaseOriginResolutionError.notFound }
        return try await provider.fetchCard(url: url)
    }

    static func firstCartoteka(anchorID: String, lowerNumber: String,
                               level: CourtLevel) throws -> Cartoteka {
        let anchorID = anchorID.lowercased()
        let prefix = String(anchorID.prefix(while: { $0.isLetter }))

        // Номер из вкладки нижестоящего суда — единственный достоверный
        // указатель стадии. Нельзя всегда сводить его к первой инстанции:
        // 3/12-… и 13-… живут в «Материалах», 11-… — районная апелляция,
        // а 22К-/33-… — апелляционные картотеки суда субъекта.
        // КоАП-картотеки `adm*` кодируют процессуальную роль якоря, а не
        // только индекс нижестоящего номера, поэтому для них ниже остаётся
        // специальная маршрутизация.
        let matched = anchorID.hasPrefix("adm")
            ? [] : CartotekaRegistry.matches(caseNumber: lowerNumber, level: level)
        if matched.count == 1, let cart = matched.first { return cart }
        let id: String
        switch anchorID {
        case "adm1":
            // Областная жалоба на постановление районного суда.
            guard level == .district else { throw CaseOriginResolutionError.unsupportedCourt }
            id = "adm"
        case "adm2":
            // Областная жалоба на решение райсуда по жалобе на постановление органа.
            guard level == .district else { throw CaseOriginResolutionError.unsupportedCourt }
            id = "admj"
        case "adm33", "adm3":
            // Для вступившего в силу акта УИД указывает исходный суд, а точный
            // номер из нижестоящей вкладки различает районные adm/admj.
            switch level {
            case .magistrate:
                id = "adm"
            case .district:
                id = CartotekaRegistry.normalizedNumber(lowerNumber).hasPrefix("12-")
                    ? "admj" : "adm"
            default:
                throw CaseOriginResolutionError.unsupportedCourt
            }
        case "admj":
            // Только MS-ветка: районный admj является апелляцией на
            // постановление мирового судьи. RS-admj уже является первым
            // судебным якорем и вниз не разрешается.
            guard level == .magistrate else {
                throw CaseOriginResolutionError.unsupportedCourt
            }
            id = "adm"
        default:
            switch prefix {
            case "g": id = "g1"
            case "p": id = "p1"
            case "u": id = "u1"
            case "adm":
                id = CartotekaRegistry.normalizedNumber(lowerNumber).hasPrefix("12-")
                    ? "admj" : "adm"
            default:
                throw CaseOriginResolutionError.unsupportedCourt
            }
        }
        guard let cart = CartotekaRegistry.find(level: level, id: id) else {
            throw CaseOriginResolutionError.unsupportedCourt
        }
        return cart
    }

    static func classificationCode(from uid: String?) -> String? {
        KoAPProceduralRole.classificationCode(from: uid)
    }

    static func verifiedParentCartoteka(for number: String, level: CourtLevel) -> Cartoteka? {
        switch CaseIndexClassifier.normalizedIndex(from: number) {
        case "13": return CartotekaRegistry.find(level: level, id: "g1")
        case "13а": return CartotekaRegistry.find(level: level, id: "p1")
        default: return nil
        }
    }

    static func normalizedUID(_ uid: String) -> String {
        uid.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func sameCaseNumber(_ lhs: String, _ rhs: String) -> Bool {
        let a = CartotekaRegistry.normalizedNumber(lhs)
        let b = CartotekaRegistry.normalizedNumber(rhs)
        return a == b || a.hasPrefix(b + "(") || b.hasPrefix(a + "(")
    }

    static func normalizedTitle(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "ё", with: "е")
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Сравнение названий внутри уже выбранного региона. Разрешает только
    /// территориальное окончание полного справочного названия; похожие номера
    /// участков и разные суды по префиксу совпавшими не считаются.
    static func sameCourtTitle(_ lhs: String, _ rhs: String, region: String) -> Bool {
        let left = titleWords(lhs)
        let right = titleWords(rhs)
        if left == right { return true }
        let short: [String]
        let long: [String]
        if left.count < right.count { short = left; long = right }
        else { short = right; long = left }
        guard !short.isEmpty, Array(long.prefix(short.count)) == short else { return false }

        let genericTerritoryWords: Set<String> = [
            "республика", "республики", "область", "области", "край", "края",
            "автономный", "автономного", "автономная", "автономной", "округ", "округа",
            "город", "города", "федерального", "значения"
        ]
        let regionCore = Set(titleWords(region)
            .filter { !genericTerritoryWords.contains($0) }
            .map(regionWordStem))
        let suffixCore = long.dropFirst(short.count)
            .filter { !genericTerritoryWords.contains($0) }
            .map(regionWordStem)
        return !suffixCore.isEmpty && suffixCore.allSatisfy { regionCore.contains($0) }
    }

    private static func titleWords(_ value: String) -> [String] {
        value.lowercased().replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func regionWordStem(_ word: String) -> String {
        for suffix in ["ского", "ской", "ская", "ский"] where word.count > suffix.count + 3 {
            if word.hasSuffix(suffix) { return String(word.dropLast(suffix.count)) }
        }
        if word.count > 7, let last = word.last, last == "а" || last == "я" {
            return String(word.dropLast())
        }
        return word
    }

    static func cleanRegion(_ raw: String?) -> String? {
        guard var raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let range = raw.range(of: #"^\d{1,2}\s*-\s*"#, options: .regularExpression) {
            raw.removeSubrange(range)
        }
        return raw.isEmpty ? nil : raw
    }

    static func isHistoricalSubjectReview(context: MovementContext, card: CaseCard) -> Bool {
        let dates = [card.receiptDate, card.decisionDate,
                     context.receiptDate, context.decisionDate].compactMap { raw -> Int? in
            guard let raw else { return nil }
            let parts = raw.prefix(10).split(separator: ".")
            guard parts.count == 3, let d = Int(parts[0]), let m = Int(parts[1]),
                  let y = Int(parts[2]) else { return nil }
            return y * 10_000 + m * 100 + d
        }
        if let earliest = dates.min() { return earliest < 2019_10_01 }
        let candidates = [card.caseNumber, Optional(context.caseNumber)].compactMap { $0 }
            .compactMap { value -> Int? in
            guard let match = value.range(of: #"/(\d{4})"#, options: .regularExpression) else {
                return nil
            }
            return Int(value[match].dropFirst())
        }
        return candidates.contains { $0 <= 2019 }
    }
}

extension CaseOriginResolver: CaseOriginResolving {}
