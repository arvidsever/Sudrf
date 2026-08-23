import XCTest
import SudrfKit
import SwiftData
@testable import SudrfApp

final class DataCatalogTests: XCTestCase {
    /// Смена prompt или pipeline делает сохранённую сводку устаревшей: показывать
    /// результат прежнего prompt как актуальный нельзя. Без текущей конфигурации
    /// (нет ключа или согласия) сводку всё равно нельзя перегенерировать, поэтому
    /// сравнивается только hash источника.
    func testSavedSummaryIsStaleAfterPromptOrPipelineBump() {
        let document = ActDocument(
            caseKey: "court/2-1/2026", sourceActID: "act-1", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Тестовый суд", instanceLevel: .first,
            kind: "Решение", date: "01.07.2026", sourceText: "Исходный абзац.")
        let snapshot = ActSummaryCatalogSnapshot(
            documentID: document.id, summary: ActSummary(), provider: "groq",
            model: "openai/gpt-oss-120b", promptVersion: "groq-act-summary-v1",
            pipelineVersion: "summary-pipeline-v1",
            sourceHash: document.sourceHash, generatedAt: .now)

        XCTAssertFalse(snapshot.isStale(for: document))
        XCTAssertFalse(snapshot.isStale(for: document, identity: SummaryIdentity(
            promptVersion: "groq-act-summary-v1",
            pipelineVersion: "summary-pipeline-v1")))
        XCTAssertTrue(snapshot.isStale(for: document, identity: SummaryIdentity(
            promptVersion: "groq-act-summary-v2",
            pipelineVersion: "summary-pipeline-v1")))
        XCTAssertTrue(snapshot.isStale(for: document, identity: SummaryIdentity(
            promptVersion: "groq-act-summary-v1",
            pipelineVersion: "summary-pipeline-v2")))
    }

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
    func testV3TrackedCaseStoreMigratesToV4WithEmptyEnforcementState() throws {
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
            let legacySchema = Schema(versionedSchema: SudrfSchemaV3.self)
            let configuration = ModelConfiguration(
                "SudrfMigrationTest", schema: legacySchema, url: storeURL,
                cloudKitDatabase: .none)
            let container = try ModelContainer(for: legacySchema, configurations: configuration)
            let context = ModelContext(container)
            context.insert(SudrfSchemaV3.TrackedCaseRecord(
                key: legacyContext.key, collections: ["Legacy"],
                caseNumber: legacyContext.caseNumber, courtTitle: legacyContext.courtTitle,
                displayDomain: legacyContext.displayDomain, contextData: contextData,
                snapshotData: nil))
            try context.save()
        }

        let currentSchema = Schema(versionedSchema: SudrfSchemaV4.self)
        let configuration = ModelConfiguration(
            "SudrfMigrationTest", schema: currentSchema, url: storeURL,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: currentSchema, migrationPlan: SudrfSchemaMigrationPlan.self,
            configurations: configuration)
        let migratedStore = TrackedStore(container: container)

        XCTAssertEqual(migratedStore.all().map(\.key), [legacyContext.key])
        XCTAssertEqual(migratedStore.all().first?.collectionNames, ["Legacy"])
        XCTAssertEqual(migratedStore.all().first?.enforcementRecords, [])
    }

    @MainActor
    func testEnforcementStoreRoundTripAndAdditiveReconciliation() throws {
        let store = TrackedStore(inMemory: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court--msk.sudrf.ru", displayDomain: "court.msk.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-9/2025")
        let tracked = store.upsert(context: context, snapshot: nil, collections: [])
        let oldDocument = CourtEnforcementDocument(id: "old-writ", blankNumber: "ФС № 123")
        let refreshedDocument = CourtEnforcementDocument(id: "new-writ", blankNumber: "ФС 123")
        let firstCheckedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let refreshedCheckedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let firstEvent = EnforcementEvent(guid: "rss-1", date: firstCheckedAt,
                                          text: "Принят", sourceOrder: 0)
        let old = EnforcementRecord(
            courtDocumentID: oldDocument.id, source: .treasury, sourceRecordID: "source-old",
            status: "Исполняется", events: [firstEvent], lastAttemptAt: firstCheckedAt,
            lastSuccessAt: firstCheckedAt)
        let bailiffDetails = BailiffEnforcementDetails(
            proceedingNumber: "587893/26/98078-ИП",
            previousProceedingNumbers: ["737102/25/98078-ИП"],
            debtor: "МКУ ДЕКАБРИСТ", department: "СОСП по г. Санкт-Петербургу",
            bailiff: "ДЯДЧЕНКО Е. В.", bailiffPhone: "+7(920)084-63-47")
        let bailiff = EnforcementRecord(
            courtDocumentID: oldDocument.id, source: .bailiffs,
            discoveryState: .found, sourceRecordID: bailiffDetails.proceedingNumber,
            status: "", lastAttemptAt: firstCheckedAt, lastSuccessAt: firstCheckedAt,
            bailiffDetails: bailiffDetails)
        tracked.enforcementRecords = [old, bailiff]
        XCTAssertEqual(tracked.enforcementRecords, [old, bailiff])

        var changedBailiff = bailiff
        changedBailiff.bailiffDetails?.bailiffPhone = "+7 (000) 000-00-00"
        XCTAssertTrue(TrackedStore.enforcementHasUserVisibleChange(
            previous: [bailiff], current: [changedBailiff],
            courtDocuments: [oldDocument]),
            "изменение опубликованных полей ФССП должно вернуть бейдж")

        let secondEvent = EnforcementEvent(guid: "rss-2", date: refreshedCheckedAt,
                                           text: "Исполнен", sourceOrder: 1)
        let update = EnforcementRecord(
            courtDocumentID: refreshedDocument.id, source: .treasury, sourceRecordID: "source-new",
            status: "Исполнен", events: [secondEvent], lastAttemptAt: refreshedCheckedAt,
            lastSuccessAt: refreshedCheckedAt)
        let merged = TrackedStore.reconciledEnforcementRecords(
            existing: tracked.enforcementRecords, updates: [update],
            courtDocuments: [oldDocument, refreshedDocument])

        let treasuryMerged = try XCTUnwrap(merged.first { $0.source == .treasury })
        let bailiffMerged = try XCTUnwrap(merged.first { $0.source == .bailiffs })
        XCTAssertEqual(merged.count, 2, "два независимых источника одного листа должны сохраниться")
        XCTAssertEqual(treasuryMerged.sourceRecordID, "source-new")
        XCTAssertEqual(Set(treasuryMerged.events.map(\.id)), Set([firstEvent.id, secondEvent.id]))
        XCTAssertEqual(bailiffMerged.bailiffDetails, bailiffDetails)
        XCTAssertEqual(TrackedStore.reconciledEnforcementRecords(
            existing: merged, updates: [], courtDocuments: [refreshedDocument]), merged,
            "пустой ответ не удаляет последний успешный статус")

        var timestampAndErrorOnly = merged[0]
        timestampAndErrorOnly.lastAttemptAt = .now
        timestampAndErrorOnly.error = "Нет сети"
        XCTAssertFalse(TrackedStore.enforcementHasUserVisibleChange(
            previous: merged, current: [timestampAndErrorOnly], courtDocuments: [refreshedDocument]))
        var stateChanged = merged[0]
        stateChanged.discoveryState = .notFound
        XCTAssertTrue(TrackedStore.enforcementHasUserVisibleChange(
            previous: merged, current: [stateChanged], courtDocuments: [refreshedDocument]))
        var historyChanged = merged[0]
        historyChanged.events.append(EnforcementEvent(guid: "rss-3", date: .now,
                                                       text: "Возвращён", sourceOrder: 2))
        XCTAssertTrue(TrackedStore.enforcementHasUserVisibleChange(
            previous: merged, current: [historyChanged], courtDocuments: [refreshedDocument]))

        tracked.enforcementData = Data("not-json".utf8)
        XCTAssertEqual(tracked.enforcementRecords, [], "повреждённый JSON не должен ронять store")
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
        XCTAssertEqual(backup.lastPathComponent, "pre-schema-4.0.0")

        SudrfPersistentStoreBackup.markMigrationCompleted(defaults: defaults)
        XCTAssertNil(try SudrfPersistentStoreBackup.prepare(
            storeURL: storeURL, backupRoot: backups, defaults: defaults))

        // Следующая schema-version получает независимые marker и каталог.
        let next = try XCTUnwrap(SudrfPersistentStoreBackup.prepare(
            storeURL: storeURL, backupRoot: backups, defaults: defaults,
            schemaVersion: "5.0.0"))
        XCTAssertEqual(next.lastPathComponent, "pre-schema-5.0.0")
    }

    @MainActor
    func testCorruptBackupIsQuarantinedAndReplaced() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SudrfCorruptBackup-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let corrupt = backups.appendingPathComponent("pre-schema-4.0.0", isDirectory: true)
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
            .filter { $0.lastPathComponent.hasPrefix("pre-schema-4.0.0-invalid-") }
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
