import CaptchaSolver

/// Собирает единый on-device captcha pipeline для всех прикладных путей.
///
/// Фабрика живёт в `SudrfApp`: только приложение связывает пользовательские
/// настройки, Vision и опциональную CoreML-модель. Сам `CaptchaSolver` не
/// получает зависимость от `SudrfKit` или состояния приложения.
@MainActor
enum CaptchaSolverFactory {
    static func make(settings: CaptchaSettings) -> CaptchaSolver {
        var vision = VisionOCRStrategy(preprocessorHosts: settings.preprocessorHosts)
        // `preprocessingProvider` — именно замыкание, а не снятое здесь значение
        // (v0.38.4, v0.38.7): флаг читается на каждом вызове `solver.solve`,
        // поэтому тоггл preprocess в меню «Captcha» действует сразу. Со
        // значением он зафиксировался бы на момент сборки солвера, и меню
        // не работало бы до перезапуска приложения.
        vision.preprocessingProvider = { [weak settings] in
            settings?.preprocessorEnabled ?? false
        }

        // `CoreMLCaptchaStrategy` (v0.38.8) обслуживает только `.sudrfToken`:
        // если модель найдена на диске, числовые captcha идут через CoreML,
        // текстовые `.kcaptcha` остаются за Vision. Без модели — только Vision.
        let provider: any CaptchaSolvingProvider
        if let modelURL = CoreMLModelDiscovery.discoverURL(),
           let coreML = try? CoreMLCaptchaStrategy(modelURL: modelURL, kind: .sudrfToken) {
            provider = KindDispatchingStrategy(
                primary: coreML,
                fallback: vision,
                minPrimaryConfidence: settings.minConfidence,
                primaryAttemptIsCompatible: { CoreMLCaptchaStrategy.isCompatibleOutput($0.value) }
            )
        } else {
            provider = vision
        }

        return CaptchaSolver(provider: provider)
    }
}
