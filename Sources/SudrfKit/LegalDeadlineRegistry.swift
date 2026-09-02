import Foundation

/// The machine-readable legal-deadline catalog built from Docs/legal-deadlines.
///
/// The generated JSON is intentionally loaded at runtime.  Rule names, formulae,
/// sources, and notes therefore cannot drift into a second hand-maintained list
/// in the application.
public struct LegalDeadlineRegistry: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sources: [LegalDeadlineSource]
    public let coreRules: [LegalDeadlineRule]
    public let policies: [LegalDeadlinePolicy]
    public let triggerDependencies: [DeadlineTriggerRequirement]
    public let constraints: [LegalDeadlineConstraint]
    public let exclusions: [LegalDeadlineExclusion]
    public let openQuestions: [LegalDeadlineOpenQuestion]

    public init(
        schemaVersion: Int = 1,
        sources: [LegalDeadlineSource],
        coreRules: [LegalDeadlineRule],
        policies: [LegalDeadlinePolicy],
        triggerDependencies: [DeadlineTriggerRequirement],
        constraints: [LegalDeadlineConstraint] = [],
        exclusions: [LegalDeadlineExclusion] = [],
        openQuestions: [LegalDeadlineOpenQuestion] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sources = sources
        self.coreRules = coreRules
        self.policies = policies
        self.triggerDependencies = triggerDependencies
        self.constraints = constraints
        self.exclusions = exclusions
        self.openQuestions = openQuestions
    }

    /// Loads the packaged resource through the app-safe resource lookup.
    public static func load() throws -> Self {
        guard let url = PackagedResource.url("LegalDeadlineRegistry", withExtension: "json") else {
            throw LegalDeadlineRegistryError.resourceNotFound
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// Compatibility name for consumers that call the catalog simply `rules`.
    public var rules: [LegalDeadlineRule] { coreRules }

    public func rule(id: String) -> LegalDeadlineRule? {
        coreRules.first { $0.ruleID == id }
    }

    public func policy(id: String) -> LegalDeadlinePolicy? {
        policies.first { $0.policyID == id }
    }
}

public enum LegalDeadlineRegistryError: Error, LocalizedError, Sendable {
    case resourceNotFound

    public var errorDescription: String? {
        switch self {
        case .resourceNotFound:
            return "Реестр процессуальных сроков не найден в ресурсах приложения"
        }
    }
}

public struct LegalDeadlineSource: Codable, Hashable, Sendable {
    public let code: String
    public let document: String
    public let revision: Int
    public let sourceHash: String
    public let markdownSha256: String?
    public let title: String?
    public let date: String?
    public let scope: String?

    public init(
        code: String,
        document: String,
        revision: Int,
        sourceHash: String,
        markdownSha256: String? = nil,
        title: String? = nil,
        date: String? = nil,
        scope: String? = nil
    ) {
        self.code = code
        self.document = document
        self.revision = revision
        self.sourceHash = sourceHash
        self.markdownSha256 = markdownSha256
        self.title = title
        self.date = date
        self.scope = scope
    }
}

public struct LegalDeadlineRule: Codable, Hashable, Sendable {
    public let ruleID: String
    public let stage: String
    public let actContext: String
    public let duration: LegalDeadlineDuration
    public let durationText: String?
    public let trigger: String
    public let source: String
    public let priority: String
    public let notes: String?
    public let code: String
    public let document: String
    public let revision: Int
    public let sourceHash: String

    public var ruleId: String { ruleID }
    public var sourceCode: String { code }

    public init(
        ruleID: String,
        stage: String,
        actContext: String,
        duration: LegalDeadlineDuration,
        durationText: String? = nil,
        trigger: String,
        source: String,
        priority: String,
        notes: String? = nil,
        code: String,
        document: String,
        revision: Int,
        sourceHash: String
    ) {
        self.ruleID = ruleID
        self.stage = stage
        self.actContext = actContext
        self.duration = duration
        self.durationText = durationText
        self.trigger = trigger
        self.source = source
        self.priority = priority
        self.notes = notes
        self.code = code
        self.document = document
        self.revision = revision
        self.sourceHash = sourceHash
    }

    private enum CodingKeys: String, CodingKey {
        case ruleID = "rule_id"
        case stage
        case actContext = "act_context"
        case duration
        case durationText
        case trigger
        case source
        case priority
        case notes
        case code
        case document
        case revision
        case sourceHash
    }
}

public struct LegalDeadlineDuration: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case calendarDays
        case calendarSutki
        case workingDays
        case months
        case years
        case relative
        case none
    }

    /// The numeric unit used by a relative expression, if one exists.
    public enum Unit: String, Codable, Hashable, Sendable {
        case calendarDays
        case calendarSutki
        case workingDays
        case months
        case years
    }

    public let kind: Kind
    public let value: Int?
    public let unit: Unit?
    public let raw: String?
    public let isUpperBound: Bool
    public let relation: String?
    public let reference: String?
    public let qualifier: String?

    public var count: Int? { value }
    public var number: Int? { value }

    public init(
        kind: Kind,
        value: Int? = nil,
        unit: Unit? = nil,
        raw: String? = nil,
        isUpperBound: Bool = false,
        relation: String? = nil,
        reference: String? = nil,
        qualifier: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.unit = unit
        self.raw = raw
        self.isUpperBound = isUpperBound
        self.relation = relation
        self.reference = reference
        self.qualifier = qualifier
    }
}

public struct LegalDeadlinePolicy: Codable, Hashable, Sendable {
    public let policyID: String
    public let rule: String
    public let source: String
    public let code: String
    public let document: String
    public let revision: Int
    public let sourceHash: String

    public var policyId: String { policyID }
    public var id: String { policyID }

    public init(
        policyID: String,
        rule: String,
        source: String,
        code: String,
        document: String,
        revision: Int,
        sourceHash: String
    ) {
        self.policyID = policyID
        self.rule = rule
        self.source = source
        self.code = code
        self.document = document
        self.revision = revision
        self.sourceHash = sourceHash
    }

    private enum CodingKeys: String, CodingKey {
        case policyID = "policy_id"
        case rule
        case source
        case code
        case document
        case revision
        case sourceHash
    }
}

public struct DeadlineTriggerRequirement: Codable, Hashable, Sendable {
    public let dependencyID: String
    public let ruleID: String?
    public let context: String
    public let duration: String?
    public let normativeTime: String?
    public let trigger: String?
    public let reliableFact: String?
    public let reliableEvent: String?
    public let significance: String?
    public let source: String
    public let notes: String?
    public let code: String
    public let document: String
    public let revision: Int
    public let sourceHash: String

    public var dependencyId: String { dependencyID }
    public var id: String { dependencyID }

    public init(
        dependencyID: String,
        ruleID: String? = nil,
        context: String,
        duration: String? = nil,
        normativeTime: String? = nil,
        trigger: String? = nil,
        reliableFact: String? = nil,
        reliableEvent: String? = nil,
        significance: String? = nil,
        source: String,
        notes: String? = nil,
        code: String,
        document: String,
        revision: Int,
        sourceHash: String
    ) {
        self.dependencyID = dependencyID
        self.ruleID = ruleID
        self.context = context
        self.duration = duration
        self.normativeTime = normativeTime
        self.trigger = trigger
        self.reliableFact = reliableFact
        self.reliableEvent = reliableEvent
        self.significance = significance
        self.source = source
        self.notes = notes
        self.code = code
        self.document = document
        self.revision = revision
        self.sourceHash = sourceHash
    }

    private enum CodingKeys: String, CodingKey {
        case dependencyID = "dependency_id"
        case ruleID = "rule_id"
        case context
        case duration
        case normativeTime
        case normativeMax = "normative_max"
        case trigger
        case reliableFact = "reliable_fact"
        case reliableEvent = "reliable_event"
        case significance
        case source
        case notes
        case code
        case document
        case revision
        case sourceHash
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dependencyID = try values.decode(String.self, forKey: .dependencyID)
        ruleID = try values.decodeIfPresent(String.self, forKey: .ruleID)
        context = try values.decode(String.self, forKey: .context)
        duration = try values.decodeIfPresent(String.self, forKey: .duration)
        normativeTime = try values.decodeIfPresent(String.self, forKey: .normativeTime)
            ?? (try values.decodeIfPresent(String.self, forKey: .normativeMax))
        trigger = try values.decodeIfPresent(String.self, forKey: .trigger)
        reliableFact = try values.decodeIfPresent(String.self, forKey: .reliableFact)
        reliableEvent = try values.decodeIfPresent(String.self, forKey: .reliableEvent)
        significance = try values.decodeIfPresent(String.self, forKey: .significance)
        source = try values.decode(String.self, forKey: .source)
        notes = try values.decodeIfPresent(String.self, forKey: .notes)
        code = try values.decode(String.self, forKey: .code)
        document = try values.decode(String.self, forKey: .document)
        revision = try values.decode(Int.self, forKey: .revision)
        sourceHash = try values.decode(String.self, forKey: .sourceHash)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(dependencyID, forKey: .dependencyID)
        try values.encodeIfPresent(ruleID, forKey: .ruleID)
        try values.encode(context, forKey: .context)
        try values.encodeIfPresent(duration, forKey: .duration)
        try values.encodeIfPresent(normativeTime, forKey: .normativeTime)
        try values.encodeIfPresent(trigger, forKey: .trigger)
        try values.encodeIfPresent(reliableFact, forKey: .reliableFact)
        try values.encodeIfPresent(reliableEvent, forKey: .reliableEvent)
        try values.encodeIfPresent(significance, forKey: .significance)
        try values.encode(source, forKey: .source)
        try values.encodeIfPresent(notes, forKey: .notes)
        try values.encode(code, forKey: .code)
        try values.encode(document, forKey: .document)
        try values.encode(revision, forKey: .revision)
        try values.encode(sourceHash, forKey: .sourceHash)
    }
}

public struct LegalDeadlineConstraint: Codable, Hashable, Sendable {
    public let id: String?
    public let problem: String?
    public let requirement: String?
    public let source: String?
    public let implementation: String?
    public let code: String
    public let document: String
    public let revision: Int
    public let sourceHash: String

    public init(
        id: String? = nil,
        problem: String? = nil,
        requirement: String? = nil,
        source: String? = nil,
        implementation: String? = nil,
        code: String,
        document: String,
        revision: Int,
        sourceHash: String
    ) {
        self.id = id
        self.problem = problem
        self.requirement = requirement
        self.source = source
        self.implementation = implementation
        self.code = code
        self.document = document
        self.revision = revision
        self.sourceHash = sourceHash
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case constraintID = "constraint_id"
        case problem
        case requirement
        case source
        case implementation
        case code
        case document
        case revision
        case sourceHash
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
            ?? (try values.decodeIfPresent(String.self, forKey: .constraintID))
        problem = try values.decodeIfPresent(String.self, forKey: .problem)
        requirement = try values.decodeIfPresent(String.self, forKey: .requirement)
        source = try values.decodeIfPresent(String.self, forKey: .source)
        implementation = try values.decodeIfPresent(String.self, forKey: .implementation)
        code = try values.decode(String.self, forKey: .code)
        document = try values.decode(String.self, forKey: .document)
        revision = try values.decode(Int.self, forKey: .revision)
        sourceHash = try values.decode(String.self, forKey: .sourceHash)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(id, forKey: .id)
        try values.encodeIfPresent(problem, forKey: .problem)
        try values.encodeIfPresent(requirement, forKey: .requirement)
        try values.encodeIfPresent(source, forKey: .source)
        try values.encodeIfPresent(implementation, forKey: .implementation)
        try values.encode(code, forKey: .code)
        try values.encode(document, forKey: .document)
        try values.encode(revision, forKey: .revision)
        try values.encode(sourceHash, forKey: .sourceHash)
    }
}

public struct LegalDeadlineExclusion: Codable, Hashable, Sendable {
    public let group: String
    public let result: String
    public let code: String
    public let document: String
    public let revision: Int
    public let sourceHash: String

    public init(
        group: String,
        result: String,
        code: String,
        document: String,
        revision: Int,
        sourceHash: String
    ) {
        self.group = group
        self.result = result
        self.code = code
        self.document = document
        self.revision = revision
        self.sourceHash = sourceHash
    }
}

public struct LegalDeadlineOpenQuestion: Codable, Hashable, Sendable {
    public let questionID: String
    public let issue: String
    public let implementationConstraint: String?
    public let implementation: String?
    public let handling: String?
    public let question: String?
    public let sourceStatus: String?
    public let code: String
    public let document: String
    public let revision: Int
    public let sourceHash: String

    public var questionId: String { questionID }
    public var id: String { questionID }

    public init(
        questionID: String,
        issue: String,
        implementationConstraint: String? = nil,
        implementation: String? = nil,
        handling: String? = nil,
        question: String? = nil,
        sourceStatus: String? = nil,
        code: String,
        document: String,
        revision: Int,
        sourceHash: String
    ) {
        self.questionID = questionID
        self.issue = issue
        self.implementationConstraint = implementationConstraint
        self.implementation = implementation
        self.handling = handling
        self.question = question
        self.sourceStatus = sourceStatus
        self.code = code
        self.document = document
        self.revision = revision
        self.sourceHash = sourceHash
    }

    private enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case id
        case issue
        case implementationConstraint
        case implementation
        case handling
        case question
        case sourceStatus = "source_status"
        case code
        case document
        case revision
        case sourceHash
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        questionID = try values.decodeIfPresent(String.self, forKey: .questionID)
            ?? (try values.decode(String.self, forKey: .id))
        issue = try values.decodeIfPresent(String.self, forKey: .issue)
            ?? (try values.decodeIfPresent(String.self, forKey: .question)) ?? ""
        implementationConstraint = try values.decodeIfPresent(String.self, forKey: .implementationConstraint)
        implementation = try values.decodeIfPresent(String.self, forKey: .implementation)
        handling = try values.decodeIfPresent(String.self, forKey: .handling)
        question = try values.decodeIfPresent(String.self, forKey: .question)
        sourceStatus = try values.decodeIfPresent(String.self, forKey: .sourceStatus)
        code = try values.decode(String.self, forKey: .code)
        document = try values.decode(String.self, forKey: .document)
        revision = try values.decode(Int.self, forKey: .revision)
        sourceHash = try values.decode(String.self, forKey: .sourceHash)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(questionID, forKey: .questionID)
        try values.encode(issue, forKey: .issue)
        try values.encodeIfPresent(implementationConstraint, forKey: .implementationConstraint)
        try values.encodeIfPresent(implementation, forKey: .implementation)
        try values.encodeIfPresent(handling, forKey: .handling)
        try values.encodeIfPresent(question, forKey: .question)
        try values.encodeIfPresent(sourceStatus, forKey: .sourceStatus)
        try values.encode(code, forKey: .code)
        try values.encode(document, forKey: .document)
        try values.encode(revision, forKey: .revision)
        try values.encode(sourceHash, forKey: .sourceHash)
    }
}

/// A rule's catalog-level support classification.  Runtime applicability is
/// decided by the rules engine; this type keeps its result strongly typed.
public enum DeadlineRuleSupport: String, Codable, Hashable, Sendable {
    case supported
    case insufficientEvidence
    case unsupportedCalculation
    case notApplicable
    case needsLegalReview
    case noNumericDeadline
    case catalogued
}
