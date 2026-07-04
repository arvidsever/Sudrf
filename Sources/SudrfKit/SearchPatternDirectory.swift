import Foundation

/// Версия поискового интерфейса модуля sud_delo на сайте суда.
///
/// Большинство судов принимает «современный» GET (`delo_id=…&new=…&<TABLE>__CASE_NUMBERSS=…`),
/// но ~101 суд (Воронежская, Тверская, Амурская, Ульяновская области, несколько
/// областных и гарнизонных) работает на «винтажной» версии модуля: параметры
/// `_deloId=…&_new=…&vnkod=<код суда>&case__case_numberss=…` (поля общие для всех
/// видов производств). Запрос современного формата такой суд молча игнорирует.
public enum SearchPattern: String, Sendable, Codable {
    case primary   // delo_id / new / <TABLE>__CASE_NUMBERSS
    case vnkod     // _deloId / _new / vnkod= / case__case_numberss
}

/// Справочник судов на винтажном интерфейсе. Источник — конфигурация проекта
/// tochno-st/sudrfscraper (см. Scripts/derive-vnkod.py); в ресурсах хранится
/// только срез VNKOD-судов, для остальных действует primary по умолчанию.
public enum SearchPatternDirectory {

    public struct Entry: Sendable, Codable {
        public let domain: String      // дефисная (модульная) форма хоста
        public let vnkod: String       // внутренний код суда, напр. 28RS0011
        public let title: String
        public let hasCaptcha: Bool
    }

    /// Индекс по хосту: и дефисная, и точечная формы указывают на одну запись,
    /// чтобы поиск работал независимо от формы, пришедшей от вызывающего.
    static let byDomain: [String: Entry] = {
        guard let url = Bundle.module.url(forResource: "VNKODCourts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return [:]
        }
        var index: [String: Entry] = [:]
        for e in entries {
            index[e.domain] = e
            if let alt = SudrfHost.alternate(e.domain) { index[alt] = e }
        }
        return index
    }()

    /// Версия поискового интерфейса суда. Неизвестный домен — primary.
    public static func pattern(forDomain domain: String) -> SearchPattern {
        byDomain[domain.lowercased()] != nil ? .vnkod : .primary
    }

    /// Внутренний код суда (vnkod) для винтажного интерфейса; nil у primary-судов.
    public static func vnkod(forDomain domain: String) -> String? {
        byDomain[domain.lowercased()]?.vnkod
    }

    /// Известно ли, что на поисковой форме суда стоит капча (по данным среза).
    public static func hasCaptcha(forDomain domain: String) -> Bool {
        byDomain[domain.lowercased()]?.hasCaptcha ?? false
    }
}
