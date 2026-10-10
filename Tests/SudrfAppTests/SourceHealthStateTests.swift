// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0

import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class SourceHealthStateTests: XCTestCase {
    private let a = "a.sudrf.ru"
    private let b = "b.sudrf.ru"

    private func attempt(_ kind: SourceOutcomeKind, _ time: Double, host: String = "a.sudrf.ru",
                         status: Int? = nil, code: String? = nil) -> SourceAttempt {
        SourceAttempt(kind: kind, provenance: .init(operation: .search, sourceFamily: "sudrf",
            host: host, observedAt: Date(timeIntervalSince1970: time), httpStatus: status, errorCode: code))
    }

    func testObservedSuccessAndErrorHaveIndependentChronologyAndHosts() {
        var state = SourceHealthState()
        state.record(attempt(.usableSnapshot, 10), confirmedOperationHost: a)
        state.record(attempt(.transportFailure, 30, code: "-1200"))
        state.record(attempt(.honestZero, 20), confirmedOperationHost: a)
        state.record(attempt(.parserFailure, 15))
        state.record(attempt(.partial, 40))
        state.record(attempt(.honestZero, 5, host: b), confirmedOperationHost: b)
        XCTAssertEqual(state.hosts[a]?.lastObserved?.kind, .partial)
        XCTAssertEqual(state.hosts[a]?.lastSuccess?.observedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(state.hosts[a]?.lastError?.transportCategory, .tls)
        XCTAssertEqual(state.hosts[a]?.lastError?.errorCode, -1200)
        XCTAssertEqual(state.hosts[b]?.lastSuccess?.observedAt, Date(timeIntervalSince1970: 5))
        state.record(attempt(.usableSnapshot, 9), confirmedOperationHost: a)
        XCTAssertEqual(state.hosts[a]?.lastSuccess?.kind, .honestZero)
    }

    func testSuccessRequiresOwnConfirmationNotStatusOrAggregateKind() {
        var state = SourceHealthState()
        state.record(attempt(.usableSnapshot, 1, status: 200))
        state.record(attempt(.honestZero, 2), confirmedOperationHost: b)
        for kind in [SourceOutcomeKind.partial, .captcha, .transportFailure, .maintenance, .parserFailure] {
            state.record(attempt(kind, 3, status: 200), confirmedOperationHost: a)
        }
        state.record(attempt(.usableSnapshot, 4, status: 500), confirmedOperationHost: a)
        state.record(attempt(.honestZero, 5, code: "-999"), confirmedOperationHost: a)
        XCTAssertNil(state.hosts[a]?.lastSuccess)
        state.record(attempt(.honestZero, 6), confirmedOperationHost: a)
        XCTAssertEqual(state.hosts[a]?.lastSuccess?.kind, .honestZero)
    }

    func testCancellationOnlyObservesAndDoesNotEraseErrorOrSuccess() {
        var state = SourceHealthState()
        state.record(attempt(.usableSnapshot, 1), confirmedOperationHost: a)
        state.record(attempt(.parserFailure, 2))
        state.record(attempt(.transportFailure, 3, code: "-999"))
        XCTAssertEqual(state.hosts[a]?.lastObserved?.transportCategory, .cancelled)
        XCTAssertEqual(state.hosts[a]?.lastObserved?.errorCode, -999)
        XCTAssertEqual(state.hosts[a]?.lastError?.kind, .parserFailure)
        XCTAssertEqual(state.hosts[a]?.lastSuccess?.kind, .usableSnapshot)
        state.record(attempt(.transportFailure, 4, status: 200, code: "-999"))
        XCTAssertEqual(state.hosts[a]?.lastError?.kind, .parserFailure)
    }

    func testMutableOrDecodedProvenanceCannotExposeUnvalidatedStrings() throws {
        var state = SourceHealthState()
        for host in ["a.sudrf.ru/path?private=sentinel", "user@a.sudrf.ru", "a.sudrf.ru:443", "a..sudrf.ru", "-a.sudrf.ru", "a.sudrf.ru.attacker.test"] {
            var bad = attempt(.parserFailure, 1)
            bad.provenance.host = host
            state.record(try JSONDecoder().decode(SourceAttempt.self,
                from: JSONEncoder().encode(bad)))
        }
        var badFamily = attempt(.parserFailure, 1)
        badFamily.provenance.sourceFamily = "private sentinel"
        state.record(badFamily)
        XCTAssertTrue(state.hosts.isEmpty)
        var decoded = try JSONDecoder().decode(SourceAttempt.self, from: JSONEncoder().encode(attempt(.transportFailure, 2)))
        decoded.provenance.errorCode = "private sentinel query/token"
        decoded.provenance.affectedSources = ["b.sudrf.ru/private"]
        decoded.provenance.attemptCount = -1
        decoded.provenance.httpStatus = -1200
        state.record(decoded)
        let fact = try XCTUnwrap(state.hosts[a]?.lastError)
        XCTAssertNil(fact.transportCategory)
        XCTAssertNil(fact.errorCode)
        XCTAssertNil(fact.httpStatus)
        XCTAssertNil(fact.attemptCount)
        XCTAssertFalse(String(describing: state).contains("sentinel"))
        XCTAssertNil(state.hosts[b])
    }

    func testFamiliesBindToOwnHostAndTiesDoNotReplaceFacts() {
        var state = SourceHealthState()
        for (family, host) in [("msudrf", "77.msudrf.ru"), ("mosgorsud", "mos-gorsud.ru"), ("vsrf", "vsrf.ru")] {
            var good = attempt(.usableSnapshot, 1, host: host)
            good.provenance.sourceFamily = family
            state.record(good, confirmedOperationHost: host)
            XCTAssertNotNil(state.hosts[host]?.lastSuccess)
            good.kind = .honestZero
            state.record(good, confirmedOperationHost: host)
            XCTAssertEqual(state.hosts[host]?.lastSuccess?.kind, .usableSnapshot)
            good.provenance.host = a
            state.record(good, confirmedOperationHost: a)
        }
        XCTAssertNil(state.hosts[a])
    }
}
