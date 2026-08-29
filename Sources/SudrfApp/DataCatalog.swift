import Foundation
import SudrfKit
import SwiftData
import os

private let backupLog = Logger(subsystem: "ru.sudrf.app", category: "StoreBackup")
private let storeBootstrapLog = Logger(subsystem: "ru.sudrf.app", category: "StoreBootstrap")

private let storeBootstrapBundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
private let storeBootstrapAppVersion: String = {
    let info = Bundle.main.infoDictionary ?? [:]
    let shortVersion = info["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info["CFBundleVersion"] as? String ?? "unknown"
    return shortVersion + " (" + build + ")"
}()

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
        if caseKey != document.caseKey { caseKey = document.caseKey }
        if sourceActID != document.sourceActID { sourceActID = document.sourceActID }
        if caseNumber != document.caseNumber { caseNumber = document.caseNumber }
        if judicialUID != document.judicialUID { judicialUID = document.judicialUID }
        if court != document.court { court = document.court }
        if instanceLevel != document.instanceLevel.rawValue {
            instanceLevel = document.instanceLevel.rawValue
        }
        if kind != document.kind { kind = document.kind }
        if actDate != document.date { actDate = document.date }
        if sourceHash != document.sourceHash {
            if sourceText != document.sourceText { sourceText = document.sourceText }
            sourceHash = document.sourceHash
            if let data = try? JSONEncoder().encode(document.paragraphs), paragraphData != data {
                paragraphData = data
            }
            if paragraphizerVersion != document.paragraphizerVersion {
                paragraphizerVersion = document.paragraphizerVersion
            }
        } else if sourceText != document.sourceText {
            sourceText = document.sourceText
        }
        if identityVersion != 1 { identityVersion = 1 }
        if self.semanticKey != semanticKey { self.semanticKey = semanticKey }
        if self.fetchedAt != fetchedAt { self.fetchedAt = fetchedAt }
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

    func isStale(for document: ActDocument, identity: SummaryIdentity? = nil) -> Bool {
        SummaryStaleness.isStale(
            sourceHash: sourceHash, promptVersion: promptVersion,
            pipelineVersion: pipelineVersion, document: document, identity: identity)
    }
}

/// Сохранённая сводка устаревает не только при изменении текста акта, но и при
/// смене prompt или pipeline: результат прежнего prompt нельзя показывать как
/// актуальный. Когда текущая конфигурация недоступна (например, ключ ещё не
/// введён и сводку всё равно нельзя перегенерировать), сравнивается только hash.
enum SummaryStaleness {
    static func isStale(sourceHash: String, promptVersion: String,
                        pipelineVersion: String, document: ActDocument,
                        identity: SummaryIdentity?) -> Bool {
        if sourceHash != document.sourceHash { return true }
        guard let identity else { return false }
        return promptVersion != identity.promptVersion
            || pipelineVersion != identity.pipelineVersion
    }
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

    /// Снимок модели, с которой была выпущена схема V3. VersionedSchema
    /// нельзя строить из текущего `TrackedCaseRecord`: после добавления нового
    /// поля SwiftData увидит одинаковые V3/V4 и завершит приложение исключением.
    @Model
    final class TrackedCaseRecord {
        @Attribute(.unique) var key: String
        var addedAt: Date
        var seenAt: Date?
        var folderName: String
        var collectionNames: [String] = []
        var caseNumber: String
        var courtTitle: String
        var displayDomain: String
        var judicialUID: String? = nil
        var contextData: Data
        var snapshotData: Data?
        var movementData: Data? = nil
        var movementFetchedAt: Date? = nil

        init(key: String, collections: [String], caseNumber: String,
             courtTitle: String, displayDomain: String, contextData: Data,
             snapshotData: Data?) {
            self.key = key
            self.addedAt = Date()
            self.seenAt = nil
            self.folderName = ""
            self.collectionNames = collections
            self.caseNumber = caseNumber
            self.courtTitle = courtTitle
            self.displayDomain = displayDomain
            self.contextData = contextData
            self.snapshotData = snapshotData
        }
    }

    static var models: [any PersistentModel.Type] {
        [TrackedCaseRecord.self, CourtActRecord.self, ActSummaryRecord.self]
    }
}

enum SudrfSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    /// Неизменяемый снимок выпущенной V4. Нельзя ссылаться здесь на текущую
    /// модель: добавление поля в V5 иначе делает V4 и V5 неразличимыми для
    /// SwiftData и ломает открытие существующего store.
    @Model
    final class TrackedCaseRecord {
        @Attribute(.unique) var key: String
        var addedAt: Date
        var seenAt: Date?
        var folderName: String
        var collectionNames: [String] = []
        var caseNumber: String
        var courtTitle: String
        var displayDomain: String
        var judicialUID: String? = nil
        var contextData: Data
        var snapshotData: Data?
        var movementData: Data? = nil
        var movementFetchedAt: Date? = nil
        var enforcementData: Data? = nil

        init(key: String, collections: [String], caseNumber: String,
             courtTitle: String, displayDomain: String, contextData: Data,
             snapshotData: Data?) {
            self.key = key
            self.addedAt = Date()
            self.seenAt = nil
            self.folderName = ""
            self.collectionNames = collections
            self.caseNumber = caseNumber
            self.courtTitle = courtTitle
            self.displayDomain = displayDomain
            self.contextData = contextData
            self.snapshotData = snapshotData
        }
    }

    static var models: [any PersistentModel.Type] {
        [TrackedCaseRecord.self, CourtActRecord.self, ActSummaryRecord.self]
    }
}

enum SudrfSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    /// Неизменяемый снимок выпущенной V5. V6 добавляет persistent identity,
    /// поэтому ссылаться здесь на текущую модель нельзя: SwiftData должен
    /// увидеть реальное различие схем при открытии уже существующей базы.
    @Model
    final class TrackedCaseRecord {
        @Attribute(.unique) var key: String
        var addedAt: Date
        var seenAt: Date?
        var folderName: String
        var collectionNames: [String] = []
        var caseNumber: String
        var courtTitle: String
        var displayDomain: String
        var judicialUID: String? = nil
        var contextData: Data
        var snapshotData: Data?
        var movementData: Data? = nil
        var movementFetchedAt: Date? = nil
        var sourceRefreshAttemptData: Data? = nil
        var enforcementData: Data? = nil

        init(key: String, collections: [String], caseNumber: String,
             courtTitle: String, displayDomain: String, contextData: Data,
             snapshotData: Data?) {
            self.key = key
            self.addedAt = Date()
            self.seenAt = nil
            self.folderName = ""
            self.collectionNames = collections
            self.caseNumber = caseNumber
            self.courtTitle = courtTitle
            self.displayDomain = displayDomain
            self.contextData = contextData
            self.snapshotData = snapshotData
        }
    }

    static var models: [any PersistentModel.Type] {
        [TrackedCaseRecord.self, CourtActRecord.self, ActSummaryRecord.self]
    }
}

enum SudrfSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        [TrackedCaseRecord.self, CourtActRecord.self, ActSummaryRecord.self]
    }
}

enum SudrfSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SudrfSchemaV1.self, SudrfSchemaV2.self, SudrfSchemaV3.self,
         SudrfSchemaV4.self, SudrfSchemaV5.self, SudrfSchemaV6.self]
    }
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: SudrfSchemaV1.self, toVersion: SudrfSchemaV2.self),
            .lightweight(fromVersion: SudrfSchemaV2.self, toVersion: SudrfSchemaV3.self),
            .lightweight(fromVersion: SudrfSchemaV3.self, toVersion: SudrfSchemaV4.self),
            .lightweight(fromVersion: SudrfSchemaV4.self, toVersion: SudrfSchemaV5.self),
            .lightweight(fromVersion: SudrfSchemaV5.self, toVersion: SudrfSchemaV6.self),
        ]
    }
}

struct SudrfStoreBootstrapError: LocalizedError {
    let underlying: Error
    let backupDirectory: URL?
    /// Точный canonical URL, который bootstrap пытался открыть. Recovery UI не
    /// должен заново вычислять путь: Application Support или legacy migration
    /// могли уже нормализовать его до этой ошибки.
    let storeURL: URL
    /// База существовала до этого запуска. От этого зависит совет: восстановить
    /// из копии можно только то, что было. Свежему пользователю прежний текст
    /// предлагал восстановить копию, которой не существует.
    var hadExistingStore: Bool = true
    let canQuarantine: Bool
    let recoveryDirectory: URL?

    init(underlying: Error, backupDirectory: URL?, storeURL: URL,
         hadExistingStore: Bool = true, canQuarantine: Bool? = nil,
         recoveryDirectory: URL? = nil) {
        self.underlying = underlying
        self.backupDirectory = backupDirectory
        self.storeURL = storeURL.resolvingSymlinksInPath().standardizedFileURL
        self.hadExistingStore = hadExistingStore
        self.canQuarantine = canQuarantine ?? hadExistingStore
        self.recoveryDirectory = recoveryDirectory?.standardizedFileURL
    }

    var errorDescription: String? {
        var text = "Не удалось открыть базу отслеживаемых дел: \(underlying.localizedDescription)"
        if let backupDirectory {
            text += "\n\nРезервная копия до миграции: \(backupDirectory.path)"
        }
        if let recoveryDirectory {
            text += "\n\nНезавершённое восстановление: \(recoveryDirectory.path). Не запускайте базу до ручного возврата файлов по README.txt."
        }
        if recoveryDirectory != nil {
            text += "\n\nSudrf заблокирован для записи до ручного завершения восстановления по README.txt. Не удаляйте каталог Sudrf."
        } else if hadExistingStore {
            text += "\n\nSudrf заблокирован для записи. Закройте приложение и восстановите базу из копии либо передайте эту ошибку разработчику."
        } else {
            text += "\n\nОтслеживаемых дел в этой копии приложения ещё не было, поэтому терять нечего: закройте Sudrf, удалите папку Sudrf в Application Support и запустите снова. Если ошибка повторится — передайте её разработчику."
        }
        return text
    }
}

/// Ошибка явного quarantine. При неполном rollback каталог остаётся единственным
/// местом, где могут лежать уже перемещённые файлы; UI может показать его в Finder.
struct SudrfStoreQuarantineError: LocalizedError {
    let underlying: Error
    let storeURL: URL
    let recoveryDirectory: URL?
    let rollbackError: Error?

    var errorDescription: String? {
        var text = "Не удалось отложить неоткрываемую базу: \(underlying.localizedDescription)"
        if let recoveryDirectory {
            text += "\n\nЧасть файлов может находиться в каталоге восстановления: \(recoveryDirectory.path). Не удаляйте и не перемещайте его содержимое до ручного восстановления."
        }
        if let rollbackError {
            text += "\n\nНе удалось полностью вернуть уже перемещённые файлы: \(rollbackError.localizedDescription)"
        }
        return text
    }
}

enum SudrfPersistentStoreBackup {
    private static let recoveryStateFilename = ".recovery-state"
    private static let recoveryComplete = "complete"

    private static var currentSchemaVersion: String {
        String(describing: SudrfSchemaV6.versionIdentifier)
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

    /// Explicitly sets aside an unopenable SQLite set. This never runs during
    /// startup: callers invoke it only after the user confirms recovery.
    ///
    /// README is written before the first move so a partially completed action
    /// remains understandable. Sidecars move first; the main store is the last
    /// completion marker. `moveItem` is injectable solely for failure-path tests.
    static func quarantineUnopenableStore(
        storeURL: URL,
        error: Error,
        quarantineRoot: URL? = nil,
        date: Date = .now,
        moveItem: (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) throws -> URL {
        let fileManager = FileManager.default
        let storeURL = storeURL.resolvingSymlinksInPath().standardizedFileURL
        let root = quarantineRoot ?? defaultBackupRoot()
        let directory = try uniqueQuarantineDirectory(root: root, date: date)
        let sources = [
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ].filter { fileManager.fileExists(atPath: $0.path) } + [storeURL]

        do {
            try writeQuarantineReadme(
                directory: directory, storeURL: storeURL, startupError: error, date: date,
                movedFiles: sources.map(\.lastPathComponent), isPartial: true)
            try writeRecoveryState(
                "in-progress", directory: directory,
                pendingFiles: sources.map(\.lastPathComponent))
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        guard fileManager.fileExists(atPath: storeURL.path) else {
            try? writeQuarantineReadme(
                directory: directory, storeURL: storeURL, startupError: error, date: date,
                movedFiles: [], recoveryError: CocoaError(.fileNoSuchFile), isPartial: true)
            throw SudrfStoreQuarantineError(
                underlying: CocoaError(.fileNoSuchFile), storeURL: storeURL,
                recoveryDirectory: directory, rollbackError: nil)
        }

        var moved: [(source: URL, destination: URL)] = []
        do {
            for source in sources {
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                try moveItem(source, destination)
                moved.append((source, destination))
            }
            try writeQuarantineReadme(
                directory: directory, storeURL: storeURL, startupError: error, date: date,
                movedFiles: sources.map(\.lastPathComponent))
            try writeRecoveryState(recoveryComplete, directory: directory)
            backupLog.notice("Неоткрываемая база перемещена в \(directory.path, privacy: .public)")
            return directory
        } catch let operationError {
            var rollbackError: Error?
            for item in moved.reversed() {
                do {
                    try moveItem(item.destination, item.source)
                } catch let restoreError {
                    if rollbackError == nil { rollbackError = restoreError }
                }
            }

            if let rollbackError {
                // This is the only path where a recovery directory remains.
                // Refresh its generated README so its file list describes what
                // is actually still there after the best-effort rollback.
                let remaining = moved.compactMap { item in
                    fileManager.fileExists(atPath: item.destination.path)
                        ? item.destination.lastPathComponent : nil
                }
                try? writeQuarantineReadme(
                    directory: directory, storeURL: storeURL, startupError: error, date: date,
                    movedFiles: remaining, recoveryError: operationError, isPartial: true)
                try? writeRecoveryState(
                    "in-progress", directory: directory, pendingFiles: remaining)
                throw SudrfStoreQuarantineError(
                    underlying: operationError, storeURL: storeURL,
                    recoveryDirectory: directory, rollbackError: rollbackError)
            }

            // Only an empty, newly created recovery directory remains. Store
            // files are all back at their original paths, so it is safe to clean
            // this implementation artifact without deleting user data.
            try? fileManager.removeItem(at: directory)
            throw SudrfStoreQuarantineError(
                underlying: operationError, storeURL: storeURL,
                recoveryDirectory: nil, rollbackError: nil)
        }
    }

    /// A durable in-progress marker makes a crash or incomplete rollback fail
    /// closed on the next launch instead of opening a main file without its WAL.
    static func incompleteRecoveryDirectory(storeURL: URL,
                                            backupRoot: URL? = nil) -> URL? {
        let root = backupRoot ?? defaultBackupRoot()
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return nil }
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where directory.lastPathComponent.hasPrefix("unopenable-") {
            let marker = directory.appendingPathComponent(recoveryStateFilename)
            guard FileManager.default.fileExists(atPath: marker.path) else { continue }
            let lines = (try? String(contentsOf: marker, encoding: .utf8))?
                .split(whereSeparator: \.isNewline).map(String.init)
            guard let state = lines?.first else {
                return directory.standardizedFileURL
            }
            if state == recoveryComplete || state == "restored" { continue }
            let pendingFiles = Array(lines?.dropFirst() ?? [])
            guard !pendingFiles.isEmpty else { return directory.standardizedFileURL }
            let storeExists = FileManager.default.fileExists(atPath: storeURL.path)
            let allReturned = storeExists && pendingFiles.allSatisfy { filename in
                let staged = directory.appendingPathComponent(filename)
                let canonical = storeURL.deletingLastPathComponent()
                    .appendingPathComponent(filename)
                return !FileManager.default.fileExists(atPath: staged.path)
                    && FileManager.default.fileExists(atPath: canonical.path)
            }
            if allReturned {
                do {
                    try writeRecoveryState("restored", directory: directory)
                    continue
                } catch {
                    return directory.standardizedFileURL
                }
            }
            return directory.standardizedFileURL
        }
        return nil
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

    private static func uniqueQuarantineDirectory(root: URL, date: Date) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let base = "unopenable-\(quarantineTimestamp(date))-schema-\(currentSchemaVersion)"
        var suffix = 0
        while true {
            let name = suffix == 0 ? base : base + "-\(suffix)"
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard !fileManager.fileExists(atPath: directory.path) else {
                suffix += 1
                continue
            }
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
                return directory
            } catch {
                // A concurrent confirmation may have created this exact name.
                // Never replace it; choose the next suffix instead.
                if fileManager.fileExists(atPath: directory.path) {
                    suffix += 1
                    continue
                }
                throw error
            }
        }
    }

    private static func quarantineTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter.string(from: date)
    }

    private static func quarantineReadme(storeURL: URL, startupError: Error, date: Date,
                                         movedFiles: [String], recoveryError: Error? = nil,
                                         isPartial: Bool = false) -> String {
        let timestamp = quarantineTimestamp(date)
        let files = movedFiles.isEmpty
            ? "- нет файлов в каталоге восстановления"
            : movedFiles.map { "- \($0)" }.joined(separator: "\n")
        let recoveryFailure = recoveryError.map {
            "\nОшибка перемещения или возврата: \($0.localizedDescription)\n"
        } ?? ""
        let instructions = isPartial ? """
        Незавершённое восстановление:
        1. Закройте Sudrf перед любыми действиями.
        2. Не перемещайте и не удаляйте файлы, которые остались по исходному пути.
        3. Из перечисленного ниже переместите обратно только те файлы, которые фактически находятся в этом каталоге, сохраняя исходные имена.
        4. Запускайте Sudrf только после возврата всех перечисленных файлов.
        """ : """
        Безопасное восстановление:
        1. Закройте Sudrf перед любыми действиями.
        2. Переместите новый canonical-набор файлов (`store`, `-wal` и `-shm`) вместе в отдельную безопасную папку.
        3. Переместите все перечисленные карантинные файлы обратно по исходному пути, сохраняя исходные имена.
        4. Запускайте Sudrf только после полного возврата всех перечисленных файлов.
        """
        return """
        Восстановление базы Sudrf

        Создано (UTC): \(timestamp)
        Приложение: \(storeBootstrapBundleIdentifier) \(storeBootstrapAppVersion)
        Версия схемы: \(currentSchemaVersion)
        Исходный путь базы: \(storeURL.path)
        Ошибка запуска: \(startupError.localizedDescription)
        \(recoveryFailure)

        Файлы в этом каталоге:
        \(files)

        \(instructions)
        """
    }

    private static func writeQuarantineReadme(directory: URL, storeURL: URL,
                                               startupError: Error, date: Date,
                                               movedFiles: [String],
                                               recoveryError: Error? = nil,
                                               isPartial: Bool = false) throws {
        let readme = quarantineReadme(
            storeURL: storeURL, startupError: startupError, date: date,
            movedFiles: movedFiles, recoveryError: recoveryError, isPartial: isPartial)
        try Data(readme.utf8).write(to: directory.appendingPathComponent("README.txt"),
                                     options: .atomic)
    }

    private static func writeRecoveryState(_ state: String, directory: URL,
                                           pendingFiles: [String] = []) throws {
        let contents = ([state] + pendingFiles).joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(
            to: directory.appendingPathComponent(recoveryStateFilename), options: .atomic)
    }

    private static func isUsableBackup(_ directory: URL, storeURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(storeURL.lastPathComponent).path)
    }
}

enum SudrfModelContainerFactory {
    static func make(inMemory: Bool, storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SudrfSchemaV6.self)
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

}

enum SudrfPersistentStoreLocation {
    /// Pure path lookup used by fail-closed recovery checks before legacy
    /// migration is allowed to copy or remove any store component.
    static func canonicalProductionURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: false)
        return support.appendingPathComponent("Sudrf", isDirectory: true)
            .appendingPathComponent("default.store")
    }

    static func productionURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true)
        let directory = support.appendingPathComponent("Sudrf", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("default.store")
        try moveLegacyStoreIfNeeded(from: ModelConfiguration().url,
                                    to: destination,
                                    fileManager: fileManager)
        return destination
    }

    static func moveLegacyStoreIfNeeded(from source: URL,
                                        to destination: URL,
                                        fileManager: FileManager = .default) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)

        // Main store — completion marker. If it exists, a previous copy
        // finished; remaining legacy files are harmless stale duplicates.
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        guard fileManager.fileExists(atPath: source.path) else { return }

        let sidecarSuffixes = ["-wal", "-shm"]
        var copied: [URL] = []
        let stagedMain = destination.deletingLastPathComponent().appendingPathComponent(
            ".default.store-migration-\(UUID().uuidString)")
        do {
            for suffix in sidecarSuffixes {
                let old = URL(fileURLWithPath: source.path + suffix)
                let new = URL(fileURLWithPath: destination.path + suffix)
                // The previous move-based migration could already have moved
                // this sidecar before crashing. With no source counterpart the
                // destination is the only copy and must be preserved.
                guard fileManager.fileExists(atPath: old.path) else { continue }
                // When both exist, the sidecar adjacent to the source main
                // belongs to the intact source set and is authoritative.
                if fileManager.fileExists(atPath: new.path) {
                    try fileManager.removeItem(at: new)
                }
                try fileManager.copyItem(at: old, to: new)
                copied.append(new)
            }
            try fileManager.copyItem(at: source, to: stagedMain)
            try fileManager.moveItem(at: stagedMain, to: destination)
            copied.append(destination)
        } catch {
            try? fileManager.removeItem(at: stagedMain)
            for url in copied { try? fileManager.removeItem(at: url) }
            throw error
        }

        // Destination is now complete. Cleanup failure leaves a safe duplicate
        // and does not prevent the application from opening the copied store.
        for suffix in sidecarSuffixes + [""] {
            let old = URL(fileURLWithPath: source.path + suffix)
            if fileManager.fileExists(atPath: old.path) {
                try? fileManager.removeItem(at: old)
            }
        }
    }
}

/// Production bootstrap использует отдельный ModelContext внутри actor. До
/// возврата контейнера выполнены backup, schema migration, legacy-поля и полная
/// проекция актов; UI получает только полностью подготовленное хранилище.
actor PersistentStoreBootstrapper {
    private let recoveryRoot: URL?

    init(recoveryRoot: URL? = nil) {
        self.recoveryRoot = recoveryRoot
    }

    /// `storeURL` и `defaultsSuiteName` инжектируются только тестами. Боевой путь
    /// живёт в `Application Support/Sudrf`; старый `default.store` переносится
    /// туда до открытия. Без инжекции сценарий первого запуска —
    /// база, которой ещё нет, — нечем было проверить, кроме как на живой
    /// машине. Имя suite, а не сам `UserDefaults`: он не `Sendable` и через
    /// границу актора не проходит.
    func prepareProduction(storeURL: URL? = nil,
                           defaultsSuiteName: String? = nil) throws -> ModelContainer {
        let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let usesProductionStore = storeURL == nil
        let preflightStoreURL = (try storeURL
            ?? SudrfPersistentStoreLocation.canonicalProductionURL())
            .resolvingSymlinksInPath().standardizedFileURL
        let recoveryDirectory = (usesProductionStore || recoveryRoot != nil)
            ? SudrfPersistentStoreBackup.incompleteRecoveryDirectory(
                storeURL: preflightStoreURL, backupRoot: recoveryRoot)
            : nil
        if let recoveryDirectory {
            throw SudrfStoreBootstrapError(
                underlying: CocoaError(.fileReadCorruptFile), backupDirectory: nil,
                storeURL: preflightStoreURL,
                hadExistingStore: FileManager.default.fileExists(atPath: preflightStoreURL.path),
                canQuarantine: false, recoveryDirectory: recoveryDirectory)
        }
        let storeURL = (try storeURL ?? SudrfPersistentStoreLocation.productionURL())
            .resolvingSymlinksInPath().standardizedFileURL
        // Замеряем ДО всего: от этого зависит, есть ли что терять.
        let hadExistingStore = FileManager.default.fileExists(atPath: storeURL.path)
        logStartup(storeURL: storeURL, outcome: "not_started",
                   newlyCreated: !hadExistingStore)
        var backup: URL?
        do {
            backup = try SudrfPersistentStoreBackup.prepare(storeURL: storeURL,
                                                             backupRoot: recoveryRoot,
                                                             defaults: defaults)
            return try open(storeURL: storeURL, defaults: defaults,
                            newlyCreated: !hadExistingStore)
        } catch {
            logStartup(storeURL: storeURL, outcome: "failure",
                       newlyCreated: !hadExistingStore, error: error)
            // Первого запуска это касаться не должно. Базы до нас не было,
            // отслеживаемых дел тоже — значит терять нечего, и упираться в
            // тупик не за что. Убираем обломки неудавшегося создания (их
            // оставляет, например, падение на первом запуске) и пробуем ещё
            // раз. Если база БЫЛА — поведение прежнее: блокируем и не трогаем
            // файлы, это осознанное решение v0.41.0 про сохранность данных.
            if !hadExistingStore, let container = try? recreate(storeURL: storeURL,
                                                               defaults: defaults) {
                return container
            }
            throw SudrfStoreBootstrapError(underlying: error, backupDirectory: backup,
                                           storeURL: storeURL,
                                           hadExistingStore: hadExistingStore)
        }
    }

    private func open(storeURL: URL, defaults: UserDefaults,
                      newlyCreated: Bool) throws -> ModelContainer {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try TrackedStorePreparation.prepare(context: context)
        let trackedCaseRecordCount = try context.fetch(
            FetchDescriptor<TrackedCaseRecord>()).count
        SudrfPersistentStoreBackup.markMigrationCompleted(defaults: defaults)
        logStartup(storeURL: storeURL, outcome: "success", newlyCreated: newlyCreated,
                   trackedCaseRecordCount: trackedCaseRecordCount)
        return container
    }

    /// Сносит недосозданную базу и её спутники и открывает заново. Вызывается
    /// только когда базы до запуска не существовало: удалять чужие данные этот
    /// путь не может по построению.
    private func recreate(storeURL: URL, defaults: UserDefaults) throws -> ModelContainer {
        for url in [storeURL,
                    URL(fileURLWithPath: storeURL.path + "-wal"),
                    URL(fileURLWithPath: storeURL.path + "-shm")] {
            try? FileManager.default.removeItem(at: url)
        }
        return try open(storeURL: storeURL, defaults: defaults, newlyCreated: true)
    }

    private func logStartup(storeURL: URL, outcome: String, newlyCreated: Bool,
                            trackedCaseRecordCount: Int? = nil, error: Error? = nil) {
        let sidecars = [
            ("store", storeURL),
            ("wal", URL(fileURLWithPath: storeURL.path + "-wal")),
            ("shm", URL(fileURLWithPath: storeURL.path + "-shm")),
        ]
        let fileState = sidecars.map { name, url in
            let exists = FileManager.default.fileExists(atPath: url.path)
            let size: String
            if exists,
               let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let number = attributes[.size] as? NSNumber {
                size = String(number.int64Value)
            } else {
                size = "unknown"
            }
            return name + "Exists=" + String(exists) + " " + name + "Bytes=" + size
        }.joined(separator: " ")
        var publicFields = "fileState=" + fileState
            + " bundle=" + storeBootstrapBundleIdentifier
            + " appVersion=" + storeBootstrapAppVersion
            + " schemaVersion=" + String(describing: SudrfSchemaV6.versionIdentifier)
            + " openOutcome=" + outcome
            + " newlyCreated=" + String(newlyCreated)
        if let trackedCaseRecordCount {
            publicFields += " trackedCaseRecordCount=" + String(trackedCaseRecordCount)
        }
        if let error {
            publicFields += " errorType=" + String(reflecting: type(of: error))
        }
        storeBootstrapLog.notice(
            "storeURL=\(storeURL.path, privacy: .private) \(publicFields, privacy: .public)")
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

    func isStale(for document: ActDocument, identity: SummaryIdentity? = nil) -> Bool {
        SummaryStaleness.isStale(
            sourceHash: sourceHash, promptVersion: promptVersion,
            pipelineVersion: pipelineVersion, document: document, identity: identity)
    }
}

/// Единственная actor-граница чтения SwiftData для Spotlight, App Intents и
/// AI. Ни один `@Model`-объект наружу не выходит.
actor CaseCatalog {
    private let container: ModelContainer
    /// Не создаём контекст в `init`: actor часто создаётся из MainActor, а
    /// SwiftData привязывает ModelContext к текущему executor. Lazy-инициализация
    /// происходит при первом actor-isolated вызове.
    private lazy var context: ModelContext = {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }()

    init(container: ModelContainer) {
        self.container = container
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
        if let record = try context.fetch(descriptor).first {
            return Self.snapshot(from: record)
        }

        // AppEntity identifiers are durable user-facing references. After an
        // identity merge the old record is gone, but its key remains on the
        // survivor as an alias. Resolve that alias before App Intents gives up
        // on restoring a saved Shortcut.
        let aliases = try context.fetch(FetchDescriptor<TrackedCaseRecord>())
        return aliases.first { $0.legacyKeyAliases.contains(id) }
            .map(Self.snapshot(from:))
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
