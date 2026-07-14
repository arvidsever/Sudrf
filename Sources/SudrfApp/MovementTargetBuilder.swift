import Foundation
import SudrfKit

/// Единый источник целей движения для живого поиска и сохранённых контекстов.
/// Уровень якоря важнее уровня суда: апелляционная карточка суда субъекта не
/// должна повторно рассматриваться как первая инстанция этого суда.
enum MovementTargetBuilder {
    /// Точные цели, когда одной пары «звено + суффикс картотеки» недостаточно.
    /// Для КоАП учитываются три картотеки суда субъекта и происхождение УИД.
    static func targets(branch: CourtBranch, courtLevel: CourtLevel,
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
        return magistrateTargetsLegacy(
            baseCartoteka: baseCartoteka, caseNumber: caseNumber,
            courtCode: courtCode, region: region, districtCourts: districtCourts)
    }

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
        targets(branch: .general, courtLevel: .magistrate,
                baseCartoteka: baseCartoteka, caseNumber: caseNumber,
                judicialUID: courtCode, courtTitle: "", courtCode: courtCode,
                region: region, displayDomain: "", districtCourts: districtCourts)
    }

    private static func magistrateTargetsLegacy(
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
