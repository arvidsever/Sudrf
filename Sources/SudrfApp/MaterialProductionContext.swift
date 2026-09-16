import Foundation
import SudrfKit

/// One classification path for stored dossiers and individual source cards.
/// A related card supplies evidence, never an instruction to merge records.
enum MaterialProductionContext {
    struct Classification {
        var production: ProductionType?
        var isMaterial: Bool
        var basis: CaseIndexClassifier.MaterialContext.Basis

        var label: String {
            if isMaterial {
                return production.map { $0.row + " · материал" }
                    ?? "Материал · вид производства не определён"
            }
            return production?.row ?? "Вид производства не определён"
        }
    }

    static func resolve(context: MovementContext?, movement: CaseMovement?) -> Classification {
        guard let context else {
            if let movement {
                let roots = movement.instances.filter { $0.caseNumber == movement.caseNumber && usable($0) }
                if roots.count == 1 { return resolve(instance: roots[0], movement: movement) }
            }
            return Classification(production: nil, isMaterial: false, basis: .unknown)
        }
        let matches = movement?.instances.filter { instance in
            if let url = context.cardURLString.flatMap(URL.init(string:)),
               let source = instance.sourceURL { return sameCard(url, source) }
            return SudrfHost.moduleHost(instance.domain) == SudrfHost.moduleHost(context.displayDomain)
                && instance.caseNumber == context.caseNumber
        } ?? []
        let instance = matches.count == 1 ? matches[0] : nil
        return classify(number: context.caseNumber, level: context.courtLevel,
                        branch: context.branch, cartoteka: context.cartotekaId,
                        instance: instance, movement: movement, baseContext: context)
    }

    static func resolve(instance: CaseInstance, movement: CaseMovement,
                        baseContext: MovementContext? = nil) -> Classification {
        let evidence = instance.sourceEvidence
        let level = evidence?.sourceCourtLevel
            ?? matchingContext(instance, context: baseContext)?.courtLevel
            ?? CourtDirectory.court(forDomain: instance.domain)?.level
        return classify(number: instance.caseNumber, level: level,
                        branch: evidence?.sourceBranch ?? baseContext?.branch ?? .general,
                        cartoteka: evidence?.cartotekaID ?? matchingContext(instance, context: baseContext)?.cartotekaId,
                        instance: instance, movement: movement, baseContext: baseContext)
    }

    private static func classify(number: String, level: CourtLevel?, branch: CourtBranch,
                                 cartoteka: String?, instance: CaseInstance?,
                                 movement: CaseMovement?, baseContext: MovementContext?) -> Classification {
        let material = instance?.level == .material || cartoteka == "m"
            || level.flatMap { CaseIndexClassifier.classify(caseNumber: number, courtLevel: $0,
                                            branch: branch) }?.cardRole.isMaterial == true
        var related: [ProcessKind] = []
        if material, let instance, usable(instance), let movement {
            for candidate in movement.instances where candidate.id != instance.id && usable(candidate) {
                let candidateContext = matchingContext(candidate, context: baseContext)
                let candidateLevel = candidate.sourceEvidence?.sourceCourtLevel
                    ?? candidateContext?.courtLevel
                    ?? CourtDirectory.court(forDomain: candidate.domain)?.level
                guard let candidateLevel else { continue }
                let own = CaseIndexClassifier.classifyMaterialContext(
                    caseNumber: candidate.caseNumber, courtLevel: candidateLevel,
                    branch: candidate.sourceEvidence?.sourceBranch ?? candidateContext?.branch ?? branch,
                    cartotekaID: candidate.sourceEvidence?.cartotekaID ?? candidateContext?.cartotekaId,
                    sourceProcessKind: candidate.sourceEvidence?.ownProcessKind ?? categoryKind(candidate.sourceEvidence?.category),
                    sourceProcessKindConflict: candidate.sourceEvidence?.ownProcessKindConflict == true)
                guard own.cardRole == .firstInstanceCase, let kind = own.processKind else { continue }
                let uid = instance.sourceEvidence?.judicialUID
                    ?? matchingContext(instance, context: baseContext)?.judicialUID
                let candidateUID = candidate.sourceEvidence?.judicialUID ?? candidateContext?.judicialUID
                let sameUID = validUID(uid) && uid == candidateUID
                // Old cached UID discoveries are usable only against the unique
                // original card; mere membership in a dossier is not evidence.
                let anchors = movement.instances.filter {
                    usable($0) && !$0.foundByUID && $0.caseNumber == movement.caseNumber
                }
                let candidateIsAnchor = anchors.count == 1 && anchors[0].id == candidate.id
                    && candidateContext != nil
                let targetIsAnchor = anchors.count == 1 && anchors[0].id == instance.id
                    && matchingContext(instance, context: baseContext) != nil
                let historicalUID = validUID(movement.uid)
                    && (uid == nil || uid == movement.uid)
                    && (candidateUID == nil || candidateUID == movement.uid)
                    && ((instance.foundByUID && candidateIsAnchor)
                        || (candidate.foundByUID && targetIsAnchor))
                let direct = links(instance, to: candidate) || links(candidate, to: instance)
                if direct, validUID(uid), validUID(candidateUID), uid != candidateUID {
                    return Classification(production: nil, isMaterial: material, basis: .conflict)
                }
                if sameUID || historicalUID || direct { related.append(kind) }
            }
        }
        let result = CaseIndexClassifier.classifyMaterialContext(
            caseNumber: number, courtLevel: level, branch: branch,
            cardRole: material ? .otherMaterial : nil, cartotekaID: cartoteka, sourceProcessKind: instance?.sourceEvidence?.ownProcessKind ?? categoryKind(instance?.sourceEvidence?.category),
            sourceProcessKindConflict: instance?.sourceEvidence?.ownProcessKindConflict == true,
            verifiedRelatedKinds: related)
        return Classification(production: result.processKind.flatMap(ProductionType.init(processKind:)),
                              isMaterial: material, basis: result.basis)
    }

    private static func matchingContext(_ instance: CaseInstance,
                                        context: MovementContext?) -> MovementContext? {
        guard let context else { return nil }
        if let url = context.cardURLString.flatMap(URL.init(string:)), let source = instance.sourceURL {
            return sameCard(url, source) ? context : nil
        }
        return nil
    }

    private static func links(_ source: CaseInstance, to target: CaseInstance) -> Bool {
        guard let reference = source.previousRegistration, let url = target.sourceURL else { return false }
        return sameCard(reference.url, url)
    }

    // Explicit code markers in the card's own category only. General words
    // such as "жалоба" or "исполнение" do not identify a code.
    private static func categoryKind(_ category: String?) -> ProcessKind? {
        guard let category else { return nil }
        let markers: [(String, ProcessKind)] = [("ГПК", .civil), ("КАС", .administrative),
                                               ("УПК", .upk), ("КОАП", .koap)]
        let kinds = markers.compactMap { marker, kind in
            category.uppercased().range(of: #"\b"# + marker + #"\s+РФ\b"#,
                                       options: .regularExpression) == nil ? nil : kind
        }
        return kinds.count == 1 ? kinds[0] : nil
    }

    private static func usable(_ instance: CaseInstance) -> Bool {
        guard instance.captchaFormURL == nil, instance.transientError != true,
              !instance.caseNumber.isEmpty, let url = instance.sourceURL,
              let card = try? SudrfCaseCardLink(url) else { return false }
        return card.moduleHost == SudrfHost.moduleHost(instance.domain)
    }

    private static func validUID(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(of: #"^\d{2}[A-ZА-Я]{2}\d{4}-\d{2}-\d{4}-\d{6}-\d{2}$"#,
                           options: .regularExpression) != nil
    }

    private static func sameCard(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = try? SudrfCaseCardLink(lhs), let b = try? SudrfCaseCardLink(rhs) else {
            return lhs == rhs
        }
        return a.moduleHost == b.moduleHost && a.caseID == b.caseID && a.caseUID == b.caseUID
            && a.deloID == b.deloID && a.resolvedNew == b.resolvedNew
            && (a.srvNum ?? "1") == (b.srvNum ?? "1")
    }
}
