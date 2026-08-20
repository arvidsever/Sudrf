//  DateUtil.swift — Sudrf · работа с РЕАЛЬНЫМИ датами (v15)
//  Прежде разделы мониторинга жили на «индексе дня в июне» (CalUtil.today = 12,
//  дни 1…30). Для дат, ВЫЧИСЛЯЕМЫХ из живого движения дела (а они приходят по
//  всем месяцам и годам — решение 2025-го, апелляция 2026-го), индекс месяца
//  непригоден. Здесь — обобщение на `Date`: «сегодня» = системная дата, грид
//  любого месяца, русское форматирование, относительные сроки.

import Foundation

enum DateUtil {

    private static let ruLocale = Locale(identifier: "ru_RU")

    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = ruLocale
        c.firstweekday_compat()
        return c
    }()

    static let weekdayShort: [String] = {
        let sundayFirst = cal.shortStandaloneWeekdaySymbols
        return (Array(sundayFirst.dropFirst()) + Array(sundayFirst.prefix(1)))
            .map { $0.uppercased(with: ruLocale) }
    }()

    // MARK: Базовое

    static func startOfDay(_ d: Date) -> Date { cal.startOfDay(for: d) }
    static var today: Date { startOfDay(Date()) }

    static func sameDay(_ a: Date, _ b: Date) -> Bool {
        cal.isDate(a, inSameDayAs: b)
    }
    static func isToday(_ d: Date) -> Bool { sameDay(d, today) }
    static func startOfWeek(_ d: Date) -> Date {
        let start = startOfDay(d)
        let offset = (cal.component(.weekday, from: start) + 5) % 7
        return addDays(start, -offset)
    }
    static func sameWeek(_ a: Date, _ b: Date) -> Bool {
        startOfWeek(a) == startOfWeek(b)
    }
    /// Разница в КАЛЕНДАРНЫХ днях (b − a). Положительная — b позже a.
    static func daysBetween(_ a: Date, _ b: Date) -> Int {
        cal.dateComponents([.day], from: startOfDay(a), to: startOfDay(b)).day ?? 0
    }
    static func addDays(_ d: Date, _ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: d) ?? d
    }
    // MARK: Разбор дат с сайта суда

    /// Парсит «дд.мм.гггг» (возможен хвост вроде «дд.мм.гггг 14:00» или мусор) в
    /// полночь местного дня. Возвращает nil для пустых/непарсируемых строк.
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // Берём дату до хвоста времени. Год всегда четырёхзначный: иначе
        // Calendar трактует «26» как 26 год н. э.
        let head = t.split(whereSeparator: { $0 == " " }).first.map(String.init) ?? t
        let parts = head.split(separator: ".")
        guard parts.count == 3,
              parts[2].count == 4,
              let d = Int(parts[0]), let m = Int(parts[1]), let y = Int(parts[2]),
              (1...31).contains(d), (1...12).contains(m) else { return nil }
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
              cal.component(.day, from: date) == d,
              cal.component(.month, from: date) == m,
              cal.component(.year, from: date) == y else { return nil }
        return startOfDay(date)
    }

    // MARK: Форматирование

    /// «14 мая».
    static func fmt(_ d: Date) -> String {
        d.formatted(.dateTime.locale(ruLocale).day().month(.wide))
    }
    /// «16.06» — короткая для повестки/лент.
    static func shortDM(_ d: Date) -> String {
        d.formatted(.dateTime.locale(ruLocale).day(.twoDigits).month(.twoDigits))
    }
    /// Полное название дня недели.
    static func weekday(_ d: Date) -> String {
        d.formatted(.dateTime.locale(ruLocale).weekday(.wide)).capitalized(with: ruLocale)
    }
    /// Короткое «вт, 16.06» / «сегодня».
    static func dateLabel(_ d: Date) -> String {
        if isToday(d) { return "сегодня" }
        let wd = cal.shortWeekdaySymbols[cal.component(.weekday, from: d) - 1]
            .lowercased(with: ruLocale)
        return "\(wd), \(shortDM(d))"
    }
    /// «Июнь 2026».
    static func monthTitle(_ d: Date) -> String {
        let month = d.formatted(.dateTime.locale(ruLocale).month(.wide)).capitalized(with: ruLocale)
        return "\(month) \(cal.component(.year, from: d))"
    }
    /// «8 – 14 июня» / «29 июня – 5 июля».
    static func weekTitle(starting start: Date) -> String {
        let s = startOfWeek(start)
        let e = addDays(s, 6)
        let sd = cal.component(.day, from: s)
        let sm = cal.component(.month, from: s)
        let em = cal.component(.month, from: e)
        let sy = cal.component(.year, from: s)
        let ey = cal.component(.year, from: e)
        if sm == em && sy == ey {
            return "\(sd) – \(fmt(e))"
        }
        if sy == ey {
            return "\(fmt(s)) – \(fmt(e))"
        }
        return "\(fmt(s)) \(sy) – \(fmt(e)) \(ey)"
    }

    // MARK: Грид месяца

    static func startOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)).map(startOfDay) ?? d
    }
    static func daysInMonth(_ d: Date) -> Int {
        cal.range(of: .day, in: .month, for: d)?.count ?? 30
    }
    /// Сколько пустых клеток до 1-го числа при счёте с понедельника (Пн=0…Вс=6).
    static func leadingBlanks(forMonth d: Date) -> Int {
        (cal.component(.weekday, from: startOfMonth(d)) + 5) % 7
    }
    /// Все даты месяца (1-е…последнее) как `Date`.
    static func datesOfMonth(_ d: Date) -> [Date] {
        let first = startOfMonth(d)
        return (0..<daysInMonth(d)).compactMap { addDays(first, $0) }
    }

    // MARK: Склонение

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let d10 = n % 10, d100 = n % 100
        if d10 == 1 && d100 != 11 { return one }
        if (2...4).contains(d10) && !(12...14).contains(d100) { return few }
        return many
    }
}

private extension Calendar {
    /// Понедельник — первый день недели (вынесено, чтобы инициализатор `cal`
    /// читался компактно).
    mutating func firstweekday_compat() { self.firstWeekday = 2 }
}
