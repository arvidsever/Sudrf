import Foundation
import XCTest
import CaptchaSolver
import SudrfKit
@testable import SudrfApp

@MainActor
final class FSSPAutoCaptchaSolverTests: XCTestCase {
    func testDisabledSettingKeepsSingleManualChallenge() async {
        var discoveries = 0
        var recognitions = 0
        var submissions = 0

        let result = await solve(
            enabled: false,
            discover: {
                discoveries += 1
                return .captchaRequired(self.challenge("manual"))
            },
            submit: { _, _ in submissions += 1; return self.found() },
            recognize: { _ in recognitions += 1; return self.attempt("12345", 1) })

        XCTAssertCaptcha(result, codeID: "manual")
        XCTAssertEqual(discoveries, 1)
        XCTAssertEqual(recognitions, 0)
        XCTAssertEqual(submissions, 0)
    }

    func testLowConfidenceNeverSubmitsAndUsesFreshChallengeEachAttempt() async {
        var next = 0
        var seen: [String] = []
        var submissions = 0

        let result = await solve(
            discover: {
                next += 1
                return .captchaRequired(self.challenge("low-\(next)"))
            },
            submit: { _, _ in submissions += 1; return self.found() },
            recognize: { challenge in
                seen.append(challenge.codeID)
                return self.attempt("12345", 0.89)
            })

        XCTAssertCaptcha(result, codeID: "low-3")
        XCTAssertEqual(seen, ["low-1", "low-2", "low-3"])
        XCTAssertEqual(submissions, 0)
    }

    func testSuccessfulHighConfidenceAnswerIsSubmitted() async {
        var submitted: [String] = []
        let result = await solve(
            discover: { .captchaRequired(self.challenge("success")) },
            submit: { code, _ in submitted.append(code); return self.found() },
            recognize: { _ in self.attempt("70120", 0.97) })

        guard case .found = result else { return XCTFail("Expected found") }
        XCTAssertEqual(submitted, ["70120"])
    }

    func testRejectedAnswerUsesReplacementChallenge() async {
        var recognized: [String] = []
        var submitted: [String] = []
        let result = await solve(
            discover: { .captchaRequired(self.challenge("first")) },
            submit: { code, challenge in
                submitted.append("\(challenge.codeID):\(code)")
                return challenge.codeID == "first"
                    ? .captchaRequired(self.challenge("replacement"))
                    : self.found()
            },
            recognize: { challenge in
                recognized.append(challenge.codeID)
                return self.attempt(challenge.codeID == "first" ? "11111" : "22222", 0.99)
            })

        guard case .found = result else { return XCTFail("Expected found") }
        XCTAssertEqual(recognized, ["first", "replacement"])
        XCTAssertEqual(submitted, ["first:11111", "replacement:22222"])
    }

    func testThreeRejectedAnswersFallBackToFreshManualChallenge() async {
        var calls = 0
        let result = await solve(
            discover: { .captchaRequired(self.challenge("c0")) },
            submit: { _, challenge in
                calls += 1
                return .captchaRequired(self.challenge("c\(calls)"))
            },
            recognize: { _ in self.attempt("12345", 0.99) })

        XCTAssertCaptcha(result, codeID: "c3")
        XCTAssertEqual(calls, 3)
    }

    func testUserThresholdAboveFloorIsRespected() async {
        var submissions = 0
        let result = await FSSPAutoCaptchaSolver.solve(
            enabled: true,
            settings: .init(maxAttempts: 1, minConfidence: 0.95),
            discover: { .captchaRequired(self.challenge("strict")) },
            submit: { _, _ in submissions += 1; return self.found() },
            recognize: { _ in self.attempt("12345", 0.94) })

        XCTAssertCaptcha(result, codeID: "strict")
        XCTAssertEqual(submissions, 0)
    }

    func testRecognitionFailurePreservesLastChallengeForManualEntry() async {
        var discoveries = 0
        let result = await FSSPAutoCaptchaSolver.solve(
            enabled: true,
            settings: .init(maxAttempts: 1, minConfidence: 0.90),
            discover: {
                discoveries += 1
                return .captchaRequired(self.challenge("recoverable"))
            },
            submit: { _, _ in self.found() },
            recognize: { _ in throw RecognitionError.failed })

        XCTAssertCaptcha(result, codeID: "recoverable")
        XCTAssertEqual(discoveries, 1)
    }

    private func solve(
        enabled: Bool = true,
        discover: @escaping () async throws -> FSSPSearchStep,
        submit: @escaping (String, FSSPCaptchaChallenge) async throws -> FSSPSearchStep,
        recognize: @escaping (FSSPCaptchaChallenge) async throws -> CaptchaAttempt
    ) async -> FSSPSearchStep {
        await FSSPAutoCaptchaSolver.solve(
            enabled: enabled,
            settings: .init(maxAttempts: 3, minConfidence: 0.55),
            discover: discover,
            submit: submit,
            recognize: recognize)
    }

    private func challenge(_ codeID: String) -> FSSPCaptchaChallenge {
        FSSPCaptchaChallenge(
            courtDocumentID: "document",
            codeID: codeID,
            imagePNG: Data([1]),
            requestURL: URL(string: "https://is-go.fssp.gov.ru/ajax_search?code_id=\(codeID)")!)
    }

    private func attempt(_ value: String, _ confidence: Double) -> CaptchaAttempt {
        CaptchaAttempt(value: value, confidence: confidence, duration: 0)
    }

    private func found() -> FSSPSearchStep {
        .found(EnforcementLookup(
            state: .found,
            record: EnforcementRecord(
                courtDocumentID: "document", source: .bailiffs,
                discoveryState: .found, status: "")))
    }

    private func XCTAssertCaptcha(_ step: FSSPSearchStep,
                                  codeID: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        guard case .captchaRequired(let challenge) = step else {
            return XCTFail("Expected manual CAPTCHA, got \(step)", file: file, line: line)
        }
        XCTAssertEqual(challenge.codeID, codeID, file: file, line: line)
    }
}

private enum RecognitionError: Error {
    case failed
}
