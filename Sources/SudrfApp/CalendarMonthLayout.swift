import Foundation

/// Заседание для раскладки в режиме «Месяц» — минимальные поля, без
/// привязки к конкретной модели дела: только то, что нужно для расчёта
/// накладок, серий и плотности ячейки.
struct CalendarMonthHearingInput: Identifiable, Equatable {
    var id: String
    var date: Date          // день заседания
    var time: String        // "HH:MM" или «—»
    var caseNumber: String  // сырой номер, идентичность дела для серии
    var courtKey: String    // нормализованная идентичность суда (один суд ⇔ равные ключи)
    var courtShort: String  // короткое имя суда для заметки «↔ <суд> <время>»
}

/// Накладка — ближайшее по времени заседание в тот же день в другом суде.
struct CalendarMonthOverlap: Equatable {
    var otherID: String
    var otherCourtShort: String
    var otherTime: String
    var deltaMinutes: Int
}

enum CalendarMonthLayout {
    static let overlapThresholdMinutes = 60

    static let twoLineHeight = 36.0
    static let oneLineHeight = 20.0
    static let itemSpacing = 3.0
    static let moreHeight = 17.0

    /// Для каждого заседания — ближайшее по времени заседание того же дня
    /// в другом суде, если разница строго меньше `overlapThresholdMinutes`.
    /// Заседания с неразбираемым временем не участвуют ни с какой стороны.
    static func overlaps(_ hearings: [CalendarMonthHearingInput]) -> [String: CalendarMonthOverlap] {
        struct Timed {
            var hearing: CalendarMonthHearingInput
            var minutes: Int
        }
        let timed = hearings.compactMap { h -> Timed? in
            guard let m = CalendarWeekLayout.parseTime(h.time) else { return nil }
            return Timed(hearing: h, minutes: m)
        }

        var result: [String: CalendarMonthOverlap] = [:]
        for a in timed {
            var best: (Timed, Int)? = nil
            for b in timed {
                guard a.hearing.id != b.hearing.id,
                      a.hearing.courtKey != b.hearing.courtKey,
                      DateUtil.sameDay(a.hearing.date, b.hearing.date) else { continue }
                let delta = abs(a.minutes - b.minutes)
                guard delta < overlapThresholdMinutes else { continue }
                if let (currentBest, currentDelta) = best {
                    if delta < currentDelta ||
                        (delta == currentDelta && b.minutes < currentBest.minutes) {
                        best = (b, delta)
                    }
                } else {
                    best = (b, delta)
                }
            }
            if let (partner, delta) = best {
                result[a.hearing.id] = CalendarMonthOverlap(otherID: partner.hearing.id,
                                                              otherCourtShort: partner.hearing.courtShort,
                                                              otherTime: partner.hearing.time,
                                                              deltaMinutes: delta)
            }
        }
        return result
    }

    /// Дни (начало суток), в которые есть хотя бы одна накладка — по возрастанию.
    static func overlapDays(_ hearings: [CalendarMonthHearingInput]) -> [Date] {
        let overlapping = overlaps(hearings)
        let byID = Dictionary(uniqueKeysWithValues: hearings.map { ($0.id, $0) })
        let days = Set(overlapping.keys.compactMap { byID[$0].map { DateUtil.startOfDay($0.date) } })
        return days.sorted()
    }

    /// Ближайший день накладки на дату `today` или позже; если такого нет —
    /// первый день из списка (чтобы счётчик «Накладки: N дней» всегда вёл
    /// куда-то при N>0).
    static func nextOverlapDay(after today: Date, in days: [Date]) -> Date? {
        let today = DateUtil.startOfDay(today)
        if let next = days.first(where: { $0 >= today }) {
            return next
        }
        return days.first
    }

    /// Позиция «N из M» для дел с ≥ 3 заседаниями в переданном наборе
    /// (обычно один месяц), упорядоченных по дате и времени; заседания без
    /// разбираемого времени идут последними внутри дня.
    static func seriesPositions(_ hearings: [CalendarMonthHearingInput]) -> [String: (index: Int, total: Int)] {
        var byCase: [String: [CalendarMonthHearingInput]] = [:]
        for h in hearings {
            byCase[h.caseNumber, default: []].append(h)
        }

        var result: [String: (index: Int, total: Int)] = [:]
        for (_, group) in byCase where group.count >= 3 {
            let ordered = group.sorted { a, b in
                if !DateUtil.sameDay(a.date, b.date) { return a.date < b.date }
                let am = CalendarWeekLayout.parseTime(a.time)
                let bm = CalendarWeekLayout.parseTime(b.time)
                switch (am, bm) {
                case let (am?, bm?): return am < bm
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                }
            }
            let total = ordered.count
            for (i, h) in ordered.enumerated() {
                result[h.id] = (index: i + 1, total: total)
            }
        }
        return result
    }

    /// Ключ сортировки внутри ячейки: активные дедлайны первыми, затем
    /// заседания по времени (нераспознанное время — в конец).
    static func sortKey(isDeadline: Bool, time: String) -> (Int, Int) {
        let timeRank = CalendarWeekLayout.parseTime(time) ?? Int.max
        return (isDeadline ? 0 : 1, timeRank)
    }

    static func cellLayout(itemCount: Int, availableHeight: Double) -> CalendarMonthCellLayout {
        guard itemCount > 0 else {
            return CalendarMonthCellLayout(mode: .twoLine, visibleCount: 0, hiddenCount: 0)
        }
        guard availableHeight > 0 else {
            return CalendarMonthCellLayout(mode: .oneLineWithMore, visibleCount: 0, hiddenCount: itemCount)
        }

        func total(_ n: Int, _ height: Double) -> Double {
            Double(n) * height + Double(max(0, n - 1)) * itemSpacing
        }

        if total(itemCount, twoLineHeight) <= availableHeight {
            return CalendarMonthCellLayout(mode: .twoLine, visibleCount: itemCount, hiddenCount: 0)
        }
        if total(itemCount, oneLineHeight) <= availableHeight {
            return CalendarMonthCellLayout(mode: .oneLine, visibleCount: itemCount, hiddenCount: 0)
        }

        // oneLineWithMore: visible one-line rows + «ещё N» row, each row preceded
        // by its own spacing, must fit inside availableHeight.
        let remaining = availableHeight - moreHeight - itemSpacing
        let visible = remaining < 0 ? 0 : max(0, Int(floor((remaining + itemSpacing) / (oneLineHeight + itemSpacing))))
        let cappedVisible = min(visible, max(0, itemCount - 1))
        let hidden = itemCount - cappedVisible
        return CalendarMonthCellLayout(mode: .oneLineWithMore, visibleCount: cappedVisible, hiddenCount: hidden)
    }
}

enum CalendarMonthCellMode: Equatable {
    case twoLine
    case oneLine
    case oneLineWithMore
}

struct CalendarMonthCellLayout: Equatable {
    var mode: CalendarMonthCellMode
    var visibleCount: Int
    var hiddenCount: Int
}
