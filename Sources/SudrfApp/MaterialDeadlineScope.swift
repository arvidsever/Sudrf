import Foundation
import SudrfKit

/// A local deadline view of one material; the original dossier remains intact.
struct MaterialDeadlineScope {
    var sourceCardID: String
    var movement: CaseMovement
    var context: MovementContext
    var classification: MaterialProductionContext.Classification

    static func proven(in movement: CaseMovement, context: MovementContext) -> [Self] {
        let materialCandidates = movement.instances.filter {
            $0.level == .material && !CaseLifecycleResolver.isRootMaterial($0, in: movement)
                && $0.captchaFormURL == nil && $0.transientError != true
        }
        let counts = Dictionary(grouping: materialCandidates, by: \.id)
        let materials = materialCandidates.filter { counts[$0.id]?.count == 1 }
        var owners: [String: String] = Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0.id) })
        var changed = true
        while changed {
            changed = false
            for review in movement.instances where owners[review.id] == nil
                && [.appeal, .cassation, .vsCassation, .supervisory].contains(review.level)
                && review.captchaFormURL == nil && review.transientError != true {
                let lower = review.sourceEvidence?.lowerCourt
                let body = review.linkedActIDs.compactMap {
                    movement.actBodies[$0].flatMap(CaseLifecycleResolver.operativeDisposition)
                }.joined(separator: " ")
                let dates = CaseLifecycleResolver.explicitTargetActDates(in: body)
                let candidates = movement.instances.filter { target in
                    guard owners[target.id] != nil else { return false }
                    if let number = lower?.caseNumber,
                       CaseOriginResolver.sameCaseNumber(number, target.caseNumber) {
                        return lower?.courtTitle.map {
                            CaseLifecycleResolver.courtTitlesAgree($0, target.court, domain: target.domain)
                        } ?? true
                    }
                    guard !dates.isEmpty,
                          lower?.courtTitle.map({ CaseLifecycleResolver.courtTitlesAgree($0, target.court, domain: target.domain) }) != false
                    else { return false }
                    return !ownAdjudicationDates(target).isDisjoint(with: dates)
                }
                // Same-day acts from different branches are not an ownership proof.
                let targetDates = Set(candidates.flatMap { ownAdjudicationDates($0) }).intersection(dates)
                let competing = movement.instances.contains { target in
                    guard owners[target.id] == nil, target.id != review.id else { return false }
                    return !ownAdjudicationDates(target).isDisjoint(with: targetDates)
                }
                let uniqueOwners = Set(candidates.compactMap { owners[$0.id] })
                if candidates.count == 1, uniqueOwners.count == 1, !competing,
                   let owner = uniqueOwners.first {
                    owners[review.id] = owner
                    // An owned higher act may explicitly name the preceding
                    // appellate act as well as this material's determination.
                    let preceding = movement.instances.filter { target in
                        guard target.level == .appeal, review.level == .cassation,
                              owners[target.id] == nil,
                              let date = target.sourceEvidence?.decisionDate.flatMap(DateUtil.parse),
                              dates.contains(date), !targetDates.contains(date) else { return false }
                        return movement.instances.filter {
                            $0.level == .appeal && $0.sourceEvidence?.decisionDate.flatMap(DateUtil.parse) == date
                        }.count == 1
                    }
                    if preceding.count == 1, let target = preceding.first { owners[target.id] = owner }
                    changed = true
                }
            }
        }
        return materials.compactMap { root in
            guard let cardID = CaseSnapshotSourceIdentity.sourceCardID(for: root, context: context) else { return nil }
            let classification = MaterialProductionContext.resolve(instance: root, movement: movement, baseContext: context)
            var projected = movement
            projected.caseNumber = root.caseNumber
            projected.instances = movement.instances.filter { owners[$0.id] == root.id }
            let acts = Set(projected.instances.flatMap(\.linkedActIDs))
            projected.acts = movement.acts.filter { acts.contains($0.id) }
            projected.actBodies = movement.actBodies.filter { acts.contains($0.key) }
            projected.category = root.sourceEvidence?.category
            var ownContext = context
            ownContext.caseNumber = root.caseNumber
            // The parent card ID is not this material's native identity.
            // Let the existing identity resolver use its known card or URL.
            ownContext.caseID = nil
            ownContext.caseUID = nil
            if SudrfHost.moduleHost(context.searchDomain) != SudrfHost.moduleHost(root.domain) {
                ownContext.courtCode = nil
            }
            ownContext.courtTitle = root.court
            ownContext.displayDomain = root.domain
            ownContext.searchDomain = SudrfHost.moduleHost(root.domain)
            ownContext.cardURLString = root.sourceURL?.absoluteString
            ownContext.courtLevelRaw = (root.sourceEvidence?.sourceCourtLevel ?? CourtDirectory.court(forDomain: root.domain)?.level ?? context.courtLevel).rawValue
            ownContext.cartotekaId = root.sourceEvidence?.cartotekaID ?? "m"
            ownContext.baseInstanceLevelRaw = CaseInstance.Level.material.rawValue
            ownContext.decisionDate = root.sourceEvidence?.decisionDate
            ownContext.resultText = root.result
            return Self(sourceCardID: cardID, movement: projected, context: ownContext, classification: classification)
        }
    }

    private static func ownAdjudicationDates(_ instance: CaseInstance) -> Set<Date> {
        var dates = Set(instance.sessions.filter {
            CaseLifecycleResolver.isMaterialAdjudication(event: $0.event, result: $0.result)
        }.compactMap { DateUtil.parse($0.date) })
        if let date = instance.sourceEvidence?.decisionDate.flatMap(DateUtil.parse) { dates.insert(date) }
        return dates
    }

    private static func keyFields(_ key: String) -> [String]? {
        guard let separator = key.firstIndex(of: "|"),
              String(key[..<separator]).range(of: #"^(?:GPK|KAS|UPK|KOAP)-[A-Z0-9-]+$"#, options: .regularExpression) != nil,
              let bytes = Data(base64Encoded: String(key[key.index(after: separator)...])),
              let payload = String(data: bytes, encoding: .utf8) else { return nil }
        let fields = payload.components(separatedBy: "\u{1F}")
        guard [6, 7].contains(fields.count), !fields[0].isEmpty,
              CaseInstance.Level(rawValue: fields[1]) != nil, !fields[2].isEmpty,
              DateUtil.parse(fields[3]) != nil,
              fields.count == 6 || !fields[6].isEmpty else { return nil }
        return fields
    }

    static func materialSourceCardID(in key: String?) -> String? {
        guard let key, let fields = keyFields(key), fields.count == 7 else { return nil }
        return fields[6]
    }

    /// Invalid opaque keys must never be mistaken for a main-case occurrence.
    static func scopeKey(in key: String?) -> String {
        guard let key else { return "main" }
        guard let fields = keyFields(key) else { return "opaque:" + key }
        return fields.count == 6 ? "main" : "material:" + fields[6]
    }
}
