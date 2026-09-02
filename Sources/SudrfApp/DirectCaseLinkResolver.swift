import Foundation
import SudrfKit

/// A parsed SUDRF card ready for the normal tracking path.  It contains no
/// persistence state: the caller still decides whether to add it to a store.
struct DirectCaseLinkResolution: Sendable, Equatable {
    let context: MovementContext
    let caseNumber: String
    let courtTitle: String
    let judicialUID: String?
    let category: String?
    let judge: String?
    let result: String?
}

/// Errors before or while turning a direct URL into a tracking context.  Source
/// errors such as CAPTCHA and transport failures deliberately pass through as
/// `SudrfError`, so the existing continuation flow can handle them.
enum DirectCaseLinkResolutionError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL
    case unsupportedMagistrate
    case unsupportedMosGorSud
    case unsupportedVSRF
    case unsupportedPortal
    case notACaseCard
    case courtNotFound
    case ambiguousCourt
    case missingCaseNumber
    case unresolvedCartoteka
    case cardRemoved

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Вставьте корректный HTTP(S)-адрес."
        case .unsupportedMagistrate:
            return "Ссылки мировых судей пока не поддерживаются."
        case .unsupportedMosGorSud:
            return "Ссылки Мосгорсуда пока не поддерживаются."
        case .unsupportedVSRF:
            return "Ссылки Верховного Суда РФ пока не поддерживаются."
        case .unsupportedPortal:
            return "Поддерживаются только прямые ссылки на карточки федеральных судов SUDRF."
        case .notACaseCard:
            return "Ссылка должна вести непосредственно на карточку дела, а не на поиск или общий раздел суда."
        case .courtNotFound:
            return "Не удалось определить суд по фактическому адресу карточки."
        case .ambiguousCourt:
            return "По адресу карточки найдено несколько судов."
        case .missingCaseNumber:
            return "В карточке суда не опубликован номер дела."
        case .unresolvedCartoteka:
            return "Не удалось определить вид производства по ссылке и номеру дела."
        case .cardRemoved:
            return "Карточка удалена или больше не опубликована на сайте суда."
        }
    }
}

/// Resolves a direct federal SUDRF card link into the same `MovementContext`
/// used by the search and import paths.
struct DirectCaseLinkResolver: Sendable {
    typealias CardFetcher = @Sendable (URL) async throws -> SudrfCaseCardFetchResult
    typealias DistrictCourtsFetcher = @Sendable (String) async throws -> [DistrictCourt]

    private let fetchCard: CardFetcher
    private let districtCourts: DistrictCourtsFetcher

    init(client: SudrfClient = SudrfClient(),
         districtResolver: DistrictCourtResolver? = nil) {
        let resolver = districtResolver ?? DistrictCourtResolver(client: client)
        fetchCard = { url in try await client.fetchCardWithResponseURL(url: url) }
        districtCourts = { code in try await resolver.allCourts(forSubjectCode: code) }
    }

    init(fetchCard: @escaping CardFetcher,
         districtCourts: @escaping DistrictCourtsFetcher) {
        self.fetchCard = fetchCard
        self.districtCourts = districtCourts
    }

    func resolve(_ rawValue: String) async throws -> DirectCaseLinkResolution {
        let inputURL = try Self.inputURL(rawValue)
        try Self.validatePlatform(inputURL)

        let requestedLink: SudrfCaseCardLink
        do {
            requestedLink = try SudrfCaseCardLink(url: inputURL)
        } catch {
            throw DirectCaseLinkResolutionError.notACaseCard
        }

        let fetched: SudrfCaseCardFetchResult
        do {
            fetched = try await fetchCard(requestedLink.url)
        } catch SudrfError.http(let status) where status == 404 || status == 410 {
            throw DirectCaseLinkResolutionError.cardRemoved
        }
        try Self.validatePlatform(fetched.responseURL)

        let link: SudrfCaseCardLink
        do {
            link = try SudrfCaseCardLink(url: fetched.responseURL)
        } catch {
            throw DirectCaseLinkResolutionError.notACaseCard
        }
        let sourceHost = link.moduleHost
        let resolvedCourt = try await resolveCourt(forHost: sourceHost)
        guard let caseNumber = Self.nonEmpty(fetched.card.caseNumber) else {
            throw DirectCaseLinkResolutionError.missingCaseNumber
        }
        guard let cartoteka = CartotekaRegistry.resolve(
            level: resolvedCourt.court.level, deloID: link.deloID,
            new: link.new, caseNumber: caseNumber
        ) else {
            throw DirectCaseLinkResolutionError.unresolvedCartoteka
        }

        let judicialUID = Self.nonEmpty(fetched.card.uid)
        let routingRegion = Self.regionNameFromUID(judicialUID) ?? resolvedCourt.region
        let baseInstanceLevel = MovementContext.instanceLevel(
            cartotekaID: cartoteka.id, courtLevel: resolvedCourt.court.level,
            judicialUID: judicialUID, lowerCourtTitle: fetched.card.lowerCourt?.courtTitle)
        let displayDomain = SudrfHost.alternate(sourceHost) ?? sourceHost
        var context = MovementContext(
            branchRaw: resolvedCourt.branch.rawValue,
            region: routingRegion,
            searchDomain: sourceHost,
            displayDomain: displayDomain,
            courtTitle: resolvedCourt.court.title,
            courtLevelRaw: resolvedCourt.court.level.rawValue,
            courtCode: resolvedCourt.code,
            cartotekaId: cartoteka.id,
            cartotekaLevelRaw: resolvedCourt.court.level.rawValue,
            caseNumber: caseNumber,
            caseID: link.caseID,
            caseUID: link.caseUID,
            essence: nil,
            judge: fetched.card.judge,
            receiptDate: fetched.card.receiptDate,
            decisionDate: fetched.card.decisionDate,
            resultText: fetched.card.result,
            legalForceDate: fetched.card.legalForceDate,
            cardURLString: link.url.absoluteString)
        context.judicialUID = judicialUID
        context.baseInstanceLevelRaw = baseInstanceLevel.rawValue
        if let caseID = Self.nonEmpty(link.caseID),
           let caseUID = Self.nonEmpty(link.caseUID) {
            context.sourceKnownCard = KnownCard(
                domain: sourceHost, courtTitle: resolvedCourt.court.title,
                caseID: caseID, caseUID: caseUID, deloID: link.deloID,
                new: link.resolvedNew, caseNumber: caseNumber,
                levelRaw: baseInstanceLevel.rawValue, cartotekaID: cartoteka.id)
        }
        context.higherCourtTargets = MovementTargetBuilder.targets(
            branch: resolvedCourt.branch, courtLevel: resolvedCourt.court.level,
            baseCartoteka: cartoteka, caseNumber: caseNumber,
            judicialUID: judicialUID, courtTitle: resolvedCourt.court.title,
            courtCode: resolvedCourt.code, region: routingRegion,
            displayDomain: displayDomain)

        return DirectCaseLinkResolution(
            context: context, caseNumber: caseNumber,
            courtTitle: resolvedCourt.court.title, judicialUID: judicialUID,
            category: fetched.card.category, judge: fetched.card.judge,
            result: fetched.card.result)
    }

    private func resolveCourt(forHost host: String) async throws -> ResolvedCourt {
        if let resolved = Self.staticCourt(forHost: host) { return resolved }
        guard let suffix = CourtDirectory.regionSuffix(ofDomain: host),
              let subjectCode = CourtDirectory.subjectCode(forRegionSuffix: suffix) else {
            throw DirectCaseLinkResolutionError.courtNotFound
        }
        let courts = try await districtCourts(subjectCode)
        let matches = courts.filter {
            Self.sameHost($0.domain, host)
        }
        guard matches.count == 1, let found = matches.first else {
            throw matches.isEmpty ? DirectCaseLinkResolutionError.courtNotFound
                                  : DirectCaseLinkResolutionError.ambiguousCourt
        }
        guard let region = Self.regionName(
            code: found.portalSubject ?? found.subjectNum ?? subjectCode
        ) else {
            throw DirectCaseLinkResolutionError.courtNotFound
        }

        let level: CourtLevel
        let branch: CourtBranch
        switch found.kind {
        case .district, .other:
            level = .district
            branch = .general
        case .military:
            branch = .military
            switch found.codeLetters {
            case "OV": level = .subject
            case "AV": level = .appeal
            case "KV": level = .cassation
            default: level = .district
            }
        case .subject:
            level = .subject
            branch = .general
        case .appeal:
            level = .appeal
            branch = .general
        case .cassation:
            level = .cassation
            branch = .general
        case .magistrate:
            throw DirectCaseLinkResolutionError.unsupportedMagistrate
        }
        return ResolvedCourt(
            court: Court(domain: host, title: found.title, level: level),
            branch: branch, region: region, code: found.code)
    }

    private static func staticCourt(forHost host: String) -> ResolvedCourt? {
        if let court = CourtDirectory.subjectCourts.first(where: { sameHost($0.domain, host) }),
           let region = regionName(code: CourtDirectory.subjectCode(forDomain: court.domain)
                                     ?? subjectCode(forHost: court.domain)) {
            return ResolvedCourt(
                court: Court(domain: host, title: court.title, level: .subject),
                branch: .general, region: region, code: nil)
        }
        if let court = CourtDirectory.cassationCourts.first(where: { sameHost($0.domain, host) }),
           let region = regionName(code: court.seatRegionCode) {
            return ResolvedCourt(
                court: Court(domain: host, title: court.title, level: .cassation),
                branch: .general, region: region, code: nil)
        }
        if let court = CourtDirectory.appealCourts.first(where: { sameHost($0.domain, host) }),
           let region = regionName(code: court.seatRegionCode) {
            return ResolvedCourt(
                court: Court(domain: host, title: court.title, level: .appeal),
                branch: .general, region: region, code: nil)
        }
        if let court = CourtDirectory.okrugMilitaryCourts.first(where: { sameHost($0.domain, host) }),
           let region = regionName(code: subjectCode(forHost: court.domain)) {
            return ResolvedCourt(
                court: Court(domain: host, title: court.title, level: .subject),
                branch: .military, region: region, code: nil)
        }
        if sameHost(CourtDirectory.appellateMilitaryCourt.domain, host),
           let region = regionName(code: "50") {
            return ResolvedCourt(
                court: Court(domain: host, title: CourtDirectory.appellateMilitaryCourt.title,
                             level: .appeal),
                branch: .military, region: region, code: nil)
        }
        if sameHost(CourtDirectory.cassationMilitaryCourt.domain, host),
           let region = regionName(code: "54") {
            return ResolvedCourt(
                court: Court(domain: host, title: CourtDirectory.cassationMilitaryCourt.title,
                             level: .cassation),
                branch: .military, region: region, code: nil)
        }
        return nil
    }

    private static func inputURL(_ rawValue: String) throws -> URL {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else {
            throw DirectCaseLinkResolutionError.invalidURL
        }
        return url
    }

    private static func validatePlatform(_ url: URL) throws {
        guard let host = url.host?.lowercased() else {
            throw DirectCaseLinkResolutionError.invalidURL
        }
        if SudrfHost.isMSudrfHost(host) {
            throw DirectCaseLinkResolutionError.unsupportedMagistrate
        }
        if host == "mos-gorsud.ru" || host.hasSuffix(".mos-gorsud.ru") {
            throw DirectCaseLinkResolutionError.unsupportedMosGorSud
        }
        if host == "vsrf.ru" || host.hasSuffix(".vsrf.ru") {
            throw DirectCaseLinkResolutionError.unsupportedVSRF
        }
        guard host.hasSuffix(".sudrf.ru"), host.count > ".sudrf.ru".count else {
            throw DirectCaseLinkResolutionError.unsupportedPortal
        }
    }

    private static func sameHost(_ lhs: String, _ rhs: String) -> Bool {
        SudrfHost.moduleHost(lhs.lowercased()) == SudrfHost.moduleHost(rhs.lowercased())
    }

    private static func subjectCode(forHost host: String) -> String? {
        CourtDirectory.regionSuffix(ofDomain: host)
            .flatMap(CourtDirectory.subjectCode(forRegionSuffix:))
    }

    private static func regionName(code: String?) -> String? {
        code.flatMap(CourtDirectory.subjectName(forSubjectCode:))
    }

    private static func regionNameFromUID(_ uid: String?) -> String? {
        KoAPProceduralRole.classificationCode(from: uid)
            .map(CourtDirectory.normalizedSubjectCode)
            .flatMap(CourtDirectory.subjectName(forSubjectCode:))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ResolvedCourt: Sendable {
    let court: Court
    let branch: CourtBranch
    let region: String
    let code: String?
}
