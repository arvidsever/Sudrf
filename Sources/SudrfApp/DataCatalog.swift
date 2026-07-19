import Foundation
import SudrfKit
import SwiftData
import os

private let backupLog = Logger(subsystem: "ru.sudrf.app", category: "StoreBackup")

// MARK: - SwiftData schema and shared container

/// Перестраиваемая проекция опубликованного акта. Источником истины остаётся
/// `TrackedCaseRecord.movementData`; эту таблицу можно целиком пересоздать.
@Model
final class CourtActRecord {
    @Attribute(.unique) var id: String
    var caseKey: String
    var sourceActID: String
    var caseNumber: String
    var judicialUID: String?
    var court: String
    var instanceLevel: String
    var kind: String
    var actDate: String
    var sourceText: String
    var sourceHash: String
    var paragraphData: Data
    var paragraphizerVersion: Int = ActParagraphizer.currentVersion
    var identityVersion: Int = 1
    var semanticKey: String = ""
    var fetchedAt: Date

    init(document: ActDocument, semanticKey: String, fetchedAt: Date) {
        id = document.id
        caseKey = document.caseKey
        sourceActID = document.sourceActID
        caseNumber = document.caseNumber
        judicialUID = document.judicialUID
        court = document.court
        instanceLevel = document.instanceLevel.rawValue
        kind = document.kind
        actDate = document.date
        sourceText = document.sourceText
        sourceHash = document.sourceHash
        paragraphData = (try? JSONEncoder().encode(document.paragraphs)) ?? Data()
        paragraphizerVersion = document.paragraphizerVersion
        identityVersion = 1
        self.semanticKey = semanticKey
        self.fetchedAt = fetchedAt
    }

    func update(from document: ActDocument, semanticKey: String, fetchedAt: Date) {
        caseKey = document.caseKey
        sourceActID = document.sourceActID
        caseNumber = document.caseNumber
        judicialUID = document.judicialUID
        court = document.court
        instanceLevel = document.instanceLevel.rawValue
        kind = document.kind
        actDate = document.date
        if sourceHash != document.sourceHash {
            sourceText = document.sourceText
            sourceHash = document.sourceHash
            paragraphData = (try? JSONEncoder().encode(document.paragraphs)) ?? Data()
            paragraphizerVersion = document.paragraphizerVersion
        } else {
            sourceText = document.sourceText
        }
        identityVersion = 1
        self.semanticKey = semanticKey
        self.fetchedAt = fetchedAt
    }

    var document: ActDocument? {
        guard let level = CaseInstance.Level(rawValue: instanceLevel),
              let paragraphs = try? JSONDecoder().decode([ActParagraph].self,
                                                         from: paragraphData) else { return nil }
        return ActDocument(id: id, caseKey: caseKey, sourceActID: sourceActID,
                           caseNumber: caseNumber, judicialUID: judicialUID,
                           court: court, instanceLevel: level, kind: kind,
                           date: actDate, sourceText: sourceText,
                           sourceHash: sourceHash,
                           paragraphizerVersion: paragraphizerVersion,
                           paragraphs: paragraphs)
    }
}

@Model
final class ActSummaryRecord {
    @Attribute(.unique) var id: String
    var documentID: String
    var summaryData: Data
    var provider: String
    var model: String
    var promptVersion: String
    var pipelineVersion: String
    var sourceHash: String
    var generatedAt: Date

    init(documentID: String, summary: ActSummary, provider: String, model: String,
         promptVersion: String, pipelineVersion: String, sourceHash: String,
         generatedAt: Date = .now) throws {
        self.id = documentID
        self.documentID = documentID
        self.summaryData = try JSONEncoder().encode(summary)
        self.provider = provider
        self.model = model
        self.promptVersion = promptVersion
        self.pipelineVersion = pipelineVersion
        self.sourceHash = sourceHash
        self.generatedAt = generatedAt
    }

    var summary: ActSummary? { try? JSONDecoder().decode(ActSummary.self, from: summaryData) }
    func isStale(for document: ActDocument) -> Bool { sourceHash != document.sourceHash }
}

enum SudrfSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [TrackedCaseRecord.self] }
}

enum SudrfSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [TrackedCaseRecord.self, CourtActRecord.self]
    }
}

enum SudrfSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [TrackedCaseRecord.self, CourtActRecord.self, ActSummaryRecord.self]
    }
}

enum SudrfSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SudrfSchemaV1.self, SudrfSchemaV2.self, SudrfSchemaV3.self]
    }
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: SudrfSchemaV1.self, toVersion: SudrfSchemaV2.self),
            .lightweight(fromVersion: SudrfSchemaV2.self, toVersion: SudrfSchemaV3.self),
        ]
    }
}

struct SudrfStoreBootstrapError: LocalizedError {
    let underlying: Error
    let backupDirectory: URL?

    var errorDescription: String? {
        var text = "Не удалось открыть базу отслеживаемых дел: \(underlying.localizedDescription)"
        if let backupDirectory {
            text += "\n\nРезервная копия до миграции: \(backupDirectory.path)"
        }
        text += "\n\nSudrf заблокирован для записи. Закройте приложение и восстановите базу из копии либо передайте эту ошибку разработчику."
        return text
    }
}

@MainActor
enum SudrfPersistentStoreBackup {
    private static var currentSchemaVersion: String {
        String(describing: SudrfSchemaV3.versionIdentifier)
    }

    private static func markerKey(schemaVersion: String) -> String {
        "swiftData.backupAndMigrationCompleted.schema-\(schemaVersion)"
    }

    static func prepare(storeURL: URL,
                        backupRoot: URL? = nil,
                        defaults: UserDefaults = .standard,
                        schemaVersion: String = currentSchemaVersion) throws -> URL? {
        guard !defaults.bool(forKey: markerKey(schemaVersion: schemaVersion)),
              FileManager.default.fileExists(atPath: storeURL.path) else { return nil }

        let root = backupRoot ?? defaultBackupRoot()
        let destination = root.appendingPathComponent(
            "pre-schema-\(schemaVersion)", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            if isUsableBackup(destination, storeURL: storeURL) {
                return destination
            }
            // Неполную копию не удаляем: сохраняем для диагностики и освобождаем
            // canonical destination, после чего создаём новую полную копию.
            let quarantine = root.appendingPathComponent(
                "pre-schema-\(schemaVersion)-invalid-\(UUID().uuidString)",
                isDirectory: true)
            try FileManager.default.moveItem(at: destination, to: quarantine)
            backupLog.error("Повреждённый backup перемещён в \(quarantine.path, privacy: .public)")
        }

        let temporary = root.appendingPathComponent(".pre-schema-\(schemaVersion)-\(UUID().uuidString)",
                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            for source in storeFiles(for: storeURL)
                where FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(
                    at: source, to: temporary.appendingPathComponent(source.lastPathComponent))
            }
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                // Два процесса могли одновременно подготовить одну и ту же
                // schema-specific копию. Принимаем победившую только после
                // проверки наличия основного store-файла.
                if FileManager.default.fileExists(atPath: destination.path),
                   isUsableBackup(destination, storeURL: storeURL) {
                    try? FileManager.default.removeItem(at: temporary)
                    backupLog.notice("Новый проверенный backup доступен в \(destination.path, privacy: .public)")
                    return destination
                }
                throw error
            }
            backupLog.notice("Новый проверенный backup создан в \(destination.path, privacy: .public)")
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func markMigrationCompleted(defaults: UserDefaults = .standard,
                                       schemaVersion: String = currentSchemaVersion) {
        defaults.set(true, forKey: markerKey(schemaVersion: schemaVersion))
    }

    private static func defaultBackupRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Sudrf", isDirectory: true)
            .appendingPathComponent("store-backups", isDirectory: true)
    }

    private static func storeFiles(for storeURL: URL) -> [URL] {
        [storeURL,
         URL(fileURLWithPath: storeURL.path + "-wal"),
         URL(fileURLWithPath: storeURL.path + "-shm")]
    }

    private static func isUsableBackup(_ directory: URL, storeURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(storeURL.lastPathComponent).path)
    }
}

@MainActor
enum SudrfModelContainerFactory {
    static func make(inMemory: Bool, storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SudrfSchemaV3.self)
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(
                "Sudrf", schema: schema, url: storeURL, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(
                nil, schema: schema, isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: SudrfSchemaMigrationPlan.self,
                                  configurations: configuration)
    }

    static func makeProduction() throws -> ModelContainer {
        let defaultURL = ModelConfiguration().url
        var backup: URL?
        do {
            backup = try SudrfPersistentStoreBackup.prepare(storeURL: defaultURL)
            // Backup и контейнер получают один и тот же URL, а не вычисляют
            // default location независимо друг от друга.
            let container = try make(inMemory: false, storeURL: defaultURL)
            SudrfPersistentStoreBackup.markMigrationCompleted()
            return container
        } catch {
            throw SudrfStoreBootstrapError(underlying: error, backupDirectory: backup)
        }
    }
}

// MARK: - Sendable catalog snapshots

struct CaseCatalogSnapshot: Sendable, Hashable, Identifiable {
    let id: String
    let caseNumber: String
    let judicialUID: String?
    let court: String
    let displayDomain: String
    let collections: [String]
    let category: String?
    let judges: [String]
    let parties: [String]
    let events: [String]
    let results: [String]
}

struct CourtActCatalogSnapshot: Sendable, Hashable, Identifiable {
    let document: ActDocument
    let fetchedAt: Date

    var id: String { document.id }
}

struct ActSummaryCatalogSnapshot: Sendable, Hashable, Identifiable {
    let documentID: String
    let summary: ActSummary
    let provider: String
    let model: String
    let promptVersion: String
    let pipelineVersion: String
    let sourceHash: String
    let generatedAt: Date

    var id: String { documentID }
    func isStale(for document: ActDocument) -> Bool { sourceHash != document.sourceHash }
}

/// Единственная actor-граница чтения SwiftData для Spotlight, App Intents и
/// AI. Ни один `@Model`-объект наружу не выходит.
actor CaseCatalog {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func cases() throws -> [CaseCatalogSnapshot] {
        let descriptor = FetchDescriptor<TrackedCaseRecord>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
        return try context.fetch(descriptor).map(Self.snapshot(from:))
    }

    func caseSnapshot(id: String) throws -> CaseCatalogSnapshot? {
        var descriptor = FetchDescriptor<TrackedCaseRecord>(
            predicate: #Predicate { $0.key == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first.map(Self.snapshot(from:))
    }

    func acts(caseKey: String? = nil) throws -> [CourtActCatalogSnapshot] {
        let records: [CourtActRecord]
        if let caseKey {
            let descriptor = FetchDescriptor<CourtActRecord>(
                predicate: #Predicate { $0.caseKey == caseKey },
                sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)])
            records = try context.fetch(descriptor)
        } else {
            let descriptor = FetchDescriptor<CourtActRecord>(
                sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)])
            records = try context.fetch(descriptor)
        }
        return records.compactMap { record in
            record.document.map { CourtActCatalogSnapshot(document: $0, fetchedAt: record.fetchedAt) }
        }
    }

    func act(id: String) throws -> CourtActCatalogSnapshot? {
        var descriptor = FetchDescriptor<CourtActRecord>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first,
              let document = record.document else { return nil }
        return CourtActCatalogSnapshot(document: document, fetchedAt: record.fetchedAt)
    }

    func summary(documentID: String) throws -> ActSummaryCatalogSnapshot? {
        var descriptor = FetchDescriptor<ActSummaryRecord>(
            predicate: #Predicate { $0.documentID == documentID })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first,
              let summary = record.summary else { return nil }
        return ActSummaryCatalogSnapshot(
            documentID: record.documentID, summary: summary,
            provider: record.provider, model: record.model,
            promptVersion: record.promptVersion, pipelineVersion: record.pipelineVersion,
            sourceHash: record.sourceHash, generatedAt: record.generatedAt)
    }

    func saveSummary(document: ActDocument, summary: ActSummary,
                     provider: String, model: String, promptVersion: String,
                     pipelineVersion: String) throws {
        let id = document.id
        var descriptor = FetchDescriptor<ActSummaryRecord>(
            predicate: #Predicate { $0.documentID == id })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.summaryData = try JSONEncoder().encode(summary)
            existing.provider = provider
            existing.model = model
            existing.promptVersion = promptVersion
            existing.pipelineVersion = pipelineVersion
            existing.sourceHash = document.sourceHash
            existing.generatedAt = .now
        } else {
            context.insert(try ActSummaryRecord(
                documentID: id, summary: summary, provider: provider, model: model,
                promptVersion: promptVersion, pipelineVersion: pipelineVersion,
                sourceHash: document.sourceHash))
        }
        try context.save()
    }

    private static func snapshot(from record: TrackedCaseRecord) -> CaseCatalogSnapshot {
        let movement = record.movementData.flatMap { try? JSONDecoder().decode(CaseMovement.self, from: $0) }
        let parties: [String] = movement.map { movement in
            let direct = movement.parties.plaintiffs
                + movement.parties.defendants
                + movement.parties.thirdParties
            let columns: [String] = movement.parties.columns
                .flatMap { $0.members }
                .map { $0.name }
            return unique(direct + columns)
        } ?? []
        let events = movement?.instances.flatMap { instance in
            instance.sessions.map { session in
                [session.date, session.time, session.event, session.result]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
        } ?? []
        let results = unique((movement?.instances.compactMap(\.result) ?? [])
            + (movement?.instances.flatMap { $0.sessions.compactMap(\.result) } ?? []))
        return CaseCatalogSnapshot(
            id: record.key,
            caseNumber: record.caseNumber,
            judicialUID: record.judicialUID,
            court: record.courtTitle,
            displayDomain: record.displayDomain,
            collections: record.collectionNames,
            category: movement?.category,
            judges: unique(movement?.instances.compactMap(\.judge) ?? []),
            parties: parties,
            events: events,
            results: results
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, value in
            guard !value.isEmpty, !result.contains(value) else { return }
            result.append(value)
        }
    }
}
