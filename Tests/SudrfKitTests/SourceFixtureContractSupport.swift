import CryptoKit
import Foundation
import XCTest
@testable import SudrfKit

// MARK: - Manifest

enum SourceFixtureContractError: Error, LocalizedError, CustomStringConvertible {
    case missingManifest
    case malformed(String)
    case missingFile(String)
    case invalidDigest(String)
    case digestMismatch(String, expected: String, actual: String)
    case unsupportedCharset(String)
    case invalidCharset(String)
    case unexpectedRequest(fixtureID: String, url: String)
    case missingInput(fixtureID: String, field: String)
    case unsupportedInput(fixtureID: String, value: String)

    var description: String {
        switch self {
        case .missingManifest:
            return "source-contract index.json is missing"
        case .malformed(let message):
            return "source-contract manifest is malformed: \(message)"
        case .missingFile(let path):
            return "source-contract file is missing: \(path)"
        case .invalidDigest(let value):
            return "invalid SHA-256 digest: \(value)"
        case let .digestMismatch(path, expected, actual):
            return "SHA-256 mismatch for \(path): expected \(expected), got \(actual)"
        case .unsupportedCharset(let value):
            return "unsupported fixture charset: \(value)"
        case .invalidCharset(let message):
            return "invalid fixture charset: \(message)"
        case let .unexpectedRequest(fixtureID, url):
            return "fixture \(fixtureID) received unexpected request: \(url)"
        case let .missingInput(fixtureID, field):
            return "fixture \(fixtureID) is missing runner input: \(field)"
        case let .unsupportedInput(fixtureID, value):
            return "fixture \(fixtureID) has unsupported runner input: \(value)"
        }
    }

    var errorDescription: String? { description }
}

enum SourceFixtureContractLevel: String, Decodable {
    case L1
}

/// Deliberately closed: a fixture cannot silently opt into an unimplemented
/// adapter by adding an arbitrary string to the manifest.
enum SourceFixtureRunner: String, Decodable {
    case sudrfCard
    case sudrfPage
    case magistratePage
    case mosGorSudSearch
    case vsrfSearch
}

enum SourceFixtureOrigin: String, Decodable {
    case liveResponse
    case webArchive
    case diagnostic
    case canaryArtifact
}

enum SourceFixtureNormalization: String, Decodable {
    case searchOutcome
    case magistrateSearchOutcome
    case cardToMovement
    case cardOutcome
}

struct SourceFixtureManifest: Decodable {
    let schemaVersion: Int
    let fixtures: [SourceFixtureRecord]
    let missing: [SourceFixtureMissing]
}

struct SourceFixtureMissing: Decodable {
    let id: String
    let reason: String?
    let pathologies: [String]?
}

struct SourceFixtureRecord: Decodable, Identifiable {
    let id: String
    let contractLevel: SourceFixtureContractLevel
    let normalization: SourceFixtureNormalization
    let runner: SourceFixtureRunner
    let portalFamily: String
    let operation: SourceOperation
    let requestedHost: String
    let effectiveHost: String
    let httpStatus: Int?
    let contentType: String?
    let charset: String
    let capturedAt: Date?
    let relatedIssue: Int
    let origin: SourceFixtureOrigin
    let pathologies: [String]
    let redaction: SourceFixtureRedaction
    let artifacts: [SourceFixtureArtifact]
    let input: SourceFixtureInput?
    let expected: SourceFixtureExpected
}

struct SourceFixtureRedaction: Decodable {
    let status: String
    let originalSHA256: String?
    let committedSHA256: String
}

struct SourceFixtureArtifact: Decodable, Identifiable {
    let role: String
    let path: String
    let sha256: String
    let request: SourceFixtureRequest?

    var id: String { role + ":" + path }
}

struct SourceFixtureRequest: Decodable {
    let method: String
    let url: String
}

/// Input is explicit so a runner never derives case identity from a filename.
/// Additional fields keep the closed Moscow and Supreme Court adapters on
/// their production request builders.
struct SourceFixtureInput: Decodable {
    let courtTitle: String?
    let courtLevel: String?
    let cartotekaID: String?
    let caseNumber: String?
    let caseID: String?
    let caseUID: String?
    let courtAlias: String?
    let participant: String?
    let instance: Int?
    let processType: Int?
    let uniqueNumber: String?
    let oldCaseNumber: String?
    let keywords: String?
}

struct SourceFixtureExpected: Decodable {
    enum Kind: String, Decodable {
        case sourceAttempt
        case caseMovement
    }

    let kind: Kind
    let path: String
}

struct SourceFixtureLoadedArtifact: Sendable {
    let descriptor: SourceFixtureArtifact
    let url: URL
    let data: Data
    let text: String
}

struct SourceFixtureCatalog {
    let manifest: SourceFixtureManifest
    /// Paths in the manifest are relative to `Fixtures/source-contract`, so
    /// `../sgs_1inst.html` can safely refer to an existing legacy fixture.
    let baseURL: URL
    let fixtureRootURL: URL

    static func load() throws -> SourceFixtureCatalog {
        guard let manifestURL = Bundle.module.url(
            forResource: "index", withExtension: "json",
            subdirectory: "Fixtures/source-contract") else {
            throw SourceFixtureContractError.missingManifest
        }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: SourceFixtureManifest
        do {
            manifest = try decoder.decode(SourceFixtureManifest.self, from: data)
        } catch {
            throw SourceFixtureContractError.malformed(String(describing: error))
        }

        guard manifest.schemaVersion == 1 else {
            throw SourceFixtureContractError.malformed(
                "unsupported schemaVersion \(manifest.schemaVersion); expected 1")
        }
        guard !manifest.fixtures.isEmpty else {
            throw SourceFixtureContractError.malformed("fixtures must not be empty")
        }

        var ids = Set<String>()
        for fixture in manifest.fixtures {
            guard !fixture.id.isEmpty else {
                throw SourceFixtureContractError.malformed("fixture id must not be empty")
            }
            guard ids.insert(fixture.id).inserted else {
                throw SourceFixtureContractError.malformed("duplicate fixture id \(fixture.id)")
            }
            guard !fixture.portalFamily.isEmpty,
                  !fixture.requestedHost.isEmpty,
                  !fixture.effectiveHost.isEmpty,
                  !fixture.charset.isEmpty,
                  !fixture.artifacts.isEmpty else {
                throw SourceFixtureContractError.malformed(
                    "fixture \(fixture.id) has incomplete source metadata")
            }
            _ = try SourceFixtureCharset(fixture.charset)
            guard isSHA256(fixture.redaction.committedSHA256) else {
                throw SourceFixtureContractError.invalidDigest(
                    fixture.redaction.committedSHA256)
            }
            if let original = fixture.redaction.originalSHA256,
               !isSHA256(original) {
                throw SourceFixtureContractError.invalidDigest(original)
            }
            for artifact in fixture.artifacts {
                guard !artifact.role.isEmpty, !artifact.path.isEmpty else {
                    throw SourceFixtureContractError.malformed(
                        "fixture \(fixture.id) has incomplete artifact metadata")
                }
                guard isSHA256(artifact.sha256) else {
                    throw SourceFixtureContractError.invalidDigest(artifact.sha256)
                }
                if let request = artifact.request {
                    guard !request.method.isEmpty, URL(string: request.url)?.scheme != nil else {
                        throw SourceFixtureContractError.malformed(
                            "fixture \(fixture.id) has invalid replay request")
                    }
                }
            }
            guard !fixture.expected.path.isEmpty else {
                throw SourceFixtureContractError.malformed(
                    "fixture \(fixture.id) has empty expected path")
            }
        }

        let baseURL = manifestURL.deletingLastPathComponent()
        return SourceFixtureCatalog(
            manifest: manifest,
            baseURL: baseURL,
            fixtureRootURL: baseURL.deletingLastPathComponent())
    }

    func loadArtifacts(for fixture: SourceFixtureRecord) throws -> [SourceFixtureLoadedArtifact] {
        try fixture.artifacts.enumerated().map { index, artifact in
            let url = try resolve(artifact.path, fixtureID: fixture.id)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SourceFixtureContractError.missingFile(artifact.path)
            }
            let data = try Data(contentsOf: url)
            let actual = sha256(data)
            guard actual == artifact.sha256 else {
                throw SourceFixtureContractError.digestMismatch(
                    artifact.path, expected: artifact.sha256, actual: actual)
            }
            // Redaction is record-level in manifest v1.  It describes the
            // first (primary) artifact; every artifact still has its own
            // independently verified SHA-256 above.
            guard index != fixture.artifacts.startIndex
                    || fixture.redaction.committedSHA256 == actual else {
                throw SourceFixtureContractError.digestMismatch(
                    "\(fixture.id) redaction.committedSHA256",
                    expected: fixture.redaction.committedSHA256, actual: actual)
            }
            guard let text = try SourceFixtureCharset(fixture.charset).decode(data) else {
                throw SourceFixtureContractError.invalidCharset(
                    "\(fixture.id): bytes are not valid \(fixture.charset)")
            }
            return SourceFixtureLoadedArtifact(descriptor: artifact, url: url,
                                               data: data, text: text)
        }
    }

    func expectedURL(for fixture: SourceFixtureRecord) throws -> URL {
        try resolve(fixture.expected.path, fixtureID: fixture.id)
    }

    private func resolve(_ path: String, fixtureID: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw SourceFixtureContractError.malformed(
                "fixture \(fixtureID) path must be relative: \(path)")
        }
        let url = baseURL.appendingPathComponent(path).standardizedFileURL
        let root = fixtureRootURL.standardizedFileURL.path
        guard url.path == root || url.path.hasPrefix(root + "/") else {
            throw SourceFixtureContractError.malformed(
                "fixture \(fixtureID) path escapes Fixtures: \(path)")
        }
        return url
    }
}

// MARK: - Charset and digest

private enum SourceFixtureCharset {
    case utf8
    case windows1251

    init(_ raw: String) throws {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: "-") {
        case "utf-8", "utf8": self = .utf8
        case "windows-1251", "cp1251", "windows1251": self = .windows1251
        default: throw SourceFixtureContractError.unsupportedCharset(raw)
        }
    }

    func decode(_ data: Data) -> String? {
        switch self {
        case .utf8:
            return String(data: data, encoding: .utf8)
        case .windows1251:
            // Deliberately no lossy conversion and no UTF-8 fallback: the
            // manifest's charset is part of the raw-response contract.
            return String(data: data, encoding: Cyrillic1251.encoding)
        }
    }
}

private func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy {
        switch $0.value {
        case 48...57, 97...102: return true
        default: return false
        }
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Offline URLSession replay

final class SourceFixtureReplayURLProtocol: URLProtocol {
    private struct Response: Sendable {
        let data: Data
        let statusCode: Int
        let contentType: String
    }

    private struct State: Sendable {
        let fixtureID: String
        let effectiveHost: String
        let responses: [String: Response]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state: State?

    static func install(fixtureID: String, effectiveHost: String,
                        artifacts: [SourceFixtureLoadedArtifact],
                        statusCode: Int, contentType: String?) throws -> URLSession {
        var responses: [String: Response] = [:]
        for artifact in artifacts {
            guard let request = artifact.descriptor.request else { continue }
            guard let url = URL(string: request.url), url.scheme != nil else {
                throw SourceFixtureContractError.malformed(
                    "fixture \(fixtureID) has invalid request URL \(request.url)")
            }
            let key = requestKey(method: request.method, url: url.absoluteString)
            guard responses[key] == nil else {
                throw SourceFixtureContractError.malformed(
                    "fixture \(fixtureID) repeats replay request \(request.url)")
            }
            responses[key] = Response(
                data: artifact.data,
                statusCode: statusCode,
                contentType: contentType ?? "text/html")
        }

        lock.lock()
        state = State(fixtureID: fixtureID, effectiveHost: effectiveHost,
                      responses: responses)
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceFixtureReplayURLProtocol.self]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = HTTPCookieStorage()
        return URLSession(configuration: configuration)
    }

    static func uninstall(fixtureID: String) {
        lock.lock()
        if state?.fixtureID == fixtureID { state = nil }
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme?.lowercased() == "http"
            || request.url?.scheme?.lowercased() == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current: State? = {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            return Self.state
        }()
        guard let current else {
            fail(SourceFixtureContractError.unexpectedRequest(
                fixtureID: "<uninstalled>", url: request.url?.absoluteString ?? "<nil>"))
            return
        }
        let url = request.url?.absoluteString ?? "<nil>"
        let key = Self.requestKey(method: request.httpMethod ?? "GET", url: url)
        guard let response = current.responses[key], let responseURL = request.url else {
            fail(SourceFixtureContractError.unexpectedRequest(fixtureID: current.fixtureID, url: url))
            return
        }
        let finalURL = Self.effectiveURL(responseURL, host: current.effectiveHost)
        guard let http = HTTPURLResponse(
            url: finalURL,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": response.contentType]) else {
            fail(SourceFixtureContractError.malformed(
                "fixture \(current.fixtureID) replay response has invalid URL \(url)"))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func fail(_ error: Error) {
        let delivered: Error
        if let error = error as? SourceFixtureContractError {
            delivered = NSError(
                domain: "SourceFixtureReplay",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error.description])
        } else {
            delivered = error
        }
        client?.urlProtocol(self, didFailWithError: delivered)
    }

    private static func requestKey(method: String, url: String) -> String {
        method.uppercased() + " " + url
    }

    private static func effectiveURL(_ requestURL: URL, host: String) -> URL {
        let effectiveHost = URL(string: host)?.host ?? host
        guard !effectiveHost.isEmpty,
              var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        else { return requestURL }
        components.host = effectiveHost
        return components.url ?? requestURL
    }
}

private final class SourceFixtureReplay {
    let session: URLSession
    private let fixtureID: String

    init(fixture: SourceFixtureRecord, artifacts: [SourceFixtureLoadedArtifact]) throws {
        fixtureID = fixture.id
        session = try SourceFixtureReplayURLProtocol.install(
            fixtureID: fixture.id,
            effectiveHost: fixture.effectiveHost,
            artifacts: artifacts,
            statusCode: fixture.httpStatus ?? 200,
            contentType: fixture.contentType)
    }

    func close() {
        session.invalidateAndCancel()
        SourceFixtureReplayURLProtocol.uninstall(fixtureID: fixtureID)
    }

    deinit { close() }
}

// MARK: - Existing adapter runners

enum SourceFixtureResult: Sendable {
    case movement(CaseMovement)
    case attempt(SourceAttempt)
}

struct SourceFixtureRunnerSupport {
    let catalog: SourceFixtureCatalog

    func run(_ fixture: SourceFixtureRecord) async throws -> SourceFixtureResult {
        let artifacts = try catalog.loadArtifacts(for: fixture)
        let replay = try SourceFixtureReplay(fixture: fixture, artifacts: artifacts)
        defer { replay.close() }

        switch fixture.runner {
        case .sudrfCard:
            let card = try await fetchCard(fixture, artifacts: artifacts, session: replay.session)
            if fixture.expected.kind == .caseMovement {
                return .movement(try await movement(
                    fixture, card: card, baseURL: artifacts.first?.descriptor.request?.url))
            }
            return .attempt(usableAttempt(for: fixture))

        case .sudrfPage:
            return .attempt(try await sudrfPageAttempt(
                fixture, artifacts: artifacts, session: replay.session))

        case .magistratePage:
            return .attempt(try await magistratePageAttempt(
                fixture, artifacts: artifacts, session: replay.session))

        case .mosGorSudSearch:
            let input = fixture.input
            let instance = input?.instance ?? 1
            let processType = try makeProcessType(fixture, input: input)
            guard let requestURL = MosGorSudEndpoint.searchURL(
                courtAlias: input?.courtAlias,
                uid: input?.uniqueNumber ?? input?.caseUID,
                caseNumber: input?.oldCaseNumber ?? input?.caseNumber,
                participant: input?.participant,
                instance: instance,
                processType: processType) else {
                throw SourceFixtureContractError.malformed(
                    "fixture \(fixture.id) could not build Moscow request")
            }
            try validateRequest(requestURL, fixture: fixture, artifacts: artifacts)
            let client = MosGorSudClient(session: replay.session, minInterval: 0)
            do {
                let rows = try await client.search(
                    courtAlias: input?.courtAlias,
                    uid: input?.uniqueNumber ?? input?.caseUID,
                    caseNumber: input?.oldCaseNumber ?? input?.caseNumber,
                    participant: input?.participant,
                    instance: instance,
                    processType: processType)
                let kind: SourceOutcomeKind = rows.isEmpty ? .honestZero : .usableSnapshot
                return .attempt(SourceAttempt(
                    kind: kind,
                    provenance: SourceProvenance(
                        operation: fixture.operation, sourceFamily: fixture.portalFamily,
                        host: fixture.effectiveHost)))
            } catch let error as SourceFixtureContractError {
                throw error
            } catch {
                return .attempt(SourceOutcomeClassifier.attempt(
                    for: error, operation: fixture.operation,
                    sourceFamily: fixture.portalFamily, host: fixture.effectiveHost))
            }

        case .vsrfSearch:
            let input = fixture.input
            guard let requestURL = VSRFEndpoint.searchURL(
                uniqueNumber: input?.uniqueNumber ?? input?.caseUID,
                oldCaseNumber: input?.oldCaseNumber ?? input?.caseNumber,
                keywords: input?.keywords) else {
                throw SourceFixtureContractError.malformed(
                    "fixture \(fixture.id) could not build VSRF request")
            }
            try validateRequest(requestURL, fixture: fixture, artifacts: artifacts)
            let client = VSRFClient(session: replay.session, minInterval: 0)
            do {
                let value = try await client.search(
                    uniqueNumber: input?.uniqueNumber ?? input?.caseUID,
                    oldCaseNumber: input?.oldCaseNumber ?? input?.caseNumber,
                    keywords: input?.keywords)
                let kind: SourceOutcomeKind = value.results.isEmpty ? .honestZero : .usableSnapshot
                return .attempt(SourceAttempt(
                    kind: kind,
                    provenance: SourceProvenance(
                        operation: fixture.operation, sourceFamily: fixture.portalFamily,
                        host: fixture.effectiveHost)))
            } catch let error as SourceFixtureContractError {
                throw error
            } catch {
                return .attempt(SourceOutcomeClassifier.attempt(
                    for: error, operation: fixture.operation,
                    sourceFamily: fixture.portalFamily, host: fixture.effectiveHost))
            }
        }
    }

    private func fetchCard(_ fixture: SourceFixtureRecord,
                           artifacts: [SourceFixtureLoadedArtifact],
                           session: URLSession) async throws -> CaseCard {
        let client = SudrfClient(session: session, minInterval: 0)
        if let request = artifacts.first(where: { $0.descriptor.request != nil })?
            .descriptor.request,
           let url = URL(string: request.url) {
            return try await client.fetchCard(url: url)
        }
        guard let first = artifacts.first else {
            throw SourceFixtureContractError.malformed(
                "fixture \(fixture.id) has no card artifact")
        }
        return try CaseCardParser.parse(html: first.text)
    }

    private func movement(_ fixture: SourceFixtureRecord, card: CaseCard,
                          baseURL: String?) async throws -> CaseMovement {
        let court = try makeCourt(fixture)
        let cartoteka = try makeCartoteka(fixture, courtLevel: court.level)
        let input = fixture.input
        let caseNumber = input?.caseNumber ?? card.caseNumber ?? "fixture-\(fixture.id)"
        // MovementService intentionally returns a minimal movement when a
        // search row has no safe card identity.  A standalone card fixture is
        // already the trusted card response, so use inert identifiers only to
        // enter the normal card path; they never leave the normalized output.
        let forceCardFetch = input?.caseID == nil && input?.caseUID == nil
        let base = CaseSearchResult(
            caseNumber: caseNumber,
            caseID: input?.caseID ?? (forceCardFetch ? "fixture-card" : nil),
            caseUID: input?.caseUID ?? (forceCardFetch ? "fixture-card" : nil),
            cardURL: baseURL.flatMap(URL.init(string:)))
        let provider = SourceFixtureCardProvider(card: card)
        var value = try await MovementService(client: provider, higherCourtDomains: [])
            .movement(for: base, court: court, cartoteka: cartoteka)
        if forceCardFetch {
            // The expected artifact intentionally carries no fabricated URL.
            // Keep the parser/service output while removing the inert URL.
            value.instances = value.instances.map { instance in
                var instance = instance
                instance.sourceURL = nil
                return instance
            }
        }
        return value
    }

    private func sudrfPageAttempt(
        _ fixture: SourceFixtureRecord,
        artifacts: [SourceFixtureLoadedArtifact],
        session: URLSession
    ) async throws -> SourceAttempt {
        let court = try makeCourt(fixture)
        let page = try await fetchFixturePage(
            fixture, artifacts: artifacts, session: session)
        let kind = SearchPageClassifier.classify(html: page.html)
        if kind == .results {
            _ = try ResultsParser.parse(
                html: page.html, court: court.withDomain(page.effectiveHost))
        }
        return SourceAttempt(
            kind: kind.sourceOutcomeKind,
            provenance: SourceProvenance(
                operation: fixture.operation,
                sourceFamily: fixture.portalFamily,
                host: page.effectiveHost))
    }

    private func magistratePageAttempt(
        _ fixture: SourceFixtureRecord,
        artifacts: [SourceFixtureLoadedArtifact],
        session: URLSession
    ) async throws -> SourceAttempt {
        let court = try makeCourt(fixture, defaultLevel: .magistrate)
        let page = try await fetchFixturePage(
            fixture, artifacts: artifacts, session: session)
        let kind = MagistratePageClassifier.classify(html: page.html)
        if kind == .results {
            _ = try MagistrateResultsParser.parse(
                html: page.html, court: court.withDomain(page.effectiveHost))
        }
        return SourceAttempt(
            kind: kind.sourceOutcomeKind,
            provenance: SourceProvenance(
                operation: fixture.operation,
                sourceFamily: fixture.portalFamily,
                host: page.effectiveHost))
    }

    private struct FixturePage {
        let html: String
        let effectiveHost: String
    }

    private func fetchFixturePage(
        _ fixture: SourceFixtureRecord,
        artifacts: [SourceFixtureLoadedArtifact],
        session: URLSession
    ) async throws -> FixturePage {
        guard let request = artifacts.first(where: { $0.descriptor.request != nil })?
            .descriptor.request,
              let url = URL(string: request.url) else {
            throw SourceFixtureContractError.missingInput(
                fixtureID: fixture.id, field: "artifacts[].request")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw SourceFixtureContractError.malformed(
                "fixture \(fixture.id) replay did not return HTTPURLResponse")
        }
        guard http.statusCode == (fixture.httpStatus ?? 200) else {
            throw SourceFixtureContractError.malformed(
                "fixture \(fixture.id) replay returned HTTP \(http.statusCode)")
        }
        guard let html = try SourceFixtureCharset(fixture.charset).decode(data) else {
            throw SourceFixtureContractError.invalidCharset(
                "\(fixture.id): replay bytes are not valid \(fixture.charset)")
        }
        return FixturePage(
            html: html,
            effectiveHost: response.url?.host?.lowercased()
                ?? url.host?.lowercased()
                ?? fixture.requestedHost)
    }

    private func makeCourt(_ fixture: SourceFixtureRecord,
                           defaultLevel: CourtLevel? = nil) throws -> Court {
        let input = fixture.input
        let level: CourtLevel
        if let raw = input?.courtLevel, let parsed = CourtLevel(rawValue: raw) {
            level = parsed
        } else if let defaultLevel {
            level = defaultLevel
        } else {
            throw SourceFixtureContractError.missingInput(
                fixtureID: fixture.id, field: "input.courtLevel")
        }
        let domain = host(fixture.requestedHost)
        let title = input?.courtTitle ?? fixture.effectiveHost
        return Court(domain: domain, title: title, level: level)
    }

    private func makeCartoteka(_ fixture: SourceFixtureRecord,
                               courtLevel: CourtLevel) throws -> Cartoteka {
        guard let id = fixture.input?.cartotekaID else {
            throw SourceFixtureContractError.missingInput(
                fixtureID: fixture.id, field: "input.cartotekaID")
        }
        guard let value = CartotekaRegistry.find(level: courtLevel, id: id) else {
            throw SourceFixtureContractError.unsupportedInput(
                fixtureID: fixture.id, value: "cartotekaID=\(id) at \(courtLevel.rawValue)")
        }
        return value
    }

    private func makeProcessType(_ fixture: SourceFixtureRecord,
                                 input: SourceFixtureInput?) throws -> MosGorSudProcessType {
        guard let raw = input?.processType else {
            return .civil
        }
        guard let value = MosGorSudProcessType(rawValue: raw) else {
            throw SourceFixtureContractError.unsupportedInput(
                fixtureID: fixture.id, value: "processType=\(raw)")
        }
        return value
    }

    private func validateRequest(
        _ url: URL,
        fixture: SourceFixtureRecord,
        artifacts: [SourceFixtureLoadedArtifact]
    ) throws {
        let expected = artifacts.compactMap(\.descriptor.request).map {
            $0.method.uppercased() + " " + $0.url
        }
        let actual = "GET " + url.absoluteString
        guard expected.contains(actual) else {
            throw SourceFixtureContractError.unexpectedRequest(
                fixtureID: fixture.id, url: url.absoluteString)
        }
    }

    private func usableAttempt(for fixture: SourceFixtureRecord) -> SourceAttempt {
        SourceAttempt(
            kind: .usableSnapshot,
            provenance: SourceProvenance(
                operation: fixture.operation,
                sourceFamily: fixture.portalFamily,
                host: fixture.effectiveHost))
    }

    private func host(_ value: String) -> String {
        if let parsed = URL(string: value)?.host { return parsed }
        return value.split(whereSeparator: { "/?#".contains($0) }).first
            .map(String.init) ?? value
    }
}

private actor SourceFixtureCardProvider: CaseProviding {
    let card: CaseCard

    init(card: CaseCard) { self.card = card }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] { [] }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard { card }

    func fetchCard(url: URL) async throws -> CaseCard { card }
}
