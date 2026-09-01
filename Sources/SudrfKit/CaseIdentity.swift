import Foundation

// MARK: - Source identity

/// Identity of one card in a source-native register.
///
/// The displayed case number and URL are deliberately not part of this key.
/// A source may change either of them while keeping the same card.  `case_uid`
/// from a SUDRF link is a source navigation identifier, not a judicial UID;
/// callers may keep it on `SourceCardObservation.caseUID`, but it is never
/// used by the reconciler as a judicial identifier.
public struct SourceNativeCardIdentity: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let sourceFamily: String
    public let courtKey: String
    public let cartotekaKey: String
    public let sourceNativeID: String

    public var id: String {
        [sourceFamily, courtKey, cartotekaKey, sourceNativeID]
            .joined(separator: "|")
    }

    /// The scope is complete enough for exact source-card matching.
    public var isComplete: Bool {
        !sourceFamily.isEmpty && !courtKey.isEmpty
            && !cartotekaKey.isEmpty && !sourceNativeID.isEmpty
    }

    public var court: String { courtKey }
    public var cartoteka: String { cartotekaKey }

    public init(sourceFamily: String, courtKey: String, cartotekaKey: String,
                sourceNativeID: String) {
        self.sourceFamily = Self.scopeValue(sourceFamily)
        self.courtKey = Self.scopeValue(courtKey)
        self.cartotekaKey = Self.scopeValue(cartotekaKey)
        self.sourceNativeID = sourceNativeID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Convenience spelling for source adapters that call these components
    /// simply source/court/cartoteka.
    public init(sourceFamily: String, court: String, cartoteka: String,
                sourceNativeID: String) {
        self.init(sourceFamily: sourceFamily, courtKey: court,
                  cartotekaKey: cartoteka, sourceNativeID: sourceNativeID)
    }

    private static func scopeValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Judicial UID

/// Structural state of a value presented as a judicial UID.
public enum JudicialUIDValidity: String, Codable, Equatable, Sendable {
    case empty
    case partial
    case invalid
    case valid
}

/// A judicial UID observation, retaining the source spelling for diagnostics.
///
/// SUDRF judicial UIDs currently have the shape
/// `DDLLDDDD-DD-DDDD-DDDDDD-DD` (22 canonical characters).  Separators and
/// whitespace are ignored for comparison, so a compact spelling is accepted;
/// the segment widths and character classes are still checked.  This is a
/// structural check, not a checksum calculation.
public struct JudicialUIDObservation: Codable, Equatable, Sendable {
    public let rawValue: String
    public let normalizedValue: String?
    public let validity: JudicialUIDValidity
    public let provenance: SourceProvenance

    public var raw: String { rawValue }
    public var normalized: String? { normalizedValue }
    public var observedAt: Date { provenance.observedAt }
    public var isStructurallyValid: Bool { validity == .valid }
    public var isMatchable: Bool { isStructurallyValid && normalizedValue != nil }

    public init(rawValue: String?, provenance: SourceProvenance) {
        let raw = rawValue ?? ""
        let normalized = Self.normalize(raw)
        self.rawValue = raw
        self.normalizedValue = normalized.isEmpty ? nil : normalized
        self.validity = Self.classify(normalized)
        self.provenance = provenance
    }

    public init(raw: String?, provenance: SourceProvenance) {
        self.init(rawValue: raw, provenance: provenance)
    }

    /// Normalization intentionally does not know about `case_uid` links.  It
    /// is only the canonical spelling operation for a judicial UID field.
    public static func normalize(_ raw: String) -> String {
        raw.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func validity(of raw: String?) -> JudicialUIDValidity {
        classify(normalize(raw ?? ""))
    }

    private static let expectedLength = 22

    private static func classify(_ normalized: String) -> JudicialUIDValidity {
        let chars = Array(normalized)
        guard !chars.isEmpty else { return .empty }

        let prefixIsValid = chars.enumerated().allSatisfy { index, character in
            guard index < expectedLength else { return false }
            return accepts(character, at: index)
        }

        if chars.count < expectedLength {
            return prefixIsValid ? .partial : .invalid
        }
        guard chars.count == expectedLength, prefixIsValid else { return .invalid }
        return .valid
    }

    private static func accepts(_ character: Character, at index: Int) -> Bool {
        switch index {
        case 2, 3:
            return isUIDLetter(character)
        default:
            return isASCIIDigit(character)
        }
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        return (48...57).contains(scalar.value)
    }

    private static func isUIDLetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (65...90).contains(value)       // Latin A-Z
            || (1040...1071).contains(value)  // Cyrillic А-Я
            || value == 1025                   // Cyrillic Ё
    }
}

// MARK: - Official relations and source observations

/// Why a source is allowed to relate one card to another.
public enum OfficialCardRelationKind: String, Codable, Equatable, Sendable {
    case predecessor
    case registry
    case sourceNative
}

/// An official, source-native relation to an already known card or UID.
///
/// `outcome` is deliberately carried with the evidence.  Only a usable
/// snapshot is allowed to establish continuity; honest-zero, partial and
/// error outcomes are retained by their caller as attempts and are ignored by
/// identity reconciliation.
public struct OfficialCardRelation: Codable, Equatable, Sendable, Identifiable {
    public let kind: OfficialCardRelationKind
    public let relatedCard: SourceNativeCardIdentity?
    public let relatedUID: JudicialUIDObservation?
    public let outcome: SourceOutcomeKind
    public let provenance: SourceProvenance

    public var id: String {
        [kind.rawValue, relatedCard?.id ?? "", relatedUID?.normalizedValue ?? ""]
            .joined(separator: "|")
    }

    public var isUsable: Bool {
        guard outcome == .usableSnapshot else { return false }
        let cardIsUsable = relatedCard?.isComplete == true
        let uidIsUsable = relatedUID?.isMatchable == true
        return cardIsUsable || uidIsUsable
    }

    public init(kind: OfficialCardRelationKind,
                relatedCard: SourceNativeCardIdentity? = nil,
                relatedUID: JudicialUIDObservation? = nil,
                outcome: SourceOutcomeKind = .usableSnapshot,
                provenance: SourceProvenance) {
        self.kind = kind
        self.relatedCard = relatedCard
        self.relatedUID = relatedUID
        self.outcome = outcome
        self.provenance = provenance
    }

    public init(kind: OfficialCardRelationKind,
                relatedCard: SourceNativeCardIdentity,
                provenance: SourceProvenance) {
        self.init(kind: kind, relatedCard: relatedCard,
                  outcome: .usableSnapshot, provenance: provenance)
    }
}

/// One normalized card observation from a source adapter.
public struct SourceCardObservation: Codable, Equatable, Sendable {
    public let cardIdentity: SourceNativeCardIdentity
    /// SUDRF's `case_uid` link parameter.  It is kept separate from
    /// `judicialUID` and is never used for cross-card case matching.
    public let caseUID: String?
    public let caseNumber: String?
    public let judicialUID: JudicialUIDObservation?
    public let officialRelations: [OfficialCardRelation]
    public let outcome: SourceOutcomeKind
    public let provenance: SourceProvenance

    public var identity: SourceNativeCardIdentity { cardIdentity }
    public var sourceLinkUID: String? { caseUID }
    public var isUsableSnapshot: Bool { outcome == .usableSnapshot }

    public init(cardIdentity: SourceNativeCardIdentity,
                caseUID: String? = nil,
                caseNumber: String? = nil,
                judicialUID: JudicialUIDObservation? = nil,
                officialRelations: [OfficialCardRelation] = [],
                outcome: SourceOutcomeKind = .usableSnapshot,
                provenance: SourceProvenance) {
        self.cardIdentity = cardIdentity
        self.caseUID = Self.clean(caseUID)
        self.caseNumber = Self.clean(caseNumber)
        self.judicialUID = judicialUID
        self.officialRelations = officialRelations
        self.outcome = outcome
        self.provenance = provenance
    }

    public var judicialUIDObservation: JudicialUIDObservation? { judicialUID }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - History bindings

/// A display-number observation attached to one source card.
public struct CaseNumberBinding: Codable, Equatable, Sendable, Identifiable {
    public let normalizedValue: String
    public var rawValue: String
    public let cardIdentity: SourceNativeCardIdentity
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    public var provenance: SourceProvenance

    public var id: String { "\(cardIdentity.id)|\(normalizedValue)" }
    public var raw: String { rawValue }
    public var normalized: String { normalizedValue }
    public var card: SourceNativeCardIdentity { cardIdentity }

    public init(rawValue: String, cardIdentity: SourceNativeCardIdentity,
                provenance: SourceProvenance) {
        self.rawValue = rawValue
        self.normalizedValue = Self.normalize(rawValue)
        self.cardIdentity = cardIdentity
        self.firstObservedAt = provenance.observedAt
        self.lastObservedAt = provenance.observedAt
        self.provenance = provenance
    }

    mutating func merge(_ other: CaseNumberBinding) {
        firstObservedAt = min(firstObservedAt, other.firstObservedAt)
        if other.lastObservedAt >= lastObservedAt {
            lastObservedAt = other.lastObservedAt
            rawValue = other.rawValue
            provenance = other.provenance
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "Е")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

public typealias CaseNumberObservation = CaseNumberBinding

/// A valid judicial UID attached to the source card where it was observed.
public struct JudicialUIDBinding: Codable, Equatable, Sendable, Identifiable {
    public let normalizedValue: String
    public var rawValue: String
    public let cardIdentity: SourceNativeCardIdentity
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    public var provenance: SourceProvenance

    public var id: String { "\(cardIdentity.id)|\(normalizedValue)" }
    public var raw: String { rawValue }
    public var normalized: String { normalizedValue }
    public var card: SourceNativeCardIdentity { cardIdentity }

    public init(observation: JudicialUIDObservation,
                cardIdentity: SourceNativeCardIdentity) {
        precondition(observation.isMatchable,
                     "JudicialUIDBinding requires a structurally valid UID")
        self.normalizedValue = observation.normalizedValue!
        self.rawValue = observation.rawValue
        self.cardIdentity = cardIdentity
        self.firstObservedAt = observation.observedAt
        self.lastObservedAt = observation.observedAt
        self.provenance = observation.provenance
    }

    mutating func merge(_ other: JudicialUIDBinding) {
        firstObservedAt = min(firstObservedAt, other.firstObservedAt)
        if other.lastObservedAt >= lastObservedAt {
            lastObservedAt = other.lastObservedAt
            rawValue = other.rawValue
            provenance = other.provenance
        }
    }
}

// MARK: - Logical case state

/// One source-native card node in a logical case graph.
public struct LogicalCaseCard: Codable, Equatable, Sendable, Identifiable {
    public let identity: SourceNativeCardIdentity
    public var caseUID: String?
    public var caseUIDHistory: [String]
    public var currentCaseNumber: String?
    public let firstObservedAt: Date
    public var lastObservedAt: Date
    public var provenance: SourceProvenance

    public var id: String { identity.id }
    public var cardIdentity: SourceNativeCardIdentity { identity }
    public var caseNumber: String? { currentCaseNumber }

    init(observation: SourceCardObservation) {
        identity = observation.cardIdentity
        caseUID = observation.caseUID
        caseUIDHistory = observation.caseUID.map { [$0] } ?? []
        currentCaseNumber = observation.caseNumber
        firstObservedAt = observation.provenance.observedAt
        lastObservedAt = observation.provenance.observedAt
        provenance = observation.provenance
    }

    mutating func apply(_ observation: SourceCardObservation) {
        let observedAt = observation.provenance.observedAt
        if let sourceUID = observation.caseUID {
            if !caseUIDHistory.contains(sourceUID) { caseUIDHistory.append(sourceUID) }
            if observedAt >= lastObservedAt { caseUID = sourceUID }
        }
        if observedAt >= lastObservedAt, let number = observation.caseNumber {
            currentCaseNumber = number
        }
        lastObservedAt = max(lastObservedAt, observedAt)
        if observedAt >= provenance.observedAt { provenance = observation.provenance }
    }

    mutating func merge(_ other: LogicalCaseCard) {
        for value in other.caseUIDHistory where !caseUIDHistory.contains(value) {
            caseUIDHistory.append(value)
        }
        if let value = other.caseUID, !caseUIDHistory.contains(value) {
            caseUIDHistory.append(value)
        }
        if other.lastObservedAt >= lastObservedAt {
            caseUID = other.caseUID ?? caseUID
            currentCaseNumber = other.currentCaseNumber ?? currentCaseNumber
            provenance = other.provenance
        }
        lastObservedAt = max(lastObservedAt, other.lastObservedAt)
    }
}

/// Persistent, source-independent identity graph for one logical case.
public struct LogicalCaseState: Codable, Equatable, Sendable, Identifiable {
    public let logicalCaseID: UUID
    public var cards: [LogicalCaseCard]
    public var uidBindings: [JudicialUIDBinding]
    public var numberHistory: [CaseNumberBinding]
    public var officialRelations: [OfficialCardRelation]
    /// Last usable source provenance applied to this graph.
    public var provenance: SourceProvenance?

    public var id: UUID { logicalCaseID }
    public var cardNodes: [LogicalCaseCard] { cards }
    public var judicialUIDBindings: [JudicialUIDBinding] { uidBindings }
    public var caseNumberHistory: [CaseNumberBinding] { numberHistory }
    public var judicialUIDs: [String] {
        Array(Set(uidBindings.map(\.normalizedValue))).sorted()
    }

    public init(logicalCaseID: UUID = UUID(),
                cards: [LogicalCaseCard] = [],
                uidBindings: [JudicialUIDBinding] = [],
                numberHistory: [CaseNumberBinding] = [],
                officialRelations: [OfficialCardRelation] = [],
                provenance: SourceProvenance? = nil) {
        self.logicalCaseID = logicalCaseID
        self.cards = cards
        self.uidBindings = uidBindings
        self.numberHistory = numberHistory
        self.officialRelations = officialRelations
        self.provenance = provenance
    }

    public init(logicalCaseID: UUID = UUID(), observation: SourceCardObservation) {
        self.init(logicalCaseID: logicalCaseID)
        _ = apply(observation)
    }

    public func contains(card identity: SourceNativeCardIdentity) -> Bool {
        cards.contains { $0.identity == identity }
    }

    public func contains(judicialUID normalizedValue: String) -> Bool {
        uidBindings.contains { $0.normalizedValue == normalizedValue }
    }

    /// Apply only a usable card snapshot.  Registry error/partial/empty
    /// outcomes therefore cannot erase or mutate an existing identity graph.
    @discardableResult
    public mutating func apply(_ observation: SourceCardObservation) -> Bool {
        guard observation.outcome == .usableSnapshot,
              observation.cardIdentity.isComplete else { return false }

        if let index = cards.firstIndex(where: { $0.identity == observation.cardIdentity }) {
            cards[index].apply(observation)
        } else {
            cards.append(LogicalCaseCard(observation: observation))
        }

        if let number = observation.caseNumber {
            let binding = CaseNumberBinding(rawValue: number,
                                            cardIdentity: observation.cardIdentity,
                                            provenance: observation.provenance)
            if let index = numberHistory.firstIndex(where: { $0.id == binding.id }) {
                numberHistory[index].merge(binding)
            } else {
                numberHistory.append(binding)
            }
        }

        if let uid = observation.judicialUID, uid.isMatchable {
            let binding = JudicialUIDBinding(observation: uid,
                                             cardIdentity: observation.cardIdentity)
            if let index = uidBindings.firstIndex(where: { $0.id == binding.id }) {
                uidBindings[index].merge(binding)
            } else {
                uidBindings.append(binding)
            }
        }

        for relation in observation.officialRelations where relation.isUsable {
            if !officialRelations.contains(where: { $0.id == relation.id }) {
                officialRelations.append(relation)
            }
        }

        if provenance == nil || observation.provenance.observedAt >= provenance!.observedAt {
            provenance = observation.provenance
        }
        return true
    }

    /// Merge another graph into this one while preserving the receiver's
    /// immutable logical-case UUID.  The reconciler uses this when legacy
    /// records violate the one-UID/one-logical-case invariant.
    public mutating func merge(_ other: LogicalCaseState) {
        for card in other.cards {
            if let index = cards.firstIndex(where: { $0.identity == card.identity }) {
                cards[index].merge(card)
            } else {
                cards.append(card)
            }
        }
        for binding in other.uidBindings {
            if let index = uidBindings.firstIndex(where: { $0.id == binding.id }) {
                uidBindings[index].merge(binding)
            } else {
                uidBindings.append(binding)
            }
        }
        for binding in other.numberHistory {
            if let index = numberHistory.firstIndex(where: { $0.id == binding.id }) {
                numberHistory[index].merge(binding)
            } else {
                numberHistory.append(binding)
            }
        }
        for relation in other.officialRelations where !officialRelations.contains(where: { $0.id == relation.id }) {
            officialRelations.append(relation)
        }
        if let otherProvenance = other.provenance,
           provenance == nil || otherProvenance.observedAt >= provenance!.observedAt {
            provenance = otherProvenance
        }
        cards.sort { $0.id < $1.id }
        uidBindings.sort { $0.id < $1.id }
        numberHistory.sort { $0.id < $1.id }
        officialRelations.sort { $0.id < $1.id }
    }
}

// MARK: - Deterministic reconciliation

public enum ReconciliationDecisionKind: String, Codable, Equatable, Sendable {
    case sameCard
    case linkedExistingCase
    case newCase
    case candidate
}

public enum ReconciliationEvidence: String, Codable, Equatable, Sendable {
    case exactCard
    case matchingJudicialUID
    case officialRelation
    case none
}

public struct LogicalCaseReconciliationDecision: Codable, Equatable, Sendable {
    public let kind: ReconciliationDecisionKind
    public let logicalCaseID: UUID?
    public let evidence: ReconciliationEvidence
    public let mutated: Bool

    public init(kind: ReconciliationDecisionKind, logicalCaseID: UUID? = nil,
                evidence: ReconciliationEvidence = .none, mutated: Bool = false) {
        self.kind = kind
        self.logicalCaseID = logicalCaseID
        self.evidence = evidence
        self.mutated = mutated
    }

    public var isCandidate: Bool { kind == .candidate }
}

public struct LogicalCaseReconciliationResult: Sendable {
    public let decision: LogicalCaseReconciliationDecision
    public let state: LogicalCaseState?

    public init(decision: LogicalCaseReconciliationDecision,
                state: LogicalCaseState?) {
        self.decision = decision
        self.state = state
    }
}

/// Stateless reconciler shared by manual discovery and background refresh.
public struct LogicalCaseReconciler: Sendable {
    public init() {}

    public static func reconcileAndUpsert(
        _ observation: SourceCardObservation,
        in states: inout [LogicalCaseState]
    ) -> LogicalCaseReconciliationResult {
        guard observation.outcome == .usableSnapshot,
              observation.cardIdentity.isComplete else {
            return result(for: LogicalCaseReconciliationDecision(
                kind: .candidate, evidence: .none), in: states)
        }

        let normalizedUID = observation.judicialUID?.isMatchable == true
            ? observation.judicialUID?.normalizedValue
            : nil
        let usableRelations = observation.officialRelations.filter(\.isUsable)

        var matchingIndices = Set<Int>()
        var exactCardIndices = Set<Int>()
        var uidMatchIndices = Set<Int>()
        var relationMatchIndices = Set<Int>()

        for (index, state) in states.enumerated() {
            if state.contains(card: observation.cardIdentity) {
                matchingIndices.insert(index)
                exactCardIndices.insert(index)
            }
            if let normalizedUID, state.contains(judicialUID: normalizedUID) {
                matchingIndices.insert(index)
                uidMatchIndices.insert(index)
            }
            if usableRelations.contains(where: { relation in
                relation.relatedCard.map { state.contains(card: $0) } == true
                    || relation.relatedUID?.isMatchable == true
                    && relation.relatedUID?.normalizedValue.map {
                        state.contains(judicialUID: $0)
                    } == true
            }) {
                matchingIndices.insert(index)
                relationMatchIndices.insert(index)
            }
            // Official links are directional in their source presentation
            // (for example, a current card names its predecessor), but they
            // establish one logical case whichever card reaches the store
            // first. The display number never takes part in this match.
            if state.officialRelations.contains(where: { relation in
                relation.isUsable
                    && (relation.relatedCard == observation.cardIdentity
                        || relation.relatedUID?.isMatchable == true
                        && relation.relatedUID?.normalizedValue == normalizedUID)
            }) {
                matchingIndices.insert(index)
                relationMatchIndices.insert(index)
            }
        }

        if matchingIndices.isEmpty {
            let state = LogicalCaseState(observation: observation)
            states.append(state)
            let decision = LogicalCaseReconciliationDecision(
                kind: .newCase, logicalCaseID: state.logicalCaseID,
                evidence: .none,
                mutated: true)
            return LogicalCaseReconciliationResult(decision: decision, state: state)
        }

        // If corrupt legacy data put one valid UID into multiple records,
        // choose the smallest UUID as survivor.  The choice is independent of
        // array order and the other graphs are folded into it atomically.
        let survivorIndex = matchingIndices.min { lhs, rhs in
            states[lhs].logicalCaseID.uuidString < states[rhs].logicalCaseID.uuidString
        }!
        let survivorID = states[survivorIndex].logicalCaseID
        for index in matchingIndices.sorted(by: >) where index != survivorIndex {
            let other = states.remove(at: index)
            let adjustedSurvivorIndex = states.firstIndex { $0.logicalCaseID == survivorID }!
            states[adjustedSurvivorIndex].merge(other)
        }

        let finalIndex = states.firstIndex { $0.logicalCaseID == survivorID }!
        _ = states[finalIndex].apply(observation)

        let kind: ReconciliationDecisionKind
        let evidence: ReconciliationEvidence
        if !exactCardIndices.isEmpty && matchingIndices == exactCardIndices {
            kind = .sameCard
            evidence = .exactCard
        } else if !relationMatchIndices.isEmpty {
            kind = .linkedExistingCase
            evidence = .officialRelation
        } else if !uidMatchIndices.isEmpty {
            kind = .linkedExistingCase
            evidence = .matchingJudicialUID
        } else {
            kind = .sameCard
            evidence = .exactCard
        }

        let decision = LogicalCaseReconciliationDecision(
            kind: kind, logicalCaseID: survivorID, evidence: evidence, mutated: true)
        return LogicalCaseReconciliationResult(decision: decision,
                                               state: states[finalIndex])
    }

    public static func reconcileAndUpsert(
        observation: SourceCardObservation,
        in states: inout [LogicalCaseState]
    ) -> LogicalCaseReconciliationResult {
        reconcileAndUpsert(observation, in: &states)
    }

    public func reconcileAndUpsert(
        _ observation: SourceCardObservation,
        in states: inout [LogicalCaseState]
    ) -> LogicalCaseReconciliationResult {
        Self.reconcileAndUpsert(observation, in: &states)
    }

    private static func result(
        for decision: LogicalCaseReconciliationDecision,
        in states: [LogicalCaseState]
    ) -> LogicalCaseReconciliationResult {
        let state = decision.logicalCaseID.flatMap { id in
            states.first { $0.logicalCaseID == id }
        }
        return LogicalCaseReconciliationResult(decision: decision, state: state)
    }
}
