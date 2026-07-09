import Foundation

struct CalendarWeekHearingLayoutInput: Identifiable, Equatable {
    var id: String
    var caseNumber: String
    var parties: String
    var court: String
    var room: String
    var judge: String
    var time: String
}

enum CalendarWeekBlockKind: Equatable {
    case single
    case stack
    case conflict
}

struct CalendarWeekBlock: Identifiable, Equatable {
    var id: String
    var kind: CalendarWeekBlockKind
    var startMinutes: Int
    var endMinutes: Int
    var top: Double
    var height: Double
    var badge: String?
    var hearings: [CalendarWeekHearingLayoutInput]

    var isConflict: Bool { kind == .conflict }
    var isSingle: Bool { kind == .single }
}

enum CalendarWeekLayout {
    static let startHour = 8
    static let endHour = 19
    static let hourHeight = 120.0
    static let defaultDurationMinutes = 60

    static func parseTime(_ value: String) -> Int? {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              (0...23).contains(h),
              (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    static func blocks(for raw: [CalendarWeekHearingLayoutInput]) -> [CalendarWeekBlock] {
        let timed = raw.compactMap { item -> TimedHearing? in
            guard let start = parseTime(item.time) else { return nil }
            return TimedHearing(item: item, start: start,
                                end: start + defaultDurationMinutes)
        }
        .sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }

        var clusters: [[TimedHearing]] = []
        var current: [TimedHearing] = []
        var currentEnd = -1
        for item in timed {
            if !current.isEmpty, item.start >= currentEnd {
                clusters.append(current)
                current = []
                currentEnd = -1
            }
            current.append(item)
            currentEnd = max(currentEnd, item.end)
        }
        if !current.isEmpty { clusters.append(current) }

        return clusters.map(block)
    }

    private static func block(_ cluster: [TimedHearing]) -> CalendarWeekBlock {
        let start = cluster.map(\.start).min() ?? startHour * 60
        let end = cluster.map(\.end).max() ?? start + defaultDurationMinutes
        let durationHeight = Double(end - start) / 60.0 * hourHeight
        let hearings = cluster.map(\.item)
        let sameStart = cluster.allSatisfy { $0.start == cluster[0].start }
        let sameCourt = cluster.allSatisfy { $0.item.court == cluster[0].item.court }
        let samePlaceAndJudge = sameCourt && cluster.allSatisfy {
            $0.item.room == cluster[0].item.room && $0.item.judge == cluster[0].item.judge
        }
        let top = Double(start - startHour * 60) / 60.0 * hourHeight
        let id = hearings.map(\.id).joined(separator: "|")

        if cluster.count == 1 {
            return CalendarWeekBlock(id: id, kind: .single,
                                     startMinutes: start, endMinutes: end,
                                     top: top, height: max(durationHeight, 96),
                                     badge: nil, hearings: hearings)
        }

        if !sameCourt {
            return CalendarWeekBlock(id: id, kind: .conflict,
                                     startMinutes: start, endMinutes: end,
                                     top: top,
                                     height: max(durationHeight, Double(cluster.count * 66 + 96)),
                                     badge: "⚠ РАЗНЫЕ СУДЫ", hearings: hearings)
        }

        let count = "\(cluster.count) \(DateUtil.plural(cluster.count, "ДЕЛО", "ДЕЛА", "ДЕЛ"))"
        return CalendarWeekBlock(id: id, kind: .stack,
                                 startMinutes: start, endMinutes: end,
                                 top: top,
                                 height: max(durationHeight,
                                             Double(cluster.count * (samePlaceAndJudge ? 34 : 52) + 96)),
                                 badge: count + (sameStart ? " · ПО ОЧЕРЕДИ" : " · НАКЛАДКА"),
                                 hearings: hearings)
    }

    private struct TimedHearing {
        var item: CalendarWeekHearingLayoutInput
        var start: Int
        var end: Int
    }
}
