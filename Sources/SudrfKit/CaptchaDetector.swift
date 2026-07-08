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
        }

        // Фолбэк по тексту — на случай нестандартной разметки.
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
        if let row = try? input.parents().select("tr").first(), let text = try? row.text() {
            return text
        }
        var parts: [String] = []
        if let id = try? input.attr("id"), !id.isEmpty,
           let labels = try? input.ownerDocument()?.select("label[for=\(id)]") {
            parts.append(contentsOf: labels.array().compactMap { try? $0.text() })
        }
        if let parent = input.parent(), let text = try? parent.text() {
            parts.append(text)
        }
        return parts.joined(separator: " ")
    }

    private static func hasCaptchaText(_ lower: String) -> Bool {
        lower.contains("проверочный код") || lower.contains("код с картинки")
    }

    private static func hasEditableInputMarkup(_ lower: String) -> Bool {
        lower.contains("<input") && !lower.contains("type=\"hidden\"")
    }
}
