import Foundation

/// `CaptchaSolvingProvider`, который делегирует вызовы `primary` или
/// `fallback` в зависимости от `CaptchaKind`. Используется
/// `AppModel`/`SearchModel` для смешанного режима: CoreML для
/// `.sudrfToken` (числовые captcha), Vision для `.kcaptcha` (текст).
///
/// Семантика:
///   - `primary.solve(...)` — для тех `kind`, которые он обслуживает
///     (например, `.sudrfToken` у CoreML-стратегии). Если primary не
///     обслуживает этот kind, делегирует `fallback`.
///   - `primary.topCandidates(...)` — то же самое.
///
/// Если `primary.solve` бросает (CIImage decode, CoreML prediction),
/// стратегия НЕ пробрасывает ошибку — она конвертирует её в
/// `.empty`, как делает `CaptchaSolver.solve` (см. там).
///
/// A4b: ответ primary допускается только если он достигает
/// `minPrimaryConfidence` и проходит `primaryAttemptIsCompatible`.
/// Иначе используется `fallback`, чтобы не отправлять на сервер
/// уверенный, но неподходящий ответ специализированной модели.
public struct KindDispatchingStrategy: CaptchaSolvingProvider {

    public let primary: any CaptchaSolvingProvider
    public let fallback: any CaptchaSolvingProvider
    public let primaryKinds: Set<CaptchaKind>
    public let minPrimaryConfidence: Double
    public let primaryAttemptIsCompatible: @Sendable (CaptchaAttempt) -> Bool

    public init(primary: any CaptchaSolvingProvider,
                fallback: any CaptchaSolvingProvider,
                primaryKinds: Set<CaptchaKind> = [.sudrfToken],
                minPrimaryConfidence: Double = 0,
                primaryAttemptIsCompatible: @escaping @Sendable (CaptchaAttempt) -> Bool = { _ in true }) {
        self.primary = primary
        self.fallback = fallback
        self.primaryKinds = primaryKinds
        self.minPrimaryConfidence = minPrimaryConfidence
        self.primaryAttemptIsCompatible = primaryAttemptIsCompatible
    }

    public func solve(pngData: Data, kind: CaptchaKind, host: String?) async throws -> CaptchaAttempt {
        if primaryKinds.contains(kind) {
            do {
                let attempt = try await primary.solve(pngData: pngData, kind: kind, host: host)
                guard attempt.confidence >= minPrimaryConfidence,
                      primaryAttemptIsCompatible(attempt) else {
                    return try await fallback.solve(pngData: pngData, kind: kind, host: host)
                }
                return attempt
            } catch {
                if error is CancellationError { throw error }
                // CoreML-specific сбои → fallback. Не превращаем в
                // .empty здесь: пусть caller увидит, что CoreML
                // не справился, и сделает сам. Vision-fallback ниже
                // гарантирует, что не зависнем.
                return try await fallback.solve(pngData: pngData, kind: kind, host: host)
            }
        }
        return try await fallback.solve(pngData: pngData, kind: kind, host: host)
    }
}
