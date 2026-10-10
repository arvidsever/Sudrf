// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0

import Foundation
import SudrfKit

/// In-memory facts only; callers must confirm the outcome of the host's own operation.
struct SourceHealthState: Sendable {
    enum Family: String, Codable, Sendable {
        case sudrf, msudrf, mosgorsud, vsrf

        func accepts(_ host: String) -> Bool {
            switch self {
            case .sudrf: host == "sudrf.ru" || host.hasSuffix(".sudrf.ru")
            case .msudrf: SudrfHost.isMSudrfHost(host)
            case .mosgorsud: host == "mos-gorsud.ru" || host == "www.mos-gorsud.ru"
            case .vsrf: host == "vsrf.ru" || host == "www.vsrf.ru"
            }
        }
    }

    struct Fact: Codable, Equatable, Sendable {
        let host: String
        let family: Family
        let operation: SourceOperation
        let kind: SourceOutcomeKind
        let observedAt: Date
        let httpStatus: Int?
        let errorCode: Int?
        let attemptCount: Int?

        var transportCategory: SourceTransportFailureCategory? {
            guard kind == .transportFailure, httpStatus == nil, let errorCode else { return nil }
            return SourceTransportFailureCategory.classify(URLError.Code(rawValue: errorCode))
        }
    }

    struct HostState: Codable, Equatable, Sendable {
        var lastObserved: Fact?
        var lastSuccess: Fact?
        var lastError: Fact?
    }

    private(set) var hosts: [String: HostState] = [:]

    mutating func record(_ attempt: SourceAttempt, confirmedOperationHost: String? = nil) {
        let provenance = attempt.provenance
        guard let host = Self.validatedHost(provenance.host),
              let family = Family(rawValue: provenance.sourceFamily), family.accepts(host),
              provenance.observedAt.timeIntervalSince1970.isFinite else { return }
        let fact = Fact(host: host, family: family, operation: provenance.operation,
                        kind: attempt.kind, observedAt: provenance.observedAt,
                        httpStatus: provenance.httpStatus.flatMap { (100...599).contains($0) ? $0 : nil },
                        errorCode: provenance.httpStatus == nil ? provenance.errorCode.flatMap(Int.init) : nil,
                        attemptCount: provenance.attemptCount.flatMap { $0 > 0 ? $0 : nil })
        var state = hosts[host] ?? HostState()
        if state.lastObserved == nil || fact.observedAt > state.lastObserved!.observedAt {
            state.lastObserved = fact
        }
        // Aggregate movement success and HTTP 200 do not attest another host's operation.
        let success = (fact.kind == .usableSnapshot || fact.kind == .honestZero)
            && confirmedOperationHost.flatMap(Self.validatedHost) == host
            && provenance.httpStatus.map { (200...299).contains($0) } != false
            && provenance.errorCode == nil
        if success, state.lastSuccess == nil || fact.observedAt > state.lastSuccess!.observedAt {
            state.lastSuccess = fact
        }
        let cancelled = provenance.errorCode.flatMap(Int.init) == URLError.cancelled.rawValue
        let error = [.maintenance, .transportFailure, .parserFailure].contains(fact.kind)
            && !cancelled
        if error, state.lastError == nil || fact.observedAt > state.lastError!.observedAt {
            state.lastError = fact
        }
        hosts[host] = state
    }

    mutating func restore(_ saved: HostState, for candidateHost: String) {
        guard let host = Self.validatedHost(candidateHost), host == candidateHost,
              let lastObserved = Self.validated(saved.lastObserved, for: host, slot: .observed) else { return }
        let state = HostState(
            lastObserved: lastObserved,
            lastSuccess: Self.validated(saved.lastSuccess, for: host, slot: .success),
            lastError: Self.validated(saved.lastError, for: host, slot: .error)
        )
        hosts[host] = state
    }

    private enum FactSlot { case observed, success, error }

    private static func validated(_ fact: Fact?, for host: String, slot: FactSlot) -> Fact? {
        guard let fact, fact.host == host, validatedHost(fact.host) == host,
              fact.family.accepts(host), fact.observedAt.timeIntervalSince1970.isFinite else { return nil }
        let status = fact.httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        let errorCode = fact.httpStatus == nil ? fact.errorCode : nil
        let attemptCount = fact.attemptCount.flatMap { $0 > 0 ? $0 : nil }
        switch slot {
        case .observed:
            break
        case .success:
            guard [.usableSnapshot, .honestZero].contains(fact.kind),
                  fact.httpStatus.map({ (200...299).contains($0) }) != false,
                  fact.errorCode == nil else { return nil }
        case .error:
            guard [.maintenance, .transportFailure, .parserFailure].contains(fact.kind),
                  fact.errorCode != URLError.cancelled.rawValue else { return nil }
        }
        return Fact(host: host, family: fact.family, operation: fact.operation, kind: fact.kind,
                    observedAt: fact.observedAt, httpStatus: status, errorCode: errorCode,
                    attemptCount: attemptCount)
    }

    private static func validatedHost(_ raw: String) -> String? {
        let host = raw.lowercased()
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" }) else { return nil }
        return host
    }
}
