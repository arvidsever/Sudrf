import Foundation

public struct ProductionCalendarImportManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let weekendReasonID: String
    public let automaticTransferReasonID: String
    public let holidayReasonID: String
    public let shortenedReasonID: String
    public let transferredShortenedReasonID: String
    public let sources: [LegalCalendarSource]
    public let reasons: [LegalCalendarReason]
    public let years: [ProductionCalendarYearImport]

    public init(schemaVersion: Int = 1, weekendReasonID: String,
                automaticTransferReasonID: String, holidayReasonID: String,
                shortenedReasonID: String, transferredShortenedReasonID: String,
                sources: [LegalCalendarSource],
                reasons: [LegalCalendarReason], years: [ProductionCalendarYearImport]) {
        self.schemaVersion = schemaVersion
        self.weekendReasonID = weekendReasonID
        self.automaticTransferReasonID = automaticTransferReasonID
        self.holidayReasonID = holidayReasonID
        self.shortenedReasonID = shortenedReasonID
        self.transferredShortenedReasonID = transferredShortenedReasonID
        self.sources = sources
        self.reasons = reasons
        self.years = years
    }
}

public struct ProductionCalendarYearImport: Codable, Hashable, Sendable {
    public let year: Int
    public let revision: Int
    public let verifiedOn: LegalCalendarDate
    public let sourceIDs: [String]
    public let calendarSourceID: String
    public let observedFinalURL: URL
    public let transferReasonID: String
    public let decreeReasonDates: [LegalCalendarDate]
    public let transferredShortenedDates: [LegalCalendarDate]
    public let specialRanges: [ProductionCalendarSpecialRange]

    public init(year: Int, revision: Int, verifiedOn: LegalCalendarDate,
                sourceIDs: [String], calendarSourceID: String, observedFinalURL: URL,
                transferReasonID: String,
                decreeReasonDates: [LegalCalendarDate] = [],
                transferredShortenedDates: [LegalCalendarDate] = [],
                specialRanges: [ProductionCalendarSpecialRange] = []) {
        self.year = year
        self.revision = revision
        self.verifiedOn = verifiedOn
        self.sourceIDs = sourceIDs
        self.calendarSourceID = calendarSourceID
        self.observedFinalURL = observedFinalURL
        self.transferReasonID = transferReasonID
        self.decreeReasonDates = decreeReasonDates
        self.transferredShortenedDates = transferredShortenedDates
        self.specialRanges = specialRanges
    }
}

public struct ProductionCalendarSpecialRange: Codable, Hashable, Sendable {
    public let start: LegalCalendarDate
    public let end: LegalCalendarDate
    public let reasonID: String
    public let proceduralRules: [LegalCalendarProceduralRule]

    public init(start: LegalCalendarDate, end: LegalCalendarDate, reasonID: String,
                proceduralRules: [LegalCalendarProceduralRule] = []) {
        self.start = start
        self.end = end
        self.reasonID = reasonID
        self.proceduralRules = proceduralRules
    }

    public func contains(_ date: LegalCalendarDate) -> Bool { start <= date && date <= end }
}

public struct ProductionCalendarImportPage: Sendable {
    public let data: Data
    public let requestedURL: URL
    public let finalURL: URL

    public init(data: Data, requestedURL: URL, finalURL: URL) {
        self.data = data
        self.requestedURL = requestedURL
        self.finalURL = finalURL
    }
}

public enum ProductionCalendarArchiveBuilder {
    public static func build(manifest: ProductionCalendarImportManifest,
                             pagesByYear: [Int: ProductionCalendarImportPage],
                             retaining previousArchive: LegalCalendarArchive? = nil) throws
        -> LegalCalendarArchive {
        guard manifest.schemaVersion == 1 else {
            throw ProductionCalendarArchiveBuilderError.invalidManifest("schemaVersion")
        }
        let sourceIDs = Set(manifest.sources.map(\.id))
        let reasonIDs = Set(manifest.reasons.map(\.id))
        guard sourceIDs.count == manifest.sources.count,
              reasonIDs.count == manifest.reasons.count,
              [manifest.weekendReasonID, manifest.automaticTransferReasonID,
               manifest.holidayReasonID, manifest.shortenedReasonID]
                .allSatisfy(reasonIDs.contains),
              reasonIDs.contains(manifest.transferredShortenedReasonID),
              manifest.reasons.allSatisfy({ Set($0.sourceIDs).isSubset(of: sourceIDs) }) else {
            throw ProductionCalendarArchiveBuilderError.invalidManifest("sources/reasons")
        }
        let keys = manifest.years.map { "\($0.year):\($0.revision)" }
        guard Set(keys).count == keys.count else {
            throw ProductionCalendarArchiveBuilderError.invalidManifest("duplicate revision")
        }
        if let previousArchive { _ = try LegalCalendar(archive: previousArchive) }

        let importedRevisions = try manifest.years.map { config -> LegalCalendarYearRevision in
            guard config.verifiedOn.isValid,
                  Set(config.sourceIDs).isSubset(of: sourceIDs),
                  config.sourceIDs.contains(config.calendarSourceID),
                  reasonIDs.contains(config.transferReasonID),
                  Set(config.decreeReasonDates).count == config.decreeReasonDates.count,
                  config.decreeReasonDates.allSatisfy({ $0.year == config.year }),
                  Set(config.transferredShortenedDates).count == config.transferredShortenedDates.count,
                  config.transferredShortenedDates.allSatisfy({ $0.year == config.year }),
                  config.specialRanges.allSatisfy({ range in
                      range.start.year == config.year && range.end.year == config.year
                          && range.start <= range.end && reasonIDs.contains(range.reasonID)
                          && Set(range.proceduralRules.flatMap(\.sourceIDs)).isSubset(of: sourceIDs)
                          && Set(range.proceduralRules.map(\.code)).count == range.proceduralRules.count
                  }), let page = pagesByYear[config.year] else {
                throw ProductionCalendarArchiveBuilderError.invalidManifest("year \(config.year)")
            }
            let parsed = try ProductionCalendarImporter.parse(
                data: page.data, expectedYear: config.year,
                requestedURL: page.requestedURL, finalURL: page.finalURL)
            guard let calendarSource = manifest.sources.first(where: {
                      $0.id == config.calendarSourceID
                  }), calendarSource.url == config.observedFinalURL,
                  page.finalURL == config.observedFinalURL,
                  calendarSource.sha256 == parsed.sourceHash else {
                throw ProductionCalendarArchiveBuilderError.invalidManifest(
                    "calendar source \(config.year)")
            }
            let days = try parsed.days.map { imported -> LegalCalendarDay in
                var reasons: [String] = []
                let decreeDate = config.decreeReasonDates.contains(imported.date)
                switch imported.kind {
                case .working:
                    if decreeDate { reasons.append(config.transferReasonID) }
                case .weekend: reasons.append(manifest.weekendReasonID)
                case .holiday: reasons.append(manifest.holidayReasonID)
                case .transferredDayOff:
                    reasons.append(decreeDate ? config.transferReasonID
                                              : manifest.automaticTransferReasonID)
                case .transferredWorkingDay:
                    guard decreeDate else {
                        throw ProductionCalendarArchiveBuilderError.invalidManifest(
                            "unmapped working transfer \(imported.date.iso8601)")
                    }
                    reasons.append(config.transferReasonID)
                case .specialNonWorking:
                    let ranges = config.specialRanges.filter { $0.contains(imported.date) }
                    guard ranges.count == 1 else {
                        throw ProductionCalendarArchiveBuilderError.unmappedSpecialDay(imported.date)
                    }
                    reasons.append(ranges[0].reasonID)
                }
                if imported.isShortened {
                    reasons.append(config.transferredShortenedDates.contains(imported.date)
                        ? manifest.transferredShortenedReasonID : manifest.shortenedReasonID)
                } else if config.transferredShortenedDates.contains(imported.date) {
                    throw ProductionCalendarArchiveBuilderError.invalidManifest(
                        "shortened transfer \(imported.date.iso8601)")
                }
                let range = config.specialRanges.first { $0.contains(imported.date) }
                return LegalCalendarDay(
                    date: imported.date, kind: imported.kind,
                    isShortened: imported.isShortened,
                    reasonIDs: reasons,
                    proceduralRules: imported.kind == .specialNonWorking
                        ? (range?.proceduralRules ?? []) : [])
            }
            return LegalCalendarYearRevision(
                year: config.year, revision: config.revision,
                verifiedOn: config.verifiedOn, sourceIDs: config.sourceIDs,
                calendarSourceID: config.calendarSourceID,
                sourceHash: parsed.sourceHash, days: days)
        }
        let prior = previousArchive?.revisions ?? []
        let previousByKey = Dictionary(uniqueKeysWithValues: prior.map {
            ("\($0.year):\($0.revision)", $0)
        })
        for revision in importedRevisions {
            if let existing = previousByKey["\(revision.year):\(revision.revision)"],
               existing != revision {
                throw ProductionCalendarArchiveBuilderError.immutableRevision(
                    year: revision.year, revision: revision.revision)
            }
        }
        let importedKeys = Set(importedRevisions.map { "\($0.year):\($0.revision)" })
        let retained = prior.filter { !importedKeys.contains("\($0.year):\($0.revision)") }
        let revisions = retained + importedRevisions
        let sources = try mergedMetadata(previousArchive?.sources ?? [], manifest.sources,
                                         section: "source")
        let reasons = try mergedMetadata(previousArchive?.reasons ?? [], manifest.reasons,
                                         section: "reason")
        let archive = LegalCalendarArchive(schemaVersion: 1, sources: sources,
                                           reasons: reasons, revisions: revisions)
        _ = try LegalCalendar(archive: archive)
        return archive
    }

    private static func mergedMetadata<T: Identifiable & Equatable>(
        _ old: [T], _ new: [T], section: String
    ) throws -> [T] where T.ID == String {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        for value in new where oldByID[value.id].map({ $0 != value }) == true {
            throw ProductionCalendarArchiveBuilderError.conflictingMetadata(section, value.id)
        }
        let newIDs = Set(new.map(\.id))
        return old.filter { !newIDs.contains($0.id) } + new
    }
}

public enum ProductionCalendarArchiveBuilderError: Error, LocalizedError, Equatable, Sendable {
    case invalidManifest(String)
    case unmappedSpecialDay(LegalCalendarDate)
    case immutableRevision(year: Int, revision: Int)
    case conflictingMetadata(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let field): "Манифест производственного календаря повреждён: \(field)"
        case .unmappedSpecialDay(let date):
            "Для специального нерабочего дня \(date.iso8601) не указано основание"
        case .immutableRevision(let year, let revision):
            "Редакция \(year)/\(revision) уже существует и не может быть изменена"
        case .conflictingMetadata(let section, let id):
            "Сохранённые метаданные \(section) с идентификатором \(id) отличаются"
        }
    }
}
