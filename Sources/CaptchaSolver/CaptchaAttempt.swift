import Foundation

/// Результат одной попытки распознавания.
///
/// `confidence` — оценка от 0.0 до 1.0. Значение ниже
/// `CaptchaConfiguration.minConfidence` означает, что солвер не уверен и
/// вызывающая сторона должна вернуться к ручному вводу. `value` в этом
/// случае может быть пустым или содержать наилучшее предположение.
public struct CaptchaAttempt: Sendable, Equatable {
    public let value: String
    public let confidence: Double
    public let duration: TimeInterval

    public init(value: String, confidence: Double, duration: TimeInterval) {
        self.value = value
        self.confidence = confidence
        self.duration = duration
    }

    /// Попытка считается надёжной, если уверенность не ниже порога.
    public func isConfident(min: Double) -> Bool {
        confidence >= min
    }

    /// Попытка без ответа — используется для «пропускаем и пробуем новый
    /// captchaid» в цикле ретраев `RefreshCenter.tryAutoSolve`.
    public static let empty = CaptchaAttempt(value: "", confidence: 0, duration: 0)
}
