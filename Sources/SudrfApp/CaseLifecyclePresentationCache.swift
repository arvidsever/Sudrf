//  CaseLifecyclePresentationCache.swift — Sudrf

import Foundation

/// Короткоживущий кэш динамической проекции дела. Полный reload очищает его;
/// scoped reload выбрасывает только изменившиеся ключи. День входит в область
/// действия кэша, потому что lifecycle зависит от текущей даты.
struct CaseLifecyclePresentationCache {
    private var values: [String: CaseLifecyclePresentation] = [:]
    private var day: Date?

    var count: Int { values.count }

    mutating func prepare(for today: Date, changedCaseKeys: Set<String>?) {
        let day = DateUtil.startOfDay(today)
        if self.day != day || changedCaseKeys == nil {
            values.removeAll(keepingCapacity: true)
        } else {
            remove(keys: changedCaseKeys ?? [])
        }
        self.day = day
    }

    mutating func remove(keys: Set<String>) {
        for key in keys {
            values.removeValue(forKey: key)
        }
    }

    mutating func presentation(
        for key: String,
        compute: () -> CaseLifecyclePresentation?
    ) -> CaseLifecyclePresentation? {
        if let cached = values[key] {
            return cached
        }
        guard let computed = compute() else { return nil }
        values[key] = computed
        return computed
    }
}
