import Foundation

/// Calendar-only date used by federal production calendars. It deliberately
/// carries no time zone; callers must name one when crossing the `Date` boundary.
public struct LegalCalendarDate: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public func date(timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public var iso8601: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var isValid: Bool {
        LegalCalendarDate(year: year, month: month, day: day) != nil
    }
}

public enum LegalDayKind: String, Codable, Hashable, Sendable {
    case working
    case weekend
    case holiday
    case transferredDayOff
    case transferredWorkingDay
    case specialNonWorking
}

/// A production-calendar status is not automatically a procedural rule.
/// Exceptional presidential non-working days stay `unknown` until an audited
/// procedural policy says otherwise.
public enum ProceduralDayStatus: String, Codable, Hashable, Sendable {
    case working
    case nonWorking
    case unknown
}

public struct LegalCalendarProceduralRule: Codable, Hashable, Sendable {
    public let code: String
    public let status: ProceduralDayStatus
    public let policyID: String
    public let sourceIDs: [String]

    public init(code: String, status: ProceduralDayStatus, policyID: String,
                sourceIDs: [String]) {
        self.code = code
        self.status = status
        self.policyID = policyID
        self.sourceIDs = sourceIDs
    }
}

public struct LegalCalendarDay: Codable, Hashable, Sendable {
    public let date: LegalCalendarDate
    public let kind: LegalDayKind
    public let isShortened: Bool
    public let reasonIDs: [String]
    public let proceduralRules: [LegalCalendarProceduralRule]

    public init(date: LegalCalendarDate, kind: LegalDayKind, isShortened: Bool = false,
                reasonIDs: [String] = [],
                proceduralRules: [LegalCalendarProceduralRule] = []) {
        self.date = date
        self.kind = kind
        self.isShortened = isShortened
        self.reasonIDs = reasonIDs
        self.proceduralRules = proceduralRules
    }

    public var isProductionWorkingDay: Bool {
        kind == .working || kind == .transferredWorkingDay
    }

    public func proceduralStatus(for code: String) -> ProceduralDayStatus {
        guard kind == .specialNonWorking else {
            return isProductionWorkingDay ? .working : .nonWorking
        }
        let matches = proceduralRules.filter { $0.code == code }
        guard matches.count == 1 else { return .unknown }
        return matches[0].status
    }
}

public struct LegalCalendarSource: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let url: URL
    public let document: String?
    /// Date carried by the source document (for example, the adoption date of
    /// a decree). This is deliberately not called a publication date: some
    /// official publication pages were unavailable during verification.
    public let documentDate: LegalCalendarDate?
    public let sha256: String?

    public init(id: String, title: String, url: URL, document: String? = nil,
                documentDate: LegalCalendarDate? = nil, sha256: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.document = document
        self.documentDate = documentDate
        self.sha256 = sha256
    }
}

public struct LegalCalendarReason: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let sourceIDs: [String]
    public let note: String?

    public init(id: String, title: String, sourceIDs: [String], note: String? = nil) {
        self.id = id
        self.title = title
        self.sourceIDs = sourceIDs
        self.note = note
    }
}

public struct LegalCalendarRevisionReference: Codable, Hashable, Sendable {
    public let year: Int
    public let revision: Int
    public let sourceHash: String

    public init(year: Int, revision: Int, sourceHash: String) {
        self.year = year
        self.revision = revision
        self.sourceHash = sourceHash
    }
}

public struct LegalCalendarYearRevision: Codable, Hashable, Sendable {
    public let year: Int
    public let revision: Int
    public let verifiedOn: LegalCalendarDate
    public let sourceIDs: [String]
    /// Structured source for the year table itself. Older saved revisions may
    /// omit it; calculations remain reproducible from `sourceHash`.
    public let calendarSourceID: String?
    public let sourceHash: String
    public let days: [LegalCalendarDay]

    public init(year: Int, revision: Int, verifiedOn: LegalCalendarDate,
                sourceIDs: [String], calendarSourceID: String? = nil,
                sourceHash: String, days: [LegalCalendarDay]) {
        self.year = year
        self.revision = revision
        self.verifiedOn = verifiedOn
        self.sourceIDs = sourceIDs
        self.calendarSourceID = calendarSourceID
        self.sourceHash = sourceHash
        self.days = days
    }

    public var reference: LegalCalendarRevisionReference {
        LegalCalendarRevisionReference(year: year, revision: revision, sourceHash: sourceHash)
    }
}

public struct LegalCalendarArchive: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sources: [LegalCalendarSource]
    public let reasons: [LegalCalendarReason]
    public let revisions: [LegalCalendarYearRevision]

    public init(schemaVersion: Int = 1, sources: [LegalCalendarSource],
                reasons: [LegalCalendarReason], revisions: [LegalCalendarYearRevision]) {
        self.schemaVersion = schemaVersion
        self.sources = sources
        self.reasons = reasons
        self.revisions = revisions
    }
}

public struct LegalCalendarTrace: Codable, Hashable, Sendable {
    public enum Operation: String, Codable, Hashable, Sendable {
        case addWorkingDays
        case moveToNextWorkingDay
    }

    public let operation: Operation
    public let start: LegalCalendarDate
    public let result: LegalCalendarDate
    public let countedWorkingDays: Int?
    public let skipped: [LegalCalendarDate]
    public let revisions: [LegalCalendarRevisionReference]
    public let proceduralPolicyIDs: [String]

    public init(operation: Operation, start: LegalCalendarDate, result: LegalCalendarDate,
                countedWorkingDays: Int?, skipped: [LegalCalendarDate],
                revisions: [LegalCalendarRevisionReference], proceduralPolicyIDs: [String] = []) {
        self.operation = operation
        self.start = start
        self.result = result
        self.countedWorkingDays = countedWorkingDays
        self.skipped = skipped
        self.revisions = revisions
        self.proceduralPolicyIDs = proceduralPolicyIDs
    }
}

public struct LegalCalendarCalculation: Codable, Hashable, Sendable {
    public let date: LegalCalendarDate
    public let trace: LegalCalendarTrace

    public init(date: LegalCalendarDate, trace: LegalCalendarTrace) {
        self.date = date
        self.trace = trace
    }
}

public struct LegalCalendar: Sendable {
    public static let federalTimeZone = TimeZone(identifier: "Europe/Moscow")!

    public let archive: LegalCalendarArchive
    private let days: [LegalCalendarDate: LegalCalendarDay]
    private let revisionsByYear: [Int: LegalCalendarYearRevision]

    public init(archive: LegalCalendarArchive,
                selecting references: [LegalCalendarRevisionReference] = []) throws {
        guard archive.schemaVersion == 1 else { throw LegalCalendarError.unsupportedSchema }
        let sourceIDs = archive.sources.map(\.id)
        guard Set(sourceIDs).count == sourceIDs.count,
              archive.sources.allSatisfy({ source in
                  source.documentDate?.isValid != false
                      && source.sha256.map(Self.isSHA256) != false
              }) else {
            throw LegalCalendarError.invalidArchive("источники")
        }
        let knownSources = Set(sourceIDs)
        let sourcesByID = Dictionary(uniqueKeysWithValues: archive.sources.map { ($0.id, $0) })
        let reasonIDs = archive.reasons.map(\.id)
        guard Set(reasonIDs).count == reasonIDs.count,
              archive.reasons.allSatisfy({ Set($0.sourceIDs).isSubset(of: knownSources) }) else {
            throw LegalCalendarError.invalidArchive("основания")
        }
        let knownReasons = Set(reasonIDs)
        let revisionKeys = archive.revisions.map { "\($0.year):\($0.revision)" }
        guard Set(revisionKeys).count == revisionKeys.count else {
            throw LegalCalendarError.invalidArchive("повторяющиеся редакции")
        }
        guard Set(references.map(\.year)).count == references.count else {
            throw LegalCalendarError.invalidArchive("повторяющиеся выбранные редакции")
        }
        let requested = Dictionary(uniqueKeysWithValues: references.map { ($0.year, $0) })
        var selected: [Int: LegalCalendarYearRevision] = [:]
        for revision in archive.revisions {
            if let reference = requested[revision.year] {
                if revision.revision == reference.revision,
                   revision.sourceHash == reference.sourceHash { selected[revision.year] = revision }
            } else if revision.revision > (selected[revision.year]?.revision ?? 0) {
                selected[revision.year] = revision
            }
        }
        guard references.allSatisfy({ selected[$0.year]?.reference == $0 }) else {
            throw LegalCalendarError.revisionNotFound
        }
        for revision in archive.revisions {
            let expected = Self.numberOfDays(in: revision.year)
            guard revision.days.count == expected,
                  Set(revision.days.map(\.date)).count == expected,
                  revision.revision > 0,
                  revision.verifiedOn.isValid,
                  Self.isSHA256(revision.sourceHash),
                  Set(revision.sourceIDs).isSubset(of: knownSources),
                  revision.calendarSourceID.map(knownSources.contains) != false,
                  revision.calendarSourceID.map(revision.sourceIDs.contains) != false,
                  revision.calendarSourceID.map({
                      sourcesByID[$0]?.sha256 == revision.sourceHash
                  }) != false,
                  revision.days.allSatisfy({
                      $0.date.isValid && $0.date.year == revision.year
                          && Set($0.reasonIDs).isSubset(of: knownReasons)
                          && $0.proceduralRules.allSatisfy {
                              Set($0.sourceIDs).isSubset(of: knownSources)
                          }
                          && Set($0.proceduralRules.map(\.code)).count == $0.proceduralRules.count
                  }) else {
                throw LegalCalendarError.incompleteYear(revision.year)
            }
        }
        var indexed: [LegalCalendarDate: LegalCalendarDay] = [:]
        for revision in selected.values {
            for day in revision.days { indexed[day.date] = day }
        }
        self.archive = archive
        self.days = indexed
        self.revisionsByYear = selected
    }

    public static func load() throws -> Self {
        guard let url = PackagedResource.url("ProductionCalendar", withExtension: "json") else {
            throw LegalCalendarError.resourceNotFound
        }
        let archive = try JSONDecoder().decode(LegalCalendarArchive.self,
                                               from: Data(contentsOf: url))
        return try Self(archive: archive)
    }

    public func day(on date: LegalCalendarDate) -> LegalCalendarDay? { days[date] }

    public func day(on date: Date, timeZone: TimeZone) -> LegalCalendarDay? {
        LegalCalendarDate(date: date, timeZone: timeZone).flatMap { days[$0] }
    }

    public func reason(id: String) -> LegalCalendarReason? {
        archive.reasons.first { $0.id == id }
    }

    public func source(id: String) -> LegalCalendarSource? {
        archive.sources.first { $0.id == id }
    }

    public func revision(for year: Int) -> LegalCalendarYearRevision? {
        revisionsByYear[year]
    }

    /// Counts working days beginning with the day after `start`.
    public func addingWorkingDays(_ count: Int, to start: LegalCalendarDate, forCode code: String)
        -> LegalCalendarCalculation? {
        guard count >= 0, days[start] != nil else { return nil }
        if count == 0 {
            return calculation(.addWorkingDays, start: start, result: start,
                               counted: 0, skipped: [], years: [start.year], policyIDs: [])
        }
        var current = start
        var counted = 0
        var skipped: [LegalCalendarDate] = []
        var years = Set([start.year])
        var policyIDs = Set<String>()
        while counted < count {
            guard let next = Self.nextDate(after: current), let status = days[next] else { return nil }
            current = next
            years.insert(next.year)
            if status.kind == .specialNonWorking {
                guard let rule = uniqueProceduralRule(in: status, code: code) else { return nil }
                policyIDs.insert(rule.policyID)
            }
            switch status.proceduralStatus(for: code) {
            case .working: counted += 1
            case .nonWorking: skipped.append(next)
            case .unknown: return nil
            }
        }
        return calculation(.addWorkingDays, start: start, result: current,
                           counted: counted, skipped: skipped, years: years, policyIDs: policyIDs)
    }

    /// Returns `date` when it is working, otherwise advances to the first
    /// procedurally confirmed working day. Unknown exceptional days fail closed.
    public func movingToNextWorkingDay(_ date: LegalCalendarDate, forCode code: String)
        -> LegalCalendarCalculation? {
        guard let initial = days[date] else { return nil }
        var current = date
        var skipped: [LegalCalendarDate] = []
        var years = Set([date.year])
        var policyIDs = Set<String>()
        var status = initial
        while status.proceduralStatus(for: code) != .working {
            if status.kind == .specialNonWorking {
                guard let rule = uniqueProceduralRule(in: status, code: code) else { return nil }
                policyIDs.insert(rule.policyID)
            }
            guard status.proceduralStatus(for: code) != .unknown,
                  let next = Self.nextDate(after: current), let nextStatus = days[next] else { return nil }
            skipped.append(current)
            current = next
            years.insert(current.year)
            status = nextStatus
        }
        if status.kind == .specialNonWorking {
            guard let rule = uniqueProceduralRule(in: status, code: code) else { return nil }
            policyIDs.insert(rule.policyID)
        }
        return calculation(.moveToNextWorkingDay, start: date, result: current,
                           counted: nil, skipped: skipped, years: years, policyIDs: policyIDs)
    }

    private func calculation(_ operation: LegalCalendarTrace.Operation,
                             start: LegalCalendarDate, result: LegalCalendarDate,
                             counted: Int?, skipped: [LegalCalendarDate], years: Set<Int>,
                             policyIDs: Set<String>)
        -> LegalCalendarCalculation? {
        let references = years.sorted().compactMap { revisionsByYear[$0]?.reference }
        guard references.count == years.count else { return nil }
        let trace = LegalCalendarTrace(operation: operation, start: start, result: result,
                                       countedWorkingDays: counted, skipped: skipped,
                                       revisions: references,
                                       proceduralPolicyIDs: policyIDs.sorted())
        return LegalCalendarCalculation(date: result, trace: trace)
    }

    private func uniqueProceduralRule(in day: LegalCalendarDay, code: String)
        -> LegalCalendarProceduralRule? {
        let matches = day.proceduralRules.filter { $0.code == code }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func nextDate(after date: LegalCalendarDate) -> LegalCalendarDate? {
        guard let instant = date.date(timeZone: TimeZone(secondsFromGMT: 0)!) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let next = calendar.date(byAdding: .day, value: 1, to: instant) else { return nil }
        return LegalCalendarDate(date: next, timeZone: calendar.timeZone)
    }

    private static func numberOfDays(in year: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return 0
        }
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

public enum LegalCalendarError: Error, LocalizedError, Equatable, Sendable {
    case resourceNotFound
    case unsupportedSchema
    case incompleteYear(Int)
    case revisionNotFound
    case invalidArchive(String)

    public var errorDescription: String? {
        switch self {
        case .resourceNotFound: "Производственный календарь не найден в ресурсах приложения"
        case .unsupportedSchema: "Версия производственного календаря не поддерживается"
        case .incompleteYear(let year): "Производственный календарь за \(year) год неполон"
        case .revisionNotFound: "Запрошенная редакция производственного календаря не найдена"
        case .invalidArchive(let section): "Архив производственного календаря повреждён: \(section)"
        }
    }
}
