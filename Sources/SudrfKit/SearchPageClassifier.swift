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
    case unrecognized   // модуль не понял запрос / другой интерфейс / заглушка
}

public enum SearchPageClassifier {

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

        // 3) Страница с шапкой выдачи, но без ссылок и без «не найдено» —
        // считаем пустой: «Всего по запросу найдено — 0» встречается без
        // отдельной фразы об отсутствии данных.
        if html.contains("Всего по запросу найдено") { return .empty }
        if html.contains("Найдено дел: 0") || html.contains("id=\"search_results\"") {
            return .empty
        }

        return .unrecognized
    }
}
