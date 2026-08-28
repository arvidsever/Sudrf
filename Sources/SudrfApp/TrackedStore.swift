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

struct IdentityReconciliationSummary: Equatable {
    var merged = 0
    var keyRemaps: [String: String] = [:]
    var affectedKeys = Set<String>()
}

/// Общая реализация подготовки store. Она не привязана к mainContext и может
/// выполняться как production bootstrap в actor с собственным ModelContext.
enum TrackedStorePreparation {
    static func prepare(context: ModelContext) throws {
        try migrateFolders(context: context)
        try migrateJudicialUIDs(context: context)
        try migrateMoscowKeyAliases(context: context)
        try bootstrapPersistentIdentity(context: context)
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

    /// Дела судов Москвы до v0.42 хранились под ключом «mos-gorsud.ru/<№>»:
    /// домен у всех судов города общий, поэтому одинаковые номера из разных
    /// райсудов схлопывались в одну запись. С v0.42 формула добавила код
    /// суда. V6 больше не переписывает уже опубликованный technical locator:
    /// новая формула становится alias, чтобы поиск и старые ссылки сходились
    /// к одной записи без ротации key.
    private static func migrateMoscowKeyAliases(context: ModelContext) throws {
        let records = try context.fetch(FetchDescriptor<TrackedCaseRecord>())
        for rec in records where MosGorSudRouting.isMosGorSud(domain: rec.displayDomain) {
            guard let code = rec.context?.courtCode, !code.isEmpty else { continue }
            let updated = MovementContext.identityKey(displayDomain: rec.displayDomain,
                                                      courtCode: code,
                                                      caseNumber: rec.caseNumber)
            rec.addLegacyKeyAlias(updated)
        }
    }

    /// V6 даёт уже существующим строкам permanent logical identity. Alias-ы
    /// нормализуются детерминированно: locator никогда не может указывать на
    /// две записи, а собственный key всегда имеет приоритет.
    private static func bootstrapPersistentIdentity(context: ModelContext) throws {
        let records = try context.fetch(FetchDescriptor<TrackedCaseRecord>())
            .sorted { lhs, rhs in
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
                return lhs.key < rhs.key
            }
        var claimed = Set(records.map(\.key))
        for rec in records {
            if rec.logicalCaseID == nil { rec.logicalCaseID = UUID() }
            var aliases: [String] = []
            for alias in rec.legacyKeyAliases where !alias.isEmpty && alias != rec.key {
                guard !claimed.contains(alias), !aliases.contains(alias) else { continue }
                aliases.append(alias)
                claimed.insert(alias)
            }
            rec.legacyKeyAliases = aliases
            TrackedCaseIdentity.persist(TrackedCaseIdentity.state(for: rec), to: rec)
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
    /// Неизменяемый технический адрес записи. Старые версии строили его из
    /// отображаемого суда и номера дела; теперь это лишь legacy locator для
    /// deep links, Spotlight, актов и подборок, а не identity дела.
    @Attribute(.unique) var key: String

    /// Постоянный идентификатор логического досье. Optional нужен только для
    /// lightweight migration V5 -> V6; bootstrap назначает его каждой записи
    /// до того, как store становится доступен приложению.
    var logicalCaseID: UUID? = nil
    /// Кодированное состояние domain identity/reconciliation. App-слой не
    /// интерпретирует байты: тип и правила принадлежат SudrfKit.
    var identityStateData: Data? = nil
    /// Производные ключи прежних/новых карточек, ведущие к этому постоянному
    /// адресу. Они не участвуют в identity и нужны только для обратной
    /// совместимости ссылок и поиска уже отслеживаемой записи.
    var legacyKeyAliases: [String] = []

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
    /// Последний нормализованный исход попытки обновления источника. Это не
    /// timestamp успешного движения: ошибки и частичные ответы тоже сохраняют
    /// attempt, но не продлевают TTL `movementFetchedAt`.
    var sourceRefreshAttemptData: Data? = nil
    /// Записи об исполнении — JSON. Optional + default позволяют легко
    /// добавить поле к уже существующим SwiftData-записям.
    var enforcementData: Data? = nil

    init(key: String, collections: [String], caseNumber: String, courtTitle: String,
         displayDomain: String, contextData: Data, snapshotData: Data?) {
        self.key = key
        self.logicalCaseID = UUID()
        self.identityStateData = nil
        self.legacyKeyAliases = []
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
    var sourceRefreshAttempt: SourceAttempt? {
        get {
            sourceRefreshAttemptData.flatMap {
                Self.decode(SourceAttempt.self, from: $0, what: "source refresh attempt")
            }
        }
        set {
            guard let newValue else {
                sourceRefreshAttemptData = nil
                return
            }
            do { sourceRefreshAttemptData = try JSONEncoder().encode(newValue) }
            catch {
                storeLog.error("Не удалось закодировать source refresh attempt; прежние данные сохранены: \(error, privacy: .public)")
            }
        }
    }
    var enforcementRecords: [EnforcementRecord] {
        get {
            enforcementData.flatMap {
                Self.decode([EnforcementRecord].self, from: $0, what: "enforcement")
            } ?? []
        }
        set {
            do { enforcementData = try JSONEncoder().encode(newValue) }
            catch {
                storeLog.error("Не удалось закодировать enforcement; прежние данные сохранены: \(error, privacy: .public)")
            }
        }
    }

    /// Не добавляет собственный `key`, пустые и повторяющиеся locators.
    /// Согласование коллизий между разными записями выполняет TrackedStore.
    func addLegacyKeyAlias(_ locator: String) {
        guard !locator.isEmpty, locator != key,
              !legacyKeyAliases.contains(locator) else { return }
        legacyKeyAliases.append(locator)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) -> T? {
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            storeLog.error("Не удалось декодировать \(what, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }
}

extension TrackedStore {
    /// Обновление исполнения дополняет кэш: пустой ответ суда или ошибка
    /// Казначейства не являются командой удалить уже известный лист.
    nonisolated static func reconciledEnforcementRecords(
        existing: [EnforcementRecord], updates: [EnforcementRecord],
        courtDocuments: [CourtEnforcementDocument]
    ) -> [EnforcementRecord] {
        var output = existing
        for update in updates {
            if let index = matchingEnforcementIndex(for: update, in: output,
                                                     courtDocuments: courtDocuments) {
                output[index] = mergedEnforcementRecord(existing: output[index], update: update)
            } else {
                output.append(update)
            }
        }
        return output
    }

    /// `seenAt` меняется только от нового результата сопоставления или новой
    /// официальной записи истории. Время проверки и транспортная ошибка не
    /// создают ложный бейдж «обновлено».
    nonisolated static func enforcementHasUserVisibleChange(
        previous: [EnforcementRecord], current: [EnforcementRecord],
        courtDocuments: [CourtEnforcementDocument]
    ) -> Bool {
        for record in current {
            guard let index = matchingEnforcementIndex(for: record, in: previous,
                                                        courtDocuments: courtDocuments) else {
                return record.discoveryState != .error
            }
            let old = previous[index]
            if old.discoveryState != record.discoveryState,
               record.discoveryState != .error,
               record.discoveryState != .captchaRequired { return true }
            if record.source == .bailiffs,
               old.sourceRecordID != record.sourceRecordID
                || old.status != record.status
                || old.organization != record.organization
                || old.subdivision != record.subdivision
                || old.sourceUpdatedRaw != record.sourceUpdatedRaw
                || old.bailiffDetails != record.bailiffDetails {
                return true
            }
            let oldEventIDs = Set(old.events.map(\.id))
            if record.events.contains(where: { !oldEventIDs.contains($0.id) }) { return true }
        }
        return false
    }

    private nonisolated static func matchingEnforcementIndex(
        for candidate: EnforcementRecord, in records: [EnforcementRecord],
        courtDocuments: [CourtEnforcementDocument]
    ) -> Int? {
        if let sourceRecordID = candidate.sourceRecordID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sourceRecordID.isEmpty,
           let index = records.firstIndex(where: {
               $0.source == candidate.source && $0.sourceRecordID == sourceRecordID
           }) {
            return index
        }
        let blank = normalizedEnforcementBlank(for: candidate, courtDocuments: courtDocuments)
        guard !blank.isEmpty else { return nil }
        return records.firstIndex {
            $0.source == candidate.source
                && normalizedEnforcementBlank(for: $0, courtDocuments: courtDocuments) == blank
        }
    }

    private nonisolated static func normalizedEnforcementBlank(
        for record: EnforcementRecord, courtDocuments: [CourtEnforcementDocument]
    ) -> String {
        let value = courtDocuments.first(where: { $0.id == record.courtDocumentID })?.blankNumber
            ?? record.courtDocumentID
        return value.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private nonisolated static func mergedEnforcementRecord(
        existing: EnforcementRecord, update: EnforcementRecord
    ) -> EnforcementRecord {
        var merged = existing
        var events = existing.events
        for event in update.events {
            if let index = events.firstIndex(where: { $0.id == event.id }) {
                events[index] = event
            } else {
                events.append(event)
            }
        }
        let existingAttempt = existing.lastAttemptAt ?? existing.lastSuccessAt ?? .distantPast
        let updateAttempt = update.lastAttemptAt ?? update.lastSuccessAt ?? .distantPast
        let updateIsNewer = updateAttempt > existingAttempt

        switch update.discoveryState {
        case .found:
            if updateIsNewer {
                merged = update
            }
            merged.events = events
        case .notFound, .ambiguous:
            if updateIsNewer {
                merged.discoveryState = update.discoveryState
                merged.lastAttemptAt = update.lastAttemptAt ?? merged.lastAttemptAt
                merged.lastSuccessAt = update.lastSuccessAt ?? merged.lastAttemptAt
                merged.error = nil
            }
            merged.events = events
        case .captchaRequired:
            // A fresh challenge is not a new enforcement fact. Retain the
            // last successful status/details while recording that the source
            // needs a human response.
            if updateIsNewer {
                merged.discoveryState = .captchaRequired
                merged.lastAttemptAt = update.lastAttemptAt ?? merged.lastAttemptAt
                merged.error = nil
            }
            merged.events = events
        case .error:
            if updateIsNewer {
                merged.lastAttemptAt = update.lastAttemptAt ?? merged.lastAttemptAt
                merged.error = update.error
            }
            merged.events = events
        }
        return merged
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
    /// открывает `PersistentStoreBootstrapper.prepareProduction()`: там выполняются
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
        if !prepared {
            do {
                try TrackedStorePreparation.prepare(context: context)
            } catch {
                context.rollback()
                storeLog.error("Не удалось подготовить хранилище: \(error, privacy: .public)")
            }
        }
        _ = reconcileStoredIdentity()
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

    /// Разрешает исходный display-derived locator и его исторические aliases
    /// к неизменяемому `TrackedCaseRecord.key`. Predicate по transformable
    /// SwiftData-массиву здесь не переносим между store, поэтому небольшой
    /// in-memory scan намеренно остаётся единым местом такого lookup.
    func record(forLocator locator: String) -> TrackedCaseRecord? {
        guard !locator.isEmpty else { return nil }
        if let direct = record(forKey: locator) { return direct }
        return all().first { $0.legacyKeyAliases.contains(locator) }
    }

    func isTracked(key: String) -> Bool { record(forLocator: key) != nil }

    func isTracked(context: MovementContext) -> Bool {
        guard let observation = TrackedCaseIdentity.observation(context: context) else {
            return record(forLocator: context.key) != nil
        }
        let normalizedUID = observation.judicialUID?.isMatchable == true
            ? observation.judicialUID?.normalizedValue : nil
        return all().contains { record in
            let state = TrackedCaseIdentity.state(for: record)
            return state.contains(card: observation.cardIdentity)
                || normalizedUID.map { state.contains(judicialUID: $0) } == true
        }
    }

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
            guard let record = record(forLocator: key) else { return .missing }
            return .caseRecord(key: record.key, staleAct: false)
        case .courtAct(let caseKey, let sourceActID):
            guard let record = record(forLocator: caseKey) else { return .missing }
            return courtActID(caseKey: record.key, sourceActID: sourceActID) == nil
                ? .caseRecord(key: record.key, staleAct: true)
                : .courtAct(caseKey: record.key, sourceActID: sourceActID)
        }
    }

    func records(forJudicialUID uid: String) -> [TrackedCaseRecord] {
        let normalized = Self.normalizedUID(uid)
        return all().filter {
            TrackedCaseIdentity.state(for: $0).contains(judicialUID: normalized)
        }
    }

    /// После lightweight V5 -> V6 migration собирает legacy graphs и одним
    /// shared reconciler-ом устраняет только подтверждённые UID-дубли. Это
    /// повторяемо: второй запуск видит уже один persistent graph и ничего не
    /// меняет.
    @discardableResult
    func reconcileStoredIdentity() -> IdentityReconciliationSummary {
        var summary = IdentityReconciliationSummary()
        let keys = all().map(\.key)
        for key in keys {
            guard let record = record(forKey: key), let movementContext = record.context else {
                continue
            }
            let observation = TrackedCaseIdentity.bootstrapObservation(for: record)
            let before = Set(all().map(\.key))
            let survivor = reconcileAndUpsert(
                context: movementContext, snapshot: record.snapshot,
                movement: record.movement, collections: record.collectionNames,
                identityObservation: observation,
                movementFetchedAt: record.movementFetchedAt,
                updatesMovementFetchedAt: false)
            let removed = before.subtracting(Set(all().map(\.key)))
            summary.merged += removed.count
            summary.affectedKeys.formUnion(removed)
            summary.affectedKeys.insert(survivor.key)
            for oldKey in removed { summary.keyRemaps[oldKey] = survivor.key }
        }
        return summary
    }

    @discardableResult
    func upsert(context ctx: MovementContext, snapshot snap: CaseSnapshot?,
                movement mv: CaseMovement? = nil, collections: [String]) -> TrackedCaseRecord {
        reconcileAndUpsert(context: ctx, snapshot: snap, movement: mv, collections: collections)
    }

    /// Единственная точка записи для ручного добавления и фонового discovery.
    /// Только `LogicalCaseReconciler` связывает разные source cards; locator
    /// номера применяется после его решения исключительно для compatibility.
    @discardableResult
    func reconcileAndUpsert(context ctx: MovementContext, snapshot snap: CaseSnapshot?,
                            movement mv: CaseMovement? = nil,
                            collections: [String],
                            identityObservation: SourceCardObservation? = nil,
                            movementFetchedAt: Date? = nil,
                            updatesMovementFetchedAt: Bool = true) -> TrackedCaseRecord {
        let observation = identityObservation
            ?? TrackedCaseIdentity.observation(context: ctx, movement: mv)
        guard let observation, observation.isUsableSnapshot,
              observation.cardIdentity.isComplete else {
            return upsertCandidate(context: ctx, snapshot: snap, movement: mv,
                                   collections: collections,
                                   movementFetchedAt: movementFetchedAt,
                                   updatesMovementFetchedAt: updatesMovementFetchedAt)
        }

        let records = all()
        let originalStates = records.map { TrackedCaseIdentity.state(for: $0) }
        var states = originalStates
        let result = LogicalCaseReconciler.reconcileAndUpsert(observation, in: &states)
        guard let state = result.state,
              result.decision.kind != .candidate else {
            return upsertCandidate(context: ctx, snapshot: snap, movement: mv,
                                   collections: collections,
                                   movementFetchedAt: movementFetchedAt,
                                   updatesMovementFetchedAt: updatesMovementFetchedAt)
        }

        let remainingIDs = Set(states.map(\.logicalCaseID))
        let mergedRecords = zip(records, originalStates).compactMap { record, oldState in
            remainingIDs.contains(oldState.logicalCaseID) ? nil : record
        }

        if let domainSurvivor = records.first(where: {
            TrackedCaseIdentity.ensuredLogicalCaseID(for: $0) == state.logicalCaseID
        }) {
            let mergedGroup = [domainSurvivor] + mergedRecords.filter { $0 !== domainSurvivor }
            let survivor = preferredPersistentSurvivor(in: mergedGroup)
            let persistedState = state.logicalCaseID == survivor.logicalCaseID
                ? state
                : LogicalCaseState(
                    logicalCaseID: TrackedCaseIdentity.ensuredLogicalCaseID(for: survivor),
                    cards: state.cards, uidBindings: state.uidBindings,
                    numberHistory: state.numberHistory,
                    officialRelations: state.officialRelations,
                    provenance: state.provenance)
            let duplicates = mergedGroup.filter { $0 !== survivor }
            if !duplicates.isEmpty {
                // Merge user-visible projections before writing the new graph.
                let canonical = survivor.context ?? ctx
                _ = TrackedCaseRepairCoordinator.atomicMerge(
                    store: self, survivor: survivor, duplicates: duplicates,
                    canonicalContext: canonical, canonicalCard: nil,
                    identityState: persistedState)
            }

            let locatorOwner = record(forLocator: ctx.key)
            let ownsOrCanClaimLocator = locatorOwner.map { $0 === survivor } ?? true
            // An exact source-card match is a renumbering/refresh of that
            // card, so its display projection must advance even if the
            // display-derived locator changed.  A UID/relation link between
            // distinct cards keeps the existing card projection intact.
            let adoptsIncomingCard = result.decision.kind == .sameCard
            var projectedMovement = mv
            var projectedSnapshot = snap
            if result.decision.kind == .linkedExistingCase {
                let cachedSnapshot = survivor.snapshot
                projectedMovement = TrackedCaseRepairCoordinator.mergeMovements(
                    [survivor.movement, mv].compactMap { $0 })
                if let projectedMovement, let canonicalContext = survivor.context {
                    var derived = MovementDerivation.snapshot(
                        from: projectedMovement, context: canonicalContext)
                    if let snap {
                        derived = MovementDerivation.preservingConfirmedDeadlines(
                            derived, old: snap)
                    }
                    if let cachedSnapshot {
                        derived = MovementDerivation.preservingConfirmedDeadlines(
                            derived, old: cachedSnapshot)
                    }
                    projectedSnapshot = derived
                } else {
                    projectedSnapshot = cachedSnapshot ?? snap
                }
            }
            update(record: survivor, context: ctx, snapshot: projectedSnapshot,
                   movement: projectedMovement,
                   collections: collections, identityState: persistedState,
                   adoptPresentation: adoptsIncomingCard,
                   addLocator: ownsOrCanClaimLocator,
                   movementFetchedAt: movementFetchedAt,
                   updatesMovementFetchedAt: updatesMovementFetchedAt)
            return survivor
        }

        return insert(context: ctx, snapshot: snap, movement: mv, collections: collections,
                      logicalCaseID: state.logicalCaseID, identityState: state,
                      movementFetchedAt: movementFetchedAt,
                      updatesMovementFetchedAt: updatesMovementFetchedAt)
    }

    /// Persistent projections have a user-visible canonical card even though
    /// the domain graph itself is source-order independent. Prefer a real
    /// first-instance case over preliminary/material/higher-court cards, then
    /// the lowest procedural level. This preserves the established movement,
    /// deadline and enforcement merge contract while the logical dossier keeps
    /// every card node.
    private func preferredPersistentSurvivor(
        in records: [TrackedCaseRecord]
    ) -> TrackedCaseRecord {
        records.min { lhs, rhs in
            let left = persistentSurvivorRank(lhs)
            let right = persistentSurvivorRank(rhs)
            if left != right { return left < right }
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
            return lhs.key < rhs.key
        }!
    }

    private func persistentSurvivorRank(_ record: TrackedCaseRecord) -> Int {
        guard let context = record.context else { return 50 }
        let role = CaseIndexClassifier.classify(
            caseNumber: context.caseNumber,
            courtLevel: context.courtLevel,
            branch: context.branch)?.cardRole
        if role == .firstInstanceCase { return 0 }
        switch context.baseInstanceLevel {
        case .first: return 10
        case .material: return 20
        case .appeal: return 30
        case .cassation: return 40
        default: return 50
        }
    }

    /// Incomplete source identity is a candidate, not evidence that another
    /// display-equal record is the same case. Only an exact stored technical
    /// key can therefore be updated on this fallback path.
    private func upsertCandidate(context movementContext: MovementContext,
                                 snapshot: CaseSnapshot?, movement: CaseMovement?,
                                 collections: [String], movementFetchedAt: Date?,
                                 updatesMovementFetchedAt: Bool)
        -> TrackedCaseRecord {
        if let existing = record(forKey: movementContext.key) {
            update(record: existing, context: movementContext, snapshot: snapshot,
                   movement: movement, collections: collections, identityState: nil,
                   adoptPresentation: true, addLocator: true,
                   movementFetchedAt: movementFetchedAt,
                   updatesMovementFetchedAt: updatesMovementFetchedAt)
            return existing
        }
        return insert(context: movementContext, snapshot: snapshot, movement: movement,
                      collections: collections, logicalCaseID: UUID(), identityState: nil,
                      movementFetchedAt: movementFetchedAt,
                      updatesMovementFetchedAt: updatesMovementFetchedAt)
    }

    private func update(record: TrackedCaseRecord, context movementContext: MovementContext,
                        snapshot: CaseSnapshot?, movement: CaseMovement?,
                        collections: [String], identityState: LogicalCaseState?,
                        adoptPresentation: Bool, addLocator: Bool,
                        movementFetchedAt: Date?,
                        updatesMovementFetchedAt: Bool) {
        let oldCaseNumber = record.caseNumber
        let oldJudicialUID = record.judicialUID
        if adoptPresentation {
            record.context = movementContext
            record.caseNumber = movementContext.caseNumber
            record.courtTitle = movementContext.courtTitle
            record.displayDomain = movementContext.displayDomain
            if let uid = movementContext.judicialUID ?? movement?.uid, !uid.isEmpty {
                record.judicialUID = Self.normalizedUID(uid)
            }
        } else if var canonical = record.context,
                  let incoming = TrackedCaseRepairCoordinator.knownCard(from: movementContext) {
            var known = canonical.knownCards ?? []
            if !known.contains(incoming) {
                known.append(incoming)
                canonical.knownCards = known
                record.context = canonical
            }
        }
        if let snapshot { record.snapshot = snapshot }
        if let movement {
            record.movement = movement
            if updatesMovementFetchedAt { record.movementFetchedAt = movementFetchedAt ?? .now }
        }
        for collection in collections where !record.collectionNames.contains(collection) {
            record.collectionNames.append(collection)
        }
        if addLocator { record.addLegacyKeyAlias(movementContext.key) }
        if let identityState { TrackedCaseIdentity.persist(identityState, to: record) }
        if movement == nil,
           oldCaseNumber != record.caseNumber || oldJudicialUID != record.judicialUID {
            synchronizeCourtActMetadata(caseKey: record.key)
        }
        _ = save(projection: movement == nil ? .none : .cases([record.key]))
    }

    private func insert(context movementContext: MovementContext, snapshot: CaseSnapshot?,
                        movement: CaseMovement?, collections: [String],
                        logicalCaseID: UUID, identityState: LogicalCaseState?,
                        movementFetchedAt: Date?,
                        updatesMovementFetchedAt: Bool) -> TrackedCaseRecord {
        let sourceLocatorTaken = record(forLocator: movementContext.key) != nil
        let key = sourceLocatorTaken
            ? "case/\(logicalCaseID.uuidString.lowercased())" : movementContext.key
        let contextData = (try? JSONEncoder().encode(movementContext)) ?? Data()
        let snapshotData = snapshot.flatMap { try? JSONEncoder().encode($0) }
        let record = TrackedCaseRecord(
            key: key, collections: collections, caseNumber: movementContext.caseNumber,
            courtTitle: movementContext.courtTitle,
            displayDomain: movementContext.displayDomain,
            contextData: contextData, snapshotData: snapshotData)
        record.logicalCaseID = logicalCaseID
        if let uid = movementContext.judicialUID ?? movement?.uid, !uid.isEmpty {
            record.judicialUID = Self.normalizedUID(uid)
        }
        if let movement {
            record.movement = movement
            if updatesMovementFetchedAt { record.movementFetchedAt = movementFetchedAt ?? .now }
        }
        if !sourceLocatorTaken { record.addLegacyKeyAlias(movementContext.key) }
        if let identityState {
            TrackedCaseIdentity.persist(identityState, to: record)
        } else {
            TrackedCaseIdentity.persist(TrackedCaseIdentity.state(for: record), to: record)
        }
        context.insert(record)
        _ = save(projection: movement == nil ? .none : .cases([record.key]))
        return record
    }

    func remove(key: String) {
        guard let rec = record(forLocator: key) else { return }
        deleteCourtActs(caseKey: rec.key)
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
