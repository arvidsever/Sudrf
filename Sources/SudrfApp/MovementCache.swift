//  MovementCache.swift — Sudrf
//  In-memory кэш карточек для «Поиска» + настройка интервала автообновления.
//
//  Персистентный кэш отслеживаемых дел живёт в TrackedCaseRecord.movementData
//  (SwiftData); правила слияния/очистки — MovementCachePolicy в SudrfKit.

import Foundation
import SudrfKit

/// Кэш карточек, открытых из «Поиска», — в памяти, на сессию приложения.
/// Ключ — displayDomain + "/" + № дела (та же схема, что MovementContext.key).
@MainActor
final class MovementMemoryCache {
    static let shared = MovementMemoryCache()

    private var storage: [String: (movement: CaseMovement, fetchedAt: Date)] = [:]

    func get(_ key: String) -> (movement: CaseMovement, fetchedAt: Date)? { storage[key] }
    func put(_ key: String, _ movement: CaseMovement) {
        storage[key] = (movement, Date())
    }
}

/// Настройка интервала автообновления отслеживаемых дел.
enum RefreshSettings {
    static let ttlKey = "movementRefreshTTLHours"
    static let ttlOptions = [1, 3, 6, 12, 24]

    /// Интервал в часах; по умолчанию 6. Читается при каждом проходе
    /// обходчика — смена настройки действует без перезапуска.
    static var ttlHours: Int {
        let v = UserDefaults.standard.integer(forKey: ttlKey)
        return v > 0 ? v : 6
    }
    static var ttl: TimeInterval { TimeInterval(ttlHours) * 3600 }
}
