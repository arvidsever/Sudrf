import Foundation

enum AppIdentity {
    static let debugBundleIdentifier = "ru.sudrf.app.debug"

    static func isDebug(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        bundleIdentifier == debugBundleIdentifier
    }

    static func urlScheme(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        isDebug(bundleIdentifier: bundleIdentifier) ? "sudrf-debug" : "sudrf"
    }

    static func keychainService(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        isDebug(bundleIdentifier: bundleIdentifier)
            ? "ru.sudrf.app.debug.ai-provider-key"
            : "ru.sudrf.app.ai-provider-key"
    }

    static var loggingSubsystem: String {
        Bundle.main.bundleIdentifier ?? "ru.sudrf.app"
    }
}
