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
    private var quarantineRoot: URL! { root.appendingPathComponent("store-backups") }
    private let quarantineDate = Date(timeIntervalSince1970: 0)
    private let quarantineName = "unopenable-1970-01-01T00-00-00Z-schema-7.0.0"

    private struct StartupFailure: LocalizedError {
        var errorDescription: String? { "test startup failure" }
    }

    private enum MoveFailure: Error {
        case forward
        case rollback
    }

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
        let nonstandardStoreURL = root.appendingPathComponent("unresolved/../default.store")
        let fresh = SudrfStoreBootstrapError(underlying: Boom(), backupDirectory: nil,
                                             storeURL: nonstandardStoreURL,
                                             hadExistingStore: false)
        XCTAssertFalse(fresh.errorDescription?.contains("восстановите базу из копии") ?? true)
        XCTAssertTrue(fresh.errorDescription?.contains("терять нечего") ?? false)
        XCTAssertFalse(fresh.canQuarantine)
        XCTAssertEqual(fresh.storeURL, freshStoreURL.standardizedFileURL)

        let existing = SudrfStoreBootstrapError(underlying: Boom(), backupDirectory: nil,
                                                storeURL: freshStoreURL,
                                                hadExistingStore: true)
        XCTAssertTrue(existing.errorDescription?.contains("восстановите базу из копии") ?? false)
        XCTAssertTrue(existing.canQuarantine)

        let recovery = SudrfStoreBootstrapError(
            underlying: Boom(), backupDirectory: nil, storeURL: freshStoreURL,
            hadExistingStore: false, canQuarantine: false,
            recoveryDirectory: quarantineRoot)
        XCTAssertFalse(recovery.errorDescription?.contains("удалите папку Sudrf") ?? true)
        XCTAssertTrue(recovery.errorDescription?.contains("Не удаляйте каталог Sudrf") ?? false)
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
            XCTAssertTrue(error.canQuarantine)
            XCTAssertNil(error.backupDirectory)
            XCTAssertEqual(error.storeURL, store.standardizedFileURL)
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

    func testExplicitQuarantineMovesSQLiteSetAndWritesRecoveryReadme() throws {
        let store = freshStoreURL!
        let files = [
            (store, Data("store bytes".utf8)),
            (URL(fileURLWithPath: store.path + "-wal"), Data("wal bytes".utf8)),
            (URL(fileURLWithPath: store.path + "-shm"), Data("shm bytes".utf8)),
        ]
        for (url, data) in files {
            try data.write(to: url)
        }

        var moveOrder: [String] = []
        var readmeExistedBeforeEveryMove = true
        var readmeWasCrashSafeBeforeEveryMove = true
        let directory = try SudrfPersistentStoreBackup.quarantineUnopenableStore(
            storeURL: store, error: StartupFailure(), quarantineRoot: quarantineRoot,
            date: quarantineDate,
            moveItem: { source, destination in
                moveOrder.append(source.lastPathComponent)
                readmeExistedBeforeEveryMove = readmeExistedBeforeEveryMove
                    && FileManager.default.fileExists(atPath: destination.deletingLastPathComponent()
                        .appendingPathComponent("README.txt").path)
                let stagedReadme = try String(
                    contentsOf: destination.deletingLastPathComponent()
                        .appendingPathComponent("README.txt"), encoding: .utf8)
                readmeWasCrashSafeBeforeEveryMove = readmeWasCrashSafeBeforeEveryMove
                    && stagedReadme.contains("Не перемещайте и не удаляйте файлы")
                    && stagedReadme.contains("фактически находятся в этом каталоге")
                try FileManager.default.moveItem(at: source, to: destination)
            })

        XCTAssertEqual(directory.lastPathComponent, quarantineName)
        XCTAssertTrue(readmeExistedBeforeEveryMove)
        XCTAssertTrue(readmeWasCrashSafeBeforeEveryMove)
        XCTAssertEqual(moveOrder, ["default.store-wal", "default.store-shm", "default.store"])
        for (source, expected) in files {
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(
                source.lastPathComponent)), expected)
        }

        let readme = try String(contentsOf: directory.appendingPathComponent("README.txt"),
                                encoding: .utf8)
        XCTAssertTrue(readme.contains("Создано (UTC): 1970-01-01T00-00-00Z"))
        XCTAssertTrue(readme.contains("Приложение: "))
        XCTAssertTrue(readme.contains("Версия схемы: 7.0.0"))
        XCTAssertTrue(readme.contains("Исходный путь базы: \(store.standardizedFileURL.path)"))
        XCTAssertTrue(readme.contains("Ошибка запуска: test startup failure"))
        XCTAssertTrue(readme.contains("Файлы в этом каталоге:\n- default.store-wal\n- default.store-shm\n- default.store"))
        XCTAssertTrue(readme.contains("1. Закройте Sudrf перед любыми действиями."))
        XCTAssertTrue(readme.contains("2. Переместите новый canonical-набор файлов"))
        XCTAssertTrue(readme.contains("вместе в отдельную безопасную папку."))
        XCTAssertTrue(readme.contains("3. Переместите все перечисленные карантинные файлы обратно"))
        XCTAssertTrue(readme.contains("4. Запускайте Sudrf только после полного возврата"))
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent(".recovery-state"),
                       encoding: .utf8), "complete\n")
        XCTAssertNil(SudrfPersistentStoreBackup.incompleteRecoveryDirectory(
            storeURL: store, backupRoot: quarantineRoot))
    }

    func testExplicitQuarantineAcceptsMissingOptionalSidecars() throws {
        let store = freshStoreURL!
        try Data("store bytes".utf8).write(to: store)

        let directory = try SudrfPersistentStoreBackup.quarantineUnopenableStore(
            storeURL: store, error: StartupFailure(), quarantineRoot: quarantineRoot,
            date: quarantineDate)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       [".recovery-state", "README.txt", "default.store"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("default.store")),
                       Data("store bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path + "-shm"))
    }

    func testExplicitQuarantineAddsNumericSuffixOnCollision() throws {
        let firstStore = root.appendingPathComponent("first.store")
        let secondStore = root.appendingPathComponent("second.store")
        try Data("first".utf8).write(to: firstStore)
        try Data("second".utf8).write(to: secondStore)

        let first = try SudrfPersistentStoreBackup.quarantineUnopenableStore(
            storeURL: firstStore, error: StartupFailure(), quarantineRoot: quarantineRoot,
            date: quarantineDate)
        let second = try SudrfPersistentStoreBackup.quarantineUnopenableStore(
            storeURL: secondStore, error: StartupFailure(), quarantineRoot: quarantineRoot,
            date: quarantineDate)

        XCTAssertEqual(first.lastPathComponent, quarantineName)
        XCTAssertEqual(second.lastPathComponent, quarantineName + "-1")
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("first.store")),
                       Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent("second.store")),
                       Data("second".utf8))
    }

    func testExplicitQuarantineFailsWithoutMainStoreAndDoesNotMoveSidecars() throws {
        let store = freshStoreURL!
        let wal = URL(fileURLWithPath: store.path + "-wal")
        try Data("wal bytes".utf8).write(to: wal)

        do {
            _ = try SudrfPersistentStoreBackup.quarantineUnopenableStore(
                storeURL: store, error: StartupFailure(), quarantineRoot: quarantineRoot,
                date: quarantineDate)
            XCTFail("quarantine без основного store не должен начаться")
        } catch let error as SudrfStoreQuarantineError {
            XCTAssertEqual(error.storeURL, store.standardizedFileURL)
            let directory = try XCTUnwrap(error.recoveryDirectory)
            XCTAssertEqual(try Data(contentsOf: wal), Data("wal bytes".utf8))
            XCTAssertEqual(
                try String(contentsOf: directory.appendingPathComponent(".recovery-state"),
                           encoding: .utf8), "in-progress\ndefault.store-wal\ndefault.store\n")
            XCTAssertEqual(SudrfPersistentStoreBackup.incompleteRecoveryDirectory(
                storeURL: store, backupRoot: quarantineRoot), directory.standardizedFileURL)
            let readme = try String(contentsOf: directory.appendingPathComponent("README.txt"),
                                    encoding: .utf8)
            XCTAssertTrue(readme.contains("нет файлов в каталоге восстановления"))
            XCTAssertTrue(readme.contains("Не перемещайте и не удаляйте файлы"))
        }
    }

    func testExplicitQuarantineRollsBackMovedFilesAfterMoveFailure() throws {
        let store = freshStoreURL!
        let files = [
            (store, Data("store bytes".utf8)),
            (URL(fileURLWithPath: store.path + "-wal"), Data("wal bytes".utf8)),
            (URL(fileURLWithPath: store.path + "-shm"), Data("shm bytes".utf8)),
        ]
        for (url, data) in files {
            try data.write(to: url)
        }

        do {
            _ = try SudrfPersistentStoreBackup.quarantineUnopenableStore(
                storeURL: store, error: StartupFailure(), quarantineRoot: quarantineRoot,
                date: quarantineDate,
                moveItem: { source, destination in
                    if source.standardizedFileURL == store.standardizedFileURL {
                        throw MoveFailure.forward
                    }
                    try FileManager.default.moveItem(at: source, to: destination)
                })
            XCTFail("инъецированная ошибка перемещения должна остановить quarantine")
        } catch let error as SudrfStoreQuarantineError {
            XCTAssertNil(error.recoveryDirectory)
            for (url, expected) in files {
                XCTAssertEqual(try Data(contentsOf: url), expected)
            }
            let contents = try FileManager.default.contentsOfDirectory(atPath: quarantineRoot.path)
            XCTAssertTrue(contents.isEmpty)
        }
    }

    func testIncompleteMarkerWithoutManifestStaysBlocked() throws {
        let store = freshStoreURL!
        try Data("canonical store".utf8).write(to: store)
        let directory = quarantineRoot.appendingPathComponent(quarantineName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("in-progress\n".utf8).write(
            to: directory.appendingPathComponent(".recovery-state"), options: .atomic)

        XCTAssertEqual(
            SudrfPersistentStoreBackup.incompleteRecoveryDirectory(
                storeURL: store, backupRoot: quarantineRoot),
            directory.standardizedFileURL)
    }

    func testIncompleteQuarantineRollbackExposesRecoveryDirectory() async throws {
        let store = freshStoreURL!
        let wal = URL(fileURLWithPath: store.path + "-wal")
        let shm = URL(fileURLWithPath: store.path + "-shm")
        try Data("store bytes".utf8).write(to: store)
        try Data("wal bytes".utf8).write(to: wal)
        try Data("shm bytes".utf8).write(to: shm)

        do {
            _ = try SudrfPersistentStoreBackup.quarantineUnopenableStore(
                storeURL: store, error: StartupFailure(), quarantineRoot: quarantineRoot,
                date: quarantineDate,
                moveItem: { source, destination in
                    if source.standardizedFileURL == store.standardizedFileURL {
                        throw MoveFailure.forward
                    }
                    if destination.standardizedFileURL == wal.standardizedFileURL {
                        throw MoveFailure.rollback
                    }
                    try FileManager.default.moveItem(at: source, to: destination)
                })
            XCTFail("неполный rollback должен быть виден recovery UI")
        } catch let error as SudrfStoreQuarantineError {
            let directory = try XCTUnwrap(error.recoveryDirectory)
            XCTAssertEqual(directory.lastPathComponent, quarantineName)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(
                wal.lastPathComponent)), Data("wal bytes".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: wal.path))
            XCTAssertEqual(try Data(contentsOf: shm), Data("shm bytes".utf8))
            XCTAssertEqual(try Data(contentsOf: store), Data("store bytes".utf8))
            let readme = try String(contentsOf: directory.appendingPathComponent("README.txt"),
                                    encoding: .utf8)
            XCTAssertTrue(readme.contains("Файлы в этом каталоге:\n- default.store-wal"))
            XCTAssertFalse(readme.contains("- default.store-shm"))
            XCTAssertFalse(readme.contains("- default.store\n"))
            XCTAssertTrue(readme.contains("Не перемещайте и не удаляйте файлы"))
            XCTAssertTrue(readme.contains("переместите обратно только те файлы"))
            XCTAssertTrue(readme.contains("Ошибка запуска: test startup failure"))
            XCTAssertTrue(readme.contains("Ошибка перемещения или возврата"))
            XCTAssertEqual(SudrfPersistentStoreBackup.incompleteRecoveryDirectory(
                storeURL: store, backupRoot: quarantineRoot), directory.standardizedFileURL)

            do {
                _ = try await PersistentStoreBootstrapper(recoveryRoot: quarantineRoot)
                    .prepareProduction(storeURL: store, defaultsSuiteName: suiteName)
                XCTFail("relaunch не должен открывать canonical main без WAL")
            } catch let bootstrapError as SudrfStoreBootstrapError {
                XCTAssertFalse(bootstrapError.canQuarantine)
                XCTAssertEqual(bootstrapError.storeURL, store.standardizedFileURL)
                XCTAssertEqual(bootstrapError.recoveryDirectory,
                               directory.standardizedFileURL)
            }
        }
    }

    @MainActor
    func testQuarantinedNonemptyV6StoreCanBeRestoredAfterFreshStoreIsMovedAside() async throws {
        let store = freshStoreURL!
        var container: ModelContainer? = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: store)
        var context: ModelContext? = ModelContext(try XCTUnwrap(container))
        let keys = ["court/2-1/2026", "court/2-2/2026"]
        for (index, key) in keys.enumerated() {
            context?.insert(TrackedCaseRecord(
                key: key, collections: [], caseNumber: "2-\(index + 1)/2026",
                courtTitle: "Тестовый районный суд", displayDomain: "court.sudrf.ru",
                contextData: Data(), snapshotData: nil))
        }
        try context?.save()
        context = nil
        container = nil

        let directory = try SudrfPersistentStoreBackup.quarantineUnopenableStore(
            storeURL: store, error: StartupFailure(), quarantineRoot: quarantineRoot,
            date: quarantineDate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))

        var fresh: ModelContainer? = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: store)
        XCTAssertEqual(try ModelContext(try XCTUnwrap(fresh)).fetch(
            FetchDescriptor<TrackedCaseRecord>()).count, 0)
        fresh = nil

        var reopenedFresh: ModelContainer? = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: store)
        XCTAssertEqual(try ModelContext(try XCTUnwrap(reopenedFresh)).fetch(
            FetchDescriptor<TrackedCaseRecord>()).count, 0)
        reopenedFresh = nil

        let newerStore = root.appendingPathComponent("newer-clean-store", isDirectory: true)
        try FileManager.default.createDirectory(at: newerStore, withIntermediateDirectories: true)
        for original in [store,
                         URL(fileURLWithPath: store.path + "-wal"),
                         URL(fileURLWithPath: store.path + "-shm")] {
            if FileManager.default.fileExists(atPath: original.path) {
                try FileManager.default.moveItem(
                    at: original, to: newerStore.appendingPathComponent(original.lastPathComponent))
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: newerStore.appendingPathComponent(store.lastPathComponent).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))

        let originalFiles = [store,
                             URL(fileURLWithPath: store.path + "-wal"),
                             URL(fileURLWithPath: store.path + "-shm")]
        let pending = originalFiles.filter {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0.lastPathComponent).path)
        }.map(\.lastPathComponent)
        try Data((["in-progress"] + pending).joined(separator: "\n").appending("\n").utf8)
            .write(to: directory.appendingPathComponent(".recovery-state"), options: .atomic)

        for original in originalFiles {
            let quarantined = directory.appendingPathComponent(original.lastPathComponent)
            if FileManager.default.fileExists(atPath: quarantined.path) {
                try FileManager.default.moveItem(at: quarantined, to: original)
            }
        }

        let reopened = try await PersistentStoreBootstrapper(recoveryRoot: quarantineRoot)
            .prepareProduction(storeURL: store, defaultsSuiteName: suiteName)
        let records = try ModelContext(reopened).fetch(FetchDescriptor<TrackedCaseRecord>())
        XCTAssertEqual(Set(records.map(\.key)), Set(keys))
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent(".recovery-state"),
                       encoding: .utf8), "restored\n")
    }
}
