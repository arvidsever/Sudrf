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
    ///
    /// `host` — опциональный домен формы (например,
    /// `sankt-peterburgsky--spb.sudrf.ru`). Пробрасывается в провайдер
    /// для per-host решений (например, preprocessor hosts).
    public func solve(pngData: Data, kind: CaptchaKind, host: String? = nil) async throws -> CaptchaAttempt {
        guard configuration.enabledKinds.contains(kind) else {
            return .empty
        }
        await throttleIfNeeded()
        let started = Date()
        do {
            let attempt = try await provider.solve(pngData: pngData, kind: kind, host: host)
            let elapsed = Date().timeIntervalSince(started)
            let measured = CaptchaAttempt(
                value: attempt.value,
                confidence: attempt.confidence,
                duration: elapsed
            )
            log.logAttempt(host: host ?? "(solver)", kind: kind, attempt: measured)
            return measured
        } catch {
            // Внутренние сбои провайдера (CIImage декод, Vision с пустой
            // картинкой) превращаем в «не уверен» — вызывающая сторона
            // уйдёт в ручную очередь. Только `CancellationError`
            // пробрасываем как есть.
            if error is CancellationError {
                throw error
            }
            log.logError(host: host ?? "(solver)", kind: kind, error: error)
            return .empty
        }
    }

    /// Возвращает топ-N кандидатов от `VisionOCRStrategy` для
    /// диагностики. Доступно только если провайдер — `VisionOCRStrategy`
    /// (для других провайдеров возвращает пустой массив). Применяет те
    /// же preprocess-правила, что и `solve`, чтобы диагностика
    /// соответствовала фактическому распознаванию. Второй элемент
    /// кортежа — был ли применён preprocess.
    public func topCandidates(pngData: Data, kind: CaptchaKind, host: String? = nil, n: Int = 3) async -> (candidates: [(text: String, confidence: Double)], preprocessed: Bool) {
        guard let vision = provider as? VisionOCRStrategy else { return ([], false) }
        do {
            return try await vision.topCandidates(pngData: pngData, kind: kind, host: host, n: n)
        } catch {
            return ([], false)
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
