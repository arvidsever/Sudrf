import Foundation

/// A validated, source-native location for one court card.
///
/// Display numbers and arbitrary URLs are not identities. A locator is made
/// only when the source URL contains its native card ID and its register or
/// section agrees with the supplied court context.
public struct SourceNativeCardLocator: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let identity: SourceNativeCardIdentity

    public var id: String { identity.id }
    public var sourceFamily: String { identity.sourceFamily }
    public var courtKey: String { identity.courtKey }
    public var cartotekaKey: String { identity.cartotekaKey }
    public var sourceNativeID: String { identity.sourceNativeID }

    public init?(sourceFamily: String, courtKey: String, cartotekaKey: String,
                 sourceNativeID: String) {
        let identity = SourceNativeCardIdentity(
            sourceFamily: sourceFamily, courtKey: courtKey,
            cartotekaKey: cartotekaKey, sourceNativeID: sourceNativeID)
        guard identity.isComplete,
              !identity.sourceFamily.contains("|"),
              !identity.courtKey.contains("|"),
              !identity.cartotekaKey.contains("|"),
              !identity.sourceNativeID.contains("|") else { return nil }
        self.identity = identity
    }

    public init?(identity: SourceNativeCardIdentity) {
        self.init(sourceFamily: identity.sourceFamily, courtKey: identity.courtKey,
                  cartotekaKey: identity.cartotekaKey,
                  sourceNativeID: identity.sourceNativeID)
    }

    /// Locator for a SUDRF row whose native card ID is already parsed.
    public static func sudrf(court: Court, cartoteka: Cartoteka,
                             caseID: String) -> Self? {
        guard let url = URL(string: "https://\(court.domain)"),
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host,
              host.lowercased().hasSuffix(".sudrf.ru")
                || SudrfHost.isMSudrfHost(host),
              let caseID = clean(caseID) else { return nil }
        return Self(sourceFamily: SudrfHost.isMSudrfHost(host) ? "msudrf" : "sudrf",
                    courtKey: SudrfHost.moduleHost(host),
                    cartotekaKey: cartoteka.id,
                    sourceNativeID: caseID)
    }

    /// Locator for a validated SUDRF card URL. `courtKey` may preserve a
    /// caller's established court-code key; by default it is the canonical host.
    public static func sudrf(url: URL, cartoteka: Cartoteka,
                             courtKey: String? = nil) -> Self? {
        guard let link = try? SudrfCaseCardLink(url: url),
              let caseID = link.caseID,
              link.deloID == cartoteka.deloID,
              link.resolvedNew == cartoteka.new else { return nil }
        return Self(sourceFamily: SudrfHost.isMSudrfHost(link.host) ? "msudrf" : "sudrf",
                    courtKey: courtKey ?? link.moduleHost,
                    cartotekaKey: cartoteka.id,
                    sourceNativeID: caseID)
    }

    /// Locator for a magistrate card, whose native route and query differ from
    /// the federal `sud_delo&name_op=case` pages.
    public static func msudrf(url: URL, cartoteka: Cartoteka) -> Self? {
        guard let host = url.host?.lowercased(),
              SudrfHost.isMSudrfHost(host),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              url.path.caseInsensitiveCompare("/modules.php") == .orderedSame,
              let name = queryValue(["name"], in: url),
              name.caseInsensitiveCompare("sud_delo") == .orderedSame,
              let operation = queryValue(["op"], in: url),
              operation.caseInsensitiveCompare("cs") == .orderedSame,
              let caseID = queryValue(["case_id", "_id"], in: url),
              let deloID = queryValue(["delo_id", "_deloId"], in: url),
              deloID == cartoteka.deloID else { return nil }
        let newValue: String
        if hasQueryParameter(["new", "_new"], in: url) {
            guard let value = queryValue(["new", "_new"], in: url) else { return nil }
            newValue = value
        } else {
            newValue = "0"
        }
        guard newValue == cartoteka.new else { return nil }
        return Self(sourceFamily: "msudrf", courtKey: SudrfHost.moduleHost(host),
                    cartotekaKey: cartoteka.id, sourceNativeID: caseID)
    }

    /// Locator for a first-instance Moscow magistrate KoAP card. Its URL embeds
    /// the court unit and a UUID; both are part of the source-native identity.
    public static func moscowMagistrateKoAP(url: URL, cartoteka: Cartoteka) -> Self? {
        guard cartoteka.id == "adm", MoscowMagistrateKoAPURLPolicy.allows(url) else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 5,
              let unit = parts.first,
              unit.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
              let unitNumber = Int(unit), unitNumber > 0,
              parts[1] == "cases", parts[2] == "admin", parts[3] == "details",
              let uuid = UUID(uuidString: parts[4]),
              uuid.uuidString.caseInsensitiveCompare(parts[4]) == .orderedSame else { return nil }

        return Self(sourceFamily: MoscowMagistrateKoAPSource.family,
                    courtKey: unit, cartotekaKey: cartoteka.id,
                    sourceNativeID: uuid.uuidString.lowercased())
    }

    /// Locator for the first district-court review card linked from a Moscow
    /// magistrate KoAP case. This is specifically the RS `appeal-admin`
    /// section; MGS review cards and other RS sections are not this appeal.
    static func moscowMagistrateKoAPAppeal(url: URL) -> Self? {
        guard let (parts, alias, prefixCount) = mosgorsudPath(url: url),
              prefixCount == 2,
              MosGorSudCourtDirectory.districtCourts.contains(where: { $0.alias == alias }),
              parts.count == prefixCount + 5,
              Array(parts[prefixCount..<(prefixCount + 2)]) == ["services", "cases"],
              parts[prefixCount + 2] == "appeal-admin",
              parts[prefixCount + 3] == "details",
              let cardID = parts.last,
              let uuid = UUID(uuidString: cardID),
              uuid.uuidString.caseInsensitiveCompare(cardID) == .orderedSame else { return nil }
        return Self(sourceFamily: "mosgorsud", courtKey: alias,
                    cartotekaKey: "admj", sourceNativeID: uuid.uuidString.lowercased())
    }

    /// Locator for a published Moscow City Court KoAP review card. The exact
    /// `review-supervision` route and MGS UUID are required; a UID search row
    /// alone is not an identity or a relation to a magistrate case.
    static func moscowMagistrateKoAPReview(url: URL) -> Self? {
        guard let (parts, alias, prefixCount) = mosgorsudPath(url: url),
              alias == MosGorSudCourtDirectory.mgsAlias,
              prefixCount == 1,
              parts.count == prefixCount + 5,
              Array(parts[prefixCount..<(prefixCount + 2)]) == ["services", "cases"],
              parts[prefixCount + 2] == "review-supervision",
              parts[prefixCount + 3] == "details",
              let cardID = parts.last,
              let uuid = UUID(uuidString: cardID),
              uuid.uuidString.caseInsensitiveCompare(cardID) == .orderedSame else { return nil }
        return Self(sourceFamily: "mosgorsud", courtKey: alias,
                    cartotekaKey: "adm33", sourceNativeID: uuid.uuidString.lowercased())
    }

    /// Locator for a Moscow card URL. The court alias is part of the native
    /// scope, so cards from distinct `/rs/<alias>/` paths stay separate.
    public static func mosgorsud(url: URL, cartoteka: Cartoteka) -> Self? {
        guard let (parts, alias, prefixCount) = mosgorsudPath(url: url) else { return nil }
        guard parts.count == prefixCount + 5,
              Array(parts[prefixCount..<(prefixCount + 2)]) == ["services", "cases"],
              MosGorSudRouting.sectionSegments(cartoteka: cartoteka)
                .contains(parts[prefixCount + 2]),
              parts[prefixCount + 3] == "details",
              let cardID = clean(parts[prefixCount + 4]) else { return nil }
        return Self(sourceFamily: "mosgorsud", courtKey: alias,
                    cartotekaKey: cartoteka.id,
                    sourceNativeID: cardID)
    }

    /// The validated native court scope from a Moscow card path, even when its
    /// card ID or registry section is unusable for a positive-load identity.
    public static func mosgorsudCourtKey(url: URL) -> String? {
        mosgorsudPath(url: url)?.alias
    }

    /// Locator for a Supreme Court production card URL.
    public static func vsrf(url: URL) -> Self? {
        guard url.scheme?.lowercased() == "https",
              ["vsrf.ru", "www.vsrf.ru"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 4, parts[0] == "lk", parts[1] == "practice",
              [VSRFCardSection.cases.rawValue, VSRFCardSection.appeals.rawValue,
               VSRFCardSection.claims.rawValue].contains(parts[2]),
              let productionID = clean(parts[3]) else { return nil }
        return Self(sourceFamily: "vsrf", courtKey: "vsrf.ru",
                    cartotekaKey: parts[2], sourceNativeID: productionID)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains("|"), !value.contains("/") else { return nil }
        return value
    }

    private static func queryValue(_ names: [String], in url: URL) -> String? {
        let accepted = Set(names.map { $0.lowercased() })
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let matching = items.filter { accepted.contains($0.name.lowercased()) }
        guard !matching.isEmpty else { return nil }
        var values: [String] = []
        for item in matching {
            guard let value = clean(item.value), value == item.value else { return nil }
            values.append(value)
        }
        guard let value = values.first, values.allSatisfy({ $0 == value }) else { return nil }
        return value
    }

    private static func hasQueryParameter(_ names: [String], in url: URL) -> Bool {
        let accepted = Set(names.map { $0.lowercased() })
        return (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .contains { accepted.contains($0.name.lowercased()) }
    }

    private static func mosgorsudPath(url: URL) -> (parts: [String], alias: String,
                                                     prefixCount: Int)? {
        guard url.scheme?.lowercased() == "https",
              ["mos-gorsud.ru", "www.mos-gorsud.ru"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.first == MosGorSudCourtDirectory.mgsAlias {
            return (parts, MosGorSudCourtDirectory.mgsAlias, 1)
        }
        guard parts.count >= 2, parts[0] == "rs",
              MosGorSudCourtDirectory.districtCourts.contains(where: {
                  $0.alias == parts[1]
              }) else { return nil }
        return (parts, parts[1], 2)
    }
}

/// Cards positively fetched during one movement refresh, grouped by source court.
/// A missing coverage record means unknown. Only `usableSnapshot` is full;
/// `honestZero` never deletes a previously known card.
public struct MovementCourtCoverage: Codable, Equatable, Sendable, Identifiable {
    public let sourceFamily: String
    public let courtKey: String
    public let kind: SourceOutcomeKind
    public let loadedCardIdentities: [SourceNativeCardIdentity]

    public var id: String { "\(sourceFamily)|\(courtKey)" }
    public var isFull: Bool { kind == .usableSnapshot }

    public init(sourceFamily: String, courtKey: String, kind: SourceOutcomeKind,
                loadedCardIdentities: [SourceNativeCardIdentity] = []) {
        let family = sourceFamily.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let court = courtKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.sourceFamily = family
        self.courtKey = court
        self.kind = kind
        self.loadedCardIdentities = Array(Set(loadedCardIdentities.filter {
            $0.isComplete && $0.sourceFamily == family && $0.courtKey == court
        })).sorted { $0.id < $1.id }
    }

    public func contains(card identity: SourceNativeCardIdentity) -> Bool {
        loadedCardIdentities.contains(identity)
    }
}

struct MovementCoverageAccumulator {
    private struct Entry {
        let sourceFamily: String
        let courtKey: String
        var kind: SourceOutcomeKind
        var loaded = Set<SourceNativeCardIdentity>()
    }

    private var entries: [String: Entry] = [:]

    mutating func recordLoaded(_ identity: SourceNativeCardIdentity) {
        guard identity.isComplete else { return }
        let key = key(identity.sourceFamily, identity.courtKey)
        var entry = entries[key] ?? Entry(sourceFamily: identity.sourceFamily,
                                          courtKey: identity.courtKey,
                                          kind: .usableSnapshot)
        if entry.kind == .honestZero { entry.kind = .usableSnapshot }
        entry.loaded.insert(identity)
        entries[key] = entry
    }

    mutating func recordLoaded(_ locator: SourceNativeCardLocator?) {
        guard let locator else { return }
        recordLoaded(locator.identity)
    }

    mutating func mark(_ kind: SourceOutcomeKind,
                       sourceFamily: String, courtKey: String) {
        let family = sourceFamily.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let court = courtKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !family.isEmpty, !court.isEmpty else { return }
        let key = key(family, court)
        var entry = entries[key] ?? Entry(sourceFamily: family, courtKey: court, kind: kind)
        switch kind {
        case .usableSnapshot:
            if entry.loaded.isEmpty, entry.kind == .honestZero { entry.kind = kind }
        case .honestZero:
            if entry.loaded.isEmpty, entry.kind == .usableSnapshot { entry.kind = kind }
        default:
            // A later card rescue adds positive evidence but cannot clear an
            // earlier listing or card failure in this source court.
            entry.kind = kind == .partial ? .partial : kind
        }
        entries[key] = entry
    }

    mutating func markPartial(sourceFamily: String, courtKey: String) {
        mark(.partial, sourceFamily: sourceFamily, courtKey: courtKey)
    }

    mutating func merge(_ coverage: [MovementCourtCoverage]?) {
        for item in coverage ?? [] {
            mark(item.kind, sourceFamily: item.sourceFamily, courtKey: item.courtKey)
            for identity in item.loadedCardIdentities { recordLoaded(identity) }
        }
    }

    var values: [MovementCourtCoverage] {
        entries.values.map { entry in
            MovementCourtCoverage(
                sourceFamily: entry.sourceFamily,
                courtKey: entry.courtKey,
                kind: entry.kind,
                loadedCardIdentities: Array(entry.loaded))
        }.sorted { $0.id < $1.id }
    }

    private func key(_ sourceFamily: String, _ courtKey: String) -> String {
        "\(sourceFamily)|\(courtKey)"
    }
}
