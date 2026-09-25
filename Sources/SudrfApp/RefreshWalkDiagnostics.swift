import Foundation
@_spi(Diagnostics) import SudrfKit
import os

private let refreshWalkLog = Logger(
    subsystem: "ru.sudrf.app", category: "RefreshWalkDiagnostics")

struct RefreshWalkReport: Codable, Equatable {
    struct Distribution: Codable, Equatable {
        var count: Int
        var minimum: Double
        var median: Double
        var p95: Double
        var maximum: Double
        var mean: Double

        init?(_ rawValues: [TimeInterval]) {
            let values = rawValues.map { max(0, $0) }.sorted()
            guard let first = values.first, let last = values.last else { return nil }
            func percentile(_ fraction: Double) -> Double {
                let index = Int((Double(values.count - 1) * fraction).rounded())
                return values[index]
            }
            count = values.count
            minimum = first
            median = percentile(0.5)
            p95 = percentile(0.95)
            maximum = last
            mean = values.reduce(0, +) / Double(values.count)
        }
    }

    struct HostSummary: Codable, Equatable {
        var host: String
        var primaryOutcomeCounts: [String: Int]
        var affectedSourceCount: Int
        var retriesAfterFailure: Int
        var transportRetryCount: Int
    }

    /// Транспортные времена относятся только к запросам данного обхода;
    /// номер дела, URL и последовательность отдельных запросов не сохраняются.
    /// `attemptCount` — вызовы транспорта, начавшие сеть: автоматические
    /// redirect hops URLSession у ВС РФ/Мосгорсуда отдельно не считаются.
    struct TransportTiming: Codable, Equatable {
        struct Host: Codable, Equatable {
            var host: String
            var attemptCount: Int
            var failureCount: Int
            var cancelledCount: Int
            var queueWaitSeconds: Double
            var queueWaitP95Seconds: Double
            var throttleWaitSeconds: Double
            var throttleWaitP95Seconds: Double
            var sessionPreparationSeconds: Double
            var sessionPreparationP95Seconds: Double
            var responseSeconds: Double
            var responseP95Seconds: Double
        }

        var attemptCount: Int
        var failureCount: Int
        var cancelledCount: Int
        /// Монотонное время самого обхода: сопоставимо с суммой фаз транспорта,
        /// в отличие от календарного durationSeconds при сне компьютера.
        var awakeDurationSeconds: Double
        var hosts: [Host]

        init(attemptCount: Int, failureCount: Int, cancelledCount: Int,
             awakeDurationSeconds: Double, hosts: [Host]) {
            self.attemptCount = attemptCount
            self.failureCount = failureCount
            self.cancelledCount = cancelledCount
            self.awakeDurationSeconds = awakeDurationSeconds
            self.hosts = hosts
        }

        init(_ snapshot: TransportTimingSnapshot, awakeDurationSeconds: Double) {
            attemptCount = snapshot.transportAttemptCount
            failureCount = snapshot.failureCount
            cancelledCount = snapshot.cancelledCount
            self.awakeDurationSeconds = max(0, awakeDurationSeconds)
            hosts = snapshot.hostTimings.map { timing in
                Host(
                    host: timing.host,
                    attemptCount: timing.attemptCount,
                    failureCount: timing.failureCount,
                    cancelledCount: timing.cancelledCount,
                    queueWaitSeconds: timing.queueWaitSeconds,
                    queueWaitP95Seconds: timing.queueWaitP95Seconds,
                    throttleWaitSeconds: timing.throttleWaitSeconds,
                    throttleWaitP95Seconds: timing.throttleWaitP95Seconds,
                    sessionPreparationSeconds: timing.sessionPreparationSeconds,
                    sessionPreparationP95Seconds: timing.sessionPreparationP95Seconds,
                    responseSeconds: timing.responseSeconds,
                    responseP95Seconds: timing.responseP95Seconds)
            }
        }
    }

    var formatVersion = 2
    var walkID: UUID
    var trigger: String
    var appVersion: String
    var appBuild: String
    var startedAt: Date
    var finishedAt: Date
    var durationSeconds: TimeInterval
    var ttlSeconds: TimeInterval
    var eligibleTotal: Int
    var courtEligible: Int
    var enforcementOnly: Int
    var completedTotal: Int
    var completedCourt: Int
    var completedEnforcement: Int
    var cancelled: Bool
    var duplicateCompletions: Int
    var continuedOnDifferentHostAfterFailure: Bool
    var queueWaitSeconds: Distribution?
    var eligibilityDelaySeconds: Distribution?
    var lastAttemptAgeSeconds: Distribution?
    var lastSuccessAgeSeconds: Distribution?
    var retryAfterFailureIntervalSeconds: Distribution?
    var retryAfterFailureCount: Int
    var reportedTransportAttemptCount: Int
    var transportFailuresWithoutAttemptCount: Int
    var transportRetryCount: Int
    var executionOutcomeCounts: [String: Int]
    var sourceOutcomeCounts: [String: Int]
    var hosts: [HostSummary]
    /// Optional для чтения отчётов формата 1.
    var transportTiming: TransportTiming? = nil
}

struct RefreshWalkMeasurement {
    struct Candidate {
        var key: String
        var courtDue: Bool
        var host: String?
        var lastAttempt: Date?
        var lastSuccess: Date?
        var previousAttempt: SourceAttempt?
        var eligibleSince: Date?
    }

    struct Completion {
        var key: String
        var courtDue: Bool
        var host: String?
        var startedAt: Date
        var lastAttempt: Date?
        var lastSuccess: Date?
        var previousAttempt: SourceAttempt?
        var eligibleSince: Date?
        var executionOutcome: String
        var sourceAttempt: SourceAttempt?
    }

    var id = UUID()
    var trigger: String
    var appVersion: String
    var appBuild: String
    var startedAt: Date
    var ttl: TimeInterval
    var candidates: [Candidate]
    var completions: [Completion] = []

    mutating func append(candidate: Candidate, startedAt: Date,
                         executionOutcome: String, sourceAttempt: SourceAttempt?) {
        completions.append(Completion(
            key: candidate.key,
            courtDue: candidate.courtDue,
            host: candidate.host,
            startedAt: startedAt,
            lastAttempt: candidate.lastAttempt,
            lastSuccess: candidate.lastSuccess,
            previousAttempt: candidate.previousAttempt,
            eligibleSince: candidate.eligibleSince,
            executionOutcome: executionOutcome,
            sourceAttempt: sourceAttempt))
    }

    func report(finishedAt: Date, cancelled: Bool,
                transportTiming: RefreshWalkReport.TransportTiming? = nil)
        -> RefreshWalkReport {
        let court = completions.filter(\.courtDue)
        let completedKeys = completions.map(\.key)
        let duplicateCount = completedKeys.count - Set(completedKeys).count
        let queueWaits = court.map { $0.startedAt.timeIntervalSince(startedAt) }
        let eligibilityDelays = court.compactMap { completion in
            completion.eligibleSince.map { completion.startedAt.timeIntervalSince($0) }
        }
        let attemptAges = court.compactMap { completion in
            completion.lastAttempt.map { completion.startedAt.timeIntervalSince($0) }
        }
        let successAges = court.compactMap { completion in
            completion.lastSuccess.map { completion.startedAt.timeIntervalSince($0) }
        }

        var executionCounts: [String: Int] = [:]
        var sourceCounts: [String: Int] = [:]
        var retryIntervals: [TimeInterval] = []
        var reportedTransportAttempts = 0
        var transportFailuresWithoutAttemptCount = 0
        var transportRetries = 0

        struct HostAccumulator {
            var outcomes: [String: Int] = [:]
            var affected = 0
            var retryAfterFailure = 0
            var transportRetries = 0
        }
        var hostAccumulators: [String: HostAccumulator] = [:]

        for completion in completions {
            executionCounts[completion.executionOutcome, default: 0] += 1
            guard completion.courtDue else { continue }
            if let attempt = completion.sourceAttempt {
                sourceCounts[attempt.kind.rawValue, default: 0] += 1
                let host = canonicalHost(attempt.provenance.host)
                if !host.isEmpty {
                    hostAccumulators[host, default: HostAccumulator()]
                        .outcomes[attempt.kind.rawValue, default: 0] += 1
                }
                for affected in attempt.provenance.affectedSources ?? [] {
                    let affectedHost = canonicalHost(affected)
                    guard !affectedHost.isEmpty else { continue }
                    hostAccumulators[affectedHost, default: HostAccumulator()].affected += 1
                }
                if attempt.kind == .transportFailure {
                    if let attemptCount = attempt.provenance.attemptCount {
                        reportedTransportAttempts += attemptCount
                        let retries = max(0, attemptCount - 1)
                        transportRetries += retries
                        if !host.isEmpty {
                            hostAccumulators[host, default: HostAccumulator()]
                                .transportRetries += retries
                        }
                    } else {
                        transportFailuresWithoutAttemptCount += 1
                    }
                }
            } else {
                sourceCounts["noSourceAttempt", default: 0] += 1
            }

            guard let previous = completion.previousAttempt,
                  Self.isFailure(previous.kind) else { continue }
            retryIntervals.append(completion.startedAt.timeIntervalSince(
                previous.provenance.observedAt))
            let previousHost = canonicalHost(previous.provenance.host)
            if !previousHost.isEmpty {
                hostAccumulators[previousHost, default: HostAccumulator()]
                    .retryAfterFailure += 1
            }
        }

        let hosts = hostAccumulators.map { host, value in
            RefreshWalkReport.HostSummary(
                host: host,
                primaryOutcomeCounts: value.outcomes,
                affectedSourceCount: value.affected,
                retriesAfterFailure: value.retryAfterFailure,
                transportRetryCount: value.transportRetries)
        }.sorted { $0.host < $1.host }

        return RefreshWalkReport(
            walkID: id,
            trigger: trigger,
            appVersion: appVersion,
            appBuild: appBuild,
            startedAt: startedAt,
            finishedAt: finishedAt,
            durationSeconds: max(0, finishedAt.timeIntervalSince(startedAt)),
            ttlSeconds: ttl,
            eligibleTotal: candidates.count,
            courtEligible: candidates.count(where: \.courtDue),
            enforcementOnly: candidates.count(where: { !$0.courtDue }),
            completedTotal: completions.count,
            completedCourt: court.count,
            completedEnforcement: completions.count(where: { !$0.courtDue }),
            cancelled: cancelled,
            duplicateCompletions: duplicateCount,
            continuedOnDifferentHostAfterFailure: continuedAfterFailure(court),
            queueWaitSeconds: RefreshWalkReport.Distribution(queueWaits),
            eligibilityDelaySeconds: RefreshWalkReport.Distribution(eligibilityDelays),
            lastAttemptAgeSeconds: RefreshWalkReport.Distribution(attemptAges),
            lastSuccessAgeSeconds: RefreshWalkReport.Distribution(successAges),
            retryAfterFailureIntervalSeconds: RefreshWalkReport.Distribution(retryIntervals),
            retryAfterFailureCount: retryIntervals.count,
            reportedTransportAttemptCount: reportedTransportAttempts,
            transportFailuresWithoutAttemptCount: transportFailuresWithoutAttemptCount,
            transportRetryCount: transportRetries,
            executionOutcomeCounts: executionCounts,
            sourceOutcomeCounts: sourceCounts,
            hosts: hosts,
            transportTiming: transportTiming)
    }

    private func continuedAfterFailure(_ court: [Completion]) -> Bool {
        for (index, completion) in court.enumerated() {
            guard let attempt = completion.sourceAttempt,
                  Self.isFailure(attempt.kind) else { continue }
            let failedHost = canonicalHost(attempt.provenance.host)
            if court.dropFirst(index + 1).contains(where: { later in
                let laterHost = canonicalHost(
                    later.sourceAttempt?.provenance.host ?? later.host ?? "")
                return !laterHost.isEmpty && laterHost != failedHost
            }) {
                return true
            }
        }
        return false
    }

    private static func isFailure(_ kind: SourceOutcomeKind) -> Bool {
        switch kind {
        case .usableSnapshot, .honestZero:
            return false
        case .partial, .captcha, .maintenance, .transportFailure, .parserFailure:
            return true
        }
    }

    private func canonicalHost(_ raw: String) -> String {
        SudrfHost.moduleHost(raw.lowercased())
    }
}

struct RefreshWalkDiagnostics {
    static let maxReports = 20

    var enabled: Bool
    var directory: URL
    var now: () -> Date
    var appVersion: String
    var appBuild: String

    static var live: RefreshWalkDiagnostics {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return RefreshWalkDiagnostics(
            enabled: true,
            directory: support.appendingPathComponent("Sudrf", isDirectory: true)
                .appendingPathComponent("diagnostics", isDirectory: true),
            now: Date.init,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
    }

    static var disabled: RefreshWalkDiagnostics {
        RefreshWalkDiagnostics(
            enabled: false,
            directory: FileManager.default.temporaryDirectory,
            now: Date.init,
            appVersion: "test",
            appBuild: "test")
    }

    func makeMeasurement(trigger: String, ttl: TimeInterval,
                         candidates: [RefreshWalkMeasurement.Candidate])
        -> RefreshWalkMeasurement {
        RefreshWalkMeasurement(
            trigger: trigger,
            appVersion: appVersion,
            appBuild: appBuild,
            startedAt: now(),
            ttl: ttl,
            candidates: candidates)
    }

    @discardableResult
    func save(_ report: RefreshWalkReport) -> URL? {
        guard enabled else { return nil }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            let filename = "refresh-walk_\(Self.timestamp(report.finishedAt))_"
                + "\(report.walkID.uuidString.prefix(8)).json"
            let url = directory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            evictOldReports(fileManager: fileManager)
            refreshWalkLog.notice(
                "walk trigger=\(report.trigger, privacy: .public) eligible=\(report.eligibleTotal) completed=\(report.completedTotal) court=\(report.completedCourt) cancelled=\(report.cancelled) duration=\(report.durationSeconds, format: .fixed(precision: 1))s")
            return url
        } catch {
            refreshWalkLog.error(
                "Не удалось сохранить диагностику обхода: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func evictOldReports(fileManager: FileManager) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let reports = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]).filter({
                $0.lastPathComponent.hasPrefix("refresh-walk_")
                    && $0.pathExtension == "json"
            }), reports.count > Self.maxReports else { return }
        let sorted = reports.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        for url in sorted.prefix(reports.count - Self.maxReports) {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}

extension CaseRefreshOutcome {
    var diagnosticsName: String {
        switch self {
        case .refreshed: "refreshed"
        case .partial: "partial"
        case .cancelled: "cancelled"
        case .captchaRequired: "captchaRequired"
        case .failed: "failed"
        case .notFound: "notFound"
        }
    }
}
