import Foundation

/// Runs two local recognizers and keeps the answer backed by the higher
/// confidence. The models make different errors, so this small ensemble is
/// more accurate than either model on the independent SUDRF exam.
public struct HighestConfidenceStrategy: CaptchaSolvingProvider {
    public let first: any CaptchaSolvingProvider
    public let second: any CaptchaSolvingProvider

    public init(first: any CaptchaSolvingProvider,
                second: any CaptchaSolvingProvider) {
        self.first = first
        self.second = second
    }

    public func solve(pngData: Data,
                      kind: CaptchaKind,
                      host: String?) async throws -> CaptchaAttempt {
        let firstAttempt = try await attempt(
            from: first, pngData: pngData, kind: kind, host: host)
        let secondAttempt = try await attempt(
            from: second, pngData: pngData, kind: kind, host: host)
        switch (firstAttempt, secondAttempt) {
        case let (.some(first), .some(second)):
            return second.confidence > first.confidence ? second : first
        case let (.some(first), .none):
            return first
        case let (.none, .some(second)):
            return second
        case (.none, .none):
            return .empty
        }
    }

    public func topCandidates(
        pngData: Data,
        kind: CaptchaKind,
        host: String?,
        n: Int
    ) async throws -> (candidates: [(text: String, confidence: Double)], preprocessed: Bool) {
        let firstResult = try await candidates(
            from: first, pngData: pngData, kind: kind, host: host, n: n)
        let secondResult = try await candidates(
            from: second, pngData: pngData, kind: kind, host: host, n: n)
        var bestByText: [String: Double] = [:]
        for candidate in firstResult.candidates + secondResult.candidates {
            bestByText[candidate.text] = max(
                bestByText[candidate.text] ?? 0, candidate.confidence)
        }
        let merged = bestByText.map { (text: $0.key, confidence: $0.value) }
            .sorted { $0.confidence > $1.confidence }
        return (Array(merged.prefix(n)),
                firstResult.preprocessed || secondResult.preprocessed)
    }

    private func attempt(
        from provider: any CaptchaSolvingProvider,
        pngData: Data,
        kind: CaptchaKind,
        host: String?
    ) async throws -> CaptchaAttempt? {
        do {
            return try await provider.solve(pngData: pngData, kind: kind, host: host)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func candidates(
        from provider: any CaptchaSolvingProvider,
        pngData: Data,
        kind: CaptchaKind,
        host: String?,
        n: Int
    ) async throws -> (candidates: [(text: String, confidence: Double)], preprocessed: Bool) {
        do {
            return try await provider.topCandidates(
                pngData: pngData, kind: kind, host: host, n: n)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ([], false)
        }
    }
}
