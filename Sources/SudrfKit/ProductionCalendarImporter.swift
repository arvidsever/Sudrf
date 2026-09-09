import CryptoKit
import Foundation
import SwiftSoup

public struct ImportedProductionCalendarDay: Codable, Hashable, Sendable {
    public let date: LegalCalendarDate
    public let kind: LegalDayKind
    public let isShortened: Bool

    public init(date: LegalCalendarDate, kind: LegalDayKind, isShortened: Bool) {
        self.date = date
        self.kind = kind
        self.isShortened = isShortened
    }
}

public struct ImportedProductionCalendarYear: Codable, Hashable, Sendable {
    public let year: Int
    public let sourceURL: URL
    public let sourceHash: String
    public let days: [ImportedProductionCalendarDay]
    public let publishedWorkingDays: Int
    public let publishedDaysOff: Int
    public let monthlyTotals: [ImportedProductionCalendarMonthTotals]

    public init(year: Int, sourceURL: URL, sourceHash: String,
                days: [ImportedProductionCalendarDay], publishedWorkingDays: Int,
                publishedDaysOff: Int,
                monthlyTotals: [ImportedProductionCalendarMonthTotals]) {
        self.year = year
        self.sourceURL = sourceURL
        self.sourceHash = sourceHash
        self.days = days
        self.publishedWorkingDays = publishedWorkingDays
        self.publishedDaysOff = publishedDaysOff
        self.monthlyTotals = monthlyTotals
    }
}

public struct ImportedProductionCalendarMonthTotals: Codable, Hashable, Sendable {
    public let month: Int
    public let calendarDays: Int
    public let workingDays: Int
    public let daysOff: Int

    public init(month: Int, calendarDays: Int, workingDays: Int, daysOff: Int) {
        self.month = month
        self.calendarDays = calendarDays
        self.workingDays = workingDays
        self.daysOff = daysOff
    }
}

/// Strict parser used by the developer-only annual import command. It accepts
/// the stable ConsultantPlus 2013+ calendar table and rejects silent redirects,
/// partial years and unknown CSS markers before any packaged data is replaced.
public enum ProductionCalendarImporter {
    public static func sourceURL(for year: Int) -> URL? {
        guard (2013...2026).contains(year) else { return nil }
        let slug = year == 2020 || year == 2024 ? "\(year)b" : String(year)
        return URL(string: "https://www.consultant.ru/law/ref/calendar/proizvodstvennye/\(slug)/")
    }

    public static func parse(data: Data, expectedYear: Int, requestedURL: URL,
                             finalURL: URL) throws -> ImportedProductionCalendarYear {
        guard let approvedURL = sourceURL(for: expectedYear) else {
            throw ProductionCalendarImportError.unsupportedYear(expectedYear)
        }
        guard canonical(requestedURL) == canonical(approvedURL) else {
            throw ProductionCalendarImportError.unexpectedSourceURL(requestedURL)
        }
        guard canonical(requestedURL) == canonical(finalURL) else {
            throw ProductionCalendarImportError.unexpectedFinalURL(finalURL)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw ProductionCalendarImportError.invalidEncoding
        }
        let document: Document
        do { document = try SwiftSoup.parse(html) }
        catch { throw ProductionCalendarImportError.invalidHTML }

        let heading = try document.select("h1").first()?.text() ?? ""
        if heading.localizedCaseInsensitiveContains("проект") {
            throw ProductionCalendarImportError.unapprovedDraft
        }
        guard heading == "Производственный календарь на \(expectedYear) год" else {
            throw ProductionCalendarImportError.unexpectedYearHeading(heading)
        }
        let tables = try document.select("table.cal").array()
        guard tables.count == 12 else {
            throw ProductionCalendarImportError.incompleteMonths(tables.count)
        }
        var output: [ImportedProductionCalendarDay] = []
        for (offset, table) in tables.enumerated() {
            let month = offset + 1
            let title = try table.select("th.month").text()
            guard title == monthNames[offset] else {
                throw ProductionCalendarImportError.unexpectedMonth(title)
            }
            let cells = try table.select("tbody td").array()
            guard cells.count.isMultiple(of: 7), !cells.isEmpty else {
                throw ProductionCalendarImportError.malformedMonth(month)
            }
            var seen: Set<Int> = []
            for (index, cell) in cells.enumerated() {
                let classes = Set(try cell.className().split(separator: " ").map(String.init))
                guard allowedClasses.contains(classes) else {
                    throw ProductionCalendarImportError.unknownDayClass(classes.sorted().joined(separator: " "))
                }
                let text = cell.ownText().trimmingCharacters(in: .whitespacesAndNewlines)
                if classes == ["inactively"] {
                    guard text.isEmpty else { throw ProductionCalendarImportError.malformedMonth(month) }
                    continue
                }
                guard let day = Int(text), seen.insert(day).inserted,
                      let date = LegalCalendarDate(year: expectedYear, month: month, day: day) else {
                    throw ProductionCalendarImportError.malformedMonth(month)
                }
                guard weekdayColumn(for: date) == index % 7 else {
                    throw ProductionCalendarImportError.misalignedDate(date)
                }
                try validateMarker(in: cell, classes: classes)
                output.append(ImportedProductionCalendarDay(
                    date: date, kind: kind(classes: classes, date: date),
                    isShortened: classes == ["preholiday"]))
            }
            let expectedDays = daysInMonth(year: expectedYear, month: month)
            guard seen == Set(1...expectedDays) else {
                throw ProductionCalendarImportError.malformedMonth(month)
            }
        }
        let expectedCount = (1...12).reduce(0) { $0 + daysInMonth(year: expectedYear, month: $1) }
        guard output.count == expectedCount else {
            throw ProductionCalendarImportError.incompleteYear(output.count)
        }
        let totals = try publishedTotals(in: document, year: expectedYear)
        let monthlyTotals = try publishedMonthlyTotals(in: document)
        let classifiedWorking = output.filter {
            $0.kind == .working || $0.kind == .transferredWorkingDay || $0.kind == .specialNonWorking
        }.count
        guard totals.calendarDays == expectedCount,
              totals.workingDays == classifiedWorking,
              totals.daysOff == expectedCount - classifiedWorking,
              monthlyTotals.count == 12,
              monthlyTotals.allSatisfy({ total in
                  let monthDays = output.filter { $0.date.month == total.month }
                  let working = monthDays.filter {
                      $0.kind == .working || $0.kind == .transferredWorkingDay
                          || $0.kind == .specialNonWorking
                  }.count
                  return total.calendarDays == monthDays.count
                      && total.workingDays == working
                      && total.daysOff == monthDays.count - working
              }) else {
            throw ProductionCalendarImportError.inconsistentTotals
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ImportedProductionCalendarYear(year: expectedYear, sourceURL: finalURL,
                                              sourceHash: digest, days: output.sorted { $0.date < $1.date },
                                              publishedWorkingDays: totals.workingDays,
                                              publishedDaysOff: totals.daysOff,
                                              monthlyTotals: monthlyTotals)
    }

    private static let monthNames = [
        "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
        "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь",
    ]
    private static let allowedClasses: Set<Set<String>> = [
        [], ["inactively"], ["weekend"], ["holiday", "weekend"],
        ["preholiday"], ["nowork"], ["work"],
    ]

    private static func canonical(_ url: URL) -> String {
        var value = url.absoluteString
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func kind(classes: Set<String>, date: LegalCalendarDate) -> LegalDayKind {
        if classes == ["nowork"] { return .specialNonWorking }
        if classes == ["work"] { return .transferredWorkingDay }
        // The source uses the visual weekend class when a statutory holiday
        // falls on Saturday or Sunday. Legal meaning comes from article 112,
        // so classify all fourteen named dates as holidays first.
        if statutoryHoliday(date) { return .holiday }
        if classes.contains("holiday") {
            return .transferredDayOff
        }
        let weekendColumn = weekdayColumn(for: date) >= 5
        if classes.contains("weekend") {
            return weekendColumn ? .weekend : .transferredDayOff
        }
        return weekendColumn ? .transferredWorkingDay : .working
    }

    private static func statutoryHoliday(_ date: LegalCalendarDate) -> Bool {
        if date.month == 1, (1...8).contains(date.day) { return true }
        return [(2, 23), (3, 8), (5, 1), (5, 9), (6, 12), (11, 4)]
            .contains { $0.0 == date.month && $0.1 == date.day }
    }

    private static func weekdayColumn(for date: LegalCalendarDate) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekday = calendar.component(.weekday, from: date.date(timeZone: calendar.timeZone)!)
        return (weekday + 5) % 7
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        return calendar.range(of: .day, in: .month, for: date)!.count
    }

    private static func validateMarker(in cell: Element, classes: Set<String>) throws {
        let links = try cell.select("a").array()
        if classes == ["preholiday"] {
            guard links.count == 1, try links[0].attr("href") == "#shortday" else {
                throw ProductionCalendarImportError.unknownDayMarker
            }
        } else if classes == ["nowork"] {
            let known = Set(["#noworkday", "#noworkday2", "#noworkday3"])
            guard links.count == 1, known.contains(try links[0].attr("href")) else {
                throw ProductionCalendarImportError.unknownDayMarker
            }
        } else if !links.isEmpty {
            throw ProductionCalendarImportError.unknownDayMarker
        }
    }

    private static func publishedTotals(in document: Document, year: Int) throws
        -> (calendarDays: Int, workingDays: Int, daysOff: Int) {
        let candidates = try document.select("p").array().compactMap { element -> String? in
            let text = try? element.text()
            return text?.contains("Кол-во дней за") == true ? text : nil
        }
        guard candidates.count == 1 else { throw ProductionCalendarImportError.missingAnnualTotals }
        let text = candidates[0]
        guard text.contains("календарных"), text.contains("рабочие дни"),
              text.contains("выходных/праздничных") else {
            throw ProductionCalendarImportError.missingAnnualTotals
        }
        let regex = try NSRegularExpression(pattern: "\\d+")
        let range = NSRange(text.startIndex..., in: text)
        let numbers = regex.matches(in: text, range: range).compactMap { match -> Int? in
            Range(match.range, in: text).flatMap { Int(text[$0]) }
        }
        guard numbers.count == 4, numbers[0] == year else {
            throw ProductionCalendarImportError.missingAnnualTotals
        }
        let calendarDays = numbers[1], workingDays = numbers[2], daysOff = numbers[3]
        return (calendarDays, workingDays, daysOff)
    }

    private static func publishedMonthlyTotals(in document: Document) throws
        -> [ImportedProductionCalendarMonthTotals] {
        var totals: [ImportedProductionCalendarMonthTotals] = []
        for cell in try document.select("p.text-center.small").array() {
            let tokens = try cell.text().split(whereSeparator: \Character.isWhitespace)
            guard tokens.count == 3, let calendarDays = Int(tokens[0]),
                  let workingDays = Int(tokens[1]), let daysOff = Int(tokens[2]),
                  (28...31).contains(calendarDays), workingDays + daysOff == calendarDays else {
                continue
            }
            totals.append(ImportedProductionCalendarMonthTotals(
                month: totals.count + 1, calendarDays: calendarDays,
                workingDays: workingDays, daysOff: daysOff))
        }
        guard totals.count == 12 else { throw ProductionCalendarImportError.missingMonthlyTotals }
        return totals
    }
}

public enum ProductionCalendarImportError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedYear(Int)
    case unexpectedSourceURL(URL)
    case unexpectedFinalURL(URL)
    case unapprovedDraft
    case invalidEncoding
    case invalidHTML
    case unexpectedYearHeading(String)
    case incompleteMonths(Int)
    case unexpectedMonth(String)
    case malformedMonth(Int)
    case unknownDayClass(String)
    case unknownDayMarker
    case misalignedDate(LegalCalendarDate)
    case incompleteYear(Int)
    case missingAnnualTotals
    case missingMonthlyTotals
    case inconsistentTotals

    public var errorDescription: String? {
        switch self {
        case .unsupportedYear(let year): "Календарь за \(year) год ещё не включён в проверенный список"
        case .unexpectedSourceURL(let url): "URL не входит в проверенный список: \(url.absoluteString)"
        case .unexpectedFinalURL(let url): "Источник перенаправил календарь на \(url.absoluteString)"
        case .unapprovedDraft: "Проект производственного календаря ещё не утверждён"
        case .invalidEncoding: "Календарь не является UTF-8 HTML"
        case .invalidHTML: "HTML календаря не удалось разобрать"
        case .unexpectedYearHeading(let heading): "Неожиданный заголовок календаря: \(heading)"
        case .incompleteMonths(let count): "Ожидалось 12 месяцев, найдено \(count)"
        case .unexpectedMonth(let month): "Неожиданный или переставленный месяц: \(month)"
        case .malformedMonth(let month): "Таблица месяца \(month) повреждена"
        case .unknownDayClass(let value): "Неизвестное обозначение дня: \(value)"
        case .unknownDayMarker: "Неизвестная сноска в ячейке календаря"
        case .misalignedDate(let date): "Дата \(date.iso8601) стоит не в том дне недели"
        case .incompleteYear(let count): "Календарь неполон: найдено \(count) дат"
        case .missingAnnualTotals: "В календаре отсутствуют годовые итоги"
        case .missingMonthlyTotals: "В календаре отсутствуют месячные итоги"
        case .inconsistentTotals: "Годовые итоги не совпадают с таблицами календаря"
        }
    }
}
