//  DateUtil.swift — Sudrf · работа с РЕАЛЬНЫМИ датами (v15)
//  Прежде разделы мониторинга жили на «индексе дня в июне» (CalUtil.today = 12,
//  дни 1…30). Для дат, ВЫЧИСЛЯЕМЫХ из живого движения дела (а они приходят по
//  всем месяцам и годам — решение 2025-го, апелляция 2026-го), индекс месяца
//  непригоден. Здесь — обобщение на `Date`: «сегодня» = системная дата, грид
//  любого месяца, русское форматирование, относительные сроки.

import Foundation

enum DateUtil {

    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "ru_RU")
        c.firstweekday_compat()
        return c
    }()

    private static let monthsGen = ["января", "февраля", "марта", "апреля", "мая",
                                    "июня", "июля", "августа", "сентября",
                                    "октября", "ноября", "декабря"]
    private static let monthsNom = ["Январь", "Февраль", "Март", "Апрель", "Май",
                                    "Июнь", "Июль", "Август", "Сентябрь",
                                    "Октябрь", "Ноябрь", "Декабрь"]
    private static let weekdaysFull = ["Воскресенье", "Понедельник", "Вторник",
                                       "Среда", "Четверг", "Пятница", "Суббота"]
    static let weekdayShort = ["ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ", "ВС"]

    // MARK: Базовое

    static func startOfDay(_ d: Date) -> Date { cal.startOfDay(for: d) }
    static var today: Date { startOfDay(Date()) }

    static func sameDay(_ a: Date, _ b: Date) -> Bool {
        cal.isDate(a, inSameDayAs: b)
    }
    static func isToday(_ d: Date) -> Bool { sameDay(d, today) }

    /// Разница в КАЛЕНДАРНЫХ днях (b − a). Положительная — b позже a.
    static func daysBetween(_ a: Date, _ b: Date) -> Int {
        cal.dateComponents([.day], from: startOfDay(a), to: startOfDay(b)).day ?? 0
    }
    static func addDays(_ d: Date, _ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: d) ?? d
    }
    static func addMonths(_ d: Date, _ n: Int) -> Date {
        cal.date(byAdding: .month, value: n, to: d) ?? d
    }

    // MARK: Разбор дат с сайта суда

    /// Парсит «дд.мм.гггг» (возможен хвост вроде «дд.мм.гггг 14:00» или мусор) в
    /// полночь местного дня. Возвращает nil для пустых/непарсируемых строк.
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // Берём первые три числовых группы, разделённые точкой.
        let head = t.split(whereSeparator: { $0 == " " }).first.map(String.init) ?? t
        let parts = head.split(separator: ".")
        guard parts.count >= 3,
              let d = Int(parts[0]), let m = Int(parts[1]), let y = Int(parts[2]),
              (1...31).contains(d), (1...12).contains(m) else { return nil }
        return cal.date(from: DateComponents(year: y, month: m, day: d)).map(startOfDay)
    }

    // MARK: Форматирование

    /// «14 мая».
    static func fmt(_ d: Date) -> String {
        "\(cal.component(.day, from: d)) \(monthsGen[cal.component(.month, from: d) - 1])"
    }
    /// «14 мая 2026 года» (полная дата прописью месяца).
    static func fmtFull(_ d: Date) -> String {
        "\(fmt(d)) \(cal.component(.year, from: d)) года"
    }
    /// «16.06» — короткая для повестки/лент.
    static func shortDM(_ d: Date) -> String {
        String(format: "%02d.%02d", cal.component(.day, from: d), cal.component(.month, from: d))
    }
    /// Полное название дня недели.
    static func weekday(_ d: Date) -> String {
        weekdaysFull[cal.component(.weekday, from: d) - 1]
    }
    /// Короткое «вт, 16.06» / «сегодня».
    static func dateLabel(_ d: Date) -> String {
        if isToday(d) { return "сегодня" }
        let wd = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"][cal.component(.weekday, from: d) - 1]
        return "\(wd), \(shortDM(d))"
    }
    /// «Июнь 2026».
    static func monthTitle(_ d: Date) -> String {
        "\(monthsNom[cal.component(.month, from: d) - 1]) \(cal.component(.year, from: d))"
    }
    /// «сегодня» / «через N дней» / «срок прошёл».
    static func relative(_ d: Date) -> String {
        let diff = daysBetween(today, d)
        if diff == 0 { return "сегодня" }
        if diff < 0 { return "срок прошёл" }
        return "через \(diff) " + plural(diff, "день", "дня", "дней")
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
