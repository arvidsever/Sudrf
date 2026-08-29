import XCTest
import SwiftData
@testable import SudrfApp

/// Первый запуск: базы ещё нет. Проверяется весь боевой путь целиком —
/// резервная копия, открытие контейнера, подготовка store и проекция актов, —
/// а не только создание `ModelContainer`. До этих тестов сценарий первого
/// запуска нечем было проверить, кроме как на живой машине.
final class StoreBootstrapTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreBootstrapTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "StoreBootstrapTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private var freshStoreURL: URL! { root.appendingPathComponent("default.store") }

    func testLegacyStoreMovesIntoSudrfDirectory() throws {
        let source = freshStoreURL!
        let destination = root.appendingPathComponent("Sudrf/default.store")
        try Data("store".utf8).write(to: source)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: source.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: source.path + "-shm"))

        try SudrfPersistentStoreLocation.moveLegacyStoreIfNeeded(from: source,
                                                                 to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("store".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination.path + "-wal")),
                       Data("wal".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination.path + "-shm")),
                       Data("shm".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testCompletedDestinationKeepsLegacySourceUntouched() throws {
        let source = freshStoreURL!
        let destination = root.appendingPathComponent("Sudrf/default.store")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: source)
        try Data("current".utf8).write(to: destination)

        try SudrfPersistentStoreLocation.moveLegacyStoreIfNeeded(from: source,
                                                                 to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("current".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("legacy".utf8))
    }

    func testOrphanedDestinationSidecarsAreRebuilt() throws {
        let source = freshStoreURL!
        let destination = root.appendingPathComponent("Sudrf/default.store")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("store".utf8).write(to: source)
        try Data("fresh-wal".utf8).write(to: URL(fileURLWithPath: source.path + "-wal"))
        try Data("orphan".utf8).write(to: URL(fileURLWithPath: destination.path + "-wal"))

        try SudrfPersistentStoreLocation.moveLegacyStoreIfNeeded(from: source,
                                                                 to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("store".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination.path + "-wal")),
                       Data("fresh-wal".utf8))
    }

    func testSidecarsMovedByInterruptedLegacyMigrationArePreserved() throws {
        let source = freshStoreURL!
        let destination = root.appendingPathComponent("Sudrf/default.store")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("store".utf8).write(to: source)
        try Data("only-wal".utf8).write(to: URL(fileURLWithPath: destination.path + "-wal"))
        try Data("only-shm".utf8).write(to: URL(fileURLWithPath: destination.path + "-shm"))

        try SudrfPersistentStoreLocation.moveLegacyStoreIfNeeded(from: source,
                                                                 to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("store".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination.path + "-wal")),
                       Data("only-wal".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination.path + "-shm")),
                       Data("only-shm".utf8))
    }

    func testMigratedSQLiteStoreReopensAtDestination() throws {
        let source = freshStoreURL!
        let destination = root.appendingPathComponent("Sudrf/default.store")
        var legacy: ModelContainer? = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: source)
        XCTAssertNotNil(legacy)
        legacy = nil

        try SudrfPersistentStoreLocation.moveLegacyStoreIfNeeded(from: source,
                                                                 to: destination)

        let reopened = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: destination)
        XCTAssertEqual(try ModelContext(reopened).fetch(
            FetchDescriptor<TrackedCaseRecord>()).count, 0)
    }

    func testFirstLaunchWithoutExistingStoreSucceeds() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshStoreURL.path),
                       "предусловие: базы ещё нет")

        let store = freshStoreURL!, suite = suiteName!
        let container = try await PersistentStoreBootstrapper()
            .prepareProduction(storeURL: store, defaultsSuiteName: suite)

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TrackedCaseRecord>()).count, 0,
                       "новая база пуста, но открыта")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshStoreURL.path),
                      "база создана по указанному пути")
    }

    /// Резервную копию не из чего делать, и это не ошибка: копирование должно
    /// молча пропускаться, а не валить запуск.
    func testFirstLaunchMakesNoBackup() throws {
        let backups = root.appendingPathComponent("store-backups")
        XCTAssertNil(try SudrfPersistentStoreBackup.prepare(
            storeURL: freshStoreURL, backupRoot: backups, defaults: defaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    /// Обломки от упавшего первого запуска: спутники SQLite есть, самой базы
    /// нет. Именно такую форму оставляет падение при старте — приложение не
    /// должно из-за них упираться в тупик.
    func testFirstLaunchRecoversFromLeftoverSidecars() async throws {
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: freshStoreURL.path + "-wal"))
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: freshStoreURL.path + "-shm"))

        let store = freshStoreURL!, suite = suiteName!
        let container = try await PersistentStoreBootstrapper()
            .prepareProduction(storeURL: store, defaultsSuiteName: suite)

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TrackedCaseRecord>()).count, 0)
    }

    /// Совет «восстановите базу из копии» бессмысленен, когда базы не было.
    func testErrorTextDependsOnWhetherStoreExisted() {
        struct Boom: Error {}
        let fresh = SudrfStoreBootstrapError(underlying: Boom(), backupDirectory: nil,
                                             hadExistingStore: false)
        XCTAssertFalse(fresh.errorDescription?.contains("восстановите базу из копии") ?? true)
        XCTAssertTrue(fresh.errorDescription?.contains("терять нечего") ?? false)

        let existing = SudrfStoreBootstrapError(underlying: Boom(), backupDirectory: nil,
                                                hadExistingStore: true)
        XCTAssertTrue(existing.errorDescription?.contains("восстановите базу из копии") ?? false)
    }

    /// Обычный relaunch после завершённой миграции не заменяет существующий
    /// неоткрываемый store чистой базой и оставляет его sidecars на месте.
    func testExistingUnopenableStoreFailsClosedAndPreservesStoreFiles() async throws {
        let store = freshStoreURL!
        let wal = URL(fileURLWithPath: store.path + "-wal")
        let shm = URL(fileURLWithPath: store.path + "-shm")
        let files = [
            (store, Data("not-a-swiftdata-store".utf8)),
            (wal, Data("wal-before-failure".utf8)),
            (shm, Data("shm-before-failure".utf8)),
        ]
        for (url, data) in files {
            try data.write(to: url)
        }
        SudrfPersistentStoreBackup.markMigrationCompleted(defaults: defaults)

        do {
            _ = try await PersistentStoreBootstrapper()
                .prepareProduction(storeURL: store, defaultsSuiteName: suiteName)
            XCTFail("существующий неоткрываемый store не должен заменяться чистым")
        } catch let error as SudrfStoreBootstrapError {
            XCTAssertTrue(error.hadExistingStore)
            XCTAssertNil(error.backupDirectory)
            for (url, data) in files {
                XCTAssertEqual(try Data(contentsOf: url), data)
            }
        } catch {
            XCTFail("ожидался SudrfStoreBootstrapError, получено: \(error)")
        }
    }

    /// Второй запуск открывает уже созданную базу и видит все сохранённые
    /// дела, включая их независимые durable keys.
    func testSecondLaunchReopensExistingStore() async throws {
        let store = freshStoreURL!, suite = suiteName!
        let cases = [
            ("court/2-1/2026", "2-1/2026"),
            ("court/2-2/2026", "2-2/2026"),
            ("court/2-3/2026", "2-3/2026"),
        ]
        do {
            let first = try await PersistentStoreBootstrapper()
                .prepareProduction(storeURL: store, defaultsSuiteName: suite)
            let writing = ModelContext(first)
            for (key, caseNumber) in cases {
                writing.insert(TrackedCaseRecord(
                    key: key, collections: [], caseNumber: caseNumber,
                    courtTitle: "Тестовый районный суд", displayDomain: "court.sudrf.ru",
                    contextData: Data(), snapshotData: nil))
            }
            try writing.save()
        }

        let second = try await PersistentStoreBootstrapper()
            .prepareProduction(storeURL: store, defaultsSuiteName: suite)
        let reading = ModelContext(second)
        let records = try reading.fetch(FetchDescriptor<TrackedCaseRecord>())
        XCTAssertEqual(records.count, cases.count)
        XCTAssertEqual(Set(records.map(\.key)), Set(cases.map { $0.0 }))
    }
}
