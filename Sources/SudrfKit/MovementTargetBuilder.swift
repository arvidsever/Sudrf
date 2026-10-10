import Foundation

/// Единый источник целей движения для живого поиска и сохранённых контекстов.
/// Уровень якоря важнее уровня суда: апелляционная карточка суда субъекта не
/// должна повторно рассматриваться как первая инстанция этого суда.
public enum MovementTargetBuilder {
    /// A published GPK/KAS source link, independent of a saved instance level or UID.
    static func magistrateGPKKASOriginProcess(
        court: Court, cartoteka: Cartoteka, card: CaseCard, expectedNumber: String
    ) -> ProcessKind? {
        guard let number = card.caseNumber,
              MovementService.samePublishedCaseNumber(number, expectedNumber),
              CartotekaRegistry.prefixMatches(cartoteka, caseNumber: number),
              card.processKindConflict != true else { return nil }
        let index = CartotekaRegistry.normalizedNumber(number)
        let indexedProcess: ProcessKind? = index.hasPrefix("2а-") ? .administrative
            : index.hasPrefix("2-") ? .civil
            : CaseIndexClassifier.classify(caseNumber: number, courtLevel: .district)?.processKind
        guard let process = card.processKind ?? indexedProcess,
              indexedProcess == nil || (process == .special ? .civil : process) == indexedProcess,
              process == .civil || process == .administrative || process == .special
        else { return nil }
        if court.level == .district {
            guard ["g2", "p2"].contains(cartoteka.id),
                  let own = CaseIndexClassifier.classify(caseNumber: number, courtLevel: .district),
                  own.cardRole == .appellateCase,
                  (process == .special ? .civil : process) == own.processKind,
                  let lower = card.lowerCourt,
                  let title = lower.courtTitle?.lowercased(),
                  ((title.contains("миров") && title.contains("суд"))
                    || title.contains("судебный участок")),
                  let lowerNumber = lower.caseNumber,
                  CartotekaRegistry.normalizedNumber(lowerNumber).hasPrefix(
                    process == .administrative ? "2а-" : "2-")
            else { return nil }
        } else {
            guard court.level == .magistrate, cartoteka.id == "g1",
                  index.hasPrefix(process == .administrative ? "2а-" : "2-")
            else { return nil }
        }
        return process
    }

    /// Rebuild only the magistrate cassation slice after the source card is loaded.
    /// A saved date rule or a legacy domain target must not choose the route.
    static func normalizedMagistrateCassationTargets(
        _ targets: [MovementSearchTarget], court: Court, cartoteka: Cartoteka,
        card: CaseCard, expectedNumber: String, expectedUID: String?
    ) -> (targets: [MovementSearchTarget], proven: Bool) {
        guard let process = magistrateGPKKASOriginProcess(
            court: court, cartoteka: cartoteka, card: card, expectedNumber: expectedNumber),
            expectedUID == nil || card.uid == nil || MovementService.normalizedJudicialUID(card.uid)
                == MovementService.normalizedJudicialUID(expectedUID)
        else { return (targets, false) }

        let publishedCode = KoAPProceduralRole.classificationCode(from: card.uid)
            .map(CourtDirectory.normalizedSubjectCode)
        let savedCode = KoAPProceduralRole.classificationCode(from: expectedUID)
            .map(CourtDirectory.normalizedSubjectCode)
        let sourceHost = court.domain.hasSuffix(".msudrf.ru")
            ? String(court.domain.dropLast(".msudrf.ru".count)) + ".sudrf.ru"
            : court.domain
        let sourceCodes = Set(CourtDirectory.subjectCourtDomainByCode.compactMap { code, domain in
            CourtDirectory.regionSuffix(ofDomain: domain)
                == CourtDirectory.regionSuffix(ofDomain: sourceHost) ? code : nil
        })
        guard sourceCodes.count <= 1 else { return (targets, false) }
        let sourceCode = sourceCodes.first
        guard let code = publishedCode ?? savedCode ?? sourceCode,
              (publishedCode == nil || publishedCode == code),
              (savedCode == nil || savedCode == code),
              (sourceCode == nil || sourceCode == code) else { return (targets, false) }
        guard let cassation = CourtDirectory.cassationCourt(forSubjectCode: code),
              let subject = CourtDirectory.subjectCourt(forSubjectCode: code),
              subject.isSudrfPlatform else { return (targets, false) }
        let isKAS = process == .administrative
        let cassationHost = SudrfHost.moduleHost(cassation.domain)
        let subjectHost = SudrfHost.moduleHost(subject.domain)
        var result = targets.compactMap { target -> MovementSearchTarget? in
            let host = SudrfHost.moduleHost(target.domain)
            let affectedIDs = host == cassationHost ? ["g3", "p3"]
                : host == subjectHost ? ["g33", "p33"] : []
            guard !affectedIDs.isEmpty,
                  target.instanceLevel == nil || target.instanceLevel == .cassation
            else { return target }
            guard let ids = target.cartotekaIDs else { return nil } // legacy domain fallback
            let retained = ids.filter { !affectedIDs.contains($0) }
            guard retained != ids else { return target }
            guard !retained.isEmpty else { return nil }
            var kept = target
            kept.cartotekaIDs = retained
            return kept
        }
        result.append(MovementSearchTarget(
            domain: cassation.domain, courtTitle: cassation.title,
            courtLevel: .cassation, instanceLevel: .cassation,
            cartotekaIDs: [isKAS ? "p3" : "g3"]))
        result.append(MovementSearchTarget(
            domain: CourtDirectory.dashVariant(of: subject.domain) ?? subject.domain,
            courtTitle: subject.title, courtLevel: .subject, instanceLevel: .cassation,
            cartotekaIDs: [isKAS ? "p33" : "g33"]))
        return (result, true)
    }

    /// Whether the principal criminal case's first cassation is routed to the
    /// Supreme Court under the current UPK route. The index and role must agree;
    /// an appeal anchor also needs a published link back to a subject/circuit
    /// first-instance case.
    public static func usesSupremeCriminalCassationRoute(
        courtLevel: CourtLevel, branch: CourtBranch, cartotekaID: String?,
        caseNumber: String?, lowerCourt: LowerCourtReference? = nil,
        sourceProcessKind: ProcessKind? = nil,
        sourceProcessKindConflict: Bool? = nil
    ) -> Bool {
        guard sourceProcessKindConflict != true,
              let cartotekaID = cartotekaID?.lowercased(),
              let caseNumber,
              let ownInfo = CaseIndexClassifier.classify(
                caseNumber: caseNumber, courtLevel: courtLevel, branch: branch),
              ownInfo.processKind == .upk,
              ownInfo.processKind == (sourceProcessKind ?? ownInfo.processKind)
        else { return false }

        if courtLevel == .subject, cartotekaID == "u1" {
            return ownInfo.cardRole == .firstInstanceCase
        }

        guard courtLevel == .appeal, cartotekaID == "u2",
              ownInfo.cardRole == .appellateCase,
            let lowerCourt,
              let lowerNumber = lowerCourt.caseNumber,
              let lowerTitle = lowerCourt.courtTitle,
              hasSubjectCourtTitle(lowerTitle, branch: branch),
              let lowerInfo = CaseIndexClassifier.classify(
                caseNumber: lowerNumber, courtLevel: .subject, branch: branch)
        else { return false }
        return lowerInfo.processKind == .upk && lowerInfo.cardRole == .firstInstanceCase
    }

    /// Moves only retry stubs and positively linked KSOYU/VKAS cards out of the
    /// primary stage. Ambiguous real cards remain untouched for data safety.
    public static func normalizeCriminalCassationRoute(
        in movement: CaseMovement,
        courtLevel: CourtLevel? = nil, branch: CourtBranch? = nil,
        cartotekaID: String? = nil, caseNumber: String? = nil,
        lowerCourt: LowerCourtReference? = nil
    ) -> CaseMovement {
        let anchorNumber = caseNumber ?? movement.caseNumber
        let anchors = movement.instances.filter {
            ($0.level == .first || $0.level == .appeal)
                && MovementService.samePublishedCaseNumber($0.caseNumber, anchorNumber)
        }
        guard anchors.count == 1, let anchor = anchors.first else { return movement }
        let evidence = anchor.sourceEvidence
        guard usesSupremeCriminalCassationRoute(
            courtLevel: courtLevel ?? evidence?.sourceCourtLevel ?? .district,
            branch: branch ?? evidence?.sourceBranch ?? .general,
            cartotekaID: cartotekaID ?? evidence?.cartotekaID,
            caseNumber: caseNumber ?? anchor.caseNumber,
            lowerCourt: lowerCourt ?? evidence?.lowerCourt,
            sourceProcessKind: evidence?.ownProcessKind,
            sourceProcessKindConflict: evidence?.ownProcessKindConflict
        ) else { return movement }

        var normalized = movement
        var materialActIDs = Set<String>()
        for index in normalized.instances.indices {
            let instance = normalized.instances[index]
            guard isRelatedCriminalReview(instance) else { continue }
            if instance.captchaFormURL != nil || instance.transientError == true {
                normalized.instances[index].level = .material
                materialActIDs.formUnion(instance.linkedActIDs)
            } else if let lower = instance.sourceEvidence?.lowerCourt,
                      isVerifiedCriminalReview(
                        instance, branch: branch ?? evidence?.sourceBranch ?? .general,
                        expectedUID: movement.uid),
                      movement.instances.contains(where: { material in
                          material.level == .material
                              && isVerifiedCriminalMaterial(
                                  material, branch: branch ?? evidence?.sourceBranch ?? .general,
                                  expectedUID: movement.uid, acts: movement.acts)
                              && MovementService.samePublishedCaseNumber(material.caseNumber, lower.caseNumber)
                              && lowerCourtTitleMatches(lower.courtTitle, material)
                              && lowerCourtDateMatches(lower.decisionDate, material, acts: movement.acts)
                      }) {
                normalized.instances[index].level = .material
                materialActIDs.formUnion(instance.linkedActIDs)
            }
        }
        for index in normalized.acts.indices where materialActIDs.contains(normalized.acts[index].id) {
            normalized.acts[index].instanceLevel = .material
        }
        return normalized
    }

    /// True for an actual KSOYU/VKAS card that must not be used as the primary
    /// cassation stage after the source anchor proves the direct UPK route.
    public static func isRelatedCriminalReview(_ instance: CaseInstance) -> Bool {
        guard instance.level == .cassation else { return false }
        let host = SudrfHost.moduleHost(instance.domain)
        return CourtDirectory.cassationCourts.contains {
            SudrfHost.moduleHost($0.domain) == host
        } || host == SudrfHost.moduleHost(CourtDirectory.cassationMilitaryCourt.domain)
    }

    static func isVerifiedRelatedCriminalMaterial(
        row: CaseSearchResult, card: CaseCard, sourceURL: URL,
        court: Court, cartoteka: Cartoteka, branch: CourtBranch,
        expectedUID: String, instances: [CaseInstance], acts: [CaseAct]
    ) -> Bool {
        guard let sourceLink = try? SudrfCaseCardLink(url: sourceURL) else { return false }
        if let publishedURL = row.cardURL {
            guard let publishedLink = try? SudrfCaseCardLink(url: publishedURL),
                  publishedLink == sourceLink else { return false }
        }
        guard sourceLink.moduleHost == SudrfHost.moduleHost(court.domain),
              sourceLink.deloID == cartoteka.deloID,
              sourceLink.resolvedNew == cartoteka.new,
              row.caseID == nil || sourceLink.caseID == row.caseID,
              row.caseUID == nil || sourceLink.caseUID == row.caseUID,
              (row.caseID != nil && sourceLink.caseID == row.caseID)
                || (row.caseUID != nil && sourceLink.caseUID == row.caseUID),
              let number = card.caseNumber,
              MovementService.sameDisplayedCaseNumber(row.caseNumber, number),
              CartotekaRegistry.prefixMatches(cartoteka, caseNumber: number),
              JudicialUIDObservation.validity(of: expectedUID) == .valid,
              MovementService.normalizedJudicialUID(card.uid)
                == MovementService.normalizedJudicialUID(expectedUID),
              JudicialUIDObservation.validity(of: card.uid) == .valid,
              card.processKindConflict != true,
              card.processKind == nil || card.processKind == .upk,
              let info = CaseIndexClassifier.classify(
                caseNumber: number, courtLevel: .cassation, branch: branch),
              info.processKind == .upk,
              info.cardRole == .cassationComplaint || info.cardRole == .cassationCase,
              let lower = card.lowerCourt,
              let lowerNumber = lower.caseNumber
        else { return false }
        return instances.contains { material in
            material.level == .material
                && isVerifiedCriminalMaterial(material, branch: branch,
                                              expectedUID: expectedUID, acts: acts)
                && MovementService.samePublishedCaseNumber(material.caseNumber, lowerNumber)
                && lowerCourtTitleMatches(lower.courtTitle, material)
                && lowerCourtDateMatches(lower.decisionDate, material, acts: acts)
        }
    }

    private static func isVerifiedCriminalReview(_ instance: CaseInstance,
                                                  branch: CourtBranch,
                                                  expectedUID: String) -> Bool {
        guard let evidence = instance.sourceEvidence,
              evidence.ownProcessKindConflict != true,
              evidence.sourceCourtLevel == .cassation,
              evidence.sourceBranch == branch,
              evidence.ownProcessKind == nil || evidence.ownProcessKind == .upk,
              JudicialUIDObservation.validity(of: expectedUID) == .valid,
              JudicialUIDObservation.validity(of: evidence.judicialUID) == .valid,
              MovementService.normalizedJudicialUID(evidence.judicialUID)
                == MovementService.normalizedJudicialUID(expectedUID),
              let cartotekaID = evidence.cartotekaID,
              let cartoteka = CartotekaRegistry.find(level: .cassation, id: cartotekaID),
              let info = CaseIndexClassifier.classify(
                caseNumber: instance.caseNumber, courtLevel: .cassation, branch: branch),
              info.processKind == .upk,
              info.cardRole == .cassationComplaint || info.cardRole == .cassationCase,
              CartotekaRegistry.prefixMatches(cartoteka, caseNumber: instance.caseNumber),
              let url = instance.sourceURL,
              let link = try? SudrfCaseCardLink(url: url),
              link.moduleHost == SudrfHost.moduleHost(instance.domain),
              link.deloID == cartoteka.deloID,
              link.resolvedNew == cartoteka.new,
              link.caseID != nil || link.caseUID != nil
        else { return false }
        if branch == .general {
            return CourtDirectory.cassationCourts.contains {
                SudrfHost.moduleHost($0.domain) == SudrfHost.moduleHost(instance.domain)
            }
        }
        return SudrfHost.moduleHost(CourtDirectory.cassationMilitaryCourt.domain)
            == SudrfHost.moduleHost(instance.domain)
    }

    private static func isVerifiedCriminalMaterial(_ instance: CaseInstance,
                                                    branch: CourtBranch,
                                                    expectedUID: String,
                                                    acts: [CaseAct]) -> Bool {
        guard let evidence = instance.sourceEvidence,
              evidence.ownProcessKindConflict != true,
              let observedUID = evidence.judicialUID,
              JudicialUIDObservation.validity(of: observedUID) == .valid,
              MovementService.normalizedJudicialUID(evidence.judicialUID)
                == MovementService.normalizedJudicialUID(expectedUID),
              let level = evidence.sourceCourtLevel,
              let cartotekaID = evidence.cartotekaID,
              let cartoteka = CartotekaRegistry.find(level: level, id: cartotekaID),
              let info = CaseIndexClassifier.classify(
                caseNumber: instance.caseNumber, courtLevel: level, branch: branch),
              info.processKind == .upk, info.cardRole.isMaterial,
              CartotekaRegistry.prefixMatches(cartoteka, caseNumber: instance.caseNumber),
              evidence.ownProcessKind == nil || evidence.ownProcessKind == .upk,
              evidence.sourceBranch == branch,
              let url = instance.sourceURL,
              let link = try? SudrfCaseCardLink(url: url),
              SudrfHost.moduleHost(link.host) == SudrfHost.moduleHost(instance.domain),
              link.caseID != nil || link.caseUID != nil,
              link.deloID == cartoteka.deloID,
              link.resolvedNew == cartoteka.new
        else { return false }
        return true
    }

    private static func lowerCourtTitleMatches(_ title: String?, _ material: CaseInstance) -> Bool {
        guard let title else { return false }
        func normalized(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "ё", with: "е")
                .filter { $0.isLetter || $0.isNumber }
        }
        let candidate = normalized(title)
        guard candidate.count >= 12 else { return false }
        var authoritativeTitles = [material.court]
        let host = SudrfHost.moduleHost(material.domain)
        authoritativeTitles += CourtDirectory.subjectCourts
            .filter { SudrfHost.moduleHost($0.domain) == host }.map(\.title)
        authoritativeTitles += CourtDirectory.appealCourts
            .filter { SudrfHost.moduleHost($0.domain) == host }.map(\.title)
        authoritativeTitles += CourtDirectory.cassationCourts
            .filter { SudrfHost.moduleHost($0.domain) == host }.map(\.title)
        authoritativeTitles += CourtDirectory.okrugMilitaryCourts
            .filter { SudrfHost.moduleHost($0.domain) == host }.map(\.title)
        authoritativeTitles += [CourtDirectory.appellateMilitaryCourt,
                                CourtDirectory.cassationMilitaryCourt]
            .filter { SudrfHost.moduleHost($0.domain) == host }.map(\.title)
        return authoritativeTitles.contains { normalized($0) == candidate }
    }

    private static func lowerCourtDateMatches(_ date: String?, _ material: CaseInstance,
                                              acts: [CaseAct]) -> Bool {
        guard let date else { return true }
        let expected = MovementService.dateSortKey(date)
        guard expected != Int.max else { return false }
        let finalActTitles: Set<String> = [
            "определение", "постановление", "решение", "приговор",
            "апелляционное определение", "апелляционное постановление",
            "кассационное определение", "определение суда кассационной инстанции"
        ]
        let actualDates = [material.sourceEvidence?.decisionDate].compactMap { $0 }
            + acts.filter {
                material.linkedActIDs.contains($0.id)
                    && finalActTitles.contains($0.title.lowercased())
            }.map(\.date)
        return actualDates.contains { MovementService.dateSortKey($0) == expected }
    }

    /// Точные цели, когда одной пары «звено + суффикс картотеки» недостаточно.
    /// Для КоАП учитываются три картотеки суда субъекта и происхождение УИД.
    public static func targets(branch: CourtBranch, courtLevel: CourtLevel,
                               baseCartoteka: Cartoteka, caseNumber: String,
                               judicialUID: String?, courtTitle: String,
                               courtCode: String?, region: String, displayDomain: String,
                               districtCourts: [(domain: String, title: String)] = [])
        -> [MovementSearchTarget]? {
        guard branch == .general else { return nil }
        if baseCartoteka.id.hasPrefix("adm") {
            return koapTargets(
                courtLevel: courtLevel, baseCartoteka: baseCartoteka,
                judicialUID: judicialUID, courtTitle: courtTitle,
                courtCode: courtCode, region: region, displayDomain: displayDomain,
                districtCourts: districtCourts)
        }
        guard courtLevel == .magistrate else { return nil }
        return magistrateTargets(
            baseCartoteka: baseCartoteka, caseNumber: caseNumber,
            courtCode: courtCode, region: region, districtCourts: districtCourts)
    }

    /// Домены судов для обычного поиска по УИД. Вызывающая сторона при
    /// необходимости разворачивает sudrf-домен в дефисный и точечный варианты.
    public static func higherDomains(branch: CourtBranch, courtLevel: CourtLevel,
                                     baseInstanceLevel: CaseInstance.Level,
                                     courtTitle: String, courtCode: String?,
                                     region: String, displayDomain: String) -> [String] {
        guard baseInstanceLevel != .cassation else { return [] }
        guard branch == .general else {
            if baseInstanceLevel == .appeal {
                return [CourtDirectory.cassationMilitaryCourt.domain]
            }
            var domains: [String] = []
            switch courtLevel {
            case .district:
                if let okrug = CourtDirectory.okrugMilitaryCourt(
                    forGarrisonTitle: courtTitle, code: courtCode) {
                    domains.append(okrug.domain)
                }
                domains.append(CourtDirectory.cassationMilitaryCourt.domain)
            case .subject:
                domains.append(CourtDirectory.appellateMilitaryCourt.domain)
                domains.append(CourtDirectory.cassationMilitaryCourt.domain)
            default:
                break
            }
            return domains
        }

        if baseInstanceLevel == .appeal {
            let code = courtCode.map(CourtDirectory.normalizedSubjectCode)
                ?? CourtDirectory.subjectCode(forDomain: displayDomain)
                ?? CourtDirectory.subjectNumericCode(forRegion: region)
            return code.flatMap(CourtDirectory.cassationCourt(forSubjectCode:))
                .map { [$0.domain] } ?? []
        }

        var domains: [String] = []
        switch courtLevel {
        case .magistrate:
            break
        case .district:
            let code = courtCode.map(CourtDirectory.normalizedSubjectCode)
                ?? CourtDirectory.subjectNumericCode(forRegion: region)
            if let code {
                if let subject = CourtDirectory.subjectCourt(forSubjectCode: code),
                   subject.isSudrfPlatform { domains.append(subject.domain) }
                if let cassation = CourtDirectory.cassationCourt(forSubjectCode: code) {
                    domains.append(cassation.domain)
                }
            }
        case .subject:
            let code = courtCode.map(CourtDirectory.normalizedSubjectCode)
                ?? CourtDirectory.subjectCode(forDomain: SudrfHost.moduleHost(displayDomain))
            if let code {
                if let appeal = CourtDirectory.appealCourt(forSubjectCode: code) {
                    domains.append(appeal.domain)
                }
                if let cassation = CourtDirectory.cassationCourt(forSubjectCode: code) {
                    domains.append(cassation.domain)
                }
            }
        default:
            break
        }
        return domains
    }

    private static func hasSubjectCourtTitle(_ title: String, branch: CourtBranch) -> Bool {
        let normalized = title.lowercased().filter { $0.isLetter }
        guard !normalized.isEmpty else { return false }
        let titles = branch == .general
            ? CourtDirectory.subjectCourts.map(\.title)
            : CourtDirectory.okrugMilitaryCourts.map(\.title)
        return titles.contains { candidate in
            let candidate = candidate.lowercased().filter { $0.isLetter }
            return normalized == candidate
        }
    }

    /// Цели мирового участка: районная апелляция и для ГПК/КАС оба возможных
    /// кассационных маршрута при неизвестной дате подачи жалобы. Суффикс
    /// картотеки КАС отличается от гражданского по индексу «2а».
    private static func magistrateTargets(
        baseCartoteka: Cartoteka, caseNumber: String,
        courtCode: String?, region: String,
        districtCourts: [(domain: String, title: String)])
        -> [MovementSearchTarget]? {
        let appealIDs = magistrateAppealCartotekaIDs(baseID: baseCartoteka.id,
                                                     caseNumber: caseNumber)
        let ksoyIDs = magistrateCassationCartotekaIDs(baseID: baseCartoteka.id,
                                                      caseNumber: caseNumber,
                                                      usePresidium: false)
        let presidiumIDs = magistrateCassationCartotekaIDs(baseID: baseCartoteka.id,
                                                           caseNumber: caseNumber,
                                                           usePresidium: true)
        let subjectCode = courtCode.map(CourtDirectory.normalizedSubjectCode)
            ?? CourtDirectory.subjectNumericCode(forRegion: region)
        let normalizedNumber = CartotekaRegistry.normalizedNumber(caseNumber)
        let civilOrKAS = baseCartoteka.id == "g1"
            && (normalizedNumber.hasPrefix("2-") || normalizedNumber.hasPrefix("2а-"))
        var targets: [MovementSearchTarget] = []

        for court in districtCourts where !appealIDs.isEmpty {
            targets.append(MovementSearchTarget(
                domain: CourtDirectory.dashVariant(of: court.domain) ?? court.domain,
                courtTitle: court.title, courtLevel: .district,
                instanceLevel: baseCartoteka.id == "m" ? .material : .appeal,
                cartotekaIDs: appealIDs))
        }
        if let subjectCode, !ksoyIDs.isEmpty,
           let court = CourtDirectory.cassationCourt(forSubjectCode: subjectCode) {
            targets.append(MovementSearchTarget(
                domain: court.domain, courtTitle: court.title, courtLevel: .cassation,
                instanceLevel: .cassation, cartotekaIDs: ksoyIDs,
                dateRule: civilOrKAS ? .always : .before2026))
        }
        if let subjectCode, !presidiumIDs.isEmpty,
           let court = CourtDirectory.subjectCourt(forSubjectCode: subjectCode),
           court.isSudrfPlatform {
            targets.append(MovementSearchTarget(
                domain: CourtDirectory.dashVariant(of: court.domain) ?? court.domain,
                courtTitle: court.title, courtLevel: .subject,
                instanceLevel: .cassation, cartotekaIDs: presidiumIDs,
                dateRule: civilOrKAS ? .always : .from2026))
        }
        return targets.isEmpty ? nil : targets
    }

    private static func koapTargets(
        courtLevel: CourtLevel, baseCartoteka: Cartoteka,
        judicialUID: String?, courtTitle: String, courtCode: String?,
        region: String, displayDomain: String,
        districtCourts: [(domain: String, title: String)])
        -> [MovementSearchTarget] {
        let id = baseCartoteka.id
        let uidKind = KoAPProceduralRole.uidCourtKind(judicialUID)
        let subjectCode = courtCode.map(CourtDirectory.normalizedSubjectCode)
            ?? KoAPProceduralRole.classificationCode(from: judicialUID)
                .map(CourtDirectory.normalizedSubjectCode)
            ?? CourtDirectory.subjectCode(forDomain: SudrfHost.moduleHost(displayDomain))
            ?? CourtDirectory.subjectNumericCode(forRegion: region)
        let subject = subjectCode.flatMap(CourtDirectory.subjectCourt(forSubjectCode:))
        let cassation = subjectCode.flatMap(CourtDirectory.cassationCourt(forSubjectCode:))
        var result: [MovementSearchTarget] = []

        func addSubject(_ ids: [String], level: CaseInstance.Level,
                        rule: MovementDateRule = .always) {
            guard let subject, subject.isSudrfPlatform else { return }
            result.append(MovementSearchTarget(
                domain: CourtDirectory.dashVariant(of: subject.domain) ?? subject.domain,
                courtTitle: subject.title, courtLevel: .subject,
                instanceLevel: level, cartotekaIDs: ids, dateRule: rule))
        }
        func addKSOYu(_ rule: MovementDateRule = .always) {
            guard let cassation else { return }
            result.append(MovementSearchTarget(
                domain: cassation.domain, courtTitle: cassation.title,
                courtLevel: .cassation, instanceLevel: .cassation,
                cartotekaIDs: ["adm3"], dateRule: rule))
        }
        func addHistoricalSubjectReview() {
            addSubject(["adm33"], level: .cassation,
                       rule: .koapSubjectBeforeOctober2019Possible)
        }

        switch (courtLevel, id) {
        case (.magistrate, "adm"):
            for court in districtCourts {
                result.append(MovementSearchTarget(
                    domain: CourtDirectory.dashVariant(of: court.domain) ?? court.domain,
                    courtTitle: court.title, courtLevel: .district,
                    instanceLevel: .appeal, cartotekaIDs: ["admj"]))
            }
            // С 10.05.2026 MS-кассация снова в суде субъекта; районная
            // апелляция перед ней по КоАП необязательна.
            addSubject(["adm33"], level: .cassation)
            addKSOYu(.koapKSOYuBeforeMay2026Possible)

        case (.district, "adm"):
            addSubject(["adm1"], level: .appeal)
            addHistoricalSubjectReview()
            addKSOYu()

        case (.district, "admj"):
            switch uidKind {
            case .magistrate:
                addSubject(["adm33"], level: .cassation)
                addKSOYu(.koapKSOYuBeforeMay2026Possible)
            case .district:
                addSubject(["adm2"], level: .appeal)
                addHistoricalSubjectReview()
                addKSOYu()
            default:
                // До загрузки карточки УИД может быть неизвестен. Безопасно
                // проверяем объединение обеих веток; поиск всё равно точный по УИД.
                addSubject(["adm2"], level: .appeal)
                addSubject(["adm33"], level: .cassation)
                addKSOYu()
            }

        case (.subject, "adm1"), (.subject, "adm2"):
            // Исторический пересмотр вступившего акта жил в другой картотеке
            // того же суда субъекта; после 01.10.2019 — в КСОЮ.
            let currentDomain = CourtDirectory.dashVariant(of: displayDomain) ?? displayDomain
            if !currentDomain.isEmpty {
                result.append(MovementSearchTarget(
                    domain: currentDomain, courtTitle: courtTitle,
                    courtLevel: .subject, instanceLevel: .cassation,
                    cartotekaIDs: ["adm33"],
                    dateRule: .koapSubjectBeforeOctober2019Possible))
            }
            addKSOYu()

        case (.subject, "adm33"), (.cassation, "adm3"):
            break
        default:
            break
        }

        // Один и тот же суд может прийти из справочника и как текущий домен.
        var seen = Set<String>()
        return result.filter {
            let key = "\(SudrfHost.moduleHost($0.domain))|\(($0.cartotekaIDs ?? []).joined(separator: ","))"
            return seen.insert(key).inserted
        }
    }

    private static func magistrateAppealCartotekaIDs(baseID: String,
                                                      caseNumber: String) -> [String] {
        switch baseID {
        case "u1": return ["u2"]
        case "g1":
            return CartotekaRegistry.normalizedNumber(caseNumber).hasPrefix("2а") ? ["p2"] : ["g2"]
        case "adm": return ["admj"]
        case "m": return ["m"]
        default: return []
        }
    }

    private static func magistrateCassationCartotekaIDs(baseID: String,
                                                         caseNumber: String,
                                                         usePresidium: Bool) -> [String] {
        let suffix = usePresidium ? "33" : "3"
        let isKAS = CartotekaRegistry.normalizedNumber(caseNumber).hasPrefix("2а")
        switch baseID {
        case "u1": return ["u\(suffix)"]
        case "g1": return ["\(isKAS ? "p" : "g")\(suffix)"]
        case "adm": return ["adm\(suffix)"]
        default: return []
        }
    }
}
