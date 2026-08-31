import Foundation

/// A CAPTCHA challenge from a `*.msudrf.ru` session.
///
/// The image is safe to hand to a presentation layer.  The submission state
/// is deliberately private: it contains the exact form action and hidden
/// controls from the response that created this challenge and must only be
/// consumed by the `SudrfClient` that loaded it.
public struct MagistrateCaptchaChallenge: Sendable {
    public let imageData: Data

    // Internal only: callers can carry the value back to `SudrfClient`, but
    // cannot construct or alter the protocol state.
    let submissionState: SubmissionState

    init(imageData: Data, submissionState: SubmissionState) {
        self.imageData = imageData
        self.submissionState = submissionState
    }

    struct SubmissionState: Sendable {
        let actionURL: URL
        let hiddenFields: [Field]
    }

    struct Field: Sendable {
        let name: String
        let value: String
    }
}

/// Result of sending a code to a magistrate-court CAPTCHA session.
public enum MagistrateCaptchaSubmission: Sendable {
    case accepted
    case rejected(MagistrateCaptchaChallenge)
}
