//  TrackedStore.swift — Sudrf · v15
//  Постоянное хранилище ОТСЛЕЖИВАЕМЫХ дел на SwiftData. Заменяет прежний
//  демо-набор: показываются только дела, которые пользователь добавил из поиска;
//  они переживают перезапуск. В записи — поисковый контекст (для перезапроса),
//  компактный снимок (для списков/календаря без сети) и кэш полного движения
//  (карточка открывается мгновенно, обновление — в фоне, см. RefreshCenter).

import Foundation
import SwiftData
import SudrfKit
import os

/// Ошибки хранилища не роняют приложение (graceful degradation), но и не
/// глотаются молча — всё уходит в unified logging (Console.app).
private let storeLog = Logger(subsystem: "ru.sudrf.app", category: "TrackedStore")

@Model
final class TrackedCaseRecord {
    /// Ключ дедупликации: «<отображаемый домен>/<№ дела>».
    @Attribute(.unique) var key: String

    var addedAt: Date
    /// Когда пользователь в последний раз открывал карточку (для бейджа «обновлено»).
    var seenAt: Date?
    /// Legacy-поле «папка-доверитель» (до v20). Оставлено в схеме; содержимое
    /// один раз пересаживается в collectionNames (см. migrateFolders), после
    /// чего обнуляется — иначе удаление дела из всех подборок воскрешало бы папку.
    var folderName: String
    /// Подборки, в которых состоит дело (v20). Одно дело может лежать в
    /// нескольких подборках. Значение по умолчанию — лёгкая миграция SwiftData.
    var collectionNames: [String] = []

    // Денормализованные поля для быстрых списков и фолбэка без декодирования.
    var caseNumber: String
    var courtTitle: String
    var displayDomain: String
    /// Настоящий судебный УИД; не `case_uid` из ссылки. Optional позволяет
    /// лёгкую миграцию существующего SwiftData-хранилища.
    var judicialUID: String? = nil

    /// Поисковый контекст (MovementContext) — JSON, для перезапроса движения.
    var contextData: Data
    /// Снимок производных данных (CaseSnapshot) — JSON; nil, если ещё не собран.
    var snapshotData: Data?
    /// Полное движение (CaseMovement) — JSON-кэш карточки; nil, если ещё не
    /// загружено. Значения по умолчанию — для лёгкой миграции SwiftData.
    var movementData: Data? = nil
    /// Когда движение в последний раз получено с портала (TTL кэша).
    var movementFetchedAt: Date? = nil

    init(key: String, collections: [String], caseNumber: String, courtTitle: String,
         displayDomain: String, contextData: Data, snapshotData: Data?) {
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

    // MARK: Декодирование значений

    var context: MovementContext? {
        get { Self.decode(MovementContext.self, from: contextData, what: "context") }
        set { if let v = newValue, let d = try? JSONEncoder().encode(v) { contextData = d } }
    }
    var snapshot: CaseSnapshot? {
        get { snapshotData.flatMap { Self.decode(CaseSnapshot.self, from: $0, what: "snapshot") } }
        set { snapshotData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    var movement: CaseMovement? {
        get { movementData.flatMap { Self.decode(CaseMovement.self, from: $0, what: "movement") } }
        set { movementData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) -> T? {
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            storeLog.error("Не удалось декодировать \(what, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Обёртка хранилища

@MainActor
final class TrackedStore {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    convenience init() {
        self.init(inMemory: false)
    }

    /// `inMemory: true` — для тестов, чтобы не трогать пользовательское
    /// `~/Library/Application Support` и держать записи изолированно.
    /// Продовый init (`inMemory: false`) создаёт постоянное хранилище; при
    /// сбое (несовместимая миграция и т. п.) — откат в память, чтобы
    /// приложение не падало на старте.
    init(inMemory: Bool) {
        do {
            let config: ModelConfiguration = inMemory
                ? ModelConfiguration(isStoredInMemoryOnly: true)
                : ModelConfiguration()
            container = try ModelContainer(for: TrackedCaseRecord.self,
                                           configurations: config)
        } catch {
            storeLog.error("Хранилище не открылось, откат в память: \(error, privacy: .public)")
            do {
                container = try ModelContainer(for: TrackedCaseRecord.self,
                                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            } catch {
                fatalError("SwiftData не смог создать даже in-memory хранилище: \(error)")
            }
        }
        migrateFolders()
        migrateJudicialUIDs()
    }

    /// Одноразовый посев подборок из legacy-папок (до v20): непустая папка
    /// «доверителя» становится подборкой, после чего поле очищается.
    private func migrateFolders() {
        var changed = false
        for rec in all() where !rec.folderName.isEmpty {
            if rec.folderName != "Без папки", rec.collectionNames.isEmpty {
                rec.collectionNames = [rec.folderName]
            }
            rec.folderName = ""
            changed = true
        }
        if changed { save() }
    }

    /// Наполняет новый денормализованный индекс из JSON-контекста/кэша без сети.
    /// Идемпотентно; дубли пока допустимы и будут сведены repair-координатором.
    private func migrateJudicialUIDs() {
        var changed = false
        for rec in all() where (rec.judicialUID ?? "").isEmpty {
            let uid = rec.context?.judicialUID ?? rec.movement?.uid
            guard let uid, !uid.isEmpty else { continue }
            rec.judicialUID = Self.normalizedUID(uid)
            changed = true
        }
        if changed { save() }
    }

    nonisolated static func normalizedUID(_ raw: String) -> String {
        raw.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    func all() -> [TrackedCaseRecord] {
        let d = FetchDescriptor<TrackedCaseRecord>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
        return (try? context.fetch(d)) ?? []
    }

    func record(forKey key: String) -> TrackedCaseRecord? {
        var d = FetchDescriptor<TrackedCaseRecord>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    func isTracked(key: String) -> Bool { record(forKey: key) != nil }

    func records(forJudicialUID uid: String) -> [TrackedCaseRecord] {
        let normalized = Self.normalizedUID(uid)
        return all().filter { ($0.judicialUID ?? "") == normalized }
    }

    @discardableResult
    func upsert(context ctx: MovementContext, snapshot snap: CaseSnapshot?,
                movement mv: CaseMovement? = nil, collections: [String]) -> TrackedCaseRecord {
        let key = ctx.key
        let ctxData = (try? JSONEncoder().encode(ctx)) ?? Data()
        let snapData = snap.flatMap { try? JSONEncoder().encode($0) }
        let mvData = mv.flatMap { try? JSONEncoder().encode($0) }
        if let existing = record(forKey: key) {
            existing.contextData = ctxData
            if snapData != nil { existing.snapshotData = snapData }
            if mvData != nil {
                existing.movementData = mvData
                existing.movementFetchedAt = Date()
            }
            existing.caseNumber = ctx.caseNumber
            existing.courtTitle = ctx.courtTitle
            existing.displayDomain = ctx.displayDomain
            if let uid = ctx.judicialUID ?? mv?.uid, !uid.isEmpty {
                existing.judicialUID = Self.normalizedUID(uid)
            }
            save()
            return existing
        }
        let rec = TrackedCaseRecord(key: key, collections: collections, caseNumber: ctx.caseNumber,
                                    courtTitle: ctx.courtTitle, displayDomain: ctx.displayDomain,
                                    contextData: ctxData, snapshotData: snapData)
        if let uid = ctx.judicialUID ?? mv?.uid, !uid.isEmpty {
            rec.judicialUID = Self.normalizedUID(uid)
        }
        if mvData != nil {
            rec.movementData = mvData
            rec.movementFetchedAt = Date()
        }
        context.insert(rec)
        save()
        return rec
    }

    func remove(key: String) {
        guard let rec = record(forKey: key) else { return }
        context.delete(rec)
        save()
    }

    /// Низкоуровневое удаление для атомарного repair-слияния. Вызывающая
    /// сторона обязана завершить группу одним `save()`.
    func deleteWithoutSaving(_ rec: TrackedCaseRecord) {
        context.delete(rec)
    }

    /// SwiftData сохраняет все изменения контекста одной транзакцией. При
    /// ошибке откатываем и изменения выжившей записи, и отложенные удаления,
    /// чтобы repair никогда не оставил базу в полуслитом состоянии.
    @discardableResult
    func save() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            storeLog.error("Не удалось сохранить хранилище: \(error, privacy: .public)")
            return false
        }
    }
}
