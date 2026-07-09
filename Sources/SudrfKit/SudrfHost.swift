import Foundation

/// Хосты судов на sudrf.ru существуют в двух формах: главная страница открывается
/// через точку (`vs.komi.sudrf.ru`), а модульные страницы (`modules.php`) — через
/// двойное тире (`vs--komi.sudrf.ru`). Точечная форма для модулей редиректит на
/// дефисную. Поэтому для запросов к `modules.php` хост приводится к дефисной форме,
/// а при ошибке делается фолбэк на точечную (перебор обоих вариантов).
public enum SudrfHost {

    private static let suffix = ".sudrf.ru"

    /// Хост платформы мировых судей: сам `msudrf.ru` или его поддомен.
    /// Голый suffix-check опасен: `xmsudrf.ru` не должен считаться мировым судом.
    public static func isMSudrfHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "msudrf.ru" || host.hasSuffix(".msudrf.ru")
    }

    /// Канонический хост для модульных страниц: первый разделитель «точка» в части
    /// до `.sudrf.ru` заменяется на «--». Уже дефисные и бессегментные (`3kas`) — без изменений.
    public static func moduleHost(_ host: String) -> String {
        guard host.hasSuffix(suffix) else { return host }
        let label = String(host.dropLast(suffix.count))
        if label.contains("--") { return host }                       // уже модульная форма
        guard let dot = label.firstIndex(of: ".") else { return host } // нет сегмента региона (3kas)
        let head = String(label[..<dot])
        let tail = String(label[label.index(after: dot)...])
        return "\(head)--\(tail)\(suffix)"
    }

    /// Альтернативная форма хоста для фолбэка: «--» ↔ «.» (первый разделитель).
    /// nil — если разделителя нет (альтернативы не существует).
    public static func alternate(_ host: String) -> String? {
        guard host.hasSuffix(suffix) else { return nil }
        let label = String(host.dropLast(suffix.count))
        if let r = label.range(of: "--") {
            let head = String(label[..<r.lowerBound])
            let tail = String(label[r.upperBound...])
            return "\(head).\(tail)\(suffix)"
        }
        if let dot = label.firstIndex(of: ".") {
            let head = String(label[..<dot])
            let tail = String(label[label.index(after: dot)...])
            return "\(head)--\(tail)\(suffix)"
        }
        return nil
    }
}

public extension Court {
    /// Копия суда с другим доменом (для перебора форм хоста).
    func withDomain(_ domain: String) -> Court {
        Court(domain: domain, title: title, level: level)
    }
}
