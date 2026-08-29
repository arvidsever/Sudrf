import Foundation
import SudrfKit

enum CaptchaSubmissionState: Equatable {
    case loading
    case ready
    case submitting
    case accepted
    case rejected
    case failed(String)

    var isSubmitting: Bool {
        if case .submitting = self { return true }
        return false
    }
}

enum CaptchaImagePayload {
    static func data(fromDataURL value: String) -> Data? {
        CaptchaImageExtractor.data(fromDataURL: value)
    }
}

enum CaptchaAssistPostSubmitDecision: Equatable {
    case accept
    case reject
    case failMissingToken

    static func decide(hasCaptchaMarkers: Bool, hasPendingToken: Bool,
                       requiresToken: Bool = true) -> Self {
        if hasCaptchaMarkers { return .reject }
        if !requiresToken { return .accept }
        return hasPendingToken ? .accept : .failMissingToken
    }
}

/// Безопасное представление URL для локальной диагностики CAPTCHA.
/// Query и fragment намеренно отбрасываются: там могут быть captchaid,
/// captcha и параметры исходного поиска.
struct CaptchaAssistDiagnosticLocation: Equatable {
    let host: String
    let path: String

    init?(url: URL?) {
        guard let url,
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.host = host
        self.path = url.path.isEmpty ? "/" : url.path
    }
}

/// Состояния WebKit-потока, отделённые от `WKWebView` для unit-тестов.
enum CaptchaWebViewState: Equatable {
    case loadingForm
    case ready
    case submitting
    case accepted
    case failed
}

enum CaptchaWebViewSubmitDecision: Equatable {
    case submit
    case skipSameRequestID
    case skipStateNotAllowed
}

enum CaptchaWebViewSubmitDecisionFactory {
    static func decide(state: CaptchaWebViewState,
                       currentRequestID: Int,
                       lastRequestID: Int) -> CaptchaWebViewSubmitDecision {
        switch state {
        case .ready, .failed:
            guard currentRequestID != lastRequestID else { return .skipSameRequestID }
            return .submit
        case .loadingForm, .submitting, .accepted:
            return .skipStateNotAllowed
        }
    }
}

struct CaptchaWebViewAttemptGenerator {
    private(set) var nextID: Int = 0
    private(set) var activeID: Int? = nil

    mutating func start() -> Int {
        nextID += 1
        activeID = nextID
        return nextID
    }

    mutating func finish(activeAttempt: Int) -> Bool {
        guard activeID == activeAttempt else { return false }
        activeID = nil
        return true
    }
}

struct CaptchaWebViewSubmitMarker: Equatable {
    let attempt: Int
    let expectedURL: URL?
    let setAt: Date
    let expectedFragment: String?

    init(attempt: Int, expectedURL: URL?, setAt: Date,
         expectedFragment: String? = nil) {
        self.attempt = attempt
        self.expectedURL = expectedURL
        self.setAt = setAt
        self.expectedFragment = expectedFragment
    }
}

enum CaptchaWebViewSubmitMarkerDecision: Equatable {
    case match
    case ignore
}

enum CaptchaWebViewSubmitMarkerFactory {
    static let windowSeconds: TimeInterval = 5.0
    private static let fragmentPrefix = "sudrf-captcha-attempt-"

    static func fragment(for attempt: Int) -> String {
        fragmentPrefix + String(attempt)
    }

    static func attempt(from url: URL?) -> Int? {
        guard let fragment = url?.fragment,
              fragment.hasPrefix(fragmentPrefix),
              let attempt = Int(fragment.dropFirst(fragmentPrefix.count)),
              attempt > 0 else { return nil }
        return attempt
    }

    static func decide(marker: CaptchaWebViewSubmitMarker,
                       actualURL: URL?,
                       now: Date) -> CaptchaWebViewSubmitMarkerDecision {
        guard now.timeIntervalSince(marker.setAt) <= windowSeconds else { return .ignore }
        if let expectedFragment = marker.expectedFragment {
            guard actualURL?.fragment == expectedFragment else { return .ignore }
        } else {
            guard marker.expectedURL == actualURL else { return .ignore }
        }
        return .match
    }
}

enum NavigationFailureDecision: Equatable {
    case ignore
    case failLoadingForm(String)
    case failSubmitting(String)
}

enum CaptchaWebViewNavigationFailureFactory {
    static func decide(state: CaptchaWebViewState,
                       error: Error,
                       submittedAttempt: Int?,
                       activeID: Int?,
                       navigationAttempt: Int?,
                       hasSubmittedNavigation: Bool,
                       navigationMatchesSubmitted: Bool) -> NavigationFailureDecision {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            return .ignore
        }
        switch state {
        case .ready, .accepted, .failed:
            return .ignore
        case .submitting:
            guard let submittedAttempt, activeID == submittedAttempt else { return .ignore }
            // A navigation that started under an older submit must not be
            // attributed to the current retry. Nil means WebKit delivered no
            // didStart callback, so the current attempt is the only fallback.
            if let navigationAttempt, navigationAttempt != submittedAttempt {
                return .ignore
            }
            // JS-submit часто не проходит через navigationAction, поэтому
            // marker может отсутствовать. Если он есть, принимаем только
            // точно совпавшую WKNavigation.
            guard !hasSubmittedNavigation || navigationMatchesSubmitted else { return .ignore }
            return .failSubmitting(
                "Не удалось отправить код: \(ns.localizedDescription). Попробуйте ещё раз.")
        case .loadingForm:
            return .failLoadingForm(
                "Не удалось загрузить форму суда: \(ns.localizedDescription). Обновите окно.")
        }
    }
}

enum CaptchaWebViewDidFinishDecision: Equatable {
    case inspect(attempt: Int)
    case skip
}

enum CaptchaWebViewDidFinishDecisionFactory {
    static func decide(state: CaptchaWebViewState,
                       submittedAttempt: Int?,
                       activeID: Int?,
                       navigationAttempt: Int?,
                       hasSubmittedNavigation: Bool,
                       navigationMatchesSubmitted: Bool) -> CaptchaWebViewDidFinishDecision {
        guard state == .submitting,
              let attempt = submittedAttempt,
              activeID == attempt else { return .skip }
        // A late callback from a navigation started by an older submit must
        // not inspect or complete the current retry. Nil is the explicit
        // fallback for WebKit callbacks with no didStart event.
        if let navigationAttempt, navigationAttempt != attempt { return .skip }
        if hasSubmittedNavigation && !navigationMatchesSubmitted { return .skip }
        return .inspect(attempt: attempt)
    }
}
