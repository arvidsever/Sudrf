import Foundation
import SudrfKit

enum CaseCardRecoveryReason: String, Sendable, Equatable {
    case originalURL
    case cartotekaParameters
    case judicialUID
    case caseNumber
}

enum CaseCardRecoveryError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedSource
    case ambiguous
    case incompleteCandidates

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            return "Восстановление доступно только для карточек федеральных судов SUDRF."
        case .ambiguous:
            return "Найдено несколько подтверждённых карточек; ссылка оставлена без изменений."
        case .incompleteCandidates:
            return "Не удалось проверить все найденные карточки; ссылка оставлена без изменений."
        }
    }
}

struct CaseCardRecoveryResolution: Sendable {
    let card: CaseCard
    let verifiedURL: URL
    let reason: CaseCardRecoveryReason
    let context: MovementContext

    var wasRecovered: Bool { reason != .originalURL }
}

/// Resolves a persisted federal SUDRF card without writing to the store.
/// Each call performs at most one bounded recovery pass after the original URL.
struct CaseCardRecovery: Sendable {
    private let provider: any CaseProviding

    init(client: SudrfClient = SudrfClient()) {
        provider = client
    }

    init(provider: any CaseProviding) {
        self.provider = provider
    }

    func resolve(context: MovementContext) async throws -> CaseCardRecoveryResolution {
        guard context.courtLevel != .magistrate,
              let originalURL = context.cardURLString.flatMap(URL.init(string:)),
              let originalLink = try? SudrfCaseCardLink(url: originalURL),
              sameCourt(originalLink.moduleHost, context.searchDomain) else {
            throw CaseCardRecoveryError.unsupportedSource
        }

        do {
            let fetched = try await provider.fetchCardWithResponseURL(url: originalURL)
            try Task.checkCancellation()
            guard let effective = try? SudrfCaseCardLink(url: fetched.responseURL),
                  sameCourt(effective.moduleHost, context.searchDomain) else {
                throw CaseCardRecoveryError.unsupportedSource
            }
            if sameLocator(originalLink, effective) {
                return resolution(card: fetched.card, url: originalURL, reason: .originalURL,
                                  original: context)
            }
            let srvNum = Int(originalLink.srvNum ?? "1") ?? 0
            guard let cartoteka = context.cartoteka ?? CartotekaRegistry.resolve(
                level: context.cartotekaLevel, deloID: originalLink.deloID,
                new: originalLink.new, caseNumber: context.caseNumber),
                  srvNum > 0,
                  verifies(fetched: fetched, expected: context,
                           cartoteka: cartoteka, srvNum: srvNum) else {
                throw CaseCardRecoveryError.incompleteCandidates
            }
            let registerChanged = originalLink.deloID != effective.deloID
                || originalLink.resolvedNew != effective.resolvedNew
            let reason: CaseCardRecoveryReason = registerChanged
                ? .cartotekaParameters
                : (nonEmpty(context.judicialUID) == nil ? .caseNumber : .judicialUID)
            return resolution(card: fetched.card, url: fetched.responseURL, reason: reason,
                              original: context)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw error
        } catch {
            guard Self.isRecoveryEligible(error) else { throw error }
            let originalError = error
            try Task.checkCancellation()

            let cartoteka = context.cartoteka ?? CartotekaRegistry.resolve(
                level: context.cartotekaLevel, deloID: originalLink.deloID,
                new: originalLink.new, caseNumber: context.caseNumber)
            guard let cartoteka else { throw originalError }
            let srvNum: Int
            if let raw = originalLink.srvNum {
                guard let parsed = Int(raw), parsed > 0 else {
                    throw CaseCardRecoveryError.incompleteCandidates
                }
                srvNum = parsed
            } else {
                srvNum = 1
            }

            if originalLink.deloID != cartoteka.deloID
                || originalLink.resolvedNew != cartoteka.new,
               let correctedURL = replacing(
                   originalURL, values: ["delo_id": cartoteka.deloID, "new": cartoteka.new]
                ) {
                do {
                    let fetched = try await provider.fetchCardWithResponseURL(url: correctedURL)
                    try Task.checkCancellation()
                    if verifies(fetched: fetched, expected: context,
                                cartoteka: cartoteka, srvNum: srvNum) {
                        return resolution(card: fetched.card, url: fetched.responseURL,
                                          reason: .cartotekaParameters, original: context)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                    throw error
                } catch {
                    if !Self.isRecoveryEligible(error) { throw error }
                }
            }

            if let uid = nonEmpty(context.judicialUID) {
                let rows = try await completeSearch(
                    court: context.searchCourt, cartoteka: cartoteka,
                    field: .uid, value: uid, srvNum: srvNum)
                if let match = try await uniqueVerified(
                    rows: rows, context: context, cartoteka: cartoteka,
                    originalURL: originalURL, srvNum: srvNum
                ) {
                    try Task.checkCancellation()
                    return resolution(card: match.card, url: match.url,
                                      reason: .judicialUID, original: context)
                }
            }

            let rows = try await completeSearch(
                court: context.searchCourt, cartoteka: cartoteka,
                field: .caseNumber, value: context.caseNumber, srvNum: srvNum)
            if let match = try await uniqueVerified(
                rows: rows, context: context, cartoteka: cartoteka,
                originalURL: originalURL, srvNum: srvNum
            ) {
                try Task.checkCancellation()
                return resolution(card: match.card, url: match.url,
                                  reason: .caseNumber, original: context)
            }
            throw originalError
        }
    }

    static func isRecoveryEligible(_ error: Error) -> Bool {
        guard let error = error as? SudrfError else { return false }
        switch error {
        case .parsing(let message):
            return message == "страница не содержит признаков карточки дела"
                || message == "страница не содержит признаков винтажной карточки дела"
        case .http(let status):
            return status == 404 || status == 410
        default:
            return false
        }
    }

    private func uniqueVerified(rows: [CaseSearchResult], context: MovementContext,
                                cartoteka: Cartoteka, originalURL: URL,
                                srvNum: Int) async throws
        -> (card: CaseCard, url: URL)? {
        let exact = rows.filter {
            Self.matchesRecoveryCaseNumber(
                $0.caseNumber, expected: context.caseNumber,
                context: context, cartoteka: cartoteka)
        }
        var seen = Set<String>()
        var seenEffective = Set<String>()
        var matches: [(card: CaseCard, url: URL)] = []
        var incomplete = false

        for row in exact {
            try Task.checkCancellation()
            guard let url = candidateURL(for: row, originalURL: originalURL,
                                         cartoteka: cartoteka),
                  let link = try? SudrfCaseCardLink(url: url),
                  sameCourt(link.moduleHost, context.searchDomain),
                  CartotekaRegistry.resolve(
                    level: context.cartotekaLevel, deloID: link.deloID,
                    new: link.new, caseNumber: context.caseNumber)?.id == cartoteka.id,
                  nonEmpty(context.judicialUID) != nil
                    || Int(link.srvNum ?? "1") == srvNum else {
                incomplete = true
                continue
            }
            guard seen.insert(link.url.absoluteString).inserted else { continue }
            do {
                let fetched = try await provider.fetchCardWithResponseURL(url: url)
                try Task.checkCancellation()
                guard verifies(fetched: fetched, expected: context,
                               cartoteka: cartoteka, srvNum: srvNum),
                      let effective = try? SudrfCaseCardLink(url: fetched.responseURL),
                      seenEffective.insert(effective.url.absoluteString).inserted else {
                    continue
                }
                matches.append((fetched.card, fetched.responseURL))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                throw error
            } catch {
                if Self.isRecoveryEligible(error) {
                    incomplete = true
                } else {
                    throw error
                }
            }
        }

        if matches.count > 1 { throw CaseCardRecoveryError.ambiguous }
        if incomplete { throw CaseCardRecoveryError.incompleteCandidates }
        return matches.first
    }

    private func completeSearch(court: Court, cartoteka: Cartoteka,
                                field: SearchField, value: String,
                                srvNum: Int) async throws -> [CaseSearchResult] {
        do {
            return try await provider.searchComplete(
                court: court, cartoteka: cartoteka, field: field,
                value: value, srvNum: srvNum)
        } catch is IncompleteCaseSearchError {
            throw CaseCardRecoveryError.incompleteCandidates
        }
    }

    private func verifies(card: CaseCard, expected context: MovementContext,
                          cartoteka: Cartoteka) -> Bool {
        guard let number = nonEmpty(card.caseNumber),
              Self.matchesRecoveryCaseNumber(
                number, expected: context.caseNumber,
                context: context, cartoteka: cartoteka),
              CartotekaRegistry.resolve(
                level: context.cartotekaLevel, deloID: cartoteka.deloID,
                new: cartoteka.new, caseNumber: number)?.id == cartoteka.id else {
            return false
        }
        if let expectedUID = nonEmpty(context.judicialUID) {
            guard let foundUID = nonEmpty(card.uid),
                  CaseOriginResolver.normalizedUID(foundUID)
                    == CaseOriginResolver.normalizedUID(expectedUID) else {
                return false
            }
        }
        return true
    }

    private func verifies(fetched: SudrfCaseCardFetchResult,
                          expected context: MovementContext,
                          cartoteka: Cartoteka,
                          srvNum: Int) -> Bool {
        guard let link = try? SudrfCaseCardLink(url: fetched.responseURL),
              sameCourt(link.moduleHost, context.searchDomain),
              CartotekaRegistry.resolve(
                level: context.cartotekaLevel, deloID: link.deloID,
                new: link.new, caseNumber: context.caseNumber)?.id == cartoteka.id,
              nonEmpty(context.judicialUID) != nil
                || Int(link.srvNum ?? "1") == srvNum else {
            return false
        }
        return verifies(card: fetched.card, expected: context, cartoteka: cartoteka)
    }

    /// Recovery-only exception for KSOYU headers that contain the incoming
    /// registration followed by the accepted proceeding in square brackets.
    static func matchesRecoveryCaseNumber(
        _ published: String, expected: String,
        context: MovementContext, cartoteka: Cartoteka
    ) -> Bool {
        if published.trimmingCharacters(in: .whitespacesAndNewlines)
            == expected.trimmingCharacters(in: .whitespacesAndNewlines) {
            return true
        }
        let containsBrackets = published.contains("[") || published.contains("]")
        if !containsBrackets,
           CaseOriginResolver.sameCaseNumber(published, expected) { return true }
        let host = SudrfHost.moduleHost(context.searchDomain)
        guard context.courtLevel == .cassation,
              context.cartotekaLevel == .cassation,
              CourtDirectory.cassationCourts.contains(where: {
                  SudrfHost.moduleHost($0.domain) == host
              }),
              let (incoming, accepted) = compositeCaseNumbers(published),
              let expected = strictCaseNumber(expected),
              accepted == expected else {
            return false
        }

        let acceptedPrefixes: Set<String>
        let requiredCartoteka: String
        switch incoming.prefix {
        case "8", "8г":
            acceptedPrefixes = ["88"]
            requiredCartoteka = "g3"
        case "8а":
            acceptedPrefixes = ["88а"]
            requiredCartoteka = "p3"
        case "7":
            acceptedPrefixes = ["77", "77у"]
            requiredCartoteka = "u3"
        case "7у":
            acceptedPrefixes = ["77", "77у"]
            requiredCartoteka = "u3"
        default:
            return false
        }
        guard acceptedPrefixes.contains(accepted.prefix),
              cartoteka.id == requiredCartoteka,
              let registered = CartotekaRegistry.find(
                level: .cassation, id: requiredCartoteka),
              registered.deloID == cartoteka.deloID,
              registered.new == cartoteka.new else {
            return false
        }
        return true
    }

    private static func compositeCaseNumbers(
        _ raw: String
    ) -> (incoming: (value: String, prefix: String),
          accepted: (value: String, prefix: String))? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.filter({ $0 == "[" }).count == 1,
              value.filter({ $0 == "]" }).count == 1,
              let open = value.firstIndex(of: "["),
              let close = value.firstIndex(of: "]"),
              open < close,
              open > value.startIndex,
              value[value.index(before: open)].isWhitespace,
              close == value.index(before: value.endIndex),
              let incoming = strictCaseNumber(String(value[..<open])),
              let accepted = strictCaseNumber(String(value[value.index(after: open)..<close]))
        else { return nil }
        return (incoming, accepted)
    }

    private static func strictCaseNumber(
        _ raw: String
    ) -> (value: String, prefix: String)? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("№") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty,
              !value.contains(where: { $0.isWhitespace || "[]~()".contains($0) }) else {
            return nil
        }
        value = CartotekaRegistry.normalizedNumber(value)
        let dash = value.split(separator: "-", omittingEmptySubsequences: false)
        guard dash.count == 2, !dash[0].isEmpty else { return nil }
        let date = dash[1].split(separator: "/", omittingEmptySubsequences: false)
        guard date.count == 2, !date[0].isEmpty,
              date[0].allSatisfy(\.isNumber),
              date[1].count == 4, date[1].allSatisfy(\.isNumber) else {
            return nil
        }
        return (value, String(dash[0]))
    }

    private func candidateURL(for row: CaseSearchResult, originalURL: URL,
                              cartoteka: Cartoteka) -> URL? {
        if let url = row.cardURL { return url }
        guard let caseID = nonEmpty(row.caseID),
              let caseUID = nonEmpty(row.caseUID) else { return nil }
        var values = ["delo_id": cartoteka.deloID, "new": cartoteka.new]
        values["case_id"] = caseID
        values["case_uid"] = caseUID
        return replacing(originalURL, values: values)
    }

    private func resolution(card: CaseCard, url: URL, reason: CaseCardRecoveryReason,
                            original: MovementContext) -> CaseCardRecoveryResolution {
        var context = original
        context.cardURLString = url.absoluteString
        if let link = try? SudrfCaseCardLink(url: url) {
            context.caseID = nonEmpty(link.caseID)
            context.caseUID = nonEmpty(link.caseUID)
            if let cartoteka = CartotekaRegistry.resolve(
                level: context.courtLevel, deloID: link.deloID, new: link.new,
                caseNumber: nonEmpty(card.caseNumber) ?? context.caseNumber
            ) {
                context.cartotekaId = cartoteka.id
                context.cartotekaLevelRaw = context.courtLevel.rawValue
            }
            if let caseID = nonEmpty(context.caseID),
               let caseUID = nonEmpty(context.caseUID) {
                context.sourceKnownCard = KnownCard(
                    domain: link.moduleHost, courtTitle: context.courtTitle,
                    caseID: caseID, caseUID: caseUID, deloID: link.deloID,
                    new: link.resolvedNew,
                    caseNumber: nonEmpty(card.caseNumber) ?? context.caseNumber,
                    levelRaw: context.baseInstanceLevel.rawValue,
                    cartotekaID: context.cartotekaId)
            } else {
                context.sourceKnownCard = nil
            }
        }
        context.caseNumber = nonEmpty(card.caseNumber) ?? context.caseNumber
        context.judicialUID = nonEmpty(card.uid) ?? context.judicialUID
        context.judge = nonEmpty(card.judge) ?? context.judge
        context.receiptDate = nonEmpty(card.receiptDate) ?? context.receiptDate
        context.decisionDate = nonEmpty(card.decisionDate) ?? context.decisionDate
        context.resultText = nonEmpty(card.result) ?? context.resultText
        context.legalForceDate = nonEmpty(card.legalForceDate) ?? context.legalForceDate
        return CaseCardRecoveryResolution(card: card, verifiedURL: url,
                                          reason: reason, context: context)
    }

    private func replacing(_ url: URL, values: [String: String]) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery else {
            return nil
        }
        var pending = values
        let segments = query.split(separator: "&", omittingEmptySubsequences: false).map { raw -> String in
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let encodedName = String(parts[0])
            let name = encodedName.removingPercentEncoding?.lowercased() ?? encodedName.lowercased()
            let canonical: String?
            switch name {
            case "delo_id", "_deloid": canonical = "delo_id"
            case "new", "_new": canonical = "new"
            case "case_id", "_id": canonical = "case_id"
            case "case_uid", "_uid": canonical = "case_uid"
            default: canonical = nil
            }
            guard let canonical, let value = values[canonical],
                  let encodedValue = percentEncodedQueryValue(value) else { return String(raw) }
            pending.removeValue(forKey: canonical)
            return encodedName + "=" + encodedValue
        }
        var updated = segments
        for name in ["case_id", "case_uid", "delo_id", "new"] {
            if let value = pending[name], let encodedValue = percentEncodedQueryValue(value) {
                updated.append(name + "=" + encodedValue)
            }
        }
        components.percentEncodedQuery = updated.joined(separator: "&")
        return components.url
    }

    private func percentEncodedQueryValue(_ value: String) -> String? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private func sameCourt(_ lhs: String, _ rhs: String) -> Bool {
        SudrfHost.moduleHost(lhs) == SudrfHost.moduleHost(rhs)
    }

    private func sameLocator(_ lhs: SudrfCaseCardLink, _ rhs: SudrfCaseCardLink) -> Bool {
        lhs.caseID == rhs.caseID && lhs.caseUID == rhs.caseUID
            && lhs.deloID == rhs.deloID && lhs.resolvedNew == rhs.resolvedNew
            && (lhs.srvNum ?? "1") == (rhs.srvNum ?? "1")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
