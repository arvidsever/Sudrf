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
    /// Папка-доверитель (для группировки в «Моих делах»).
    var folderName: String

    // Денормализованные поля для быстрых списков и фолбэка без декодирования.
    var caseNumber: String
    var courtTitle: String
    var displayDomain: String

    /// Поисковый контекст (MovementContext) — JSON, для перезапроса движения.
    var contextData: Data
    /// Снимок производных данных (CaseSnapshot) — JSON; nil, если ещё не собран.
    var snapshotData: Data?
    /// Полное движение (CaseMovement) — JSON-кэш карточки; nil, если ещё не
    /// загружено. Значения по умолчанию — для лёгкой миграции SwiftData.
    var movementData: Data? = nil
    /// Когда движение в последний раз получено с портала (TTL кэша).
    var movementFetchedAt: Date? = nil

    init(key: String, folderName: String, caseNumber: String, courtTitle: String,
         displayDomain: String, contextData: Data, snapshotData: Data?) {
        self.key = key
        self.addedAt = Date()
        self.seenAt = nil
        self.folderName = folderName
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

    init() {
        // Постоянное хранилище в стандартной папке поддержки приложения; при
        // сбое (несовместимая миграция и т. п.) — откат в память, чтобы
        // приложение не падало на старте.
        do {
            container = try ModelContainer(for: TrackedCaseRecord.self)
        } catch {
            storeLog.error("Постоянное хранилище не открылось, откат в память: \(error, privacy: .public)")
            do {
                container = try ModelContainer(for: TrackedCaseRecord.self,
                                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            } catch {
                fatalError("SwiftData не смог создать даже in-memory хранилище: \(error)")
            }
        }
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

    @discardableResult
    func upsert(context ctx: MovementContext, snapshot snap: CaseSnapshot?,
                movement mv: CaseMovement? = nil, folder: String) -> TrackedCaseRecord {
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
            save()
            return existing
        }
        let rec = TrackedCaseRecord(key: key, folderName: folder, caseNumber: ctx.caseNumber,
                                    courtTitle: ctx.courtTitle, displayDomain: ctx.displayDomain,
                                    contextData: ctxData, snapshotData: snapData)
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

    func save() {
        do { try context.save() }
        catch { storeLog.error("Не удалось сохранить хранилище: \(error, privacy: .public)") }
    }
}
