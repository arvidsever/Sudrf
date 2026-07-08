import Foundation

/// Параметры поведения `CaptchaSolver` и интеграции в `RefreshCenter`.
///
/// Значения по умолчанию подобраны под sudrf: 3 попытки на одну форму
/// (новая `captchaid` каждый раз, потому что серверная сессия одноразовая),
/// нижняя граница уверенности 0.55 — Vision на простых цифровых капчах
/// обычно уверен выше этого, но шумные msudrf-картинки могут «плавать».
public struct CaptchaConfiguration: Sendable, Equatable {
    /// Максимальное число попыток солвера на одну форму. После исчерпания
    /// `RefreshCenter` ставит дело в `CaptchaPendingQueue` и ждёт пользователя.
    public var maxAttempts: Int

    /// Минимальная уверенность, при которой попытка считается успешной и
    /// токен сохраняется в `CaptchaTokenStore`. Ниже — попытка отбрасывается,
    /// цикл идёт за новым `captchaid`.
    public var minConfidence: Double

    /// Минимальный интервал между вызовами солвера (в миллисекундах).
    /// Защищает от разгона CPU, если `RefreshCenter` по какой-то причине
    /// вызывает солвер в плотном цикле.
    public var minIntervalMs: Int

    /// Поддерживаемые виды капчи. По умолчанию оба — `.sudrfToken` и
    /// `.kcaptcha`. Можно отключить один из них для изоляции проблем.
    public var enabledKinds: Set<CaptchaKind>

    public init(maxAttempts: Int = 3,
                minConfidence: Double = 0.55,
                minIntervalMs: Int = 50,
                enabledKinds: Set<CaptchaKind> = [.sudrfToken, .kcaptcha]) {
        self.maxAttempts = maxAttempts
        self.minConfidence = minConfidence
        self.minIntervalMs = minIntervalMs
        self.enabledKinds = enabledKinds
    }

    public static let `default` = CaptchaConfiguration()
}
