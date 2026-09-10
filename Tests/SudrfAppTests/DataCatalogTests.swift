import XCTest
import SudrfKit
import SwiftData
@testable import SudrfApp

final class DataCatalogTests: XCTestCase {
    private enum ForcedPreparationSaveError: Error { case forced }

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
            sourceHash: document.sourceHash, generatedAt: .now,
            paragraphizerVersion: document.paragraphizerVersion)

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
    func testPreparationMigratesLegacyParagraphSnapshotTransactionallyAndIdempotently() throws {
        XCTAssertGreaterThan(ActParagraphizer.currentVersion, 1)
        let store = TrackedStore(inMemory: true)
        let sourceText = "Дело № 2-1/2026 РЕШЕНИЕ Суд установил: иск подтверждён. решил: иск удовлетворить."
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court--msk.sudrf.ru", displayDomain: "court.msk.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-1/2026")
        let act = CaseAct(id: "act-1", title: "Решение", date: "01.07.2026",
                          courtShort: "Тестовый суд", instanceLevel: .first)
        _ = try store.upsert(
            context: context, snapshot: nil,
            movement: CaseMovement(uid: "", caseNumber: context.caseNumber, inForce: false,
                                   instances: [], complaints: [:], acts: [act],
                                   actBodies: [act.id: sourceText]),
            collections: [])
        let record = try XCTUnwrap(try store.container.mainContext.fetch(
            FetchDescriptor<CourtActRecord>()).first)
        let document = try XCTUnwrap(record.document)
        let legacyParagraphs = [ActParagraph(ordinal: 1, text: document.sourceText)]
        record.paragraphizerVersion = 1
        record.paragraphData = try JSONEncoder().encode(legacyParagraphs)
        let legacyParagraphData = record.paragraphData
        try store.container.mainContext.save()
        let expectedID = record.id
        let expectedCaseKey = record.caseKey
        let expectedSourceActID = record.sourceActID
        let expectedCaseNumber = record.caseNumber
        let expectedUID = record.judicialUID
        let expectedCourt = record.court
        let expectedLevel = record.instanceLevel
        let expectedKind = record.kind
        let expectedDate = record.actDate
        let expectedText = record.sourceText
        let expectedHash = record.sourceHash
        let expectedSemanticKey = record.semanticKey
        let expectedFetchedAt = record.fetchedAt

        XCTAssertThrowsError(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, save: { _ in throw ForcedPreparationSaveError.forced }))
        XCTAssertEqual(record.paragraphizerVersion, 1)
        XCTAssertEqual(record.paragraphData, legacyParagraphData)

        XCTAssertTrue(try TrackedStorePreparation.prepare(context: store.container.mainContext))
        XCTAssertEqual(record.paragraphizerVersion, ActParagraphizer.currentVersion)
        XCTAssertEqual(record.document?.paragraphs,
                       ActParagraphizer.paragraphs(in: document.sourceText))
        XCTAssertNotEqual(record.document?.paragraphs, legacyParagraphs)
        XCTAssertEqual(record.id, expectedID)
        XCTAssertEqual(record.caseKey, expectedCaseKey)
        XCTAssertEqual(record.sourceActID, expectedSourceActID)
        XCTAssertEqual(record.caseNumber, expectedCaseNumber)
        XCTAssertEqual(record.judicialUID, expectedUID)
        XCTAssertEqual(record.court, expectedCourt)
        XCTAssertEqual(record.instanceLevel, expectedLevel)
        XCTAssertEqual(record.kind, expectedKind)
        XCTAssertEqual(record.actDate, expectedDate)
        XCTAssertEqual(record.sourceText, expectedText)
        XCTAssertEqual(record.sourceHash, expectedHash)
        XCTAssertEqual(record.semanticKey, expectedSemanticKey)
        XCTAssertEqual(record.fetchedAt, expectedFetchedAt)
        XCTAssertFalse(try TrackedStorePreparation.prepare(context: store.container.mainContext))
    }

    @MainActor
    func testPreparationDoesNotDowngradeFutureParagraphSnapshot() throws {
        let store = TrackedStore(inMemory: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court--msk.sudrf.ru", displayDomain: "court.msk.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-1/2026")
        let act = CaseAct(id: "act-1", title: "Решение", date: "01.07.2026",
                          courtShort: "Тестовый суд", instanceLevel: .first)
        _ = try store.upsert(
            context: context, snapshot: nil,
            movement: CaseMovement(uid: "", caseNumber: context.caseNumber, inForce: false,
                                   instances: [], complaints: [:], acts: [act],
                                   actBodies: [act.id: "Текст."]),
            collections: [])
        let record = try XCTUnwrap(try store.container.mainContext.fetch(
            FetchDescriptor<CourtActRecord>()).first)
        let futureParagraphs = [ActParagraph(ordinal: 99, text: "Будущая граница.")]
        record.paragraphizerVersion = ActParagraphizer.currentVersion + 1
        record.paragraphData = try JSONEncoder().encode(futureParagraphs)
        try store.container.mainContext.save()

        _ = try TrackedStorePreparation.prepare(context: store.container.mainContext)
        XCTAssertEqual(record.paragraphizerVersion, ActParagraphizer.currentVersion + 1)
        XCTAssertEqual(record.document?.paragraphs, futureParagraphs)
    }

    @MainActor
    func testCourtActDocumentResolvesLegacyCaseLocator() throws {
        let store = TrackedStore(inMemory: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court--msk.sudrf.ru", displayDomain: "court.msk.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-1/2026")
        let act = CaseAct(id: "act-1", title: "Решение", date: "01.07.2026",
                          courtShort: "Тестовый суд", instanceLevel: .first)
        let record = try store.upsert(
            context: context, snapshot: nil,
            movement: CaseMovement(uid: "", caseNumber: context.caseNumber, inForce: false,
                                   instances: [], complaints: [:], acts: [act],
                                   actBodies: [act.id: "Текст акта."]),
            collections: [])
        record.addLegacyKeyAlias("legacy/case")
        try store.save()

        let document = try XCTUnwrap(
            store.courtActDocument(caseKey: "legacy/case", sourceActID: act.id))
        XCTAssertEqual(document.id, "\(record.key)#\(act.id)")
        XCTAssertEqual(document.paragraphs, ActParagraphizer.paragraphs(in: "Текст акта."))
    }

    @MainActor
    func testLegacySummaryDataReadsAsVersionOneAndIsStaleForNewParagraphs() async throws {
        XCTAssertGreaterThan(ActParagraphizer.currentVersion, 1)
        let store = TrackedStore(inMemory: true)
        let document = ActDocument(
            caseKey: "court/2-1/2026", sourceActID: "act-1", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Тестовый суд", instanceLevel: .first,
            kind: "Решение", date: "01.07.2026", sourceText: "Текст.")
        let summary = ActSummary(disposition: [SummaryClaim(text: "Итог", citations: [])])
        let record = try ActSummaryRecord(documentID: document.id, summary: summary,
                                          provider: "test", model: "test", promptVersion: "v1",
                                          pipelineVersion: "v1", sourceHash: document.sourceHash)
        record.summaryData = try JSONEncoder().encode(summary)
        store.container.mainContext.insert(record)
        try store.container.mainContext.save()

        XCTAssertEqual(record.summary?.disposition.map(\.text), summary.disposition.map(\.text))
        XCTAssertEqual(record.paragraphizerVersion, 1)
        XCTAssertTrue(record.isStale(for: document))
        let snapshot = try await CaseCatalog(container: store.container).summary(documentID: document.id)
        XCTAssertEqual(snapshot?.paragraphizerVersion, 1)
        XCTAssertTrue(snapshot?.isStale(for: document) == true)
    }

    @MainActor
    func testSaveSummaryStampsDocumentParagraphizerVersion() async throws {
        let store = TrackedStore(inMemory: true)
        let document = ActDocument(
            caseKey: "court/2-1/2026", sourceActID: "act-1", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Тестовый суд", instanceLevel: .first,
            kind: "Решение", date: "01.07.2026", sourceText: "Текст.")
        let catalog = CaseCatalog(container: store.container)
        try await catalog.saveSummary(document: document, summary: ActSummary(), provider: "test",
                                      model: "test", promptVersion: "v1", pipelineVersion: "v1")

        let record = try XCTUnwrap(try store.container.mainContext.fetch(
            FetchDescriptor<ActSummaryRecord>()).first)
        XCTAssertEqual(record.paragraphizerVersion, document.paragraphizerVersion)
        XCTAssertEqual(try JSONDecoder().decode(SummaryData.self, from: record.summaryData)
            .paragraphizerVersion, document.paragraphizerVersion)
    }

    @MainActor
    func testV3TrackedCaseStoreMigratesToV7WithPersistentIdentityAndEventBaseline() throws {
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

        let currentSchema = Schema(versionedSchema: SudrfSchemaV7.self)
        let configuration = ModelConfiguration(
            "SudrfMigrationTest", schema: currentSchema, url: storeURL,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: currentSchema, migrationPlan: SudrfSchemaMigrationPlan.self,
            configurations: configuration)
        let migratedStore = try TrackedStore(container: container)

        XCTAssertEqual(migratedStore.all().map(\.key), [legacyContext.key])
        XCTAssertEqual(migratedStore.all().first?.collectionNames, ["Legacy"])
        XCTAssertEqual(migratedStore.all().first?.enforcementRecords, [])
        XCTAssertNotNil(migratedStore.all().first?.logicalCaseID)
        let identityData = try XCTUnwrap(migratedStore.all().first?.identityStateData)
        let identity = try JSONDecoder().decode(LogicalCaseState.self, from: identityData)
        XCTAssertEqual(identity.cards.count, 1)
        XCTAssertEqual(identity.cards.first?.identity.sourceFamily, "legacy")
        XCTAssertEqual(migratedStore.all().first?.eventJournal, CaseEventJournal())
    }

    @MainActor
    func testV4TrackedCaseStoreMigratesToV7PreservingLastSuccess() throws {
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
        let lastSuccess = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshotData = Data("legacy-snapshot".utf8)
        let movementData = Data("legacy-movement".utf8)
        let enforcementData = Data("legacy-enforcement".utf8)

        do {
            let legacySchema = Schema(versionedSchema: SudrfSchemaV4.self)
            let configuration = ModelConfiguration(
                "SudrfMigrationTest", schema: legacySchema, url: storeURL,
                cloudKitDatabase: .none)
            let container = try ModelContainer(for: legacySchema, configurations: configuration)
            let context = ModelContext(container)
            let record = SudrfSchemaV4.TrackedCaseRecord(
                key: legacyContext.key, collections: ["Legacy"],
                caseNumber: legacyContext.caseNumber, courtTitle: legacyContext.courtTitle,
                displayDomain: legacyContext.displayDomain,
                contextData: try JSONEncoder().encode(legacyContext), snapshotData: snapshotData)
            record.folderName = "Доверитель"
            record.collectionNames = ["Legacy", "Избранное"]
            record.judicialUID = "77RS0001-01-2025-000001-11"
            record.movementData = movementData
            record.movementFetchedAt = lastSuccess
            record.enforcementData = enforcementData
            context.insert(record)
            try context.save()
        }

        let currentSchema = Schema(versionedSchema: SudrfSchemaV7.self)
        let configuration = ModelConfiguration(
            "SudrfMigrationTest", schema: currentSchema, url: storeURL,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: currentSchema, migrationPlan: SudrfSchemaMigrationPlan.self,
            configurations: configuration)
        let migrated = try TrackedStore(container: container).all().first

        XCTAssertEqual(migrated?.movementFetchedAt, lastSuccess)
        XCTAssertEqual(migrated?.folderName, "",
                       "legacy folder is intentionally cleared after collection migration")
        XCTAssertEqual(migrated?.collectionNames, ["Legacy", "Избранное"])
        XCTAssertEqual(migrated?.judicialUID, "77RS0001-01-2025-000001-11")
        XCTAssertEqual(migrated?.snapshotData, snapshotData)
        XCTAssertEqual(migrated?.movementData, movementData)
        XCTAssertEqual(migrated?.enforcementData, enforcementData)
        XCTAssertNil(migrated?.sourceRefreshAttempt)
    }

    @MainActor
    func testV5TrackedCaseStoreMigratesToV7AndKeepsIdentityOnReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SudrfMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")

        var legacyContext = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru", displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-100/2026", caseID: "native-card", caseUID: "portal-link")
        legacyContext.judicialUID = "11RS0001-01-2026-000100-01"
        var duplicateContext = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "vs--komi.sudrf.ru", displayDomain: "vs.komi.sudrf.ru",
            courtTitle: "Верховный суд Республики Коми",
            courtLevelRaw: CourtLevel.subject.rawValue, courtCode: "11VS0001",
            cartotekaId: "g2", cartotekaLevelRaw: CourtLevel.subject.rawValue,
            caseNumber: "33-200/2026", caseID: "appeal-card", caseUID: "appeal-link")
        duplicateContext.judicialUID = legacyContext.judicialUID

        do {
            let legacySchema = Schema(versionedSchema: SudrfSchemaV5.self)
            let configuration = ModelConfiguration(
                "SudrfMigrationTest", schema: legacySchema, url: storeURL,
                cloudKitDatabase: .none)
            let container = try ModelContainer(for: legacySchema, configurations: configuration)
            let context = ModelContext(container)
            let record = SudrfSchemaV5.TrackedCaseRecord(
                key: legacyContext.key, collections: ["Доверитель"],
                caseNumber: legacyContext.caseNumber, courtTitle: legacyContext.courtTitle,
                displayDomain: legacyContext.displayDomain,
                contextData: try JSONEncoder().encode(legacyContext), snapshotData: nil)
            record.judicialUID = legacyContext.judicialUID
            context.insert(record)
            let duplicate = SudrfSchemaV5.TrackedCaseRecord(
                key: duplicateContext.key, collections: ["Апелляция"],
                caseNumber: duplicateContext.caseNumber,
                courtTitle: duplicateContext.courtTitle,
                displayDomain: duplicateContext.displayDomain,
                contextData: try JSONEncoder().encode(duplicateContext), snapshotData: nil)
            duplicate.judicialUID = duplicateContext.judicialUID
            context.insert(duplicate)
            try context.save()
        }

        let firstIdentity: UUID
        let firstState: LogicalCaseState
        do {
            let currentSchema = Schema(versionedSchema: SudrfSchemaV7.self)
            let configuration = ModelConfiguration(
                "SudrfMigrationTest", schema: currentSchema, url: storeURL,
                cloudKitDatabase: .none)
            let container = try ModelContainer(
                for: currentSchema, migrationPlan: SudrfSchemaMigrationPlan.self,
                configurations: configuration)
            let store = try TrackedStore(container: container)
            XCTAssertEqual(store.all().count, 1)
            let record = try XCTUnwrap(store.all().first)
            firstIdentity = try XCTUnwrap(record.logicalCaseID)
            firstState = try JSONDecoder().decode(
                LogicalCaseState.self, from: XCTUnwrap(record.identityStateData))
            XCTAssertEqual(firstState.logicalCaseID, firstIdentity)
            XCTAssertEqual(firstState.judicialUIDs,
                           [TrackedStore.normalizedUID(legacyContext.judicialUID!)])
            XCTAssertEqual(Set(record.collectionNames), ["Доверитель", "Апелляция"])
            XCTAssertEqual(firstState.cards.count, 2)
            XCTAssertNotNil(store.record(forLocator: legacyContext.key))
            XCTAssertNotNil(store.record(forLocator: duplicateContext.key))
        }

        do {
            let currentSchema = Schema(versionedSchema: SudrfSchemaV7.self)
            let configuration = ModelConfiguration(
                "SudrfMigrationTest", schema: currentSchema, url: storeURL,
                cloudKitDatabase: .none)
            let container = try ModelContainer(
                for: currentSchema, migrationPlan: SudrfSchemaMigrationPlan.self,
                configurations: configuration)
            let store = try TrackedStore(container: container)
            XCTAssertEqual(store.all().count, 1)
            let record = try XCTUnwrap(store.all().first)
            XCTAssertEqual(record.logicalCaseID, firstIdentity)
            XCTAssertEqual(try JSONDecoder().decode(
                LogicalCaseState.self, from: XCTUnwrap(record.identityStateData)), firstState)
            XCTAssertEqual(record.key, legacyContext.key)
            XCTAssertNotNil(store.record(forLocator: duplicateContext.key))
        }
    }

    @MainActor
    func testSourceRefreshAttemptRoundTripsWithoutChangingLastSuccess() throws {
        let store = TrackedStore(inMemory: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court--msk.sudrf.ru", displayDomain: "court.msk.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-9/2025")
        let record = try store.upsert(context: context, snapshot: nil, collections: [])
        let lastSuccess = Date(timeIntervalSince1970: 1_700_000_000)
        let attempt = SourceAttempt(
            kind: .captcha,
            provenance: SourceProvenance(
                operation: .movement, sourceFamily: "sudrf",
                host: context.displayDomain, observedAt: .now,
                httpStatus: 403, errorCode: "captcha", attemptCount: 2))

        record.movementFetchedAt = lastSuccess
        record.sourceRefreshAttempt = attempt

        try store.save()
        XCTAssertEqual(record.sourceRefreshAttempt, attempt)
        XCTAssertEqual(record.movementFetchedAt, lastSuccess)
    }

    @MainActor
    func testV6StoreMigratesToV7WithEmptyAppendOnlyBaseline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SudrfV7Migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let movementContext = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-1/2026", caseID: "card-1")

        do {
            let schema = Schema(versionedSchema: SudrfSchemaV6.self)
            let configuration = ModelConfiguration(
                "SudrfMigrationTest", schema: schema, url: storeURL,
                cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)
            context.insert(SudrfSchemaV6.TrackedCaseRecord(
                key: movementContext.key, collections: [],
                caseNumber: movementContext.caseNumber,
                courtTitle: movementContext.courtTitle,
                displayDomain: movementContext.displayDomain,
                contextData: try JSONEncoder().encode(movementContext),
                snapshotData: nil))
            try context.save()
        }

        let schema = Schema(versionedSchema: SudrfSchemaV7.self)
        let configuration = ModelConfiguration(
            "SudrfMigrationTest", schema: schema, url: storeURL,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: schema, migrationPlan: SudrfSchemaMigrationPlan.self,
            configurations: configuration)
        let store = try TrackedStore(container: container)
        let record = try XCTUnwrap(store.all().first)
        XCTAssertEqual(record.eventJournal, CaseEventJournal())
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
        let tracked = try store.upsert(context: context, snapshot: nil, collections: [])
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
        XCTAssertEqual(backup.lastPathComponent, "pre-schema-7.0.0")

        SudrfPersistentStoreBackup.markMigrationCompleted(defaults: defaults)
        XCTAssertNil(try SudrfPersistentStoreBackup.prepare(
            storeURL: storeURL, backupRoot: backups, defaults: defaults))

        // Следующая schema-version получает независимые marker и каталог.
        let next = try XCTUnwrap(SudrfPersistentStoreBackup.prepare(
            storeURL: storeURL, backupRoot: backups, defaults: defaults,
            schemaVersion: "8.0.0"))
        XCTAssertEqual(next.lastPathComponent, "pre-schema-8.0.0")
    }

    @MainActor
    func testCorruptBackupIsQuarantinedAndReplaced() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SudrfCorruptBackup-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let corrupt = backups.appendingPathComponent("pre-schema-7.0.0", isDirectory: true)
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
            .filter { $0.lastPathComponent.hasPrefix("pre-schema-7.0.0-invalid-") }
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
    func testMissingExtractedFileBodyDoesNotCreateOrOverwriteActProjection() async throws {
        let store = TrackedStore(inMemory: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: MosGorSudEndpoint.host, displayDomain: MosGorSudEndpoint.host,
            courtTitle: "Московский городской суд", courtLevelRaw: CourtLevel.subject.rawValue,
            courtCode: "77OS0000", cartotekaId: "p1",
            cartotekaLevelRaw: CourtLevel.subject.rawValue, caseNumber: "3а-1/2026")
        let actID = "act_mos-gorsud.ru#3а-1/2026#file-one"
        let instance = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.displayDomain, foundByUID: false, result: nil,
            sessions: [], actID: actID)
        let act = CaseAct(id: actID, title: "Решение", date: "01.08.2026",
                          courtShort: context.courtTitle, instanceLevel: .first)
        var movement = CaseMovement(uid: "", caseNumber: context.caseNumber, inForce: false,
                                    instances: [instance], complaints: [:], acts: [act],
                                    actBodies: [actID: "Проверенный текст решения"])
        _ = try store.upsert(context: context, snapshot: nil, movement: movement,
                             collections: [])
        let catalog = CaseCatalog(container: store.container)
        let originalActs = try await catalog.acts(caseKey: context.key)
        let original = try XCTUnwrap(originalActs.first)

        movement.actBodies = [:]
        _ = try store.upsert(context: context, snapshot: nil, movement: movement,
                             collections: [])
        let preservedActs = try await catalog.acts(caseKey: context.key)
        let preserved = try XCTUnwrap(preservedActs.first)
        XCTAssertEqual(preserved.document.id, original.document.id)
        XCTAssertEqual(preserved.document.sourceText, "Проверенный текст решения")

        let newContext = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: MosGorSudEndpoint.host, displayDomain: MosGorSudEndpoint.host,
            courtTitle: "Московский городской суд", courtLevelRaw: CourtLevel.subject.rawValue,
            courtCode: "77OS0000", cartotekaId: "p1",
            cartotekaLevelRaw: CourtLevel.subject.rawValue, caseNumber: "3а-2/2026")
        var firstFailure = movement
        firstFailure.caseNumber = newContext.caseNumber
        firstFailure.instances[0].caseNumber = newContext.caseNumber
        _ = try store.upsert(context: newContext, snapshot: nil, movement: firstFailure,
                             collections: [])
        let firstFailureActs = try await catalog.acts(caseKey: newContext.key)
        XCTAssertTrue(firstFailureActs.isEmpty)
    }

    @MainActor
    func testActProjectionUsesExactCourtLinksIndependentOfInstanceOrder() throws {
        let store = TrackedStore(inMemory: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court-a--msk.sudrf.ru", displayDomain: "court-a.msk.sudrf.ru",
            courtTitle: "Суд A", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-263/2026")
        let acts = [
            CaseAct(id: "act-a", title: "Апелляционное определение", date: "01.08.2025",
                    courtShort: "Апелляция", instanceLevel: .appeal),
            CaseAct(id: "act-b", title: "Апелляционное определение", date: "01.08.2026",
                    courtShort: "Апелляция", instanceLevel: .appeal)
        ]
        let instances = [
            CaseInstance(level: .appeal, court: "Суд A", caseNumber: "33-1/2025",
                         judge: nil, domain: "court-a--msk.sudrf.ru", foundByUID: true,
                         result: nil, sessions: [], actID: acts[0].id),
            CaseInstance(level: .appeal, court: "Суд B", caseNumber: "33-2/2026",
                         judge: nil, domain: "court-b--msk.sudrf.ru", foundByUID: true,
                         result: nil, sessions: [], actID: acts[1].id)
        ]
        var movement = CaseMovement(
            uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: instances, complaints: [:], acts: acts,
            actBodies: ["act-a": "Текст A.", "act-b": "Текст B."])

        _ = try store.upsert(context: context, snapshot: nil, movement: movement,
                             collections: [])
        func projection() throws -> [String: (court: String, semanticKey: String)] {
            Dictionary(uniqueKeysWithValues: try store.container.mainContext.fetch(
                FetchDescriptor<CourtActRecord>()).filter { $0.caseKey == context.key }.map {
                    ($0.sourceActID, ($0.court, $0.semanticKey))
                })
        }
        let initial = try projection()
        XCTAssertEqual(initial["act-a"]?.court, "Суд A")
        XCTAssertEqual(initial["act-b"]?.court, "Суд B")

        movement.instances.reverse()
        movement.acts.reverse()
        _ = try store.upsert(context: context, snapshot: nil, movement: movement,
                             collections: [])
        let reordered = try projection()
        XCTAssertEqual(reordered["act-a"]?.court, "Суд A")
        XCTAssertEqual(reordered["act-b"]?.court, "Суд B")
        XCTAssertEqual(reordered["act-a"]?.semanticKey, initial["act-a"]?.semanticKey)
        XCTAssertEqual(reordered["act-b"]?.semanticKey, initial["act-b"]?.semanticKey)
    }

    @MainActor
    func testActProjectionFallsBackOnlyWithUnambiguousCompatibleEvidence() throws {
        let store = TrackedStore(inMemory: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court-a--msk.sudrf.ru", displayDomain: "court-a.msk.sudrf.ru",
            courtTitle: "Суд A", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-264/2026")
        func provenance(sourceHost: String, finalHost: String) -> PublishedActProvenance {
            PublishedActProvenance(
                sourceURL: URL(string: "https://\(sourceHost)/act.pdf")!,
                finalURL: URL(string: "https://\(finalHost)/act.pdf")!, format: .pdf,
                contentType: "application/pdf", contentHash: "01", byteCount: 1,
                fetchedAt: .distantPast, extractorVersion: 1)
        }
        let instances = [
            CaseInstance(
                level: .appeal, court: "Суд A", caseNumber: "33-1/2025", judge: nil,
                domain: "court-a--msk.sudrf.ru", foundByUID: true, result: nil, sessions: [],
                actIDs: ["exact-a", "ambiguous-generic", "ambiguous-own"]),
            CaseInstance(
                level: .appeal, court: "Суд B", caseNumber: "33-2/2026", judge: nil,
                domain: "court-b--msk.sudrf.ru", foundByUID: true, result: nil, sessions: [],
                actIDs: ["exact-b", "ambiguous-generic", "ambiguous-own"]),
            CaseInstance(
                level: .cassation, court: "Третий кассационный суд", caseNumber: "8Г-1/2026",
                judge: nil, domain: "3kas.sudrf.ru", foundByUID: true,
                result: nil, sessions: []),
            CaseInstance(
                level: .supervisory, court: "Надзорный суд", caseNumber: "4-1/2026",
                judge: nil, domain: "supervisory.sudrf.ru", foundByUID: true,
                result: nil, sessions: []),
            CaseInstance(
                level: .material, court: "Материальный суд", caseNumber: "13-1/2026",
                judge: nil, domain: "material--msk.sudrf.ru", foundByUID: true,
                result: nil, sessions: []),
            CaseInstance(
                level: .first, court: "Первый суд", caseNumber: "2-1/2026", judge: nil,
                domain: "first--msk.sudrf.ru", foundByUID: false, result: nil, sessions: []),
            CaseInstance(
                level: .first, court: "—", caseNumber: "2-2/2026", judge: nil,
                domain: "", foundByUID: false, result: nil, sessions: [])
        ]
        let acts = [
            CaseAct(id: "exact-a", title: "Акт A", date: "01.01.2026",
                    courtShort: "Апелляция", instanceLevel: .appeal),
            CaseAct(id: "exact-b", title: "Акт B", date: "02.01.2026",
                    courtShort: "Апелляция", instanceLevel: .appeal),
            CaseAct(id: "ambiguous-generic", title: "Акт C", date: "03.01.2026",
                    courtShort: "  АПЕЛЛЯЦИЯ  ", instanceLevel: .appeal),
            CaseAct(id: "ambiguous-own", title: "Акт D", date: "04.01.2026",
                    courtShort: "Суд акта", instanceLevel: .appeal),
            CaseAct(
                id: "fallback-multiple", title: "Акт E", date: "05.01.2026",
                courtShort: "Апелляция", instanceLevel: .appeal,
                fileProvenance: provenance(
                    sourceHost: "court-b.msk.sudrf.ru", finalHost: "court-b--msk.sudrf.ru")),
            CaseAct(id: "fallback-own", title: "Акт F", date: "06.01.2026",
                    courtShort: "Собственный суд", instanceLevel: .appeal),
            CaseAct(
                id: "fallback-compatible", title: "Акт G", date: "07.01.2026",
                courtShort: "Кассация", instanceLevel: .cassation,
                fileProvenance: provenance(
                    sourceHost: "3kas.sudrf.ru", finalHost: "redirect.example")),
            CaseAct(
                id: "fallback-mismatch", title: "Акт H", date: "08.01.2026",
                courtShort: "Надзор", instanceLevel: .supervisory,
                fileProvenance: provenance(
                    sourceHost: "other.sudrf.ru", finalHost: "supervisory.sudrf.ru")),
            CaseAct(id: "vs-own", title: "Акт I", date: "09.01.2026",
                    courtShort: " ВС РФ ", instanceLevel: .vsCassation),
            CaseAct(id: "fallback-no-provenance", title: "Акт J", date: "10.01.2026",
                    courtShort: "Материал", instanceLevel: .material),
            CaseAct(id: "fallback-empty-peer", title: "Акт K", date: "11.01.2026",
                    courtShort: "1-я инстанция", instanceLevel: .first)
        ]
        let bodies = Dictionary(uniqueKeysWithValues: acts.map { ($0.id, "Текст \($0.id).") })
        let movement = CaseMovement(
            uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: instances, complaints: [:], acts: acts, actBodies: bodies)

        _ = try store.upsert(context: context, snapshot: nil, movement: movement,
                             collections: [])
        let projected = try store.container.mainContext.fetch(FetchDescriptor<CourtActRecord>())
            .filter { $0.caseKey == context.key }
        let courts = Dictionary(uniqueKeysWithValues: projected.map { ($0.sourceActID, $0.court) })
        XCTAssertEqual(courts["exact-a"], "Суд A")
        XCTAssertEqual(courts["exact-b"], "Суд B")
        XCTAssertEqual(courts["ambiguous-generic"], "Суд не установлен")
        XCTAssertEqual(courts["ambiguous-own"], "Суд акта")
        XCTAssertEqual(courts["fallback-multiple"], "Суд не установлен")
        XCTAssertEqual(courts["fallback-own"], "Собственный суд")
        XCTAssertEqual(courts["fallback-compatible"], "Третий кассационный суд")
        XCTAssertEqual(courts["fallback-mismatch"], "Суд не установлен")
        XCTAssertEqual(courts["vs-own"], "ВС РФ")
        XCTAssertEqual(courts["fallback-no-provenance"], "Материальный суд")
        XCTAssertEqual(courts["fallback-empty-peer"], "Суд не установлен")
        XCTAssertTrue(projected.first { $0.sourceActID == "fallback-mismatch" }?
            .semanticKey.contains("суднеустановлен") == true)
    }

    @MainActor
    func testPreparationCorrectsStoredActCourtWithoutReplacingDocumentOrSummary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SudrfActOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court-a--msk.sudrf.ru", displayDomain: "court-a.msk.sudrf.ru",
            courtTitle: "Суд A", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-265/2026")
        let act = CaseAct(id: "act-b", title: "Апелляционное определение",
                          date: "01.08.2026", courtShort: "Апелляция",
                          instanceLevel: .appeal)
        let movement = CaseMovement(
            uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: [
                CaseInstance(level: .appeal, court: "Суд A", caseNumber: "33-1/2025",
                             judge: nil, domain: "court-a--msk.sudrf.ru", foundByUID: true,
                             result: nil, sessions: [], actID: "other"),
                CaseInstance(level: .appeal, court: "Суд B", caseNumber: "33-2/2026",
                             judge: nil, domain: "court-b--msk.sudrf.ru", foundByUID: true,
                             result: nil, sessions: [], actID: act.id)
            ], complaints: [:], acts: [act], actBodies: [act.id: "Первый.\n\nВторой."])
        var expectedID = ""
        var expectedText = ""
        var expectedHash = ""
        var expectedParagraphData = Data()

        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container)
            _ = try store.upsert(context: context, snapshot: nil, movement: movement,
                                 collections: [])
            let record = try XCTUnwrap(try container.mainContext.fetch(
                FetchDescriptor<CourtActRecord>()).first)
            expectedID = record.id
            expectedText = record.sourceText
            expectedHash = record.sourceHash
            expectedParagraphData = record.paragraphData
            container.mainContext.insert(try ActSummaryRecord(
                documentID: record.id,
                summary: ActSummary(disposition: [SummaryClaim(text: "Итог", citations: [])]),
                provider: "test", model: "test", promptVersion: "v1",
                pipelineVersion: "v1", sourceHash: record.sourceHash))
            record.court = "Суд A"
            record.semanticKey = "wrong"
            try store.save()
        }

        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container)
            let record = try XCTUnwrap(try container.mainContext.fetch(
                FetchDescriptor<CourtActRecord>()).first)
            XCTAssertEqual(record.id, expectedID)
            XCTAssertEqual(record.court, "Суд B")
            XCTAssertNotEqual(record.semanticKey, "wrong")
            XCTAssertEqual(record.sourceText, expectedText)
            XCTAssertEqual(record.sourceHash, expectedHash)
            XCTAssertEqual(record.paragraphData, expectedParagraphData)
            XCTAssertEqual(try container.mainContext.fetch(
                FetchDescriptor<ActSummaryRecord>()).map(\.documentID), [expectedID])

            store.failNextSaveForTesting = true
            try store.save(projection: .full)
            XCTAssertTrue(store.failNextSaveForTesting,
                          "an unchanged repeated projection must not save")
        }

        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            _ = try TrackedStore(container: container)
            let record = try XCTUnwrap(try container.mainContext.fetch(
                FetchDescriptor<CourtActRecord>()).first)
            XCTAssertEqual(record.id, expectedID)
            XCTAssertEqual(record.court, "Суд B")
            XCTAssertEqual(try container.mainContext.fetch(
                FetchDescriptor<ActSummaryRecord>()).map(\.documentID), [expectedID])
        }
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

        _ = try store.upsert(context: context, snapshot: nil, movement: movement, collections: ["Клиент"])
        let catalog = CaseCatalog(container: store.container)
        let cases = try await catalog.cases()
        let acts = try await catalog.acts(caseKey: context.key)

        XCTAssertEqual(cases.count, 1)
        var metadataOnlyContext = context
        metadataOnlyContext.judicialUID = "77RS0001-01-2026-999999-10"
        _ = try store.upsert(context: metadataOnlyContext, snapshot: nil, movement: nil,
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
        _ = try store.upsert(context: context, snapshot: nil, movement: updated, collections: ["Клиент"])
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
        _ = try store.upsert(context: context, snapshot: nil, movement: renumbered,
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
        _ = try store.upsert(context: context, snapshot: nil, movement: finalRevision,
                     collections: ["Клиент"])
        let staleSummary = try await catalog.summary(documentID: finalDocument.id)
        let refreshedAct = try await catalog.act(id: finalDocument.id)
        let refreshedDocument = try XCTUnwrap(refreshedAct?.document)
        XCTAssertTrue(try XCTUnwrap(staleSummary).isStale(
            for: refreshedDocument))

        try store.remove(key: context.key)
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
        let record = try store.upsert(context: context, snapshot: nil, movement: movement,
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
        try store.save(projection: .full)

        let preservedActs = try await catalog.acts()
        let preservedSummary = try await catalog.summary(documentID: document.id)
        XCTAssertEqual(preservedActs.map(\.document.id), [document.id])
        XCTAssertNotNil(preservedSummary)
        XCTAssertEqual(record.movementData, Data("not-json".utf8))
    }
}
