import Foundation
import SudrfKit

/// Однозначно восстановленная карточка канонической первой инстанции.
struct ResolvedCaseOrigin: Sendable {
    var court: Court
    var branch: CourtBranch
    var region: String
    var courtCode: String?
    var cartoteka: Cartoteka
    var result: CaseSearchResult
    var card: CaseCard
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
        guard anchorContext.baseInstanceLevel == .appeal
                || anchorContext.baseInstanceLevel == .cassation else {
            throw CaseOriginResolutionError.noReference
        }
        guard let ref = anchorCard.lowerCourt,
              let lowerNumber = ref.caseNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lowerNumber.isEmpty else {
            throw CaseOriginResolutionError.noReference
        }

        let judicialUID = anchorCard.uid ?? anchorContext.judicialUID
        let code = Self.classificationCode(from: judicialUID)
        let region = Self.cleanRegion(ref.region)
            ?? code.flatMap { CourtDirectory.subjectName(forSubjectCode: $0) }
            ?? anchorContext.region
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
                if case .transientNetworkError = error { throw error }
                rows = []
            }
        }
        if rows.isEmpty {
            rows = try await provider.search(court: resolved.court, cartoteka: cart,
                                             field: .caseNumber, value: lowerNumber)
        }
        let exact = rows.filter { Self.sameCaseNumber($0.caseNumber, lowerNumber) }
        guard !exact.isEmpty else { throw CaseOriginResolutionError.notFound }

        var matches: [(CaseSearchResult, CaseCard)] = []
        for row in exact {
            let card: CaseCard
            do {
                card = try await fetchCard(row: row, court: resolved.court,
                                           cartoteka: cart, provider: provider)
            } catch let error as SudrfError {
                if case .transientNetworkError = error { throw error }
                continue
            } catch {
                continue
            }
            if let judicialUID, !judicialUID.isEmpty,
               let found = card.uid, !found.isEmpty,
               Self.normalizedUID(found) != Self.normalizedUID(judicialUID) { continue }
            matches.append((row, card))
        }
        guard matches.count == 1, let match = matches.first else {
            throw matches.isEmpty ? CaseOriginResolutionError.notFound
                                  : CaseOriginResolutionError.ambiguous
        }
        return ResolvedCaseOrigin(court: resolved.court, branch: resolved.branch,
                                  region: region, courtCode: resolved.code,
                                  cartoteka: cart, result: match.0, card: match.1)
    }

    private func resolveCourt(code: String?, title: String?, region: String) async throws
        -> OriginCourtResolution {
        if let courtOverride { return courtOverride }
        if let code {
            let kind = CourtKind(classificationCode: code)
            switch kind {
            case .district, .military:
                let courts = try await districtResolver.allCourts(forRegion: region)
                if let found = courts.first(where: { $0.code?.uppercased() == code.uppercased() }) {
                    let level: CourtLevel = kind == .military ? .district : .district
                    return OriginCourtResolution(
                        court: Court(domain: SudrfHost.moduleHost(found.domain), title: found.title,
                                     level: level),
                        branch: kind == .military ? .military : .general, code: found.code)
                }
            case .subject:
                if let found = CourtDirectory.subjectCourt(forSubjectCode: code), found.isSudrfPlatform {
                    return OriginCourtResolution(
                        court: Court(domain: SudrfHost.moduleHost(found.domain), title: found.title,
                                     level: .subject), branch: .general, code: code)
                }
            case .other where code.uppercased().contains("MS"):
                let courts = try await magistrateResolver.courts(forRegion: region)
                if let found = courts.first(where: { $0.code.uppercased() == code.uppercased() }),
                   found.isSupported {
                    return OriginCourtResolution(court: found.court, branch: .general,
                                                 code: found.code)
                }
            default:
                break
            }
        }

        // УИД может отсутствовать в карточке КСОЮ. Тогда допускается только
        // единственное точное совпадение нормализованного названия в регионе.
        if let title, !title.isEmpty {
            let district = try await districtResolver.allCourts(forRegion: region)
                .filter { Self.normalizedTitle($0.title) == Self.normalizedTitle(title) }
            if district.count == 1, let found = district.first {
                return OriginCourtResolution(
                    court: Court(domain: SudrfHost.moduleHost(found.domain), title: found.title,
                                 level: found.kind == .subject ? .subject : .district),
                    branch: found.kind == .military ? .military : .general, code: found.code)
            }
            let magistrates = try await magistrateResolver.courts(forRegion: region)
                .filter { Self.normalizedTitle($0.title) == Self.normalizedTitle(title) && $0.isSupported }
            if magistrates.count == 1, let found = magistrates.first {
                return OriginCourtResolution(court: found.court, branch: .general,
                                             code: found.code)
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
        let prefix = String(anchorID.prefix(while: { $0.isLetter })).lowercased()
        let id: String
        switch prefix {
        case "g": id = "g1"
        case "p": id = "p1"
        case "u": id = "u1"
        case "adm":
            id = CartotekaRegistry.normalizedNumber(lowerNumber).hasPrefix("12-") ? "admj" : "adm"
        default:
            throw CaseOriginResolutionError.unsupportedCourt
        }
        guard let cart = CartotekaRegistry.find(level: level, id: id) else {
            throw CaseOriginResolutionError.unsupportedCourt
        }
        return cart
    }

    static func classificationCode(from uid: String?) -> String? {
        guard let uid else { return nil }
        let upper = uid.uppercased()
        guard let range = upper.range(of: #"^\d{2}[A-ZА-Я]{2}\d{4}"#,
                                      options: .regularExpression) else { return nil }
        return String(upper[range])
    }

    static func normalizedUID(_ uid: String) -> String {
        uid.uppercased().filter { $0.isLetter || $0.isNumber }
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

    static func cleanRegion(_ raw: String?) -> String? {
        guard var raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let range = raw.range(of: #"^\d{1,2}\s*-\s*"#, options: .regularExpression) {
            raw.removeSubrange(range)
        }
        return raw.isEmpty ? nil : raw
    }
}

extension CaseOriginResolver: CaseOriginResolving {}
