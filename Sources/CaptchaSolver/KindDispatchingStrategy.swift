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
public struct KindDispatchingStrategy: CaptchaSolvingProvider {

    public let primary: any CaptchaSolvingProvider
    public let fallback: any CaptchaSolvingProvider
    public let primaryKinds: Set<CaptchaKind>

    public init(primary: any CaptchaSolvingProvider,
                fallback: any CaptchaSolvingProvider,
                primaryKinds: Set<CaptchaKind> = [.sudrfToken]) {
        self.primary = primary
        self.fallback = fallback
        self.primaryKinds = primaryKinds
    }

    public func solve(pngData: Data, kind: CaptchaKind, host: String?) async throws -> CaptchaAttempt {
        if primaryKinds.contains(kind) {
            do {
                return try await primary.solve(pngData: pngData, kind: kind, host: host)
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
