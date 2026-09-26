import XCTest
@testable import SudrfApp

final class CaptchaAssistTests: XCTestCase {
    func testTokenCaptchaKeepsWebViewPath() {
        XCTAssertEqual(
            CaptchaAssistPresentationPath.forKind(.sudrfToken),
            .webView
        )
    }

    func testMagistrateCaptchaUsesNativePath() {
        XCTAssertEqual(
            CaptchaAssistPresentationPath.forKind(.kcaptcha),
            .nativeMagistrate
        )
    }

    func testEmptyMagistrateImageOffersRetry() {
        XCTAssertEqual(
            MagistrateCaptchaLoadDecision.decide(imageData: Data()),
            .retryLoad
        )
    }

    func testNonemptyMagistrateImageStartsPresentation() {
        XCTAssertEqual(
            MagistrateCaptchaLoadDecision.decide(imageData: Data([0x89])),
            .showChallenge
        )
    }

    func testAcceptedMagistrateSubmissionProducesExactVerifiedSample() throws {
        let image = Data([0x89, 0x50, 0x4e, 0x47])
        let formURL = try XCTUnwrap(
            URL(string: "https://pushkinsky.komi.msudrf.ru/kcaptchaForm"))

        let sample = VerifiedMagistrateCaptchaSample.make(
            outcome: .accepted,
            imageData: image,
            code: "дягше",
            formURL: formURL
        )

        XCTAssertEqual(sample?.imageData, image)
        XCTAssertEqual(sample?.code, "дягше")
        XCTAssertEqual(sample?.host, "pushkinsky.komi.msudrf.ru")
    }

    func testRejectedMagistrateSubmissionDoesNotProduceVerifiedSample() throws {
        let formURL = try XCTUnwrap(URL(string: "https://example.msudrf.ru/kcaptchaForm"))

        XCTAssertNil(VerifiedMagistrateCaptchaSample.make(
            outcome: .notAccepted,
            imageData: Data([1]),
            code: "wrong",
            formURL: formURL
        ))
    }

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

    @MainActor
    func testCookieCopyFiltersDomainsAndCompletesOnMainAfterWritesIncludingEmptyBatch() async throws {
        let prefix = "codex-issue-342-\(UUID().uuidString.lowercased())"
        let host = "court.\(UUID().uuidString.lowercased()).example.com"
        let destination = HTTPCookieStorage.shared
        let exactName = "\(prefix)-exact"
        let parentName = "\(prefix)-parent"
        let unrelatedName = "\(prefix)-unrelated"
        defer {
            for cookie in destination.cookies ?? [] where cookie.name.hasPrefix(prefix) {
                destination.deleteCookie(cookie)
            }
        }
        let expectedCookies = [
            try makeCookie(name: exactName, domain: host),
            try makeCookie(name: parentName, domain: ".example.com")
        ]
        let unrelatedCookie = try makeCookie(name: unrelatedName, domain: "elsewhere.test")

        let copyCompleted = expectation(description: "matching cookies copied")
        var copyCompletionCount = 0
        var copyCompletedOnMain = false
        CaptchaWebViewCoordinator.copyCookies(expectedCookies + [unrelatedCookie], host: host) {
            copyCompletionCount += 1
            copyCompletedOnMain = Thread.isMainThread
            XCTAssertEqual(
                Set((destination.cookies ?? []).filter { $0.name.hasPrefix(prefix) }.map(\.name)),
                Set([exactName, parentName])
            )
            copyCompleted.fulfill()
        }
        await fulfillment(of: [copyCompleted], timeout: 2)
        XCTAssertEqual(copyCompletionCount, 1)
        XCTAssertTrue(copyCompletedOnMain)
        let emptyCopyCompleted = expectation(description: "empty cookie batch completes")
        var emptyCompletionCount = 0
        var emptyCompletedOnMain = false
        CaptchaWebViewCoordinator.copyCookies([], host: host) {
            emptyCompletionCount += 1
            emptyCompletedOnMain = Thread.isMainThread
            emptyCopyCompleted.fulfill()
        }
        await fulfillment(of: [emptyCopyCompleted], timeout: 2)
        XCTAssertEqual(emptyCompletionCount, 1)
        XCTAssertTrue(emptyCompletedOnMain)
    }

    private func makeCookie(name: String, domain: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .domain: domain,
            .path: "/",
            .name: name,
            .value: "test-value"
        ]))
    }
}
