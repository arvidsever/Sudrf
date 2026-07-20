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

enum ProjectionScope: Sendable, Equatable {
    case none
    case cases(Set<String>)
    case full
}

/// Общая реализация подготовки store. Она не привязана к mainContext и может
/// выполняться как production bootstrap в actor с собственным ModelContext.
enum TrackedStorePreparation {
    static func prepare(context: ModelContext) throws {
        try migrateFolders(context: context)
        try migrateJudicialUIDs(context: context)
        try CourtActProjectionSynchronizer.synchronize(context: context, scope: .full)
        try context.save()
    }

    private static func migrateFolders(context: ModelContext) throws {
        let records = try context.fetch(FetchDescriptor<TrackedCaseRecord>())
        for rec in records where !rec.folderName.isEmpty {
            if rec.folderName != "Без папки", rec.collectionNames.isEmpty {
                rec.collectionNames = [rec.folderName]
            }
            rec.folderName = ""
        }
    }

    private static func migrateJudicialUIDs(context: ModelContext) throws {
        let records = try context.fetch(FetchDescriptor<TrackedCaseRecord>())
        for rec in records where (rec.judicialUID ?? "").isEmpty {
            let uid = rec.context?.judicialUID ?? rec.movement?.uid
            guard let uid, !uid.isEmpty else { continue }
            rec.judicialUID = TrackedStore.normalizedUID(uid)
        }
    }
}

enum CourtActProjectionSynchronizer {
    static func synchronize(context: ModelContext, scope: ProjectionScope) throws {
        let tracked: [TrackedCaseRecord]
        let stored: [CourtActRecord]
        switch scope {
        case .none:
            return
        case .full:
            tracked = try context.fetch(FetchDescriptor<TrackedCaseRecord>())
            stored = try context.fetch(FetchDescriptor<CourtActRecord>())
        case .cases(let caseKeys):
            tracked = try caseKeys.compactMap { key in
                var descriptor = FetchDescriptor<TrackedCaseRecord>(
                    predicate: #Predicate { $0.key == key })
                descriptor.fetchLimit = 1
                return try context.fetch(descriptor).first
            }
            stored = try caseKeys.flatMap { caseKey in
                try context.fetch(FetchDescriptor<CourtActRecord>(
                    predicate: #Predicate { $0.caseKey == caseKey }))
            }
        }
        var unmatched = Set(stored.map(ObjectIdentifier.init))
        let byExact = Dictionary(grouping: stored) {
            lookupKey($0.caseKey, $0.sourceActID)
        }
        let bySemantic = Dictionary(grouping: stored) {
            lookupKey($0.caseKey, $0.semanticKey)
        }
        let byHash = Dictionary(grouping: stored) {
            lookupKey($0.caseKey, $0.sourceHash)
        }
        var desiredIDs = Set<String>()
        var undecodableCaseKeys = Set<String>()

        for trackedRecord in tracked {
            guard let movement = trackedRecord.movement else {
                if trackedRecord.movementData != nil {
                    undecodableCaseKeys.insert(trackedRecord.key)
                }
                continue
            }
            for act in movement.acts {
                let instance = movement.instances.first {
                    $0.actID == act.id || $0.level == act.instanceLevel
                }
                let document = ActDocument(
                    caseKey: trackedRecord.key, sourceActID: act.id,
                    caseNumber: movement.caseNumber.isEmpty
                        ? trackedRecord.caseNumber : movement.caseNumber,
                    judicialUID: trackedRecord.judicialUID
                        ?? (movement.uid.isEmpty ? nil : movement.uid),
                    court: instance?.court ?? act.courtShort,
                    instanceLevel: act.instanceLevel, kind: act.title, date: act.date,
                    sourceText: movement.actBodies[act.id] ?? "")
                let semanticKey = semanticKey(
                    caseKey: trackedRecord.key, level: act.instanceLevel,
                    court: instance?.court ?? act.courtShort,
                    kind: act.title, date: act.date)
                func available(_ values: [CourtActRecord]?) -> [CourtActRecord] {
                    (values ?? []).filter { unmatched.contains(ObjectIdentifier($0)) }
                }
                let exact = available(byExact[lookupKey(trackedRecord.key, act.id)])
                let semantic = available(bySemantic[lookupKey(trackedRecord.key, semanticKey)])
                let hash = available(byHash[lookupKey(trackedRecord.key, document.sourceHash)])
                let existing = exact.first
                    ?? (semantic.count == 1 ? semantic[0] : nil)
                    ?? (hash.count == 1 ? hash[0] : nil)
                let fetchedAt = trackedRecord.movementFetchedAt ?? trackedRecord.addedAt
                if let existing {
                    desiredIDs.insert(existing.id)
                    existing.update(from: document, semanticKey: semanticKey,
                                    fetchedAt: fetchedAt)
                    unmatched.remove(ObjectIdentifier(existing))
                } else {
                    var stableID = document.id
                    if desiredIDs.contains(stableID) {
                        stableID += "#\(document.sourceHash.prefix(12))"
                    }
                    let stableDocument = ActDocument(
                        caseKey: document.caseKey, sourceActID: document.sourceActID,
                        caseNumber: document.caseNumber, judicialUID: document.judicialUID,
                        court: document.court, instanceLevel: document.instanceLevel,
                        kind: document.kind, date: document.date,
                        sourceText: document.sourceText, documentID: stableID)
                    desiredIDs.insert(stableID)
                    context.insert(CourtActRecord(document: stableDocument,
                                                  semanticKey: semanticKey,
                                                  fetchedAt: fetchedAt))
                }
            }
        }

        for stale in stored where unmatched.contains(ObjectIdentifier(stale))
            && !desiredIDs.contains(stale.id)
            && !undecodableCaseKeys.contains(stale.caseKey) {
            try deleteSummary(documentID: stale.id, context: context)
            context.delete(stale)
        }
    }

    private static func semanticKey(caseKey: String, level: CaseInstance.Level,
                                    court: String, kind: String, date: String) -> String {
        [caseKey, level.rawValue, court, kind, date]
            .map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .replacingOccurrences(of: "[^a-zа-яё0-9]+", with: "",
                                          options: .regularExpression)
            }
            .joined(separator: "|")
    }

    private static func lookupKey(_ caseKey: String, _ value: String) -> String {
        "\(caseKey.utf8.count):\(caseKey)\(value)"
    }

    private static func deleteSummary(documentID: String,
                                      context: ModelContext) throws {
        let descriptor = FetchDescriptor<ActSummaryRecord>(
            predicate: #Predicate { $0.documentID == documentID })
        for summary in try context.fetch(descriptor) { context.delete(summary) }
    }
}

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
        set {
            guard let newValue else {
                snapshotData = nil
                return
            }
            do { snapshotData = try JSONEncoder().encode(newValue) }
            catch {
                storeLog.error("Не удалось закодировать snapshot; прежние данные сохранены: \(error, privacy: .public)")
            }
        }
    }
    var movement: CaseMovement? {
        get { movementData.flatMap { Self.decode(CaseMovement.self, from: $0, what: "movement") } }
        set {
            guard let newValue else {
                movementData = nil
                return
            }
            do { movementData = try JSONEncoder().encode(newValue) }
            catch {
                storeLog.error("Не удалось закодировать movement; прежние данные сохранены: \(error, privacy: .public)")
            }
        }
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

    /// `inMemory: true` — для тестов, чтобы не трогать пользовательское
    /// `~/Library/Application Support` и держать записи изолированно.
    /// Этот initializer предназначен для тестов. Production-контейнер
    /// открывает `SudrfModelContainerFactory.makeProduction()`: там выполняются
    /// versioned migration и предмиграционный backup.
    convenience init(inMemory: Bool) {
        do {
            let resolved = try SudrfModelContainerFactory.make(inMemory: inMemory)
            self.init(container: resolved)
        } catch {
            fatalError("SwiftData не смог создать \(inMemory ? "in-memory" : "persistent") хранилище: \(error)")
        }
    }

    /// Позволяет UI, Spotlight, App Intents и тестам использовать один явно
    /// созданный контейнер вместо скрытого экземпляра внутри `TrackedStore`.
    init(container: ModelContainer, prepared: Bool = false) {
        self.container = container
        guard !prepared else { return }
        do {
            try TrackedStorePreparation.prepare(context: context)
        } catch {
            context.rollback()
            storeLog.error("Не удалось подготовить хранилище: \(error, privacy: .public)")
        }
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

    func courtActID(caseKey: String, sourceActID: String) -> String? {
        var descriptor = FetchDescriptor<CourtActRecord>(
            predicate: #Predicate {
                $0.caseKey == caseKey && $0.sourceActID == sourceActID
            })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.id
    }

    enum DeepLinkRoute: Equatable {
        case caseRecord(key: String, staleAct: Bool)
        case courtAct(caseKey: String, sourceActID: String)
        case missing
    }

    func route(for link: SudrfDeepLink) -> DeepLinkRoute {
        switch link {
        case .caseRecord(let key):
            return record(forKey: key) == nil
                ? .missing : .caseRecord(key: key, staleAct: false)
        case .courtAct(let caseKey, let sourceActID):
            guard record(forKey: caseKey) != nil else { return .missing }
            return courtActID(caseKey: caseKey, sourceActID: sourceActID) == nil
                ? .caseRecord(key: caseKey, staleAct: true)
                : .courtAct(caseKey: caseKey, sourceActID: sourceActID)
        }
    }

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
            let oldCaseNumber = existing.caseNumber
            let oldJudicialUID = existing.judicialUID
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
            if mvData == nil,
               oldCaseNumber != existing.caseNumber || oldJudicialUID != existing.judicialUID {
                synchronizeCourtActMetadata(caseKey: existing.key)
            }
            save(projection: mvData == nil ? .none : .cases([key]))
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
        save(projection: mvData == nil ? .none : .cases([key]))
        return rec
    }

    func remove(key: String) {
        guard let rec = record(forKey: key) else { return }
        deleteCourtActs(caseKey: key)
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
    func save(projection: ProjectionScope = .none) -> Bool {
        do {
            try CourtActProjectionSynchronizer.synchronize(context: context, scope: projection)
        } catch {
            context.rollback()
            storeLog.error("Не удалось обновить проекцию актов: \(error, privacy: .public)")
            return false
        }
        return saveContext()
    }

    /// Обновляет только денормализованные реквизиты существующих актов. Тексты,
    /// sourceHash, paragraph snapshots и summary при reroute не затрагиваются.
    func synchronizeCourtActMetadata(caseKey: String) {
        guard let tracked = record(forKey: caseKey) else { return }
        let descriptor = FetchDescriptor<CourtActRecord>(
            predicate: #Predicate { $0.caseKey == caseKey })
        for act in (try? context.fetch(descriptor)) ?? [] {
            act.caseNumber = tracked.caseNumber
            act.judicialUID = tracked.judicialUID
        }
    }

    /// Перед repair-проекцией переносит уникальные логические акты на новый
    /// caseKey, сохраняя documentID и связанную ActSummaryRecord. Если в
    /// destination уже есть тот же source/semantic/hash, приоритет у него, а
    /// старый дубль удалит обычная scoped reconciliation.
    func prepareCourtActsForReroute(from oldKeys: [String], to newKey: String) {
        let destinationDescriptor = FetchDescriptor<CourtActRecord>(
            predicate: #Predicate { $0.caseKey == newKey })
        var destination = (try? context.fetch(destinationDescriptor)) ?? []
        for oldKey in oldKeys where oldKey != newKey {
            let descriptor = FetchDescriptor<CourtActRecord>(
                predicate: #Predicate { $0.caseKey == oldKey })
            for act in (try? context.fetch(descriptor)) ?? [] {
                let collides = destination.contains {
                    $0.sourceActID == act.sourceActID
                        || $0.semanticKey == act.semanticKey
                        || $0.sourceHash == act.sourceHash
                }
                guard !collides else { continue }
                act.caseKey = newKey
                destination.append(act)
            }
        }
    }

    private func saveContext() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            storeLog.error("Не удалось сохранить хранилище: \(error, privacy: .public)")
            return false
        }
    }

    // MARK: - Перестраиваемая проекция актов

    private func deleteCourtActs(caseKey: String) {
        let descriptor = FetchDescriptor<CourtActRecord>(
            predicate: #Predicate { $0.caseKey == caseKey })
        for act in (try? context.fetch(descriptor)) ?? [] {
            deleteSummary(documentID: act.id)
            context.delete(act)
        }
    }

    private func deleteSummary(documentID: String) {
        let descriptor = FetchDescriptor<ActSummaryRecord>(
            predicate: #Predicate { $0.documentID == documentID })
        for summary in (try? context.fetch(descriptor)) ?? [] {
            context.delete(summary)
        }
    }
}
