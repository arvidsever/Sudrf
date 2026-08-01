import CaptchaSolver

/// Собирает единый on-device captcha pipeline для всех прикладных путей.
///
/// Фабрика живёт в `SudrfApp`: только приложение связывает пользовательские
/// настройки, Vision и опциональную CoreML-модель. Сам `CaptchaSolver` не
/// получает зависимость от `SudrfKit` или состояния приложения.
@MainActor
enum CaptchaSolverFactory {
    static func make(settings: CaptchaSettings) -> CaptchaSolver {
        let configuration = settings.solverConfiguration
        var vision = VisionOCRStrategy(preprocessorHosts: settings.preprocessorHosts)
        vision.preprocessingProvider = { [weak settings] in
            settings?.preprocessorEnabled ?? false
        }

        let provider: any CaptchaSolvingProvider
        if let modelURL = CoreMLModelDiscovery.discoverURL(),
           let coreML = try? CoreMLCaptchaStrategy(modelURL: modelURL, kind: .sudrfToken) {
            provider = KindDispatchingStrategy(
                primary: coreML,
                fallback: vision,
                minPrimaryConfidence: configuration.minConfidence,
                primaryAttemptIsCompatible: { CoreMLCaptchaStrategy.isCompatibleOutput($0.value) }
            )
        } else {
            provider = vision
        }

        return CaptchaSolver(provider: provider, configuration: configuration)
    }
}
