import Foundation

/// Главная точка входа солвера. Обёртка над `CaptchaSolvingProvider`,
/// добавляющая три вещи:
///   1. Per-process rate limit (защита от разгона CPU).
///   2. Логирование каждой попытки.
///   3. Возможность подмены провайдера в тестах.
public actor CaptchaSolver {

    private let provider: any CaptchaSolvingProvider
    private let configuration: CaptchaConfiguration
    public nonisolated let log: CaptchaSolverLog
    private var lastInvocationAt: Date = .distantPast

    public init(provider: any CaptchaSolvingProvider = VisionOCRStrategy(),
                configuration: CaptchaConfiguration = .default,
                log: CaptchaSolverLog = .shared) {
        self.provider = provider
        self.configuration = configuration
        self.log = log
    }

    /// Распознать капчу. Метод идемпотентен относительно `pngData + kind` —
    /// внутри нет глобального состояния, только rate limit.
    public func solve(pngData: Data, kind: CaptchaKind) async throws -> CaptchaAttempt {
        guard configuration.enabledKinds.contains(kind) else {
            return .empty
        }
        await throttleIfNeeded()
        let started = Date()
        do {
            let attempt = try await provider.solve(pngData: pngData, kind: kind)
            let elapsed = Date().timeIntervalSince(started)
            let measured = CaptchaAttempt(
                value: attempt.value,
                confidence: attempt.confidence,
                duration: elapsed
            )
            log.logAttempt(host: "(solver)", kind: kind, attempt: measured)
            return measured
        } catch {
            // Внутренние сбои провайдера (CIImage декод, Vision с пустой
            // картинкой) превращаем в «не уверен» — вызывающая сторона
            // уйдёт в ручную очередь. Только `CancellationError`
            // пробрасываем как есть.
            if error is CancellationError {
                throw error
            }
            log.logError(host: "(solver)", kind: kind, error: error)
            return .empty
        }
    }

    private func throttleIfNeeded() async {
        let now = Date()
        let elapsedMs = Int(now.timeIntervalSince(lastInvocationAt) * 1000)
        let wait = configuration.minIntervalMs - elapsedMs
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
        }
        lastInvocationAt = Date()
    }
}
