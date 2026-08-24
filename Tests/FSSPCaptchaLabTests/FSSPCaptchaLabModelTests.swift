import Foundation
import XCTest
import CaptchaSolver
import SudrfKit
@testable import FSSPCaptchaLab

@MainActor
final class FSSPCaptchaLabModelTests: XCTestCase {
    func testManualAcceptedResponseSavesPairAndLoadsFreshChallenge() async {
        let harness = Harness()
        harness.discoverSteps = [.captchaRequired(challenge("first")), .captchaRequired(challenge("next"))]
        harness.submitSteps = [.found(EnforcementLookup(state: .found))]
        let model = FSSPCaptchaLabModel(dependencies: harness.dependencies())
        XCTAssertEqual(model.documentID, "ФС 038169867")

        await model.start()
        await model.submitManual(code: "12345")

        XCTAssertEqual(harness.savedCodes, ["12345"])
        XCTAssertEqual(model.manualAcceptedCount, 1)
        XCTAssertEqual(model.automaticAcceptedCount, 0)
        XCTAssertEqual(model.corpusCount, 1)
        XCTAssertEqual(model.challenge?.codeID, "next")
        XCTAssertEqual(model.state, .awaitingManualInput)
    }

    func testRejectedAndErrorResponsesNeverSavePair() async {
        let rejected = Harness()
        rejected.discoverSteps = [.captchaRequired(challenge("first"))]
        rejected.submitSteps = [.captchaRequired(challenge("replacement"))]
        let rejectedModel = FSSPCaptchaLabModel(dependencies: rejected.dependencies())

        await rejectedModel.start()
        await rejectedModel.submitManual(code: "12345")

        XCTAssertTrue(rejected.savedCodes.isEmpty)
        XCTAssertEqual(rejectedModel.rejectedCount, 1)
        XCTAssertEqual(rejectedModel.challenge?.codeID, "replacement")

        let failed = Harness()
        failed.discoverSteps = [.captchaRequired(challenge("error"))]
        failed.submitSteps = [.error("network")]
        let failedModel = FSSPCaptchaLabModel(dependencies: failed.dependencies())

        await failedModel.start()
        await failedModel.submitManual(code: "12345")

        XCTAssertTrue(failed.savedCodes.isEmpty)
        XCTAssertEqual(failedModel.state, .loading)
        XCTAssertTrue(failedModel.message.contains("Повторяем запрос автоматически"))
        failedModel.stop()
    }

    func testNotFoundAndAmbiguousResponsesAreConfirmedCorpusPairs() async {
        for step in [
            FSSPSearchStep.notFound(EnforcementLookup(state: .notFound)),
            FSSPSearchStep.ambiguous(EnforcementLookup(state: .ambiguous))
        ] {
            let harness = Harness()
            harness.discoverSteps = [.captchaRequired(challenge(UUID().uuidString)), .error("done")]
            harness.submitSteps = [step]
            let model = FSSPCaptchaLabModel(dependencies: harness.dependencies())

            await model.start()
            await model.submitManual(code: "12345")

            XCTAssertEqual(harness.savedCodes, ["12345"])
            XCTAssertEqual(model.manualAcceptedCount, 1)
        }
    }

    func testModelAutomaticallySubmitsEvenWithZeroConfidence() async {
        let automatic = Harness()
        automatic.recognition = CaptchaAttempt(value: "70120", confidence: 0, duration: 0)
        automatic.discoverSteps = [.captchaRequired(challenge("auto")), .error("done")]
        automatic.submitSteps = [.found(EnforcementLookup(state: .found))]
        let automaticModel = FSSPCaptchaLabModel(dependencies: automatic.dependencies())

        await automaticModel.start()

        XCTAssertEqual(automatic.submittedCodes, ["70120"])
        XCTAssertEqual(automaticModel.automaticAcceptedCount, 1)
        XCTAssertEqual(automaticModel.manualAcceptedCount, 0)
        automaticModel.stop()
    }

    func testAutomaticRejectionsKeepTryingFreshChallengesUntilAccepted() async {
        let harness = Harness()
        harness.recognition = CaptchaAttempt(value: "12345", confidence: 0, duration: 0)
        harness.discoverSteps = [.captchaRequired(challenge("c0"))]
        harness.submitSteps = [
            .captchaRequired(challenge("c1")),
            .captchaRequired(challenge("c2")),
            .captchaRequired(challenge("c3")),
            .captchaRequired(challenge("c4")),
            .found(EnforcementLookup(state: .found))
        ]
        let model = FSSPCaptchaLabModel(dependencies: harness.dependencies())

        await model.start()
        await waitUntil { model.automaticAcceptedCount == 1 }

        XCTAssertEqual(harness.submittedCodes, Array(repeating: "12345", count: 5))
        XCTAssertEqual(model.rejectedCount, 4)
        XCTAssertEqual(model.automaticAcceptedCount, 1)
        XCTAssertEqual(harness.savedCodes, ["12345"])
        model.stop()
    }

    func testNetworkErrorAutomaticallyStartsFreshAttempt() async {
        let harness = Harness()
        harness.recognition = CaptchaAttempt(value: "54321", confidence: 0, duration: 0)
        harness.discoverSteps = [
            .error("network"),
            .captchaRequired(challenge("recovered"))
        ]
        harness.submitSteps = [.error("stop")]
        let model = FSSPCaptchaLabModel(dependencies: harness.dependencies())

        await model.start()
        await waitUntil { harness.submittedCodes == ["54321"] }

        XCTAssertEqual(harness.submittedCodes, ["54321"])
        XCTAssertTrue(harness.savedCodes.isEmpty)
        model.stop()
    }

    func testTrainingStartsAt200AndThenAtEachHundredNewUniquePairs() async {
        let initial = Harness()
        initial.corpus = 200
        initial.trainingResults = [.succeeded("initial training")]
        initial.afterTraining = { initial.reportedCorpusCount = 200 }
        initial.discoverSteps = [.captchaRequired(challenge("after-training"))]
        let initialModel = FSSPCaptchaLabModel(dependencies: initial.dependencies())

        await initialModel.start()

        XCTAssertEqual(initial.trainingCalls, 1)
        XCTAssertEqual(initial.markedTrainedCounts, [200])
        XCTAssertEqual(initialModel.challenge?.codeID, "after-training")

        let retrain = Harness()
        retrain.corpus = 299
        retrain.reportedCorpusCount = 200
        retrain.discoverSteps = [.captchaRequired(challenge("before")), .captchaRequired(challenge("after"))]
        retrain.submitSteps = [.found(EnforcementLookup(state: .found))]
        retrain.trainingResults = [.succeeded("retraining")]
        retrain.afterTraining = { retrain.reportedCorpusCount = 300 }
        let retrainModel = FSSPCaptchaLabModel(dependencies: retrain.dependencies())

        await retrainModel.start()
        await retrainModel.submitManual(code: "12345")

        XCTAssertEqual(retrain.trainingCalls, 1)
        XCTAssertEqual(retrain.markedTrainedCounts, [300])
        XCTAssertEqual(retrainModel.challenge?.codeID, "after")
    }

    func testRetrainingRealignsToHundredsAfterLateTraining() async {
        let harness = Harness()
        harness.corpus = 400
        harness.reportedCorpusCount = 308
        harness.trainingResults = [.succeeded("realigned training")]
        harness.afterTraining = { harness.reportedCorpusCount = 400 }
        harness.discoverSteps = [.captchaRequired(challenge("after-training"))]
        let model = FSSPCaptchaLabModel(dependencies: harness.dependencies())

        await model.start()

        XCTAssertEqual(harness.trainingCalls, 1)
        XCTAssertEqual(harness.markedTrainedCounts, [400])
        XCTAssertEqual(model.challenge?.codeID, "after-training")
    }

    func testFailedTrainingDoesNotLoopAtTheSameCorpusCount() async {
        let harness = Harness()
        harness.corpus = 200
        harness.trainingResults = [.failed("trainer failed")]
        harness.discoverSteps = [
            .captchaRequired(challenge("manual")),
            .captchaRequired(challenge("next"))
        ]
        harness.submitSteps = [.found(EnforcementLookup(state: .found))]
        harness.saveAdvancesCorpus = false
        let model = FSSPCaptchaLabModel(dependencies: harness.dependencies())

        await model.start()
        XCTAssertEqual(model.state, .trainingFailed)
        XCTAssertEqual(harness.trainingCalls, 1)

        await model.continueAfterTrainingFailure()
        await model.submitManual(code: "12345")

        XCTAssertEqual(harness.trainingCalls, 1)
        XCTAssertEqual(model.challenge?.codeID, "next")
    }

    func testStopInvalidatesTheCurrentChallengeUntilRestarted() async {
        let harness = Harness()
        harness.discoverSteps = [.captchaRequired(challenge("first")), .captchaRequired(challenge("second"))]
        let model = FSSPCaptchaLabModel(dependencies: harness.dependencies())

        await model.start()
        model.stop()
        await model.start()

        XCTAssertEqual(model.state, .awaitingManualInput)
        XCTAssertEqual(model.challenge?.codeID, "second")
    }

    private func challenge(_ codeID: String) -> FSSPCaptchaChallenge {
        FSSPCaptchaChallenge(
            courtDocumentID: "court-document",
            codeID: codeID,
            imagePNG: Data([1, 2, 3]),
            requestURL: URL(string: "https://is-go.fssp.gov.ru/ajax_search?code_id=\(codeID)")!)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
    }
}

@MainActor
private final class Harness {
    var corpus = 0
    var reportedCorpusCount: Int?
    var recognition: CaptchaAttempt?
    var discoverSteps: [FSSPSearchStep] = []
    var submitSteps: [FSSPSearchStep] = []
    var trainingResults: [FSSPCaptchaLabTrainingResult] = []
    var savedCodes: [String] = []
    var submittedCodes: [String] = []
    var markedTrainedCounts: [Int] = []
    var trainingCalls = 0
    var saveAdvancesCorpus = true
    var afterTraining: (() -> Void)?

    func dependencies() -> FSSPCaptchaLabDependencies {
        .init(
            trainingRoot: URL(fileURLWithPath: "/tmp/fssp-captcha-lab-tests", isDirectory: true),
            discover: { _ in self.next(&self.discoverSteps, fallback: .error("unexpected discover")) },
            submit: { code, _, _ in
                self.submittedCodes.append(code)
                return self.next(&self.submitSteps, fallback: .error("unexpected submit"))
            },
            saveConfirmedPair: { _, code in
                self.savedCodes.append(code)
                if self.saveAdvancesCorpus { self.corpus += 1 }
                return true
            },
            corpusCount: { self.corpus },
            markTrained: { self.markedTrainedCounts.append($0) },
            loadModel: {
                .init(
                    status: self.reportedCorpusCount == nil ? "no model" : "bootstrap model",
                    trainedCorpusCount: self.reportedCorpusCount,
                    recognize: { _ in self.recognition })
            },
            train: { _ in
                self.trainingCalls += 1
                self.afterTraining?()
                return self.next(&self.trainingResults, fallback: .failed("unexpected training"))
            }
        )
    }

    private func next<T>(_ values: inout [T], fallback: @autoclosure () -> T) -> T {
        values.isEmpty ? fallback() : values.removeFirst()
    }
}
