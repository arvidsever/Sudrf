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

    /// Включает лёгкую предобработку (grayscale + contrast + 2x scale)
    /// перед подачей в `VNRecognizeTextRequest`. По умолчанию **выключена**:
    /// на captcha sudrf без сильных искажений Vision с прямым PNG
    /// даёт conf=1.00, а предобработка может вносить артефакты
    /// (например, читать «667» как «49»). Включать стоит только для
    /// хостов с rotated/struck-through captcha, у которых Vision
    /// возвращает conf=0.00 на сырых данных.
    ///
    /// Per-host gating: `preprocessorHosts: Set<String>` ниже
    /// определяет, на каких хостах preprocess активен. Если множество
    /// пустое — preprocess выключен глобально.
    public var preprocessingEnabled: Bool

    /// Хосты (например, `sankt-peterburgsky--spb.sudrf.ru`), на которых
    /// предобработка применяется. Если пусто и `preprocessingEnabled = true`,
    /// preprocess применяется ко всем. Если `preprocessingEnabled = false`,
    /// preprocess выключен везде.
    public var preprocessorHosts: Set<String>

    /// Путь к скомпилированной CoreML-модели (`*.mlmodelc`). Если задан —
    /// `AppModel`/`SearchModel` оборачивают солвер в `CoreMLCaptchaStrategy`
    /// для указанного `kind`; nil — fallback на `VisionOCRStrategy`.
    /// Модель обучена на корпусе captcha-изображений (см.
    /// `Scripts/train-coreml-captcha.swift`) и заменяет Vision на captcha
    /// с rotated/struck-through цифрами, где Vision даёт conf=0.00.
    public var modelURL: URL?

    public init(maxAttempts: Int = 3,
                minConfidence: Double = 0.55,
                minIntervalMs: Int = 50,
                enabledKinds: Set<CaptchaKind> = [.sudrfToken, .kcaptcha],
                preprocessingEnabled: Bool = false,
                preprocessorHosts: Set<String> = [],
                modelURL: URL? = nil) {
        self.maxAttempts = maxAttempts
        self.minConfidence = minConfidence
        self.minIntervalMs = minIntervalMs
        self.enabledKinds = enabledKinds
        self.preprocessingEnabled = preprocessingEnabled
        self.preprocessorHosts = preprocessorHosts
        self.modelURL = modelURL
    }

    public static let `default` = CaptchaConfiguration()
}
