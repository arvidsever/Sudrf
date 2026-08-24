import Combine
import Foundation
import CaptchaSolver
import SudrfKit

/// Small, injectable description of the locally trained bootstrap model.
/// The executable owns its discovery path, so production model discovery can
/// never accidentally see the bootstrap artifact.
@MainActor
struct FSSPCaptchaLabModelProvider {
    var status: String
    /// Corpus size recorded by the model report. `nil` means there is no
    /// usable model/report pair and the initial 200-image training is due.
    var trainedCorpusCount: Int?
    var recognize: @MainActor (FSSPCaptchaChallenge) async -> CaptchaAttempt?
}

enum FSSPCaptchaLabTrainingResult: Equatable, Sendable {
    case succeeded(String)
    case failed(String)
}

/// The network, corpus and process boundaries are closures so the state
/// machine is deterministic in tests. The live initializer below still uses
/// the existing FSSPClient, CorpusStore and CoreML strategy.
@MainActor
struct FSSPCaptchaLabDependencies {
    var trainingRoot: URL
    var discover: @MainActor (String) async -> FSSPSearchStep
    var submit: @MainActor (String, FSSPCaptchaChallenge, String) async -> FSSPSearchStep
    var saveConfirmedPair: @MainActor (Data, String) async -> Bool
    var corpusCount: @MainActor () async -> Int
    var markTrained: @MainActor (Int) async -> Void
    var loadModel: @MainActor () -> FSSPCaptchaLabModelProvider
    var train: @MainActor (URL) async -> FSSPCaptchaLabTrainingResult
    var waitBeforeRetry: @MainActor () async -> Bool
}

@MainActor
final class FSSPCaptchaLabModel: ObservableObject {
    static let defaultDocumentID = "ФС 038169867"
    static let firstTrainingCount = 200
    static let retrainingIncrement = 100
    private static let trainingRetryDelay: Duration = .seconds(30)

    enum State: Equatable {
        case idle
        case loading
        case recognizing
        case awaitingManualInput
        case submitting
        case retryWaiting
        case training
        case trainingFailed
        case error
    }

    private enum SubmissionSource: Equatable {
        case manual
        case automatic
    }

    @Published var documentID: String
    @Published private(set) var state: State = .idle
    @Published private(set) var challenge: FSSPCaptchaChallenge?
    @Published private(set) var suggestedCode: String?
    @Published private(set) var suggestionConfidence: Double?
    @Published private(set) var corpusCount = 0
    @Published private(set) var manualAcceptedCount = 0
    @Published private(set) var automaticAcceptedCount = 0
    @Published private(set) var submittedCount = 0
    @Published private(set) var rejectedCount = 0
    @Published private(set) var errorCount = 0
    @Published private(set) var lastSubmittedCode: String?
    @Published private(set) var lastOutcome = ""
    @Published private(set) var modelStatus: String
    @Published private(set) var message = ""
    @Published private(set) var trainingLog = "Обучение ещё не запускалось."

    private let dependencies: FSSPCaptchaLabDependencies
    private var modelProvider: FSSPCaptchaLabModelProvider
    private var activeDocumentID: String?
    private var failedTrainingAtCorpusCount: Int?
    private var generation = 0

    init(dependencies: FSSPCaptchaLabDependencies,
         documentID: String = FSSPCaptchaLabModel.defaultDocumentID) {
        self.dependencies = dependencies
        self.documentID = documentID
        self.modelProvider = dependencies.loadModel()
        self.modelStatus = modelProvider.status
    }

    var canSubmitManually: Bool {
        state == .awaitingManualInput && challenge != nil
    }

    var isBusy: Bool {
        state == .loading || state == .recognizing || state == .submitting
            || state == .retryWaiting || state == .training
    }

    func start() async {
        guard !isBusy else { return }
        generation += 1
        let currentGeneration = generation
        state = .loading
        message = ""
        await refreshCorpusAndModel()
        guard isCurrent(currentGeneration) else { return }
        if trainingIsDue(for: corpusCount) {
            await runTraining(at: corpusCount, generation: currentGeneration)
        } else {
            await requestFreshChallenge(generation: currentGeneration)
        }
    }

    func stop() {
        generation += 1
        state = .idle
        self.challenge = nil
        suggestedCode = nil
        suggestionConfidence = nil
        activeDocumentID = nil
        message = "Сбор остановлен."
    }

    func submitManual(code: String) async {
        await submit(code: code, source: .manual)
    }

    func retryTraining() async {
        guard state == .trainingFailed else { return }
        failedTrainingAtCorpusCount = nil
        generation += 1
        let currentGeneration = generation
        state = .loading
        await refreshCorpusAndModel()
        guard isCurrent(currentGeneration) else { return }
        await runTraining(at: corpusCount, generation: currentGeneration)
    }

    func continueAfterTrainingFailure() async {
        guard state == .trainingFailed else { return }
        generation += 1
        await requestFreshChallenge(generation: generation)
    }

    private func refreshCorpusAndModel() async {
        corpusCount = await dependencies.corpusCount()
        modelProvider = dependencies.loadModel()
        modelStatus = modelProvider.status
    }

    private func requestFreshChallenge(generation currentGeneration: Int) async {
        guard isCurrent(currentGeneration) else { return }
        let number = normalizedDocumentID
        guard !number.isEmpty else {
            fail("Введите номер исполнительного документа.")
            return
        }
        state = .loading
        challenge = nil
        suggestedCode = nil
        suggestionConfidence = nil
        activeDocumentID = nil

        let step = await dependencies.discover(number)
        guard isCurrent(currentGeneration) else { return }
        switch step {
        case .captchaRequired(let freshChallenge):
            activeDocumentID = number
            await present(freshChallenge, generation: currentGeneration)
        case .found, .notFound, .ambiguous:
            state = .loading
            message = "ФССП вернула ответ без CAPTCHA; автоматически запрашиваем следующую."
            scheduleFreshChallenge(generation: currentGeneration)
        case .error(let error):
            scheduleRetry(after: error, generation: currentGeneration)
        }
    }

    private func present(_ freshChallenge: FSSPCaptchaChallenge,
                         generation currentGeneration: Int) async {
        guard isCurrent(currentGeneration) else { return }
        show(freshChallenge)
        await offerModelSuggestion(for: freshChallenge, generation: currentGeneration)
    }

    private func offerModelSuggestion(for freshChallenge: FSSPCaptchaChallenge,
                                      generation currentGeneration: Int) async {
        let provider = modelProvider
        let attempt = await provider.recognize(freshChallenge)
        guard isCurrent(currentGeneration),
              challenge?.codeID == freshChallenge.codeID else { return }
        guard let attempt,
              CoreMLCaptchaStrategy.isCompatibleOutput(attempt.value) else {
            state = .awaitingManualInput
            message = "Модель не распознала эту CAPTCHA; автоматически запрашиваем следующую."
            scheduleFreshChallenge(generation: currentGeneration)
            return
        }

        suggestedCode = attempt.value
        suggestionConfidence = attempt.confidence
        state = .awaitingManualInput
        await submit(code: attempt.value, source: .automatic)
    }

    private func submit(code rawCode: String, source: SubmissionSource) async {
        guard state == .awaitingManualInput,
              let challenge,
              let activeDocumentID else { return }
        let code = String(rawCode.filter { ("0"..."9").contains($0) }.prefix(5))
        guard code.count == 5 else {
            message = "Код должен состоять из пяти цифр."
            return
        }
        let currentGeneration = generation
        submittedCount += 1
        lastSubmittedCode = code
        state = .submitting
        message = "Код \(code) отправлен. Ждём ответ ФССП."
        let step = await dependencies.submit(code, challenge, activeDocumentID)
        guard isCurrent(currentGeneration) else { return }
        switch step {
        case .found, .notFound, .ambiguous:
            await accepted(challenge: challenge, code: code, source: source,
                           step: step, generation: currentGeneration)
        case .captchaRequired(let replacement):
            rejectedCount += 1
            lastOutcome = "Код \(code) отклонён ФССП; получена новая CAPTCHA."
            if source == .automatic {
                show(replacement)
                scheduleModelAttempt(for: replacement, generation: currentGeneration)
            } else {
                await present(replacement, generation: currentGeneration)
            }
        case .error(let error):
            scheduleRetry(after: error, generation: currentGeneration)
        }
    }

    private func accepted(challenge: FSSPCaptchaChallenge,
                          code: String,
                          source: SubmissionSource,
                          step: FSSPSearchStep,
                          generation currentGeneration: Int) async {
        let saved = await dependencies.saveConfirmedPair(challenge.imagePNG, code)
        guard isCurrent(currentGeneration) else { return }
        switch source {
        case .manual:
            manualAcceptedCount += 1
        case .automatic:
            automaticAcceptedCount += 1
        }
        await refreshCorpusAndModel()
        guard isCurrent(currentGeneration) else { return }

        let result = switch step {
        case .found: "найдена запись"
        case .notFound: "записей не найдено"
        case .ambiguous: "несколько записей"
        case .captchaRequired, .error: ""
        }
        message = saved
            ? "Ответ принят ФССП: \(result). Пара добавлена в корпус."
            : "Ответ принят ФССП: \(result). Не удалось сохранить PNG в корпус."
        lastOutcome = message
        self.challenge = nil
        suggestedCode = nil
        suggestionConfidence = nil
        activeDocumentID = nil

        if trainingIsDue(for: corpusCount) {
            await runTraining(at: corpusCount, generation: currentGeneration)
        } else if source == .automatic {
            // Break the async call chain between accepted automatic answers.
            // Otherwise a long collection session retains one continuation
            // per CAPTCHA even though every network request is sequential.
            scheduleFreshChallenge(generation: currentGeneration)
        } else {
            await requestFreshChallenge(generation: currentGeneration)
        }
    }

    private func runTraining(at count: Int, generation currentGeneration: Int) async {
        guard isCurrent(currentGeneration), count >= Self.firstTrainingCount else {
            await requestFreshChallenge(generation: currentGeneration)
            return
        }
        state = .training
        message = "Корпус: \(count). Идёт обучение черновой модели; сбор приостановлен."
        let result = await dependencies.train(dependencies.trainingRoot)
        guard isCurrent(currentGeneration) else { return }
        switch result {
        case .succeeded(let log):
            modelProvider = dependencies.loadModel()
            modelStatus = modelProvider.status
            guard let trainedCount = modelProvider.trainedCorpusCount,
                  trainedCount >= count else {
                trainingLog = log
                trainingFailed(at: count, detail: "Тренер завершился, но не создал актуальную проверяемую модель и отчёт.")
                scheduleTrainingRetry(generation: currentGeneration)
                return
            }
            await dependencies.markTrained(trainedCount)
            failedTrainingAtCorpusCount = nil
            trainingLog = log
            message = "Черновая модель обновлена по \(trainedCount) уникальным изображениям."
            await requestFreshChallenge(generation: currentGeneration)
        case .failed(let log):
            // The trainer removes a stale report before writing a new model.
            // Reload so a failed run cannot keep using a previously eligible
            // in-memory bootstrap model after the on-disk gate disappeared.
            modelProvider = dependencies.loadModel()
            modelStatus = modelProvider.status
            trainingLog = log
            trainingFailed(at: count, detail: "Обучение не выполнено.")
            scheduleTrainingRetry(generation: currentGeneration)
        }
    }

    private func trainingFailed(at count: Int, detail: String) {
        failedTrainingAtCorpusCount = count
        state = .trainingFailed
        message = "\(detail) Новая попытка обучения начнётся автоматически."
    }

    private func trainingIsDue(for count: Int) -> Bool {
        guard count >= Self.firstTrainingCount,
              failedTrainingAtCorpusCount != count else { return false }
        guard let trainedCount = modelProvider.trainedCorpusCount else { return true }
        let nextBoundary = (trainedCount / Self.retrainingIncrement + 1)
            * Self.retrainingIncrement
        return count >= nextBoundary
    }

    private func scheduleFreshChallenge(generation currentGeneration: Int) {
        Task { [weak self] in
            await self?.requestFreshChallenge(generation: currentGeneration)
        }
    }

    private func scheduleModelAttempt(for challenge: FSSPCaptchaChallenge,
                                      generation currentGeneration: Int) {
        Task { [weak self] in
            await self?.offerModelSuggestion(for: challenge, generation: currentGeneration)
        }
    }

    private func scheduleRetry(after error: String, generation currentGeneration: Int) {
        errorCount += 1
        state = .retryWaiting
        challenge = nil
        suggestedCode = nil
        suggestionConfidence = nil
        activeDocumentID = nil
        lastOutcome = error
        message = "\(error) Пауза 60 секунд, затем повторим автоматически."
        // FSSPClient keeps the three-second interval, Retry-After and its own
        // one network retry; the longer lab pause also lets a CAPTCHA attempt
        // block expire instead of keeping it alive with immediate requests.
        Task { [weak self] in
            guard let self else { return }
            guard await self.dependencies.waitBeforeRetry(),
                  !Task.isCancelled,
                  self.isCurrent(currentGeneration),
                  self.state == .retryWaiting else { return }
            await self.requestFreshChallenge(generation: currentGeneration)
        }
    }

    private func scheduleTrainingRetry(generation currentGeneration: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.trainingRetryDelay)
            guard !Task.isCancelled,
                  let self,
                  self.isCurrent(currentGeneration),
                  self.state == .trainingFailed else { return }
            await self.retryTraining()
        }
    }

    private func show(_ freshChallenge: FSSPCaptchaChallenge) {
        challenge = freshChallenge
        suggestedCode = nil
        suggestionConfidence = nil
        state = .recognizing
        message = "Модель распознаёт CAPTCHA."
    }

    private var normalizedDocumentID: String {
        documentID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fail(_ text: String) {
        state = .error
        message = text
    }

    private func isCurrent(_ value: Int) -> Bool {
        generation == value
    }
}
