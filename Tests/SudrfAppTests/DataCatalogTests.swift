import XCTest
import SudrfKit
import SwiftData
@testable import SudrfApp

final class DataCatalogTests: XCTestCase {
    func testStoredParagraphSnapshotSurvivesProjectionRefreshForSameSourceRevision() throws {
        let source = "Первый абзац.\n\nВторой абзац."
        let document = ActDocument(
            caseKey: "court/2-1/2026", sourceActID: "act-1",
            caseNumber: "2-1/2026", judicialUID: nil, court: "Тестовый суд",
            instanceLevel: .first, kind: "Решение", date: "01.07.2026",
            sourceText: source)
        let record = CourtActRecord(document: document, semanticKey: "semantic", fetchedAt: .now)

        // Имитируем snapshot, созданный прежней версией segmenter. Пока hash
        // оригинала тот же, update обязан оставить эти границы и версию.
        let legacyParagraphs = [ActParagraph(ordinal: 1, text: source)]
        record.paragraphData = try JSONEncoder().encode(legacyParagraphs)
        record.paragraphizerVersion = 77
        record.update(from: document, semanticKey: "semantic", fetchedAt: .now)

        XCTAssertEqual(record.document?.paragraphizerVersion, 77)
        XCTAssertEqual(record.document?.paragraphs, legacyParagraphs)

        let revised = ActDocument(
            caseKey: document.caseKey, sourceActID: document.sourceActID,
            caseNumber: document.caseNumber, judicialUID: nil, court: document.court,
            instanceLevel: .first, kind: document.kind, date: document.date,
            sourceText: source + "\n\nТретий абзац.")
        record.update(from: revised, semanticKey: "semantic", fetchedAt: .now)
        XCTAssertEqual(record.document?.paragraphizerVersion, ActParagraphizer.currentVersion)
        XCTAssertEqual(record.document?.paragraphs.map(\.id), ["¶1", "¶2", "¶3"])
    }

    @MainActor
    func testLegacyTrackedCaseStoreMigratesWhenProjectionEntityIsAdded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SudrfMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")

        let legacyContext = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court--msk.sudrf.ru", displayDomain: "court.msk.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-9/2025")
        let contextData = try JSONEncoder().encode(legacyContext)

        do {
            let legacySchema = Schema([TrackedCaseRecord.self])
            let configuration = ModelConfiguration(
                "SudrfMigrationTest", schema: legacySchema, url: storeURL,
                cloudKitDatabase: .none)
            let container = try ModelContainer(for: legacySchema, configurations: configuration)
            let context = ModelContext(container)
            context.insert(TrackedCaseRecord(
                key: legacyContext.key, collections: ["Legacy"],
                caseNumber: legacyContext.caseNumber, courtTitle: legacyContext.courtTitle,
                displayDomain: legacyContext.displayDomain, contextData: contextData,
                snapshotData: nil))
            try context.save()
        }

        let currentSchema = Schema(versionedSchema: SudrfSchemaV3.self)
        let configuration = ModelConfiguration(
            "SudrfMigrationTest", schema: currentSchema, url: storeURL,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: currentSchema, migrationPlan: SudrfSchemaMigrationPlan.self,
            configurations: configuration)
        let migratedStore = TrackedStore(container: container)

        XCTAssertEqual(migratedStore.all().map(\.key), [legacyContext.key])
        XCTAssertEqual(migratedStore.all().first?.collectionNames, ["Legacy"])
    }

    @MainActor
    func testPreMigrationBackupCopiesSQLiteSidecarsOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SudrfBackup-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = source.appendingPathComponent("default.store")
        try Data("store".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-shm"))
        let suite = "SudrfBackupTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let backup = try XCTUnwrap(SudrfPersistentStoreBackup.prepare(
            storeURL: storeURL, backupRoot: backups, defaults: defaults))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("default.store")),
                       Data("store".utf8))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("default.store-wal")),
                       Data("wal".utf8))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("default.store-shm")),
                       Data("shm".utf8))
        XCTAssertEqual(try SudrfPersistentStoreBackup.prepare(
            storeURL: storeURL, backupRoot: backups, defaults: defaults), backup)
        XCTAssertEqual(backup.lastPathComponent, "pre-schema-3.0.0")

        SudrfPersistentStoreBackup.markMigrationCompleted(defaults: defaults)
        XCTAssertNil(try SudrfPersistentStoreBackup.prepare(
            storeURL: storeURL, backupRoot: backups, defaults: defaults))

        // Следующая schema-version получает независимые marker и каталог.
        let next = try XCTUnwrap(SudrfPersistentStoreBackup.prepare(
            storeURL: storeURL, backupRoot: backups, defaults: defaults,
            schemaVersion: "4.0.0"))
        XCTAssertEqual(next.lastPathComponent, "pre-schema-4.0.0")
    }

    @MainActor
    func testCorruptBackupIsQuarantinedAndReplaced() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SudrfCorruptBackup-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let corrupt = backups.appendingPathComponent("pre-schema-3.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("incomplete".utf8).write(to: corrupt.appendingPathComponent("orphan-wal"))
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = source.appendingPathComponent("default.store")
        try Data("valid-store".utf8).write(to: storeURL)
        let suite = "SudrfCorruptBackupTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let replacement = try XCTUnwrap(SudrfPersistentStoreBackup.prepare(
            storeURL: storeURL, backupRoot: backups, defaults: defaults))
        XCTAssertEqual(try Data(contentsOf: replacement.appendingPathComponent("default.store")),
                       Data("valid-store".utf8))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: backups, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("pre-schema-3.0.0-invalid-") }
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: quarantined[0].appendingPathComponent("orphan-wal").path))
        let secondLaunch = try XCTUnwrap(SudrfPersistentStoreBackup.prepare(
            storeURL: storeURL, backupRoot: backups, defaults: defaults))
        XCTAssertEqual(secondLaunch.standardizedFileURL, replacement.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: secondLaunch.appendingPathComponent("default.store")),
                       Data("valid-store".utf8))
    }

    @MainActor
    func testExplicitStoreURLIsUsedByModelContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SudrfExplicitStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("chosen.store")

        let container = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        XCTAssertEqual(container.configurations.first?.url.standardizedFileURL,
                       storeURL.standardizedFileURL)
    }

    @MainActor
    func testProjectionAndCatalogLifecycle() async throws {
        let store = TrackedStore(inMemory: true)
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Москва",
            searchDomain: "court--msk.sudrf.ru",
            displayDomain: "court.msk.sudrf.ru",
            courtTitle: "Тестовый суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77",
            cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-1/2026"
        )
        context.judicialUID = "77RS0001-01-2026-000001-10"
        let instance = CaseInstance(
            level: .first, court: "Тестовый суд", caseNumber: context.caseNumber,
            judge: "Иванова И.И.", domain: context.displayDomain,
            foundByUID: false, result: "Иск удовлетворён", sessions: [
                CaseSession(date: "01.07.2026", event: "Рассмотрение",
                            result: "Иск удовлетворён")
            ], actID: "act-1")
        let act = CaseAct(id: "act-1", title: "Решение", date: "01.07.2026",
                          courtShort: "1-я инстанция", instanceLevel: .first)
        let parties = CaseParties(plaintiffs: ["Истец"], defendants: ["Ответчик"])
        let movement = CaseMovement(
            uid: context.judicialUID!, caseNumber: context.caseNumber, inForce: false,
            instances: [instance], complaints: [:], acts: [act],
            actBodies: [act.id: "Первый абзац.\n\nВторой абзац."],
            category: "Споры о договоре", parties: parties)

        store.upsert(context: context, snapshot: nil, movement: movement, collections: ["Клиент"])
        let catalog = CaseCatalog(container: store.container)
        let cases = try await catalog.cases()
        let acts = try await catalog.acts(caseKey: context.key)

        XCTAssertEqual(cases.count, 1)
        var metadataOnlyContext = context
        metadataOnlyContext.judicialUID = "77RS0001-01-2026-999999-10"
        store.upsert(context: metadataOnlyContext, snapshot: nil, movement: nil,
                     collections: ["Клиент"])
        let metadataUpdatedAct = try await catalog.act(id: acts[0].document.id)
        XCTAssertEqual(metadataUpdatedAct?.document.judicialUID,
                       TrackedStore.normalizedUID("77RS0001-01-2026-999999-10"))
        XCTAssertEqual(cases[0].parties, ["Истец", "Ответчик"])
        XCTAssertEqual(cases[0].judges, ["Иванова И.И."])
        XCTAssertEqual(acts.count, 1)
        XCTAssertEqual(acts[0].document.id, "\(context.key)#act-1")
        XCTAssertEqual(acts[0].document.paragraphs.map(\.id), ["¶1", "¶2"])
        let oldHash = acts[0].document.sourceHash

        var updated = movement
        updated.actBodies[act.id] = "Исправленный текст."
        store.upsert(context: context, snapshot: nil, movement: updated, collections: ["Клиент"])
        let updatedActs = try await catalog.acts(caseKey: context.key)
        XCTAssertEqual(updatedActs.first?.document.id, acts.first?.document.id)
        XCTAssertNotEqual(updatedActs.first?.document.sourceHash, oldHash)

        // Новый sourceActID от изменившейся HTML-разметки не меняет logical ID,
        // если semantic identity и текст однозначно совпали.
        var renumbered = updated
        let renumberedAct = CaseAct(id: "act-2", title: act.title, date: act.date,
                                    courtShort: act.courtShort, instanceLevel: act.instanceLevel)
        renumbered.acts = [renumberedAct]
        renumbered.actBodies = [renumberedAct.id: "Исправленный текст."]
        renumbered.instances[0].actID = renumberedAct.id
        store.upsert(context: context, snapshot: nil, movement: renumbered,
                     collections: ["Клиент"])
        let renumberedActs = try await catalog.acts(caseKey: context.key)
        XCTAssertEqual(renumberedActs.first?.document.id, acts.first?.document.id)
        XCTAssertEqual(renumberedActs.first?.document.sourceActID, "act-2")
        XCTAssertEqual(store.courtActID(caseKey: context.key, sourceActID: "act-2"),
                       acts.first?.document.id)

        let finalDocument = try XCTUnwrap(renumberedActs.first?.document)
        let summary = ActSummary(disposition: [SummaryClaim(
            text: "Исправленный текст.",
            citations: [SummaryCitation(paragraphID: "¶1",
                                         evidenceQuote: "Исправленный текст.")])])
        try await catalog.saveSummary(
            document: finalDocument, summary: summary, provider: "test",
            model: "test-v1", promptVersion: "v1", pipelineVersion: "v1")
        let savedSummary = try await catalog.summary(documentID: finalDocument.id)
        XCTAssertNotNil(savedSummary)

        // Второй ModelContext видит refresh главного context: запись summary
        // сохраняется, но становится stale. Затем удаление дела из mainContext
        // обязано удалить её без merge-конфликта.
        var finalRevision = renumbered
        finalRevision.actBodies[renumberedAct.id] = "Новая редакция после сводки."
        store.upsert(context: context, snapshot: nil, movement: finalRevision,
                     collections: ["Клиент"])
        let staleSummary = try await catalog.summary(documentID: finalDocument.id)
        let refreshedAct = try await catalog.act(id: finalDocument.id)
        let refreshedDocument = try XCTUnwrap(refreshedAct?.document)
        XCTAssertTrue(try XCTUnwrap(staleSummary).isStale(
            for: refreshedDocument))

        store.remove(key: context.key)
        let casesAfterRemoval = try await catalog.cases()
        let actsAfterRemoval = try await catalog.acts()
        XCTAssertTrue(casesAfterRemoval.isEmpty)
        XCTAssertTrue(actsAfterRemoval.isEmpty)
        let removedSummary = try await catalog.summary(documentID: finalDocument.id)
        XCTAssertNil(removedSummary)
    }

    @MainActor
    func testCorruptMovementBlobPreservesProjectionAndSummary() async throws {
        let store = TrackedStore(inMemory: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court--msk.sudrf.ru", displayDomain: "court.msk.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-8/2026")
        let act = CaseAct(id: "act-1", title: "Решение", date: "01.07.2026",
                          courtShort: "Тестовый суд", instanceLevel: .first)
        let movement = CaseMovement(
            uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: [], complaints: [:], acts: [act],
            actBodies: [act.id: "Сохранённый текст акта."],
            category: nil, parties: CaseParties())
        let record = store.upsert(context: context, snapshot: nil, movement: movement,
                                  collections: [])
        let catalog = CaseCatalog(container: store.container)
        let projectedActs = try await catalog.acts()
        let document = try XCTUnwrap(projectedActs.first?.document)
        try await catalog.saveSummary(
            document: document,
            summary: ActSummary(disposition: [SummaryClaim(
                text: "Сохранённый текст акта.",
                citations: [SummaryCitation(paragraphID: "¶1",
                                             evidenceQuote: "Сохранённый текст акта.")])]),
            provider: "test", model: "test", promptVersion: "v1", pipelineVersion: "v1")

        record.movementData = Data("not-json".utf8)
        XCTAssertTrue(store.save(projection: .full))

        let preservedActs = try await catalog.acts()
        let preservedSummary = try await catalog.summary(documentID: document.id)
        XCTAssertEqual(preservedActs.map(\.document.id), [document.id])
        XCTAssertNotNil(preservedSummary)
        XCTAssertEqual(record.movementData, Data("not-json".utf8))
    }
}
