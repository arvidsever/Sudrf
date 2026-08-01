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
}

enum CaptchaWebViewSubmitMarkerDecision: Equatable {
    case match
    case ignore
}

enum CaptchaWebViewSubmitMarkerFactory {
    static let windowSeconds: TimeInterval = 5.0

    static func decide(marker: CaptchaWebViewSubmitMarker,
                       actualURL: URL?,
                       now: Date) -> CaptchaWebViewSubmitMarkerDecision {
        guard marker.expectedURL == actualURL else { return .ignore }
        guard now.timeIntervalSince(marker.setAt) <= windowSeconds else { return .ignore }
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
                       isOurActiveAttempt: Bool) -> NavigationFailureDecision {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            return .ignore
        }
        switch state {
        case .ready, .accepted, .failed:
            return .ignore
        case .submitting:
            if isOurActiveAttempt {
                return .failSubmitting(
                    "Не удалось отправить код: \(ns.localizedDescription). Попробуйте ещё раз.")
            }
            return .ignore
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
                       hasSubmittedNavigation: Bool,
                       navigationMatchesSubmitted: Bool) -> CaptchaWebViewDidFinishDecision {
        guard state == .submitting,
              let attempt = submittedAttempt,
              activeID == attempt else { return .skip }
        if hasSubmittedNavigation && !navigationMatchesSubmitted { return .skip }
        return .inspect(attempt: attempt)
    }
}
