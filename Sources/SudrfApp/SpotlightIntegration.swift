import AppIntents
@preconcurrency import CoreSpotlight
import Foundation
import SudrfKit

// MARK: - Deep links

enum SudrfDeepLink: Sendable, Equatable {
    case caseRecord(key: String)
    case courtAct(caseKey: String, sourceActID: String)

    var url: URL? {
        var components = URLComponents()
        components.scheme = "sudrf"
        switch self {
        case .caseRecord(let key):
            components.host = "case"
            components.queryItems = [URLQueryItem(name: "id", value: key)]
        case .courtAct(let caseKey, let sourceActID):
            components.host = "act"
            components.queryItems = [
                URLQueryItem(name: "case", value: caseKey),
                URLQueryItem(name: "act", value: sourceActID),
            ]
        }
        return components.url
    }

    init?(url: URL) {
        guard url.scheme == "sudrf",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let queryItems = components.queryItems ?? []
        func uniqueValue(_ name: String) -> String? {
            let matches = queryItems.filter { $0.name == name }.compactMap(\.value)
            guard matches.count == 1 else { return nil }
            return matches[0]
        }
        switch components.host {
        case "case":
            guard let key = uniqueValue("id"), !key.isEmpty else { return nil }
            self = .caseRecord(key: key)
        case "act":
            guard let caseKey = uniqueValue("case"), !caseKey.isEmpty,
                  let sourceActID = uniqueValue("act"), !sourceActID.isEmpty else { return nil }
            self = .courtAct(caseKey: caseKey, sourceActID: sourceActID)
        default:
            return nil
        }
    }
}

// MARK: - Indexed AppEntity values

struct CaseEntity: IndexedEntity, Sendable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Судебное дело", numericFormat: "\(placeholder: .int) судебных дел")
    static let defaultQuery = CaseEntityQuery()

    let id: String
    let caseNumber: String
    let judicialUID: String?
    let court: String
    let collections: [String]
    let category: String?
    let judges: [String]
    let parties: [String]
    let events: [String]
    let results: [String]

    init(snapshot: CaseCatalogSnapshot) {
        id = snapshot.id
        caseNumber = snapshot.caseNumber
        judicialUID = snapshot.judicialUID
        court = snapshot.court
        collections = snapshot.collections
        category = snapshot.category
        judges = snapshot.judges
        parties = snapshot.parties
        events = snapshot.events
        results = snapshot.results
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Дело \(caseNumber)", subtitle: "\(court)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = "Дело № \(caseNumber)"
        attributes.displayName = caseNumber
        attributes.contentDescription = [court, category, judicialUID]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        attributes.textContent = searchableText
        attributes.keywords = keywords
        attributes.domainIdentifier = "ru.sudrf.case"
        attributes.contentURL = SudrfDeepLink.caseRecord(key: id).url
        return attributes
    }

    var searchableText: String {
        ([caseNumber, judicialUID, court, category].compactMap { $0 }
            + judges + parties + collections + events + results)
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var keywords: [String] {
        ([caseNumber, judicialUID, court, category].compactMap { $0 }
            + judges + parties + collections).filter { !$0.isEmpty }
    }

    var fingerprint: String { ActParagraphizer.sourceHash(for: searchableText) }
}

struct CourtActEntity: IndexedEntity, Sendable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Судебный акт", numericFormat: "\(placeholder: .int) судебных актов")
    static let defaultQuery = CourtActEntityQuery()

    let document: ActDocument

    var id: String { document.id }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(document.kind) по делу \(document.caseNumber)",
            subtitle: "\(document.court)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = "\(document.kind) по делу № \(document.caseNumber)"
        attributes.displayName = document.kind
        attributes.contentDescription = [document.court, document.date, document.judicialUID]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        attributes.textContent = document.paragraphs.map(\.text).joined(separator: "\n")
        attributes.keywords = [document.caseNumber, document.judicialUID,
                               document.court, document.kind, document.date]
            .compactMap { $0 }.filter { !$0.isEmpty }
        attributes.domainIdentifier = "ru.sudrf.court-act"
        attributes.relatedUniqueIdentifier = document.caseKey
        attributes.contentURL = SudrfDeepLink.courtAct(
            caseKey: document.caseKey, sourceActID: document.sourceActID).url
        return attributes
    }

    var fingerprint: String {
        ActParagraphizer.sourceHash(for: [document.sourceHash, document.caseNumber,
                                          document.judicialUID, document.court,
                                          document.kind, document.date]
            .compactMap { $0 }
            .joined(separator: "\n"))
    }
}

// MARK: - Entity queries backed by CaseCatalog

actor CaseCatalogRegistry {
    static let shared = CaseCatalogRegistry()
    private var catalog: CaseCatalog?

    func install(_ catalog: CaseCatalog) { self.catalog = catalog }

    func caseEntities() async throws -> [CaseEntity] {
        guard let catalog else { return [] }
        return try await catalog.cases().map(CaseEntity.init(snapshot:))
    }

    func courtActEntities() async throws -> [CourtActEntity] {
        guard let catalog else { return [] }
        return try await catalog.acts().map { CourtActEntity(document: $0.document) }
    }
}

struct CaseEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [CaseEntity.ID]) async throws -> [CaseEntity] {
        let wanted = Set(identifiers)
        return try await CaseCatalogRegistry.shared.caseEntities().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [CaseEntity] {
        let needle = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return try await CaseCatalogRegistry.shared.caseEntities().filter {
            $0.searchableText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(needle)
        }
    }

    func suggestedEntities() async throws -> [CaseEntity] {
        try await CaseCatalogRegistry.shared.caseEntities()
    }
}

struct CourtActEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [CourtActEntity.ID]) async throws -> [CourtActEntity] {
        let wanted = Set(identifiers)
        return try await CaseCatalogRegistry.shared.courtActEntities().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [CourtActEntity] {
        let needle = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return try await CaseCatalogRegistry.shared.courtActEntities().filter { entity in
            let text = ([entity.document.caseNumber, entity.document.judicialUID,
                         entity.document.court, entity.document.kind,
                         entity.document.date].compactMap { $0 }).joined(separator: "\n")
            return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(needle)
        }
    }

    func suggestedEntities() async throws -> [CourtActEntity] {
        try await CaseCatalogRegistry.shared.courtActEntities()
    }
}

// MARK: - Incremental Spotlight lifecycle

protocol SpotlightIndexWriting: Sendable {
    func index(cases: [CaseEntity], acts: [CourtActEntity]) async throws
    func delete(caseIDs: [String], actIDs: [String]) async throws
    func deleteAll() async throws
}

actor SystemSpotlightWriter: SpotlightIndexWriting {
    private let index = CSSearchableIndex.default()

    func index(cases: [CaseEntity], acts: [CourtActEntity]) async throws {
        if !cases.isEmpty { try await index.indexAppEntities(cases) }
        if !acts.isEmpty { try await index.indexAppEntities(acts) }
    }

    func delete(caseIDs: [String], actIDs: [String]) async throws {
        if !caseIDs.isEmpty {
            try await index.deleteAppEntities(identifiedBy: caseIDs, ofType: CaseEntity.self)
        }
        if !actIDs.isEmpty {
            try await index.deleteAppEntities(identifiedBy: actIDs, ofType: CourtActEntity.self)
        }
    }

    func deleteAll() async throws {
        try await index.deleteAppEntities(ofType: CaseEntity.self)
        try await index.deleteAppEntities(ofType: CourtActEntity.self)
    }
}

struct SpotlightActManifestEntry: Sendable, Codable, Equatable {
    let fingerprint: String
    let caseKey: String
}

struct SpotlightManifest: Sendable, Codable, Equatable {
    var cases: [String: String] = [:]
    var acts: [String: SpotlightActManifestEntry] = [:]
}

enum SpotlightSyncScope: Sendable, Equatable {
    case cases(Set<String>)
    case full

    func merging(_ other: Self) -> Self {
        switch (self, other) {
        case (.full, _), (_, .full): .full
        case (.cases(let lhs), .cases(let rhs)): .cases(lhs.union(rhs))
        }
    }
}

actor SpotlightManifestStore {
    private struct Envelope: Codable {
        let version: Int
        let manifest: SpotlightManifest
    }
    struct Snapshot: Sendable {
        let manifest: SpotlightManifest
        let requiresFullRebuild: Bool
    }
    private let defaults: UserDefaults
    private let key: String

    init(suiteName: String? = nil, key: String = "spotlightManifest.v1") {
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.key = key
    }

    func loadSnapshot() -> Snapshot {
        guard let data = defaults.data(forKey: key) else {
            return Snapshot(manifest: SpotlightManifest(), requiresFullRebuild: false)
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 2 else {
            // v1/corrupt manifest не является основанием оставлять возможные
            // stale записи в системном индексе: следующий sync делает purge.
            return Snapshot(manifest: SpotlightManifest(), requiresFullRebuild: true)
        }
        return Snapshot(manifest: envelope.manifest, requiresFullRebuild: false)
    }

    func load() -> SpotlightManifest { loadSnapshot().manifest }

    func save(_ manifest: SpotlightManifest) {
        defaults.set(try? JSONEncoder().encode(Envelope(version: 2, manifest: manifest)),
                     forKey: key)
    }
}

/// UserDefaults документирован как thread-safe; синхронное хранилище позволяет
/// применить preference revision без actor-reentrancy между проверкой и записью.
final class SpotlightPreferenceStore: @unchecked Sendable {
    static let key = "spotlight.systemIndexEnabled"
    static let onboardingKey = "spotlight.systemIndexDisclosure.v1"
    private let defaults: UserDefaults

    init(suiteName: String? = nil) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func isEnabled() -> Bool {
        defaults.object(forKey: Self.key) == nil
            ? true
            : defaults.bool(forKey: Self.key)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
    }
}

actor SpotlightIndexer {
    private let catalog: CaseCatalog
    private let writer: any SpotlightIndexWriting
    private let manifestStore: SpotlightManifestStore
    private let preferenceStore: SpotlightPreferenceStore
    private var scheduledTask: Task<Void, Never>?
    private var pendingScope: SpotlightSyncScope?
    private var writeTail: Task<Void, Never>?
    private var writeSequence: UInt64 = 0
    private var latestPreferenceRevision: UInt64 = 0

    init(catalog: CaseCatalog,
         writer: any SpotlightIndexWriting = SystemSpotlightWriter(),
         manifestStore: SpotlightManifestStore = SpotlightManifestStore(),
         preferenceStore: SpotlightPreferenceStore = SpotlightPreferenceStore()) {
        self.catalog = catalog
        self.writer = writer
        self.manifestStore = manifestStore
        self.preferenceStore = preferenceStore
    }

    func setEnabled(_ enabled: Bool, revision: UInt64) async throws {
        guard revision >= latestPreferenceRevision else { return }
        latestPreferenceRevision = revision
        preferenceStore.setEnabled(enabled)
        scheduledTask?.cancel()
        pendingScope = nil
        if enabled {
            try await synchronize(scope: .full)
        } else {
            try await enqueuePurge()
        }
    }

    func scheduleSynchronization(scope: SpotlightSyncScope) {
        pendingScope = pendingScope.map { $0.merging(scope) } ?? scope
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            try? await self?.runScheduledSynchronization()
        }
    }

    func synchronize() async throws {
        try await synchronize(scope: .full)
    }

    func synchronize(scope: SpotlightSyncScope) async throws {
        guard preferenceStore.isEnabled() else { return try await enqueuePurge() }
        let loadedBeforeFetch = await manifestStore.loadSnapshot()
        let effectiveScope: SpotlightSyncScope = loadedBeforeFetch.requiresFullRebuild ? .full : scope
        let entities = try await entities(for: effectiveScope)
        let writer = self.writer
        let manifestStore = self.manifestStore
        let preferenceStore = self.preferenceStore
        try await enqueueWrite {
            guard preferenceStore.isEnabled() else {
                return try await Self.purge(writer: writer, manifestStore: manifestStore)
            }
            let loaded = await manifestStore.loadSnapshot()
            var previous = loaded.manifest
            if loaded.requiresFullRebuild {
                try await writer.deleteAll()
                previous = SpotlightManifest()
            }
            var next = previous
            let affectedKeys: Set<String>
            switch effectiveScope {
            case .full:
                affectedKeys = Set(previous.cases.keys)
                    .union(previous.acts.values.map(\.caseKey))
                    .union(entities.cases.map(\.id))
                    .union(entities.acts.map { $0.document.caseKey })
                next = SpotlightManifest()
            case .cases(let keys):
                affectedKeys = keys
                keys.forEach { next.cases[$0] = nil }
                next.acts = next.acts.filter { !keys.contains($0.value.caseKey) }
            }
            entities.cases.forEach { next.cases[$0.id] = $0.fingerprint }
            entities.acts.forEach {
                next.acts[$0.id] = SpotlightActManifestEntry(
                    fingerprint: $0.fingerprint, caseKey: $0.document.caseKey)
            }
            let changedCases = entities.cases.filter {
                previous.cases[$0.id] != $0.fingerprint
            }
            let changedActs = entities.acts.filter {
                previous.acts[$0.id]?.fingerprint != $0.fingerprint
                    || previous.acts[$0.id]?.caseKey != $0.document.caseKey
            }
            let removedCases = Array(previous.cases.keys.filter {
                affectedKeys.contains($0) && next.cases[$0] == nil
            })
            let removedActs = Array(previous.acts.filter {
                affectedKeys.contains($0.value.caseKey) && next.acts[$0.key] == nil
            }.keys)

            try await writer.delete(caseIDs: removedCases, actIDs: removedActs)
            guard preferenceStore.isEnabled() else {
                return try await Self.purge(writer: writer, manifestStore: manifestStore)
            }
            try await writer.index(cases: changedCases, acts: changedActs)
            guard preferenceStore.isEnabled() else {
                return try await Self.purge(writer: writer, manifestStore: manifestStore)
            }
            await manifestStore.save(next)
        }
    }

    func rebuild() async throws {
        guard preferenceStore.isEnabled() else { return try await enqueuePurge() }
        let cases = try await catalog.cases().map(CaseEntity.init(snapshot:))
        let acts = try await catalog.acts().map { CourtActEntity(document: $0.document) }
        let next = SpotlightManifest(
            cases: Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0.fingerprint) }),
            acts: Dictionary(uniqueKeysWithValues: acts.map {
                ($0.id, SpotlightActManifestEntry(
                    fingerprint: $0.fingerprint, caseKey: $0.document.caseKey))
            }))
        let writer = self.writer
        let manifestStore = self.manifestStore
        let preferenceStore = self.preferenceStore
        try await enqueueWrite {
            guard preferenceStore.isEnabled() else {
                return try await Self.purge(writer: writer, manifestStore: manifestStore)
            }
            try await writer.deleteAll()
            guard preferenceStore.isEnabled() else {
                return try await Self.purge(writer: writer, manifestStore: manifestStore)
            }
            try await writer.index(cases: cases, acts: acts)
            guard preferenceStore.isEnabled() else {
                return try await Self.purge(writer: writer, manifestStore: manifestStore)
            }
            await manifestStore.save(next)
        }
    }

    private func enqueuePurge() async throws {
        let writer = self.writer
        let manifestStore = self.manifestStore
        try await enqueueWrite {
            try await Self.purge(writer: writer, manifestStore: manifestStore)
        }
    }

    private func runScheduledSynchronization() async throws {
        guard let scope = pendingScope else { return }
        pendingScope = nil
        scheduledTask = nil
        try await synchronize(scope: scope)
    }

    private func entities(for scope: SpotlightSyncScope) async throws
        -> (cases: [CaseEntity], acts: [CourtActEntity]) {
        switch scope {
        case .full:
            return (
                try await catalog.cases().map(CaseEntity.init(snapshot:)),
                try await catalog.acts().map { CourtActEntity(document: $0.document) })
        case .cases(let keys):
            var cases: [CaseEntity] = []
            var acts: [CourtActEntity] = []
            for key in keys.sorted() {
                if let value = try await catalog.caseSnapshot(id: key) {
                    cases.append(CaseEntity(snapshot: value))
                }
                acts += try await catalog.acts(caseKey: key).map {
                    CourtActEntity(document: $0.document)
                }
            }
            return (cases, acts)
        }
    }

    /// Все системные writes и соответствующий manifest образуют одну FIFO.
    /// Следующая операция начинается только после фактического завершения
    /// предыдущей, включая асинхронный CSSearchableIndex callback.
    private func enqueueWrite(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let previous = writeTail
        writeSequence &+= 1
        let sequence = writeSequence
        let queued = Task {
            await previous?.value
            try await operation()
        }
        writeTail = Task { _ = try? await queued.value }
        let result = await queued.result
        if writeSequence == sequence { writeTail = nil }
        try result.get()
    }

    private nonisolated static func purge(
        writer: any SpotlightIndexWriting,
        manifestStore: SpotlightManifestStore
    ) async throws {
        // Не доверяем manifest как доказательству отсутствия системных записей.
        try await writer.deleteAll()
        await manifestStore.save(SpotlightManifest())
    }
}

// MARK: - In-app global search through the same local Spotlight index

struct SpotlightSearchHit: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let url: URL
    let isCourtAct: Bool
}

@MainActor
final class SpotlightSearchSession {
    private var query: CSUserQuery?

    func cancel() {
        query?.cancel()
        query = nil
    }

    func search(_ text: String,
                onBatch: @escaping @MainActor ([SpotlightSearchHit]) -> Void,
                onCompletion: @escaping @MainActor (Error?) -> Void) {
        cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onBatch([])
            onCompletion(nil)
            return
        }

        let context = CSUserQueryContext()
        context.enableRankedResults = true
        context.disableSemanticSearch = false
        context.maxResultCount = 50
        context.maxRankedResultCount = 50
        context.filterQueries = [
            "domainIdentifier == 'ru.sudrf.case' || domainIdentifier == 'ru.sudrf.court-act'"
        ]
        let query = CSUserQuery(userQueryString: trimmed, userQueryContext: context)
        self.query = query

        query.foundItemsHandler = { items in
            let hits = items.compactMap(Self.hit(from:))
            Task { @MainActor in onBatch(hits) }
        }
        query.completionHandler = { [weak self, weak query] error in
            Task { @MainActor in
                if self?.query === query { self?.query = nil }
                onCompletion(error)
            }
        }
        query.start()
    }

    nonisolated private static func hit(from item: CSSearchableItem) -> SpotlightSearchHit? {
        let attributes = item.attributeSet
        guard let url = attributes.contentURL,
              let deepLink = SudrfDeepLink(url: url) else { return nil }
        let isCourtAct: Bool
        switch deepLink {
        case .caseRecord: isCourtAct = false
        case .courtAct: isCourtAct = true
        }
        return SpotlightSearchHit(
            id: item.uniqueIdentifier,
            title: attributes.title ?? attributes.displayName ?? item.uniqueIdentifier,
            subtitle: attributes.contentDescription ?? "",
            url: url,
            isCourtAct: isCourtAct
        )
    }
}
