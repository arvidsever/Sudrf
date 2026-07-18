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
}

protocol CaseOriginResolving: Sendable {
    func resolve(anchorContext: MovementContext,
                 anchorCard: CaseCard) async throws -> ResolvedCaseOrigin
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
        if cart.id == "m", Self.requiresVerifiedParent(number: lowerNumber,
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

    private func resolveVerifiedMaterialParent(context: MovementContext, card: CaseCard) async throws
        -> ResolvedCaseOrigin {
        guard Self.requiresVerifiedParent(number: context.caseNumber, courtLevel: context.courtLevel),
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

    static func requiresVerifiedParent(number: String, courtLevel: CourtLevel) -> Bool {
        if let info = CaseIndexClassifier.classify(caseNumber: number, courtLevel: courtLevel),
           info.materialLinkPolicy == .requiresVerifiedParent { return true }
        let index = CaseIndexClassifier.normalizedIndex(from: number)
        return index == "13" || index == "13а"
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
