import Foundation
import SudrfKit

enum CaseEventSourceAdmission {
    static func nativeCardIdentity(for instance: CaseInstance,
                                   context: MovementContext) -> SourceNativeCardIdentity? {
        if let url = instance.sourceURL, let locator = SourceNativeCardLocator.vsrf(url: url) {
            return locator.identity
        }
        if instance.domain.caseInsensitiveCompare("mos-sud.ru") == .orderedSame {
            guard instance.level == .first,
                  let url = instance.sourceURL,
                  let cart = CartotekaRegistry.find(level: .magistrate, id: "adm"),
                  let locator = SourceNativeCardLocator.moscowMagistrateKoAP(
                    url: url, cartoteka: cart) else { return nil }
            return locator.identity
        }
        if instance.caseNumber == context.caseNumber,
           instance.level == context.baseInstanceLevel,
           SudrfHost.moduleHost(instance.domain) == SudrfHost.moduleHost(context.searchDomain),
           let cart = context.cartoteka {
            if let url = instance.sourceURL {
                let locator = MosGorSudRouting.isMosGorSud(domain: instance.domain)
                    ? SourceNativeCardLocator.mosgorsud(url: url, cartoteka: cart)
                    : SourceNativeCardLocator.sudrf(url: url, cartoteka: cart)
                if let identity = locator?.identity { return identity }
            } else if let caseID = context.caseID {
                return SourceNativeCardLocator.sudrf(
                    court: context.searchCourt, cartoteka: cart, caseID: caseID)?.identity
            }
        }
        guard let url = instance.sourceURL else { return nil }
        let identities = Set(CourtLevel.allCases.flatMap { CartotekaRegistry.sets(for: $0) }.compactMap { cart in
            (MosGorSudRouting.isMosGorSud(domain: instance.domain)
                ? SourceNativeCardLocator.mosgorsud(url: url, cartoteka: cart)
                : SourceNativeCardLocator.sudrf(url: url, cartoteka: cart))?.identity
        })
        return identities.count == 1 ? identities.first : nil
    }

    static func courts(in fresh: CaseMovement, context: MovementContext) -> [String: [String: String]] {
        let groups = Dictionary(grouping: fresh.sourceRefreshCoverage ?? []) {
            $0.sourceFamily + "|" + $0.courtKey
        }
        var admitted: [String: [String: String]] = [:]
        let unscopedMoscowFailure = groups["mosgorsud|mos-gorsud.ru"]?.contains {
            $0.kind != .usableSnapshot && $0.kind != .honestZero
        } == true
        for (scope, coverage) in groups {
            // A portal-wide query failure has no proven alias. Its useful rows
            // cannot qualify any Moscow court until the query is complete.
            if unscopedMoscowFailure && coverage.contains(where: { $0.sourceFamily == "mosgorsud" }) { continue }
            if scope == "mosgorsud|mos-gorsud.ru" { continue }
            guard coverage.allSatisfy({ $0.kind == .usableSnapshot || $0.kind == .honestZero }) else { continue }
            let loaded = Set(coverage.flatMap(\.loadedCardIdentities))
            if loaded.isEmpty {
                // A recognized zero can initialize a never-seen court. It must
                // never replace observations already handled for that court.
                if coverage.allSatisfy({ $0.kind == .honestZero }) { admitted[scope] = [:] }
                continue
            }
            var cards: [String: String] = [:]
            for native in loaded {
                guard native.isComplete,
                      scope == native.sourceFamily + "|" + native.courtKey else { break }
                let matches = fresh.instances.filter { instance in
                    instance.captchaFormURL == nil && instance.transientError != true
                        && instance.actFileError == nil
                        && nativeIdentity(for: instance, matching: native, context: context) == native
                }
                guard matches.count == 1, let instance = matches.first,
                      let semanticID = CaseSnapshotSourceIdentity.sourceCardID(for: instance, context: context) else { break }
                cards[native.id] = semanticID
            }
            // Do not qualify a court if any promised card is missing or several
            // native cards collapse into one ambiguous projection identity.
            if cards.count == loaded.count, Set(cards.values).count == cards.count {
                admitted[scope] = cards
            }
        }
        return admitted
    }

    static func chainIsConfirmed(in fresh: CaseMovement, context: MovementContext,
                                 admitted: [String: [String: String]]) -> Bool {
        guard let coverage = fresh.sourceRefreshCoverage, !coverage.isEmpty else { return false }
        guard coverage.allSatisfy({ item in
            if item.sourceFamily == "mosgorsud", item.courtKey == "mos-gorsud.ru" {
                return item.kind == .honestZero
            }
            return admitted[item.id] != nil
        }) else { return false }
        let ids = Set(admitted.values.flatMap { $0.values })
        return fresh.instances.allSatisfy { instance in
            guard instance.captchaFormURL == nil, instance.transientError != true,
                  instance.actFileError == nil,
                  let id = CaseSnapshotSourceIdentity.sourceCardID(for: instance, context: context) else { return false }
            return ids.contains(id)
        }
    }

    private static func nativeIdentity(for instance: CaseInstance,
                                       matching native: SourceNativeCardIdentity,
                                       context: MovementContext) -> SourceNativeCardIdentity? {
        if native.sourceFamily == "vsrf", let url = instance.sourceURL {
            return SourceNativeCardLocator.vsrf(url: url)?.identity
        }
        if native.sourceFamily == "moscow-magistrate-koap" {
            guard instance.domain.caseInsensitiveCompare("mos-sud.ru") == .orderedSame,
                  instance.level == .first,
                  let url = instance.sourceURL,
                  let cart = CartotekaRegistry.find(level: .magistrate,
                                                    id: native.cartotekaKey),
                  let identity = SourceNativeCardLocator.moscowMagistrateKoAP(
                    url: url, cartoteka: cart)?.identity,
                  identity == native else { return nil }
            return identity
        }
        let carts = CourtLevel.allCases.flatMap { CartotekaRegistry.sets(for: $0) }
            .filter { $0.id == native.cartotekaKey }
        for cart in carts {
            if let url = instance.sourceURL {
                let locator = native.sourceFamily == "mosgorsud"
                    ? SourceNativeCardLocator.mosgorsud(url: url, cartoteka: cart)
                    : SourceNativeCardLocator.sudrf(url: url, cartoteka: cart)
                if let identity = locator?.identity, identity == native { return identity }
            } else if native.sourceFamily != "mosgorsud",
                      SudrfHost.moduleHost(instance.domain) == SudrfHost.moduleHost(context.searchDomain),
                      instance.caseNumber == context.caseNumber,
                      instance.level == context.baseInstanceLevel,
                      let caseID = context.caseID, cart.id == context.cartotekaId {
                return SourceNativeCardLocator.sudrf(
                    court: context.searchCourt, cartoteka: cart, caseID: caseID)?.identity
            }
        }
        return nil
    }
}
