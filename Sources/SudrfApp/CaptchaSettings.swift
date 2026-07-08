import Foundation
import SwiftUI
import CaptchaSolver

/// Настройки авто-солвера капчи. Хранятся в UserDefaults, читаются
/// `RefreshCenter.tryAutoSolve` и пунктом меню «Captcha» в системном
/// меню (см. `CaptchaMenu`). Дефолт — солвер включён
/// (плановая позиция из задачи: opt-out).
final class CaptchaSettings: ObservableObject {

    static let shared = CaptchaSettings()

    private static let enabledKey = "captcha.autoSolve"
    private static let minConfidenceKey = "captcha.minConfidence"

    /// Принудительно выключает солвер независимо от настройки — для
    /// тестов, в которых нужен детерминированный «как без солвера»
    /// сценарий.
    var forceDisabled: Bool = false

    @Published var autoSolveEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSolveEnabled, forKey: Self.enabledKey)
        }
    }

    @Published var minConfidence: Double {
        didSet {
            UserDefaults.standard.set(minConfidence, forKey: Self.minConfidenceKey)
        }
    }

    /// Текущая «эффективная» конфигурация для `CaptchaSolver`. Объединяет
    /// пользовательские настройки с жёсткими лимитами (`maxAttempts = 3`,
    /// `minIntervalMs = 50`).
    var solverConfiguration: CaptchaConfiguration {
        var config = CaptchaConfiguration.default
        config.minConfidence = minConfidence
        return config
    }

    var isEffectivelyEnabled: Bool {
        autoSolveEnabled && !forceDisabled
    }

    private init() {
        let defaults = UserDefaults.standard
        // Дефолт — true (opt-out). Если ключа нет в UserDefaults, читаем
        // registerDefaults с явным true — иначе первая установка покажет
        // «выключено» при `Bool()` от `nil`.
        defaults.register(defaults: [Self.enabledKey: true])
        defaults.register(defaults: [Self.minConfidenceKey: 0.55])
        self.autoSolveEnabled = defaults.bool(forKey: Self.enabledKey)
        self.minConfidence = defaults.double(forKey: Self.minConfidenceKey)
    }
}
