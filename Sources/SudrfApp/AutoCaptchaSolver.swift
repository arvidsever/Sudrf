import Foundation
import SudrfKit
import CaptchaSolver

/// Общая логика авто-решения капчи для интерактивного поиска и
/// фонового обновления. Вынесена из `RefreshCenter`, чтобы оба
/// сценария (пользователь жмёт «Искать» и фоновый 10-минутный
/// обход `RefreshCenter`) использовали один и тот же код-путь и
/// одну и ту же телеметрию.
///
/// Логика:
///   1. Скачать HTML формы (`SudrfClient.fetchForm`).
///   2. Извлечь PNG и `captchaid` через `CaptchaImageExtractor`.
///   3. Прогнать PNG через `CaptchaSolver` для конкретного `CaptchaKind`
///      (по домену URL).
///   4. Если уверенность ≥ `minConfidence` — вернуть `CaptchaToken`.
///   5. Иначе повторить со следующей попытки (новый `captchaid` —
///      каждый GET формы выдаёт свежую пару). До `maxAttempts`.
///   6. При исчерпании — `nil` (вызывающая сторона откроет ручную
///      `CaptchaAssistSheet`).
///
/// При любой внутренней ошибке (Vision, CIImage, извлечение) —
/// попытка считается неудачной, лог пишется, цикл идёт дальше.
enum AutoCaptchaSolver {

    struct Settings: Sendable, Equatable {
        var maxAttempts: Int
        var minConfidence: Double

        static let `default` = Settings(maxAttempts: 3, minConfidence: 0.55)
    }

    /// Попытаться решить капчу на форме `formURL`. Возвращает токен
    /// или `nil` после исчерпания попыток. На каждой итерации —
    /// свежий GET формы, поэтому `captchaid` уникален.
    ///
    /// При полном исчерпании попыток последний извлечённый PNG
    /// (если был) сохраняется в `~/Library/Application Support/Sudrf/captcha-failures/`
    /// для ручного изучения — типичный кейс: какой-то конкретный суд
    /// даёт Vision-у conf=0.00, без скриншота картинки невозможно
    /// понять, в чём дело.
    static func solve(formURL: URL,
                      client: SudrfClient,
                      solver: CaptchaSolver,
                      settings: Settings = .default) async -> CaptchaToken? {
        let kind = kindFromURL(formURL)
        let log = solver.log
        var lastPNG: Data? = nil
        for attempt in 0..<settings.maxAttempts {
            do {
                let html = try await client.fetchForm(formURL)
                guard let (png, captchaid) = try CaptchaImageExtractor.extract(html: html) else {
                    log.logSkip(host: formURL.host ?? "?", kind: kind,
                                reason: "no captcha image in form HTML (attempt \(attempt + 1))")
                    return nil
                }
                lastPNG = png
                let result = try await solver.solve(pngData: png, kind: kind)
                if result.confidence >= settings.minConfidence {
                    let token = CaptchaToken(value: result.value, id: captchaid)
                    log.logSkip(host: formURL.host ?? "?", kind: kind,
                                reason: "solved value=\(result.value) conf=\(String(format: "%.2f", result.confidence)) on attempt \(attempt + 1)")
                    return token
                } else {
                    log.logSkip(host: formURL.host ?? "?", kind: kind,
                                reason: "low confidence \(String(format: "%.2f", result.confidence)) on attempt \(attempt + 1)")
                }
                } catch {
                    log.logError(host: formURL.host ?? "?", kind: kind, error: error)
                    continue
                }
        }
        // Полное исчерпание попыток — сохраняем последнюю картинку для
        // отладки и помечаем в логе путь к ней.
        if let png = lastPNG {
            let path = log.logFailedImage(png: png, host: formURL.host ?? "?", kind: kind)
            let pathStr = path?.path ?? "(save failed)"
            log.logSkip(host: formURL.host ?? "?", kind: kind,
                        reason: "all \(settings.maxAttempts) attempts failed; last image saved to \(pathStr)")
        }
        return nil
    }

    /// Вид капчи по URL — `msudrf.ru` → `.kcaptcha`, иначе `.sudrfToken`.
    /// Совпадает с правилом, по которому `SearchModel.beginCaptcha` выбирал
    /// `Kind` в UI-сценарии (см. SearchModel.swift:593) и `MagistrateClient`.
    static func kindFromURL(_ url: URL) -> CaptchaKind {
        guard let host = url.host?.lowercased() else { return .sudrfToken }
        if host == "msudrf.ru" || host.hasSuffix(".msudrf.ru") {
            return .kcaptcha
        }
        return .sudrfToken
    }
}
