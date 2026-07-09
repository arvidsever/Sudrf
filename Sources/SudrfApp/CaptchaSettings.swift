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
    private static let preprocessorEnabledKey = "captcha.preprocessorEnabled"
    private static let preprocessorHostsKey = "captcha.preprocessorHosts"

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

    /// Глобальный флаг предобработки. По умолчанию выключен —
    /// предобработка на captcha sudrf без искажений РЕГРЕССИРУЕТ
    /// (Vision читает «667» как «49»). Включайте только если у вас
    /// есть конкретные хосты с rotated/struck-through captcha, где
    /// Vision возвращает conf=0.00 на сырых данных.
    @Published var preprocessorEnabled: Bool {
        didSet {
            UserDefaults.standard.set(preprocessorEnabled, forKey: Self.preprocessorEnabledKey)
        }
    }

    /// Хосты, на которых применяется предобработка. Активно только
    /// если `preprocessorEnabled = true`. По умолчанию пусто —
    /// пользователь добавляет хосты, на которых Vision не справляется
    /// без preprocess.
    @Published var preprocessorHosts: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(preprocessorHosts), forKey: Self.preprocessorHostsKey)
        }
    }

    /// Текущая «эффективная» конфигурация для `CaptchaSolver`. Объединяет
    /// пользовательские настройки с жёсткими лимитами (`maxAttempts = 3`,
    /// `minIntervalMs = 50`).
    var solverConfiguration: CaptchaConfiguration {
        var config = CaptchaConfiguration.default
        config.minConfidence = minConfidence
        config.preprocessingEnabled = preprocessorEnabled
        config.preprocessorHosts = preprocessorHosts
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
        // Preprocessor: выключен по умолчанию (см. solverConfiguration).
        defaults.register(defaults: [Self.preprocessorEnabledKey: false])
        defaults.register(defaults: [Self.preprocessorHostsKey: [String]()])
        self.autoSolveEnabled = defaults.bool(forKey: Self.enabledKey)
        self.minConfidence = defaults.double(forKey: Self.minConfidenceKey)
        self.preprocessorEnabled = defaults.bool(forKey: Self.preprocessorEnabledKey)
        let hosts = defaults.stringArray(forKey: Self.preprocessorHostsKey) ?? []
        self.preprocessorHosts = Set(hosts)
    }
}
