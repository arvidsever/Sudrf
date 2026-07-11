import Foundation
import SwiftSoup

/// Обнаружение капчи на странице.
///
/// Принцип навыка и пакета: капчу НЕ решаем автоматически. Если она есть,
/// клиент бросает `SudrfError.captchaRequired`, и человек вводит код в браузере.
/// Этот тип только детектирует наличие капчи, ничего не «обходя».
public enum CaptchaDetector {

    public static func hasCaptcha(in html: String) -> Bool {
        if let doc = try? SwiftSoup.parse(html) {
            if hasNamedCaptchaInput(in: doc) || hasCaptchaLabelNearEditableInput(in: doc) {
                return true
            }
            // Старые страницы иногда оставляют подпись заголовком вне контейнера
            // поля. Допускаем её лишь вне таблиц: текст чужой строки не должен
            // влиять на произвольное поле ниже страницы.
            if hasCaptchaTextOutsideTable(in: doc), hasEditableInput(in: doc) {
                return true
            }
            return false
        }

        // Фолбэк по тексту — только если нестандартная разметка не разобралась.
        // На судах ОСЮ (напр. КСОЮ) капча выводится inline-картинкой (data:URI),
        // а поле подписано «Проверочный код»; на странице ошибки — «Неверно указан
        // проверочный код». Не считаем `captchaid` внутри URL счётчиков признаком:
        // успешные страницы КСОЮ кодируют исходный URL в `counter.sudrf.ru`.
        let lower = html.lowercased()
        return lower.contains("name=\"captcha\"")
            || lower.contains("name='captcha'")
            || (hasCaptchaText(lower) && hasEditableInputMarkup(lower))
    }

    private static func hasNamedCaptchaInput(in doc: Document) -> Bool {
        guard let inputs = try? doc.select("input") else { return false }
        return inputs.array().contains { input in
            guard isEditableInput(input) else { return false }
            let name = inputName(input)
            return name == "captcha" || (name.contains("captcha") && !name.contains("captchaid"))
        }
    }

    private static func hasEditableInput(in doc: Document) -> Bool {
        ((try? doc.select("input").array()) ?? []).contains(where: isEditableInput)
    }

    private static func hasCaptchaTextOutsideTable(in doc: Document) -> Bool {
        let candidates = (try? doc.select("h1, h2, h3, h4, h5, h6, label, p, span, div").array()) ?? []
        return candidates.contains { element in
            let inTable = element.parents().array().contains { $0.tagName().lowercased() == "table" }
            return !inTable && hasCaptchaText(((try? element.text()) ?? "").lowercased())
        }
    }

    private static func hasCaptchaLabelNearEditableInput(in doc: Document) -> Bool {
        guard let inputs = try? doc.select("input") else { return false }
        return inputs.array().contains { input in
            guard isEditableInput(input) else { return false }
            return hasCaptchaText(nearbyText(for: input).lowercased())
        }
    }

    private static func inputName(_ input: Element) -> String {
        let raw = ((try? input.attr("name")) ?? "") + " " + ((try? input.attr("id")) ?? "")
        return raw.lowercased()
    }

    private static func isEditableInput(_ input: Element) -> Bool {
        let type = ((try? input.attr("type")) ?? "text").lowercased()
        let ignoredTypes: Set<String> = ["hidden", "submit", "button", "reset", "checkbox", "radio"]
        guard !ignoredTypes.contains(type) else { return false }
        if input.hasAttr("disabled") || input.hasAttr("readonly") { return false }
        let style = ((try? input.attr("style")) ?? "").lowercased()
        return !style.contains("display:none")
            && !style.contains("display: none")
            && !style.contains("visibility:hidden")
            && !style.contains("visibility: hidden")
    }

    private static func nearbyText(for input: Element) -> String {
        if let row = input.parents().array().first(where: { $0.tagName().lowercased() == "tr" }),
           let text = try? row.text() {
            return text
        }
        var parts: [String] = []
        if let id = try? input.attr("id"), !id.isEmpty,
           let labels = try? input.ownerDocument()?.select("label[for=\(id)]") {
            parts.append(contentsOf: labels.array().compactMap { try? $0.text() })
        }
        if let parent = input.parent(), let text = try? parent.text() {
            parts.append(text)
            // Некоторые страницы ставят заголовок «Проверочный код» отдельным
            // элементом непосредственно перед контейнером поля. Это локальная
            // связь, в отличие от поиска первой строки таблицы по документу.
            if let previous = try? parent.previousElementSibling(),
               ["h1", "h2", "h3", "h4", "h5", "h6"].contains(previous.tagName().lowercased()),
               let heading = try? previous.text() {
                parts.append(heading)
            }
        }
        return parts.joined(separator: " ")
    }

    private static func hasCaptchaText(_ lower: String) -> Bool {
        lower.contains("проверочный код")
            || lower.contains("код с картинки")
            || lower.contains("дополнительную проверку")
    }

    private static func hasEditableInputMarkup(_ lower: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"<input\b[^>]*>"#) else { return false }
        let ns = lower as NSString
        let range = NSRange(location: 0, length: ns.length)
        return re.matches(in: lower, range: range).contains { match in
            isEditableInputMarkup(ns.substring(with: match.range))
        }
    }

    private static func isEditableInputMarkup(_ tag: String) -> Bool {
        let type = attribute("type", in: tag) ?? "text"
        let ignoredTypes: Set<String> = ["hidden", "submit", "button", "reset", "checkbox", "radio"]
        guard !ignoredTypes.contains(type) else { return false }
        if tag.contains("disabled") || tag.contains("readonly") { return false }
        let style = attribute("style", in: tag) ?? ""
        return !style.contains("display:none")
            && !style.contains("display: none")
            && !style.contains("visibility:hidden")
            && !style.contains("visibility: hidden")
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name)
            + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = tag as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = re.firstMatch(in: tag, range: range) else { return nil }
        for i in 1..<match.numberOfRanges where match.range(at: i).location != NSNotFound {
            return ns.substring(with: match.range(at: i))
        }
        return nil
    }
}
