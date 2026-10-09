import Foundation

extension MovementService {
    /// Refreshes a Moscow magistrate KoAP anchor and its first published
    /// district-court appeal when the source exposes enough matching facts.
    func moscowMagistrateKoAPMovement(for base: CaseSearchResult,
                                     court: Court,
                                     cartoteka: Cartoteka) async throws -> CaseMovement {
        guard court.domain.caseInsensitiveCompare(MoscowMagistrateKoAPSource.host) == .orderedSame,
              court.level == .magistrate,
              cartoteka.id == "adm",
              let url = base.cardURL,
              let requestedLocator = SourceNativeCardLocator.moscowMagistrateKoAP(
                url: url, cartoteka: cartoteka) else {
            throw SudrfError.parsing("Базовая ссылка не является карточкой КоАП мирового судьи Москвы")
        }
        if let savedCaseID = base.caseID {
            let savedUUID = UUID(uuidString: savedCaseID.trimmingCharacters(
                in: .whitespacesAndNewlines))?.uuidString.lowercased()
            guard savedUUID == requestedLocator.sourceNativeID else {
                throw SudrfError.caseCardTemporarilyUnavailable
            }
        }

        let fetched = try await client.fetchCardWithResponseURL(url: url)
        guard let responseLocator = SourceNativeCardLocator.moscowMagistrateKoAP(
                url: fetched.responseURL, cartoteka: cartoteka),
              responseLocator.identity == requestedLocator.identity,
              let publishedNumber = fetched.card.caseNumber,
              Self.sameMoscowPublishedCaseNumber(publishedNumber, base.caseNumber) else {
            throw SudrfError.caseCardTemporarilyUnavailable
        }
        if let savedUID = Self.normalizedJudicialUID(base.caseUID),
           Self.normalizedJudicialUID(fetched.card.uid) != savedUID {
            throw SudrfError.caseCardTemporarilyUnavailable
        }

        var coverage = MovementCoverageAccumulator()
        coverage.recordLoaded(requestedLocator)
        coverage.markPartial(sourceFamily: MoscowMagistrateKoAPSource.family,
                             courtKey: requestedLocator.courtKey)
        // The exact card is fresh, but the source has not established a
        // complete listing for this selected unit.
        var incompleteDomains: [String] = [MoscowMagistrateKoAPSource.host]
        var honestZeroDomains: [String] = []
        func markMGSPartial() {
            coverage.markPartial(sourceFamily: "mosgorsud", courtKey: MosGorSudEndpoint.host)
            if !incompleteDomains.contains(MosGorSudEndpoint.host) {
                incompleteDomains.append(MosGorSudEndpoint.host)
            }
        }
        func markMGSReviewPartial() {
            coverage.markPartial(sourceFamily: "mosgorsud",
                                 courtKey: MosGorSudCourtDirectory.mgsAlias)
            if !incompleteDomains.contains(MosGorSudEndpoint.host) {
                incompleteDomains.append(MosGorSudEndpoint.host)
            }
        }

        var instances = [CaseInstance(
            level: .first,
            court: court.title,
            caseNumber: fetched.card.caseNumber ?? base.caseNumber,
            judge: fetched.card.judge,
            domain: MoscowMagistrateKoAPSource.host,
            foundByUID: false,
            result: fetched.card.result,
            sessions: fetched.card.sessions,
            sourceURL: fetched.responseURL,
            sourceEvidence: .init(card: fetched.card, cartotekaID: cartoteka.id,
                                  courtLevel: .magistrate, branch: .general))]

        if let anchorUID = Self.normalizedJudicialUID(fetched.card.uid), let mosgorsud {
            do {
                let rows = try await mosgorsud.search(
                    courtAlias: nil, uid: fetched.card.uid,
                    caseNumber: nil, participant: nil,
                    instance: MosGorSudInstance.appeal, processType: .admin)
                if rows.isEmpty {
                    // The client filters rows by section. An empty filtered
                    // result cannot prove that the source had no candidates.
                    markMGSPartial()
                } else if rows.count != 1 {
                    markMGSPartial()
                } else if let row = rows.first,
                          (row.section == nil || row.section?.caseInsensitiveCompare("appeal-admin") == .orderedSame),
                          let candidateURL = row.cardURL,
                          let locator = SourceNativeCardLocator.moscowMagistrateKoAPAppeal(
                            url: candidateURL),
                          row.uid.map({ Self.normalizedJudicialUID($0) == anchorUID }) ?? true {
                    do {
                        let fetchedCandidate = try await fetchMosGorSudCard(
                            url: candidateURL, from: mosgorsud)
                        let candidate = fetchedCandidate.card
                        let responseLocator = SourceNativeCardLocator.moscowMagistrateKoAPAppeal(
                            url: fetchedCandidate.responseURL)
                        if responseLocator?.identity == locator.identity,
                           Self.verifiedKoAPAppeal(candidate, row: row,
                                                   locator: locator,
                                                   anchor: fetched.card,
                                                   anchorUID: anchorUID),
                           let caseNumber = candidate.caseNumber,
                           let courtTitle = candidate.court
                            ?? MosGorSudCourtDirectory.title(forAlias: locator.courtKey) {
                            coverage.recordLoaded(locator)
                            let actURLs = candidate.actFiles.compactMap {
                                PublishedActURLPolicy.safeMosGorSudURL($0.url)
                            }
                            let candidateCaseCard = Self.koapEvidenceCard(candidate)
                            instances.append(CaseInstance(
                                level: .appeal,
                                court: courtTitle,
                                caseNumber: caseNumber,
                                judge: candidate.judge,
                                domain: MosGorSudEndpoint.host,
                                foundByUID: true,
                                result: candidate.result,
                                sessions: candidate.sessions,
                                actURL: actURLs.first,
                                actURLs: actURLs.isEmpty ? nil : actURLs,
                                sourceURL: candidateURL,
                                sourceEvidence: .init(card: candidateCaseCard,
                                                      cartotekaID: "admj",
                                                      courtLevel: .district,
                                                      branch: .general)))
                        } else {
                            markMGSPartial()
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                        throw error
                    } catch {
                        markMGSPartial()
                    }
                } else {
                    // A published UID listing is only a candidate. It must
                    // lead to one verified RS appeal card with matching
                    // person and KoAP article before it joins this movement.
                    markMGSPartial()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                throw error
            } catch {
                markMGSPartial()
            }
        } else {
            markMGSPartial()
        }

        // The published MGS 4а card may identify its predecessor by the
        // lower-instance number. A UID search only locates candidates; only
        // the exact MGS review locator and its own `lowerNumber` can add it.
        let expectedLowerNumbers = Set(
            [fetched.card.caseNumber, instances.first(where: { $0.level == .appeal })?.caseNumber]
                .compactMap { $0 })
        if let anchorUID = Self.normalizedJudicialUID(fetched.card.uid), !expectedLowerNumbers.isEmpty,
           let mosgorsud {
            do {
                let rows = try await mosgorsud.search(
                    courtAlias: MosGorSudCourtDirectory.mgsAlias,
                    uid: fetched.card.uid, caseNumber: nil, participant: nil,
                    instance: MosGorSudInstance.review, processType: .admin)
                if rows.isEmpty {
                    // Search currently exposes section-filtered rows without
                    // completeness metadata; empty is unknown, not zero.
                    markMGSReviewPartial()
                } else if rows.count != 1 {
                    markMGSReviewPartial()
                } else if let row = rows.first,
                          row.section?.caseInsensitiveCompare("review-supervision") == .orderedSame,
                          let candidateURL = row.cardURL,
                          let locator = SourceNativeCardLocator.moscowMagistrateKoAPReview(
                            url: candidateURL),
                          row.uid.map({ Self.normalizedJudicialUID($0) == anchorUID }) ?? true {
                    do {
                        let fetchedCandidate = try await fetchMosGorSudCard(
                            url: candidateURL, from: mosgorsud)
                        let candidate = fetchedCandidate.card
                        let lowerMatches = candidate.lowerNumber.map { lower in
                            expectedLowerNumbers.contains {
                                Self.sameMoscowPublishedCaseNumber(lower, $0)
                            }
                        } == true
                        let responseLocator = SourceNativeCardLocator.moscowMagistrateKoAPReview(
                            url: fetchedCandidate.responseURL)
                        if responseLocator?.identity == locator.identity,
                           let caseNumber = candidate.caseNumber,
                           Self.sameMoscowPublishedCaseNumber(caseNumber, row.caseNumber),
                           Self.normalizedJudicialUID(candidate.uid) == anchorUID,
                           candidate.court.map(Self.normalizedText)
                            == Optional("московский городской суд"),
                           lowerMatches {
                            coverage.recordLoaded(locator)
                            let actURLs = candidate.actFiles.compactMap {
                                PublishedActURLPolicy.safeMosGorSudURL($0.url)
                            }
                            instances.append(CaseInstance(
                                level: .supervisory,
                                court: candidate.court ?? "Московский городской суд",
                                caseNumber: caseNumber,
                                judge: candidate.judge,
                                domain: MosGorSudEndpoint.host,
                                foundByUID: true,
                                result: candidate.result,
                                sessions: candidate.sessions,
                                actURL: actURLs.first,
                                actURLs: actURLs.isEmpty ? nil : actURLs,
                                sourceURL: candidateURL,
                                sourceEvidence: .init(card: Self.koapEvidenceCard(candidate),
                                                      cartotekaID: "adm33",
                                                      courtLevel: .subject,
                                                      branch: .general)))
                        } else {
                            markMGSReviewPartial()
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                        throw error
                    } catch {
                        markMGSReviewPartial()
                    }
                } else {
                    markMGSReviewPartial()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                throw error
            } catch {
                markMGSReviewPartial()
            }
        } else {
            markMGSReviewPartial()
        }

        let legalForceDate = fetched.card.legalForceDate ?? base.legalForceDate
        let cassationDomains = higherCourtTargets.filter {
            ($0.courtLevel ?? Self.courtLevel(forDomain: $0.domain)) == .cassation
                && $0.dateRule.matches(legalForceDate: legalForceDate)
        }.map(\.domain)
        let federal = try await moscowFederalStages(
            uid: fetched.card.uid,
            firstInstanceCourt: court.title,
            firstInstanceCaseNumber: fetched.card.caseNumber ?? base.caseNumber,
            baseCartotekaID: cartoteka.id,
            cassationDomains: cassationDomains)
        instances.append(contentsOf: federal.instances)
        incompleteDomains.append(contentsOf: federal.incompleteDomains.filter {
            !incompleteDomains.contains($0)
        })
        honestZeroDomains.append(contentsOf: federal.honestZeroDomains.filter {
            !honestZeroDomains.contains($0)
        })
        coverage.merge(federal.sourceRefreshCoverage)

        return CaseMovement(
            uid: fetched.card.uid ?? "",
            caseNumber: fetched.card.caseNumber ?? base.caseNumber,
            inForce: fetched.card.legalForceDate?.isEmpty == false
                || base.legalForceDate?.isEmpty == false,
            instances: instances,
            complaints: [:],
            acts: federal.acts,
            actBodies: federal.bodies,
            category: fetched.card.category,
            parties: fetched.card.parties,
            incompleteHigherCourtDomains: incompleteDomains,
            honestZeroDomains: honestZeroDomains,
            executionDocuments: fetched.card.executionDocuments,
            sourceRefreshCoverage: coverage.values)
    }

    private static func verifiedKoAPAppeal(_ candidate: MosGorSudCard,
                                            row: MosGorSudResult,
                                            locator: SourceNativeCardLocator,
                                            anchor: CaseCard,
                                            anchorUID: String) -> Bool {
        guard let candidateUID = normalizedJudicialUID(candidate.uid),
              candidateUID == anchorUID,
              let candidateNumber = candidate.caseNumber,
              sameMoscowPublishedCaseNumber(candidateNumber, row.caseNumber),
              let expectedCourt = MosGorSudCourtDirectory.title(forAlias: locator.courtKey),
              let actualCourt = candidate.court,
              normalizedText(actualCourt) == normalizedText(expectedCourt),
              let anchorPeople = principalNames(anchor.parties),
              let candidatePeople = principalNames(koapParties(candidate.participants)),
              anchorPeople == candidatePeople,
              let anchorArticle = koapArticleEvidence(anchor.category),
              let candidateArticle = koapArticleEvidence(candidate.category),
              anchorArticle == candidateArticle else { return false }
        return true
    }

    private func fetchMosGorSudCard(url: URL,
                                    from provider: any MosGorSudProviding) async throws
        -> MosGorSudCardFetchResult {
        if let responseProvider = provider as? any MosGorSudCardResponseProviding {
            return try await responseProvider.fetchCardWithResponseURL(url: url)
        }
        return MosGorSudCardFetchResult(card: try await provider.fetchCard(url: url),
                                        responseURL: url)
    }

    private static func koapEvidenceCard(_ card: MosGorSudCard) -> CaseCard {
        CaseCard(rawText: card.rawText, actText: nil,
                 sessions: card.sessions, judge: card.judge, result: card.result,
                 uid: card.uid, caseNumber: card.caseNumber,
                 category: card.category, receiptDate: card.receiptDate,
                 legalForceDate: card.legalForceDate,
                 parties: koapParties(card.participants),
                 lowerCourt: card.lowerNumber.map { LowerCourtReference(caseNumber: $0) },
                 processKind: .koap)
    }

    private static func sameMoscowPublishedCaseNumber(_ lhs: String, _ rhs: String) -> Bool {
        samePublishedCaseNumber(lhs, rhs)
            || MosGorSudRouting.sameRegistrationNumber(lhs, rhs)
            || MoscowMagistrateKoAPNumber.matchesPublishedNumber(lhs, rhs)
    }

    private static func koapParties(_ participants: [String]) -> CaseParties {
        var parties = CaseParties(kind: .koap)
        for raw in participants {
            guard let separator = raw.firstIndex(of: ":") else { continue }
            let role = raw[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = raw[raw.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !role.isEmpty, !name.isEmpty { parties.add(role: role, name: name) }
        }
        return parties
    }

    private static func principalNames(_ parties: CaseParties) -> [String]? {
        let names = parties.koapPrincipalMembers.map { normalizedText($0.name) }.sorted()
        guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty }) else { return nil }
        return names
    }

    private static func koapArticleEvidence(_ category: String?) -> String? {
        guard let category else { return nil }
        let normalized = normalizedText(category)
        guard normalized.contains("коап") else { return nil }
        let pattern = #"(?i)(?:(?:ч(?:асть)?\.?\s*(\d+)\s*)?ст(?:атья|атьи)?\.?\s*(\d{1,3}(?:\.\d+)+)(?:\s*ч(?:асть)?\.?\s*(\d+))?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(normalized.startIndex..., in: normalized)
        let citations = regex.matches(in: normalized, range: range).compactMap { match -> String? in
            guard let articleRange = Range(match.range(at: 2), in: normalized) else { return nil }
            let beforePart = Range(match.range(at: 1), in: normalized).map { String(normalized[$0]) }
            let afterPart = Range(match.range(at: 3), in: normalized).map { String(normalized[$0]) }
            guard beforePart == nil || afterPart == nil || beforePart == afterPart else { return nil }
            return "\(normalized[articleRange])#\(beforePart ?? afterPart ?? "")"
        }
        if !citations.isEmpty { return Array(Set(citations)).sorted().joined(separator: ",") }

        // Some cards publish the code and dotted article number without the
        // word «статья». Accept only one such number; ambiguous values stay
        // unlinked instead of guessing which number is the charge.
        let numberRegex = try? NSRegularExpression(pattern: #"\b\d{1,3}(?:\.\d+)+\b"#)
        let numbers = numberRegex?.matches(in: normalized, range: range).compactMap { match in
            Range(match.range, in: normalized).map { String(normalized[$0]) }
        } ?? []
        guard numbers.count == 1 else { return nil }
        let partRegex = try? NSRegularExpression(
            pattern: #"(?i)\b(?:часть|ч)\.?\s*(\d+)\b"#)
        let parts = partRegex?.matches(in: normalized, range: range).compactMap { match in
            Range(match.range(at: 1), in: normalized).map { String(normalized[$0]) }
        } ?? []
        guard parts.count <= 1 else { return nil }
        return "\(numbers[0])#\(parts.first ?? "")"
    }

    private static func normalizedText(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
