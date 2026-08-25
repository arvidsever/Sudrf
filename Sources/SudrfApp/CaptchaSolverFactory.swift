import CaptchaSolver

/// Собирает единый on-device captcha pipeline для всех прикладных путей.
///
/// Фабрика живёт в `SudrfApp`: только приложение связывает пользовательские
/// настройки, Vision и опциональную CoreML-модель. Сам `CaptchaSolver` не
/// получает зависимость от `SudrfKit` или состояния приложения.
@MainActor
enum CaptchaSolverFactory {
    static func hasEligibleFSSPModel() -> Bool {
        CoreMLModelDiscovery.discoverEligibleFSSPURL() != nil
    }

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
        var provider: any CaptchaSolvingProvider = vision
        var enabledKinds: Set<CaptchaKind> = [.sudrfToken, .kcaptcha]
        if let modelURL = CoreMLModelDiscovery.discoverURL(),
           let coreML = try? CoreMLCaptchaStrategy(modelURL: modelURL, kind: .sudrfToken) {
            var numericProvider: any CaptchaSolvingProvider = coreML
            if let specialistURL = CoreMLModelDiscovery.discoverNumericSpecialistURL(
                beside: modelURL),
               let specialist = try? CoreMLCaptchaStrategy(
                    modelURL: specialistURL, kind: .sudrfToken) {
                numericProvider = HighestConfidenceStrategy(
                    first: coreML, second: specialist)
            }
            provider = KindDispatchingStrategy(
                primary: numericProvider,
                fallback: vision,
                minPrimaryConfidence: settings.minConfidence,
                primaryAttemptIsCompatible: { CoreMLCaptchaStrategy.isCompatibleOutput($0.value) }
            )
        }

        // The FSSP model is a second, nested dispatcher. It never falls back
        // to Vision or the GAS Pravosudie model: on any model failure the
        // attempt is empty and the app remains on the manual path.
        if let modelURL = CoreMLModelDiscovery.discoverEligibleFSSPURL(),
           let fssp = try? CoreMLCaptchaStrategy(modelURL: modelURL, kind: .fsspDigits) {
            provider = KindDispatchingStrategy(
                primary: fssp,
                fallback: provider,
                primaryKinds: [.fsspDigits],
                minPrimaryConfidence: 0,
                primaryAttemptIsCompatible: { CoreMLCaptchaStrategy.isCompatibleOutput($0.value) },
                fallbackOnPrimaryFailure: false
            )
            enabledKinds.insert(.fsspDigits)
        }

        return CaptchaSolver(provider: provider, enabledKinds: enabledKinds)
    }
}
