import XCTest
@testable import SudrfApp

/// A15: state-machine submit-решений + навигационный fail classification
/// + монотонный attempt-generator + best-effort URL+window marker matcher.
final class CaptchaSheetStateTests: XCTestCase {

    // MARK: - CaptchaWebViewSubmitDecisionFactory (7 unit-тестов)

    func testDecideSubmitReadyAllows() {
        let d = CaptchaWebViewSubmitDecisionFactory.decide(
            state: .ready, currentRequestID: 5, lastRequestID: 4)
        XCTAssertEqual(d, .submit)
    }

    func testDecideSubmitFailedAllowsRetry() {
        // A15: главный сценарий — retry из .failed.
        let d = CaptchaWebViewSubmitDecisionFactory.decide(
            state: .failed, currentRequestID: 5, lastRequestID: 4)
        XCTAssertEqual(d, .submit)
    }

    func testDecideSubmitLoadingFormSkipped() {
        let d = CaptchaWebViewSubmitDecisionFactory.decide(
            state: .loadingForm, currentRequestID: 5, lastRequestID: 4)
        XCTAssertEqual(d, .skipStateNotAllowed)
    }

    func testDecideSubmitSubmittingSkipped() {
        // UI блокирует submit в .submitting, decision — тоже.
        let d = CaptchaWebViewSubmitDecisionFactory.decide(
            state: .submitting, currentRequestID: 5, lastRequestID: 4)
        XCTAssertEqual(d, .skipStateNotAllowed)
    }

    func testDecideSubmitAcceptedSkipped() {
        let d = CaptchaWebViewSubmitDecisionFactory.decide(
            state: .accepted, currentRequestID: 5, lastRequestID: 4)
        XCTAssertEqual(d, .skipStateNotAllowed)
    }

    func testDecideSubmitSameRequestIDSkipped() {
        // Защита от двойной отправки одного события.
        let d = CaptchaWebViewSubmitDecisionFactory.decide(
            state: .ready, currentRequestID: 4, lastRequestID: 4)
        XCTAssertEqual(d, .skipSameRequestID)
    }

    func testDecideSubmitStateCheckedBeforeRequestID() {
        // state .loadingForm + новый requestID → всё равно skip.
        let d = CaptchaWebViewSubmitDecisionFactory.decide(
            state: .loadingForm, currentRequestID: 5, lastRequestID: 4)
        XCTAssertEqual(d, .skipStateNotAllowed)
    }

    // MARK: - CaptchaWebViewNavigationFailureFactory (7 unit-тестов)

    private let cancelledError = NSError(
        domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    private let genericError = NSError(
        domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

    func testNavFailureCancelledIgnored() {
        // Замечание 5: NSURLErrorCancelled — не наш кейс.
        let d = CaptchaWebViewNavigationFailureFactory.decide(
            state: .submitting, error: cancelledError, isOurActiveAttempt: true)
        XCTAssertEqual(d, .ignore)
    }

    func testNavFailureReadyIgnored() {
        // background-ресурс не должен морозить готовый лист.
        let d = CaptchaWebViewNavigationFailureFactory.decide(
            state: .ready, error: genericError, isOurActiveAttempt: false)
        XCTAssertEqual(d, .ignore)
    }

    func testNavFailureAcceptedIgnored() {
        // submit прошёл, токен получен; background-навигация может упасть.
        let d = CaptchaWebViewNavigationFailureFactory.decide(
            state: .accepted, error: genericError, isOurActiveAttempt: false)
        XCTAssertEqual(d, .ignore)
    }

    func testNavFailureFailedIgnored() {
        // уже-failed; не дублируем.
        let d = CaptchaWebViewNavigationFailureFactory.decide(
            state: .failed, error: genericError, isOurActiveAttempt: false)
        XCTAssertEqual(d, .ignore)
    }

    func testNavFailureSubmittingOursFails() {
        // Замечание 1+5: наш submit упал → fail.
        let d = CaptchaWebViewNavigationFailureFactory.decide(
            state: .submitting, error: genericError, isOurActiveAttempt: true)
        if case .failSubmitting(let msg) = d {
            XCTAssertTrue(msg.contains("Не удалось отправить код"))
        } else {
            XCTFail("expected .failSubmitting, got \(d)")
        }
    }

    func testNavFailureSubmittingNotOursIgnored() {
        // Замечание 1: submit #1 упал, но submit #2 уже активен → ignore.
        let d = CaptchaWebViewNavigationFailureFactory.decide(
            state: .submitting, error: genericError, isOurActiveAttempt: false)
        XCTAssertEqual(d, .ignore)
    }

    func testNavFailureLoadingFormFails() {
        let d = CaptchaWebViewNavigationFailureFactory.decide(
            state: .loadingForm, error: genericError, isOurActiveAttempt: false)
        if case .failLoadingForm(let msg) = d {
            XCTAssertTrue(msg.contains("Не удалось загрузить форму"))
        } else {
            XCTFail("expected .failLoadingForm, got \(d)")
        }
    }

    // MARK: - CaptchaWebViewAttemptGenerator (1 unit-тест, реальный сценарий)

    func testAttemptGeneratorFinishRealScenario() {
        // Сценарий: после retry первый attempt ID не должен инвалидировать второй.
        // Защита от прежней watchdog-гонки (v3: (activeSubmitAttempt ?? 0) + 1).
        var g = CaptchaWebViewAttemptGenerator()
        let first = g.start()
        XCTAssertTrue(g.finish(activeAttempt: first))
        let second = g.start()
        XCTAssertFalse(g.finish(activeAttempt: first),
                       "старый attempt не должен инвалидировать новый")
        XCTAssertEqual(g.activeID, second,
                       "activeID сохраняется после неудачного finish")
        XCTAssertTrue(g.finish(activeAttempt: second))
        XCTAssertNil(g.activeID)
    }

    // MARK: - CaptchaWebViewSubmitMarkerFactory (3 unit-теста, URL+window matcher)

    private let submitURL = URL(string: "https://sudrf.ru/modules.php?name=sud_delo&name_op=case")!

    func testSubmitMarkerMatchWithinWindow() {
        // URL совпал + timestamp в окне 5 сек → match.
        let now = Date()
        let marker = CaptchaWebViewSubmitMarker(
            attempt: 1, expectedURL: submitURL, setAt: now)
        let d = CaptchaWebViewSubmitMarkerFactory.decide(
            marker: marker, actualURL: submitURL, now: now)
        XCTAssertEqual(d, .match)
    }

    func testSubmitMarkerMismatchOnURL() {
        // URL не совпал → ignore.
        let now = Date()
        let marker = CaptchaWebViewSubmitMarker(
            attempt: 1, expectedURL: submitURL, setAt: now)
        let otherURL = URL(string: "https://sudrf.ru/other")!
        let d = CaptchaWebViewSubmitMarkerFactory.decide(
            marker: marker, actualURL: otherURL, now: now)
        XCTAssertEqual(d, .ignore)
    }

    func testSubmitMarkerExpired() {
        // URL совпал, но timestamp старше 5 сек → ignore.
        let now = Date()
        let expired = now.addingTimeInterval(-6.0)
        let marker = CaptchaWebViewSubmitMarker(
            attempt: 1, expectedURL: submitURL, setAt: expired)
        let d = CaptchaWebViewSubmitMarkerFactory.decide(
            marker: marker, actualURL: submitURL, now: now)
        XCTAssertEqual(d, .ignore)
    }
}
