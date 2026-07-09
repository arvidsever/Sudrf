import XCTest
@testable import SudrfApp

final class CaptchaAssistTests: XCTestCase {
    func testPostSubmitAcceptsPendingTokenWhenCaptchaIsGone() {
        XCTAssertEqual(
            CaptchaAssistPostSubmitDecision.decide(hasCaptchaMarkers: false, hasPendingToken: true),
            .accept
        )
    }

    func testPostSubmitRejectsWhenCaptchaRemains() {
        XCTAssertEqual(
            CaptchaAssistPostSubmitDecision.decide(hasCaptchaMarkers: true, hasPendingToken: true),
            .reject
        )
    }

    func testPostSubmitFailsWhenCaptchaIsGoneButTokenMissing() {
        XCTAssertEqual(
            CaptchaAssistPostSubmitDecision.decide(hasCaptchaMarkers: false, hasPendingToken: false),
            .failMissingToken
        )
    }

    func testDecodesBase64ImagePayload() {
        let source = Data([0x89, 0x50, 0x4E, 0x47])
        let payload = "data:image/png;base64," + source.base64EncodedString()

        XCTAssertEqual(CaptchaImagePayload.data(fromDataURL: payload), source)
    }

    func testDecodesPercentEncodedTextPayload() {
        let payload = "data:text/plain,%36%38%39%35%38"

        XCTAssertEqual(CaptchaImagePayload.data(fromDataURL: payload), Data("68958".utf8))
    }

    func testRejectsNonDataPayload() {
        XCTAssertNil(CaptchaImagePayload.data(fromDataURL: "https://example.test/captcha.png"))
    }
}
