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
            let selector = "input[name=captcha], input[name=captchaid], img[src*=captcha], #captcha"
            if let els = try? doc.select(selector), els.size() > 0 {
                return true
            }
        }
        // Фолбэк по тексту — на случай нестандартной разметки.
        // На судах ОСЮ (напр. КСОЮ) капча выводится inline-картинкой (data:URI),
        // а поле подписано «Проверочный код»; на странице ошибки — «Неверно указан
        // проверочный код». Это надёжные текстовые признаки.
        let lower = html.lowercased()
        return lower.contains("name=\"captcha\"")
            || lower.contains("name='captcha'")
            || lower.contains("captchaid")
            || lower.contains("/captcha")
            || lower.contains("проверочный код")
            || lower.contains("код с картинки")
    }
}
