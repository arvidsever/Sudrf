import Foundation

/// Opt-in, task-scoped timings for the existing court transports.
@_spi(Diagnostics) public enum TransportTiming {
    @TaskLocal public static var collector: TransportTimingCollector?
}

/// Collects anonymized transport timing samples for one explicitly scoped run.
/// Samples contain only a canonical host, durations, and outcome flags. Calls
/// cancelled before URLSession starts are intentionally omitted.
@_spi(Diagnostics) public final class TransportTimingCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [TransportTimingSample] = []

    public init() {}

    /// Returns a thread-safe point-in-time copy and its per-host aggregates.
    public func snapshot() -> TransportTimingSnapshot {
        lock.lock()
        let samples = self.samples
        lock.unlock()

        let grouped = Dictionary(grouping: samples, by: \.host)
        let hosts = grouped.keys.sorted().compactMap { host -> TransportHostTiming? in
            guard let hostSamples = grouped[host], !hostSamples.isEmpty else { return nil }
            return TransportHostTiming(
                host: host,
                attemptCount: hostSamples.count,
                failureCount: hostSamples.filter(\.failed).count,
                cancelledCount: hostSamples.filter(\.cancelled).count,
                queueWaitSeconds: hostSamples.reduce(0) { $0 + $1.queueWaitSeconds },
                queueWaitP95Seconds: Self.p95(hostSamples.map(\.queueWaitSeconds)),
                throttleWaitSeconds: hostSamples.reduce(0) { $0 + $1.throttleWaitSeconds },
                throttleWaitP95Seconds: Self.p95(hostSamples.map(\.throttleWaitSeconds)),
                sessionPreparationSeconds: hostSamples.reduce(0) { $0 + $1.sessionPreparationSeconds },
                sessionPreparationP95Seconds: Self.p95(hostSamples.map(\.sessionPreparationSeconds)),
                responseSeconds: hostSamples.reduce(0) { $0 + $1.responseSeconds },
                responseP95Seconds: Self.p95(hostSamples.map(\.responseSeconds)))
        }

        return TransportTimingSnapshot(
            transportAttemptCount: samples.count,
            failureCount: samples.filter(\.failed).count,
            cancelledCount: samples.filter(\.cancelled).count,
            samples: samples,
            hostTimings: hosts)
    }

    func record(host: String,
                queueWaitSeconds: Double,
                throttleWaitSeconds: Double,
                sessionPreparationSeconds: Double,
                responseSeconds: Double,
                failed: Bool,
                cancelled: Bool) {
        let sample = TransportTimingSample(
            host: host,
            queueWaitSeconds: max(0, queueWaitSeconds),
            throttleWaitSeconds: max(0, throttleWaitSeconds),
            sessionPreparationSeconds: max(0, sessionPreparationSeconds),
            responseSeconds: max(0, responseSeconds),
            failed: failed,
            cancelled: cancelled)
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    static func canonicalHost(for url: URL?) -> String {
        guard let rawHost = url?.host else { return "unknown" }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return "unknown" }
        return SudrfHost.moduleHost(host)
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return Task.isCancelled
    }

    public static func elapsedSeconds(since start: SuspendingClock.Instant) -> Double {
        let elapsed = start.duration(to: SuspendingClock.now).components
        return max(0, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    private static func p95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }
}

@_spi(Diagnostics) public struct TransportTimingSample: Sendable, Equatable {
    public let host: String
    public let queueWaitSeconds: Double
    public let throttleWaitSeconds: Double
    public let sessionPreparationSeconds: Double
    public let responseSeconds: Double
    public let failed: Bool
    public let cancelled: Bool
}

@_spi(Diagnostics) public struct TransportHostTiming: Sendable, Equatable {
    public let host: String
    public let attemptCount: Int
    public let failureCount: Int
    public let cancelledCount: Int
    public let queueWaitSeconds: Double
    public let queueWaitP95Seconds: Double
    public let throttleWaitSeconds: Double
    public let throttleWaitP95Seconds: Double
    public let sessionPreparationSeconds: Double
    public let sessionPreparationP95Seconds: Double
    public let responseSeconds: Double
    public let responseP95Seconds: Double
}

@_spi(Diagnostics) public struct TransportTimingSnapshot: Sendable, Equatable {
    public let transportAttemptCount: Int
    public let failureCount: Int
    public let cancelledCount: Int
    public let samples: [TransportTimingSample]
    public let hostTimings: [TransportHostTiming]
}
