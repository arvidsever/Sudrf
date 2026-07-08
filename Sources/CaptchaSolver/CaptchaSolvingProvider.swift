import Foundation

/// Контракт, которому должны соответствовать все стратегии распознавания.
///
/// Реализация по умолчанию — `VisionOCRStrategy` (Vision framework, без
/// сетевых вызовов). Протокол оставлен узким, чтобы при желании можно было
/// подменить стратегию (например, на обученную CoreML-модель) без затрагивания
/// вызывающего кода.
public protocol CaptchaSolvingProvider: Sendable {
    /// Распознать капчу. Бросает `CancellationError` при отмене задачи и
    /// `CaptchaSolverError` при внутренних сбоях (Core Image, Vision).
    /// Возвращает `CaptchaAttempt.empty` при неуверенном чтении — это
    /// нормальный поток, а не ошибка.
    func solve(pngData: Data, kind: CaptchaKind) async throws -> CaptchaAttempt
}

/// Ошибки солвера, которые нельзя интерпретировать как «я не уверен» —
/// настоящие сбои (повреждённый PNG, отмена задачи, сбой Vision).
public enum CaptchaSolverError: Error, Sendable, Equatable {
    /// PNG не удалось декодировать в `CIImage` (битые данные, не PNG).
    case imageDecodeFailed
    /// Контекст Core Image не инициализировался.
    case coreImageContextUnavailable
    /// Vision вернул ошибку распознавания.
    case visionFailed(String)
}
