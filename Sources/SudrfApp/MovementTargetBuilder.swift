import Foundation
import SudrfKit

/// Единый источник целей движения для живого поиска и сохранённых контекстов.
/// Уровень якоря важнее уровня суда: апелляционная карточка суда субъекта не
/// должна повторно рассматриваться как первая инстанция этого суда.
enum MovementTargetBuilder {
    static func higherDomains(branch: CourtBranch, courtLevel: CourtLevel,
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

    static func magistrateTargets(baseCartoteka: Cartoteka, caseNumber: String,
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
                instanceLevel: .cassation, cartotekaIDs: ksoyIDs, dateRule: .before2026))
        }
        if let subjectCode, !presidiumIDs.isEmpty,
           let court = CourtDirectory.subjectCourt(forSubjectCode: subjectCode),
           court.isSudrfPlatform {
            targets.append(MovementSearchTarget(
                domain: CourtDirectory.dashVariant(of: court.domain) ?? court.domain,
                courtTitle: court.title, courtLevel: .subject,
                instanceLevel: .cassation, cartotekaIDs: presidiumIDs, dateRule: .from2026))
        }
        return targets.isEmpty ? nil : targets
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
