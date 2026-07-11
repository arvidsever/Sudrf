import Foundation
import SwiftSoup

/// Классификация страницы, пришедшей в ответ на поисковый GET.
///
/// Нужна для перебора вариантов URL: «валидная пустая выдача» и «модуль не понял
/// запрос» выглядят одинаково с точки зрения ResultsParser (ноль результатов),
/// но означают противоположное — в первом случае дел действительно нет, во втором
/// надо пробовать следующий вариант URL, а если вариантов не осталось — честно
/// сообщать об ошибке, а не показывать пустоту.
///
/// Текстовые маркеры выверены по IssueByTextIdentifier из tochno-st/sudrfscraper —
/// у них это боевой классификатор, прогнанный по всем ~2270 судам платформы.
public enum SearchPageKind: Sendable {
    case results        // есть ссылки на карточки дел
    case empty          // валидная выдача, дел не найдено
    case captcha        // страница требует проверочный код
    /// Страница с сообщением о неверно введённом проверочном коде
    /// (например, «Неверно указан проверочный код с картинки»).
    /// Это **не** форма captcha — это сервер сообщает, что
    /// ранее отправленный код был отвергнут. Используется в
    /// `AutoCaptchaSolver` как сигнал «не добавлять этот
    /// captcha PNG в bootstrap-корпус» (v0.38.9).
    case captchaRejected
    case unrecognized   // модуль не понял запрос / другой интерфейс / заглушка
}

public enum SearchPageClassifier {

    /// Маркеры страницы «captcha отвергнута сервером». Это
    /// появляется на странице результатов после submit'а с
    /// неверным кодом. Маркеры собраны из handoff v0.38.7
    /// (1kas variant diag файл) и опроса `captcha-failures/`.
    public static let captchaRejectedMarkers: [String] = [
        "Неверно указан проверочный код с картинки",
        "Неверный проверочный код",
        "Неверно введен проверочный код",
        "Invalid security code",
        "Invalid captcha"
    ]

    public static func classify(html: String) -> SearchPageKind {
        // 1) Ссылки на карточки — самый надёжный признак настоящей выдачи.
        if let doc = try? SwiftSoup.parse(html),
           let anchors = try? doc.select("a[href*=name_op=case]"),
           anchors.size() > 0 {
            return .results
        }
        if let doc = try? SwiftSoup.parse(html),
           let anchors = try? doc.select("a[href*=op=cs][href*=case_id]"),
           anchors.size() > 0 {
            return .results
        }

        // 1a) Captcha-rejected: страница результатов с сообщением
        // «неверный код». Проверяем ДО общего captcha-детектора,
        // чтобы различать «форму с картинкой» (`.captcha`) и
        // «отказ после submit'а» (`.captchaRejected`).
        if captchaRejectedMarkers.contains(where: html.contains) {
            return .captchaRejected
        }

        if CaptchaDetector.hasCaptcha(in: html) { return .captcha }

        // «Время жизни сессии закончилось» — сессионная страница, требующая
        // повторного захода через форму; для вызывающего равносильна капче.
        if html.contains("Время жизни сессии закончилось") { return .captcha }

        // 2) Явные формулировки пустой выдачи sud_delo.
        let emptyMarkers = [
            "Данных по запросу не обнаружено",
            "Данных по запросу не найдено",
            "Ничего не найдено"
        ]
        if emptyMarkers.contains(where: html.contains) { return .empty }

        // 3) Счётчик выдачи без карточек. Положительный счётчик означает
        // регрессию селектора, а не уверенное «дел нет».
        if let count = resultCount(in: html) { return count == 0 ? .empty : .unrecognized }
        if html.contains("Всего по запросу найдено") { return .unrecognized }
        if html.contains("Найдено дел: 0") || html.contains("id=\"search_results\"") {
            return .empty
        }

        return .unrecognized
    }

    private static func resultCount(in html: String) -> Int? {
        let pattern = #"Всего\s+по\s+запросу\s+найдено\s*[-—:]?\s*(?:<[^>]+>\s*)*(\d+)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let match = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return Int(ns.substring(with: match.range(at: 1)))
    }
}
