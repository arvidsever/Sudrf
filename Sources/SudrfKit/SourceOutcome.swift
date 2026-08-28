import Foundation

/// Операция источника определяет семантику подтверждённой пустоты и freshness.
public enum SourceOperation: String, Codable, Sendable {
    case search
    case discovery
    case movement
}

/// Нормализованный результат источника до persistence и semantic diff.
public enum SourceOutcomeKind: String, Codable, Sendable {
    case usableSnapshot
    case honestZero
    case partial
    case captcha
    case maintenance
    case transportFailure
    case parserFailure
}

/// Безопасный provenance: только источник и машинные коды, без URL query,
/// cookies, токенов и введённых CAPTCHA-кодов.
public struct SourceProvenance: Codable, Equatable, Sendable {
    public var operation: SourceOperation
    public var sourceFamily: String
    public var host: String
    public var observedAt: Date
    public var httpStatus: Int?
    public var errorCode: String?
    public var attemptCount: Int?
    public var affectedSources: [String]?

    public init(operation: SourceOperation, sourceFamily: String, host: String,
                observedAt: Date = .now, httpStatus: Int? = nil,
                errorCode: String? = nil, attemptCount: Int? = nil,
                affectedSources: [String] = []) {
        self.operation = operation
        self.sourceFamily = sourceFamily
        self.host = Self.sanitizedHost(host)
        self.observedAt = observedAt
        self.httpStatus = httpStatus
        self.errorCode = errorCode
        self.attemptCount = attemptCount
        let sanitized = Array(Set(affectedSources.map(Self.sanitizedHost)))
            .filter { !$0.isEmpty }.sorted()
        self.affectedSources = sanitized.isEmpty ? nil : sanitized
    }

    private static func sanitizedHost(_ raw: String) -> String {
        if let host = URL(string: raw)?.host { return host.lowercased() }
        return raw.split(whereSeparator: { "/?#".contains($0) }).first
            .map(String.init)?.lowercased() ?? ""
    }
}

public struct SourceAttempt: Codable, Equatable, Sendable {
    public var kind: SourceOutcomeKind
    public var provenance: SourceProvenance

    public init(kind: SourceOutcomeKind, provenance: SourceProvenance) {
        self.kind = kind
        self.provenance = provenance
    }
}

/// Runtime payload остаётся отдельно от сохраняемого `SourceAttempt`: URL
/// формы CAPTCHA нужен для продолжения операции, но в persistence не попадает.
public enum SourceOutcome<Value: Sendable>: Sendable {
    case usableSnapshot(Value, SourceAttempt)
    case honestZero(SourceAttempt)
    case partial(Value?, SourceAttempt)
    case captcha(formURL: URL, SourceAttempt)
    case maintenance(message: String, SourceAttempt)
    case transportFailure(message: String, SourceAttempt)
    case parserFailure(message: String, SourceAttempt)
}

public enum SourceOutcomeClassifier {
    public static func attempt(for movement: CaseMovement, sourceFamily: String,
                               host: String, observedAt: Date = .now) -> SourceAttempt {
        let affected = (movement.incompleteHigherCourtDomains ?? [])
            + (movement.honestZeroDomains ?? [])
        let kind: SourceOutcomeKind = affected.isEmpty ? .usableSnapshot : .partial
        return SourceAttempt(
            kind: kind,
            provenance: SourceProvenance(operation: .movement,
                                         sourceFamily: sourceFamily, host: host,
                                         observedAt: observedAt,
                                         affectedSources: affected))
    }

    public static func attempt(for error: Error, operation: SourceOperation,
                               sourceFamily: String, host: String,
                               observedAt: Date = .now) -> SourceAttempt {
        var kind: SourceOutcomeKind = .parserFailure
        var status: Int?
        var code: String?
        var attempts: Int?

        switch error {
        case SudrfError.captchaRequired:
            kind = .captcha
        case SudrfError.caseCardTemporarilyUnavailable, SudrfError.sourceMaintenance:
            kind = .maintenance
        case SudrfError.http(let value):
            kind = .transportFailure
            status = value
        case SudrfError.transientNetworkError(_, let value, let count):
            kind = .transportFailure
            code = String(value.rawValue)
            attempts = count
        case let value as URLError:
            kind = .transportFailure
            code = String(value.code.rawValue)
        default:
            break
        }

        return SourceAttempt(
            kind: kind,
            provenance: SourceProvenance(operation: operation,
                                         sourceFamily: sourceFamily, host: host,
                                         observedAt: observedAt, httpStatus: status,
                                         errorCode: code, attemptCount: attempts))
    }
}

/// Typed search boundary shared by federal and magistrate adapters. Callers no
/// longer have to infer whether an empty array means a valid zero or a failed
/// response; runtime continuation data stays out of persisted provenance.
public extension CaseProviding {
    func searchOutcome(court: Court, cartoteka: Cartoteka,
                       field: SearchField, value: String,
                       operation: SourceOperation = .search) async
        throws -> SourceOutcome<[CaseSearchResult]> {
        let family = court.level == .magistrate ? "msudrf" : "sudrf"
        do {
            let rows = try await search(court: court, cartoteka: cartoteka,
                                        field: field, value: value)
            let kind: SourceOutcomeKind = rows.isEmpty ? .honestZero : .usableSnapshot
            let attempt = SourceAttempt(
                kind: kind,
                provenance: SourceProvenance(operation: operation, sourceFamily: family,
                                             host: court.domain))
            return rows.isEmpty ? .honestZero(attempt) : .usableSnapshot(rows, attempt)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw error
        } catch SudrfError.captchaRequired(let formURL) {
            let attempt = SourceOutcomeClassifier.attempt(
                for: SudrfError.captchaRequired(formURL: formURL), operation: operation,
                sourceFamily: family, host: court.domain)
            return .captcha(formURL: formURL, attempt)
        } catch {
            let attempt = SourceOutcomeClassifier.attempt(
                for: error, operation: operation, sourceFamily: family, host: court.domain)
            let message = (error as? SudrfError)?.description ?? error.localizedDescription
            switch attempt.kind {
            case .maintenance: return .maintenance(message: message, attempt)
            case .transportFailure: return .transportFailure(message: message, attempt)
            default: return .parserFailure(message: message, attempt)
            }
        }
    }
}

public extension SearchPageKind {
    var sourceOutcomeKind: SourceOutcomeKind {
        switch self {
        case .results: .usableSnapshot
        case .empty: .honestZero
        case .captcha, .captchaRejected: .captcha
        case .maintenance: .maintenance
        case .unrecognized: .parserFailure
        }
    }
}
