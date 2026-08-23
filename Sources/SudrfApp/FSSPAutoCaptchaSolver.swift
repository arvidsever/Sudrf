import Foundation
import CaptchaSolver
import SudrfKit

/// On-device-only FSSP CAPTCHA loop. Every recognition uses a fresh challenge;
/// a value below the hard 0.90 floor is never sent to FSSP.
@MainActor
enum FSSPAutoCaptchaSolver {
    struct Settings: Sendable, Equatable {
        let maxAttempts: Int
        let minConfidence: Double

        init(maxAttempts: Int, minConfidence: Double) {
            self.maxAttempts = min(max(maxAttempts, 1), 3)
            self.minConfidence = max(minConfidence, 0.90)
        }
    }

    static func solve(document: CourtEnforcementDocument,
                      client: FSSPClient,
                      solver: CaptchaSolver,
                      enabled: Bool,
                      settings: Settings) async -> FSSPSearchStep {
        let result = await solve(
            enabled: enabled,
            settings: settings,
            discover: { try await client.discover(document: document) },
            submit: { code, challenge in
                try await client.submit(code: code, for: challenge, document: document)
            },
            recognize: { challenge in
                let host = challenge.requestURL.host
                let attempt = try await solver.solve(
                    pngData: challenge.imagePNG, kind: .fsspDigits, host: host)
                let (candidates, _) = await solver.topCandidates(
                    pngData: challenge.imagePNG, kind: .fsspDigits, host: host, n: 3)
                let willSubmit = attempt.confidence >= settings.minConfidence
                    && CoreMLCaptchaStrategy.isCompatibleOutput(attempt.value)
                _ = solver.log.logCandidates(
                    host: host ?? "fssp.gov.ru",
                    kind: .fsspDigits,
                    submitted: willSubmit ? attempt.value : nil,
                    confidence: attempt.confidence,
                    alternatives: candidates.filter { $0.text != attempt.value }.prefix(2).map { $0 },
                    preprocessed: false)
                return attempt
            })
        if enabled, case .captchaRequired(let challenge) = result {
            _ = solver.log.logFailedImage(
                png: challenge.imagePNG,
                host: challenge.requestURL.host ?? "fssp.gov.ru",
                kind: .fsspDigits)
        }
        return result
    }

    /// Closure-based core keeps network and CoreML out of deterministic tests.
    static func solve(
        enabled: Bool,
        settings: Settings,
        discover: () async throws -> FSSPSearchStep,
        submit: (String, FSSPCaptchaChallenge) async throws -> FSSPSearchStep,
        recognize: (FSSPCaptchaChallenge) async throws -> CaptchaAttempt
    ) async -> FSSPSearchStep {
        guard enabled else {
            do { return try await discover() }
            catch { return .error(error.localizedDescription) }
        }

        var step: FSSPSearchStep?
        for attemptIndex in 0..<settings.maxAttempts {
            do {
                if step == nil { step = try await discover() }
                guard case .captchaRequired(let challenge) = step else {
                    return step ?? .error("ФССП не вернула результат поиска.")
                }
                let attempt = try await recognize(challenge)
                guard attempt.confidence >= settings.minConfidence,
                      CoreMLCaptchaStrategy.isCompatibleOutput(attempt.value) else {
                    // No answer was sent. A new discover call obtains a fresh
                    // code_id for the next model invocation.
                    if attemptIndex + 1 < settings.maxAttempts { step = nil }
                    continue
                }
                step = try await submit(attempt.value, challenge)
                if case .captchaRequired = step {
                    // Rejection already contains a replacement code_id.
                    continue
                }
                return step ?? .error("ФССП не вернула результат поиска.")
            } catch is CancellationError {
                return .error("Проверка CAPTCHA ФССП отменена.")
            } catch {
                if let manualStep = step, case .captchaRequired = manualStep {
                    if attemptIndex + 1 < settings.maxAttempts {
                        step = nil
                        continue
                    }
                    return manualStep
                }
                return .error(error.localizedDescription)
            }
        }
        return step ?? .error("ФССП не вернула CAPTCHA для ручного ввода.")
    }
}
