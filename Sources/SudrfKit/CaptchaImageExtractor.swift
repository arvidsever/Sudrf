import Foundation
import SwiftSoup

/// Извлечение капчи (PNG + captchaid) из HTML формы sud_delo.
///
/// Раньше эта логика жила в `CaptchaImagePayload` внутри `CaptchaWebView`
/// (`SudrfApp`) — для UI-сценария с `WKWebView`. С добавлением
/// авто-солвера она нужна и в фоне (для `RefreshCenter.tryAutoSolve`),
/// поэтому вынесена в `SudrfKit`, чтобы оба сценария опирались на одну
/// реализацию.
public enum CaptchaImageExtractor {

    /// Декодирует `data:image/png;base64,XXXX` (включая вариант с пробелом
    /// после `data:`, который встречается в sudrf). Возвращает `nil`,
    /// если вход — не data-URL или данные битые.
    public static func data(fromDataURL value: String) -> Data? {
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let meta = value[..<comma].lowercased()
        // sudrf ставит пробел сразу после запятой — и сам base64 может
        // содержать внутренние пробелы (переводы строк) для
        // человекопригодности. Чистим.
        let body = String(value[value.index(after: comma)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        if meta.contains(";base64") {
            return Data(base64Encoded: body)
        }
        return body.removingPercentEncoding?.data(using: .utf8)
    }

    /// Находит в HTML первый кандидат `<input name="captchaid">` со
    /// значением, плюс первую `<img src="data:image/...">` или, при
    /// отсутствии inline-картинки, `<img src="…captcha…">`.
    public static func extract(html: String) throws -> (png: Data, captchaid: String)? {
        let doc = try SwiftSoup.parse(html)
        guard let captchaidInput = try doc.select("input[name=captchaid]").first() else {
            return nil
        }
        let captchaid = (try? captchaidInput.attr("value")) ?? ""
        guard !captchaid.isEmpty else { return nil }

        // Inline data URL — основной путь для sudrf-капч. Selector
        // `src^=data` ловит и `data: image/png;base64,…` (с пробелом
        // после двоеточия — реальный формат sudrf), и канонический
        // `data:image/png;base64,…`.
        if let img = try doc.select("img[src^=data]").first() {
            let src = (try? img.attr("src")) ?? ""
            if let png = data(fromDataURL: src) {
                return (png, captchaid)
            }
        }
        return nil
    }
}
