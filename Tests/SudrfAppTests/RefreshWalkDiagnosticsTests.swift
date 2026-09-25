import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class RefreshWalkDiagnosticsTests: XCTestCase {
    func testReportKeepsEveryTypedFailureCategorySeparatedByHost() {
        let start = Date(timeIntervalSince1970: 500)
        let kinds: [SourceOutcomeKind] = [
            .captcha, .partial, .maintenance, .transportFailure, .parserFailure,
        ]
        let candidates = kinds.enumerated().map { index, _ in
            RefreshWalkMeasurement.Candidate(
                key: "private-\(index)",
                courtDue: true,
                host: "court-\(index).sudrf.ru",
                lastAttempt: nil,
                lastSuccess: nil,
                previousAttempt: nil,
                eligibleSince: start)
        }
        var measurement = RefreshWalkMeasurement(
            trigger: "background",
            appVersion: "test",
            appBuild: "1",
            startedAt: start,
            ttl: 10_800,
            candidates: candidates)

        for (index, kind) in kinds.enumerated() {
            measurement.append(
                candidate: candidates[index],
                startedAt: start.addingTimeInterval(TimeInterval(index + 1)),
                executionOutcome: kind.rawValue,
                sourceAttempt: SourceAttempt(
                    kind: kind,
                    provenance: SourceProvenance(
                        operation: .movement,
                        sourceFamily: "sudrf",
                        host: "court-\(index).sudrf.ru",
                        observedAt: start.addingTimeInterval(TimeInterval(index + 2)))))
        }

        let report = measurement.report(
            finishedAt: start.addingTimeInterval(10), cancelled: false)
        for (index, kind) in kinds.enumerated() {
            XCTAssertEqual(report.sourceOutcomeCounts[kind.rawValue], 1)
            XCTAssertEqual(report.hosts.first(where: {
                $0.host == "court-\(index).sudrf.ru"
            })?.primaryOutcomeCounts[kind.rawValue], 1)
        }
        XCTAssertTrue(report.continuedOnDifferentHostAfterFailure)
    }

    func testReportAggregatesTimingFailuresAndContinuationWithoutCaseIdentity() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let previousFailure = SourceAttempt(
            kind: .transportFailure,
            provenance: SourceProvenance(
                operation: .movement,
                sourceFamily: "sudrf",
                host: "court-a--region.sudrf.ru",
                observedAt: start.addingTimeInterval(-30),
                errorCode: "-1001",
                attemptCount: 2))
        let candidates = [
            RefreshWalkMeasurement.Candidate(
                key: "secret-case-key-a",
                courtDue: true,
                host: "court-a--region.sudrf.ru",
                lastAttempt: previousFailure.provenance.observedAt,
                lastSuccess: start.addingTimeInterval(-100),
                previousAttempt: previousFailure,
                eligibleSince: start.addingTimeInterval(-50)),
            RefreshWalkMeasurement.Candidate(
                key: "secret-case-key-b",
                courtDue: true,
                host: "court-b--region.sudrf.ru",
                lastAttempt: nil,
                lastSuccess: start.addingTimeInterval(-80),
                previousAttempt: nil,
                eligibleSince: start.addingTimeInterval(-10)),
            RefreshWalkMeasurement.Candidate(
                key: "secret-enforcement-key",
                courtDue: false,
                host: nil,
                lastAttempt: nil,
                lastSuccess: nil,
                previousAttempt: nil,
                eligibleSince: nil),
        ]
        var measurement = RefreshWalkMeasurement(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000068")!,
            trigger: "background",
            appVersion: "0.58.30",
            appBuild: "200",
            startedAt: start,
            ttl: 10,
            candidates: candidates)
        let currentFailure = SourceAttempt(
            kind: .transportFailure,
            provenance: SourceProvenance(
                operation: .movement,
                sourceFamily: "sudrf",
                host: "court-a--region.sudrf.ru",
                observedAt: start.addingTimeInterval(12),
                errorCode: "-1001",
                attemptCount: 3,
                affectedSources: ["higher-a.sudrf.ru"]))
        measurement.append(
            candidate: candidates[0],
            startedAt: start.addingTimeInterval(10),
            executionOutcome: "failed",
            sourceAttempt: currentFailure)
        measurement.append(
            candidate: candidates[1],
            startedAt: start.addingTimeInterval(20),
            executionOutcome: "refreshed",
            sourceAttempt: SourceAttempt(
                kind: .usableSnapshot,
                provenance: SourceProvenance(
                    operation: .movement,
                    sourceFamily: "sudrf",
                    host: "court-b--region.sudrf.ru",
                    observedAt: start.addingTimeInterval(21))))
        measurement.append(
            candidate: candidates[2],
            startedAt: start.addingTimeInterval(30),
            executionOutcome: "enforcementCompleted",
            sourceAttempt: nil)

        let transport = RefreshWalkReport.TransportTiming(
            attemptCount: 2, failureCount: 1, cancelledCount: 0,
            awakeDurationSeconds: 38,
            hosts: [RefreshWalkReport.TransportTiming.Host(
                host: "court-a--region.sudrf.ru", attemptCount: 2,
                failureCount: 1, cancelledCount: 0,
                queueWaitSeconds: 4, queueWaitP95Seconds: 3,
                throttleWaitSeconds: 1, throttleWaitP95Seconds: 1,
                sessionPreparationSeconds: 2, sessionPreparationP95Seconds: 2,
                responseSeconds: 18, responseP95Seconds: 12)])
        let report = measurement.report(
            finishedAt: start.addingTimeInterval(40), cancelled: false,
            transportTiming: transport)

        XCTAssertEqual(report.durationSeconds, 40)
        XCTAssertEqual(report.transportTiming?.awakeDurationSeconds, 38)
        XCTAssertEqual(report.eligibleTotal, 3)
        XCTAssertEqual(report.courtEligible, 2)
        XCTAssertEqual(report.enforcementOnly, 1)
        XCTAssertEqual(report.completedCourt, 2)
        XCTAssertEqual(report.completedEnforcement, 1)
        XCTAssertEqual(report.duplicateCompletions, 0)
        XCTAssertEqual(report.queueWaitSeconds?.minimum, 10)
        XCTAssertEqual(report.queueWaitSeconds?.maximum, 20)
        XCTAssertEqual(report.eligibilityDelaySeconds?.minimum, 30)
        XCTAssertEqual(report.eligibilityDelaySeconds?.maximum, 60)
        XCTAssertEqual(report.retryAfterFailureCount, 1)
        XCTAssertEqual(report.retryAfterFailureIntervalSeconds?.maximum, 40)
        XCTAssertEqual(report.reportedTransportAttemptCount, 3)
        XCTAssertEqual(report.transportRetryCount, 2)
        XCTAssertEqual(report.sourceOutcomeCounts["transportFailure"], 1)
        XCTAssertEqual(report.sourceOutcomeCounts["usableSnapshot"], 1)
        XCTAssertTrue(report.continuedOnDifferentHostAfterFailure)
        XCTAssertEqual(report.hosts.first(where: {
            $0.host == "court-a--region.sudrf.ru"
        })?.retriesAfterFailure, 1)
        XCTAssertEqual(report.hosts.first(where: {
            $0.host == "higher-a.sudrf.ru"
        })?.affectedSourceCount, 1)
        XCTAssertEqual(report.formatVersion, 2)
        XCTAssertEqual(report.transportTiming, transport)

        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret-case-key"))
        XCTAssertFalse(encoded.contains("secret-enforcement-key"))

        var legacy = report
        legacy.formatVersion = 1
        legacy.transportTiming = nil
        let decodedLegacy = try JSONDecoder().decode(
            RefreshWalkReport.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decodedLegacy.transportTiming)
    }

    func testWriterKeepsOnlyTwentyAtomicDecodableReports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-walk-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = RefreshWalkDiagnostics(
            enabled: true,
            directory: directory,
            now: Date.init,
            appVersion: "test",
            appBuild: "1")
        let base = Date(timeIntervalSince1970: 2_000)

        for index in 0..<22 {
            let startedAt = base.addingTimeInterval(TimeInterval(index * 10))
            let measurement = RefreshWalkMeasurement(
                id: UUID(),
                trigger: "background",
                appVersion: "test",
                appBuild: "1",
                startedAt: startedAt,
                ttl: 10_800,
                candidates: [])
            XCTAssertNotNil(diagnostics.save(measurement.report(
                finishedAt: startedAt.addingTimeInterval(1), cancelled: false)))
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, RefreshWalkDiagnostics.maxReports)
        XCTAssertTrue(files.allSatisfy {
            $0.lastPathComponent.hasPrefix("refresh-walk_") && $0.pathExtension == "json"
        })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files {
            _ = try decoder.decode(RefreshWalkReport.self, from: Data(contentsOf: file))
        }
    }
}
