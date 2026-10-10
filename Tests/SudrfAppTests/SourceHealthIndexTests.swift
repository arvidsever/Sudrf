// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0

import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class SourceHealthIndexTests: XCTestCase {
    private struct Snapshot: Codable {
        let version: Int
        let hosts: [String: SourceHealthState.HostState]
    }

    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceHealthIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("source-health-index.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testWritesAndReopensOnlySafeMetadata() throws {
        var state = SourceHealthState()
        state.record(attempt(.transportFailure, time: 10, code: "-1200"))
        var unsafe = attempt(.parserFailure, time: 20)
        unsafe.provenance.host = "court.sudrf.ru/path?private=sentinel"
        unsafe.provenance.errorCode = "raw error sentinel"
        unsafe.provenance.affectedSources = ["other.sudrf.ru/private-sentinel"]
        state.record(unsafe)

        let index = SourceHealthIndex(fileURL: fileURL)
        try index.save(state, trackedHosts: [])
        let json = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(json.contains("sentinel"))
        XCTAssertFalse(json.contains("affectedSources"))

        let loaded = try index.load(trackedHosts: [])
        XCTAssertEqual(loaded.hosts.count, 1)
        XCTAssertEqual(loaded.hosts["court.sudrf.ru"]?.lastError?.errorCode, -1200)
        XCTAssertEqual(loaded.hosts["court.sudrf.ru"]?.lastError?.transportCategory, .tls)
    }

    func testRoundTripPreservesIndependentAttemptSuccessAndError() throws {
        var state = SourceHealthState()
        state.record(attempt(.usableSnapshot, time: 10), confirmedOperationHost: "court.sudrf.ru")
        state.record(attempt(.parserFailure, time: 20))
        state.record(attempt(.partial, time: 30))

        let index = SourceHealthIndex(fileURL: fileURL)
        try index.save(state, trackedHosts: [])
        let loaded = try index.load(trackedHosts: [])
        let host = try XCTUnwrap(loaded.hosts["court.sudrf.ru"])
        XCTAssertEqual(host.lastObserved?.kind, .partial)
        XCTAssertEqual(host.lastSuccess?.kind, .usableSnapshot)
        XCTAssertEqual(host.lastError?.kind, .parserFailure)
    }

    func testReopenDropsHostWithPathOrQueryInjectedIntoFile() throws {
        var state = SourceHealthState()
        state.record(attempt(.parserFailure, time: 10))
        try SourceHealthIndex(fileURL: fileURL).save(state, trackedHosts: [])
        let poisoned = try String(contentsOf: fileURL, encoding: .utf8)
            .replacingOccurrences(of: "court.sudrf.ru",
                                  with: "court.sudrf.ru/path?private=sentinel")
        try poisoned.write(to: fileURL, atomically: true, encoding: .utf8)

        let loaded = try SourceHealthIndex(fileURL: fileURL).load(trackedHosts: [])
        XCTAssertTrue(loaded.hosts.isEmpty)
        XCTAssertFalse(String(describing: loaded).contains("sentinel"))
    }

    func testReopenRejectsSuccessWithHiddenErrorCodeAlongsideHTTPStatus() throws {
        try writePoisonedSnapshot(lastSuccess: fact(kind: "usableSnapshot", errorCode: -1200),
                                  lastError: "null")

        let loaded = try SourceHealthIndex(fileURL: fileURL).load(trackedHosts: [])
        XCTAssertNil(loaded.hosts["court.sudrf.ru"]?.lastSuccess)
    }

    func testReopenRejectsCancelledErrorWithHTTPStatus() throws {
        try writePoisonedSnapshot(lastSuccess: "null",
                                  lastError: fact(kind: "transportFailure", errorCode: -999))

        let loaded = try SourceHealthIndex(fileURL: fileURL).load(trackedHosts: [])
        XCTAssertNil(loaded.hosts["court.sudrf.ru"]?.lastError)
    }

    func testCorruptIndexThrowsWithoutChangingFile() throws {
        let original = Data("not-json sentinel".utf8)
        try original.write(to: fileURL)

        XCTAssertThrowsError(try SourceHealthIndex(fileURL: fileURL).load(trackedHosts: []))
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testWriteFailureLeavesExistingFileUntouched() throws {
        let blocker = directory.appendingPathComponent("not-a-directory")
        let original = Data("preserve this file".utf8)
        try original.write(to: blocker)
        var state = SourceHealthState()
        state.record(attempt(.parserFailure, time: 10))

        XCTAssertThrowsError(try SourceHealthIndex(
            fileURL: blocker.appendingPathComponent("source-health-index.json")
        ).save(state, trackedHosts: []))
        XCTAssertEqual(try Data(contentsOf: blocker), original)
    }

    func testRetentionKeepsTrackedHostsAndNewestOtherHostsAcrossReadAndWrite() throws {
        let trackedHosts = Set((0..<55).map { String(format: "tracked-%02d.sudrf.ru", $0) })
        let recentHosts = (0..<48).map { String(format: "recent-%02d.sudrf.ru", $0) }
        let tiedHosts = (0..<4).map { String(format: "tie-%02d.sudrf.ru", $0) }
        let oldHosts = (0..<2).map { String(format: "old-%02d.sudrf.ru", $0) }
        var state = SourceHealthState()

        for host in trackedHosts.sorted() {
            state.record(attempt(.parserFailure, time: -100, host: host))
        }
        for host in recentHosts {
            state.record(attempt(.parserFailure, time: 100, host: host))
        }
        for host in tiedHosts {
            state.record(attempt(.parserFailure, time: 90, host: host))
        }
        for host in oldHosts {
            state.record(attempt(.parserFailure, time: 80, host: host))
        }

        // Existing index files can predate the retention rule, so load must bound them too.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(version: 1, hosts: state.hosts))
        try data.write(to: fileURL, options: .atomic)

        let index = SourceHealthIndex(fileURL: fileURL)
        let suppliedTrackedHosts = Set(trackedHosts.map { $0.uppercased() })
        let retainedOtherHosts = Set(recentHosts + Array(tiedHosts.prefix(2)))
        let expectedHosts = trackedHosts.union(retainedOtherHosts)

        let retainedLegacyIndex = try index.load(trackedHosts: suppliedTrackedHosts)
        XCTAssertEqual(Set(retainedLegacyIndex.hosts.keys), expectedHosts)
        XCTAssertEqual(retainedLegacyIndex.hosts.count, 105)

        // Save must bound an oversized in-memory state, not only an already-trimmed load.
        try index.save(state, trackedHosts: suppliedTrackedHosts)
        let persisted = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(Set(persisted.hosts.keys), expectedHosts)
        XCTAssertEqual(persisted.hosts.count, 105)

        let reopened = try index.load(trackedHosts: suppliedTrackedHosts)
        XCTAssertEqual(Set(reopened.hosts.keys), expectedHosts)
        XCTAssertEqual(reopened.hosts.count, 105)

        // Once a caller no longer marks a host as tracked, it competes by observation time.
        let afterUntracking = try index.load(trackedHosts: [])
        XCTAssertEqual(Set(afterUntracking.hosts.keys), retainedOtherHosts)
        XCTAssertEqual(afterUntracking.hosts.count, 50)
    }

    private func attempt(_ kind: SourceOutcomeKind, time: Double, host: String = "court.sudrf.ru",
                         code: String? = nil) -> SourceAttempt {
        SourceAttempt(kind: kind, provenance: .init(
            operation: .search, sourceFamily: "sudrf", host: host,
            observedAt: Date(timeIntervalSince1970: time), errorCode: code
        ))
    }

    private func writePoisonedSnapshot(lastSuccess: String, lastError: String) throws {
        let observed = fact(kind: "partial", errorCode: nil)
        let json = """
        {"version":1,"hosts":{"court.sudrf.ru":{"lastObserved":\(observed),"lastSuccess":\(lastSuccess),"lastError":\(lastError)}}}
        """
        try Data(json.utf8).write(to: fileURL)
    }

    private func fact(kind: String, errorCode: Int?) -> String {
        let code = errorCode.map { String($0) } ?? "null"
        return #"{"host":"court.sudrf.ru","family":"sudrf","operation":"search","kind":"\#(kind)","observedAt":0,"httpStatus":200,"errorCode":\#(code),"attemptCount":null}"#
    }
}
