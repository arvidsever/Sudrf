import Foundation
import CryptoKit
import XCTest
@testable import SudrfKit
@testable import CaptchaSolver
@testable import SudrfApp

/// Opt-in network acceptance. Private references and results never enter repository fixtures.
@MainActor
final class Issue241LiveAcceptanceTests: XCTestCase {
    private struct Reference: Decodable {
        let label: String
        let uid: String
        let cartotekaID: String
        let number: String
        let requiresAct: Bool
    }

    func testLiveUIDDiscoveryCardActAndDiskReopen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SUDRF_241_LIVE"] == "1" else {
            throw XCTSkip("#241 live acceptance is opt-in")
        }
        let referencePath = try XCTUnwrap(env["SUDRF_241_REFERENCES"])
        let outputPath = try XCTUnwrap(env["SUDRF_241_OUTPUT"])
        let attempt = try XCTUnwrap(env["SUDRF_241_ATTEMPT"].flatMap(Int.init))
        XCTAssertTrue((1...3).contains(attempt))
        guard (1...3).contains(attempt) else { return }
        let directory = URL(fileURLWithPath: outputPath).appendingPathComponent("run-\(attempt)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let references = try JSONDecoder().decode([Reference].self,
            from: Data(contentsOf: URL(fileURLWithPath: referencePath)))
        guard references.count == 2, Set(references.map(\.label)) == Set(["A", "B"]) else {
            return XCTFail("#241 requires exactly two private references A and B")
        }
        let oldDiagnostics = SearchDiagnostics.setDirForTesting(directory)
        defer { SearchDiagnostics.setDirForTesting(oldDiagnostics) }
        let tokens = CaptchaTokenStore.shared // RefreshCenter's native continuation uses this process-only actor.
        await tokens.invalidate(domain: "3kas.sudrf.ru")
        defer { Task { await tokens.invalidate(domain: "3kas.sudrf.ru") } }
        let client = SudrfClient(sessionFactory: { delegate in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = SudrfClient.requestTimeout
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        }, trustCourtCertificates: true, variantStore: WorkingVariantStore(cacheURL: nil),
           captchaStore: tokens)
        let solver = try makeSolver(directory: directory)
        let settings = CaptchaSettings.shared // XCTest process domain, never ru.sudrf.app preferences.
        guard settings.isEffectivelyEnabled else {
            return XCTFail("#241 requires native automatic CAPTCHA solving")
        }
        let court = Court(domain: "3kas.sudrf.ru", title: "Третий кассационный суд", level: .cassation)
        var report: [[String: Any]] = []
        for reference in references {
            let started = Date()
            do {
                let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .cassation, id: reference.cartotekaID))
                let rows: [CaseSearchResult]
                do {
                    rows = try await client.search(court: court, cartoteka: cartoteka,
                                                   field: .uid, value: reference.uid)
                } catch SudrfError.captchaRequired(let formURL) {
                    let solved = await AutoCaptchaSolver.solve(formURL: formURL, client: client,
                                                                solver: solver, settings: settings.autoSolverSettings)
                    guard let token = solved.token else { throw LiveFailure.captchaExhausted }
                    await tokens.store(token, domain: court.domain)
                    rows = try await client.search(court: court, cartoteka: cartoteka,
                                                   field: .uid, value: reference.uid)
                }
                let matches = rows.filter { $0.caseNumber == reference.number }
                guard matches.count == 1, let row = matches.first, let url = row.cardURL else {
                    throw LiveFailure.discovery
                }
                let parsed = try SudrfCaseCardLink(url: url)
                let context = MovementContext(
                    branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
                    searchDomain: court.domain, displayDomain: court.domain, courtTitle: court.title,
                    courtLevelRaw: court.level.rawValue, cartotekaId: cartoteka.id,
                    cartotekaLevelRaw: court.level.rawValue, caseNumber: row.caseNumber,
                    caseID: row.caseID, caseUID: row.caseUID, cardURLString: url.absoluteString,
                    judicialUID: reference.uid, baseInstanceLevelRaw: CaseInstance.Level.cassation.rawValue,
                    higherCourtTargets: [])
                let storeURL = directory.appendingPathComponent("\(reference.label).store")
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
                let store = try TrackedStore(container: container, prepared: true)
                let record = try store.upsert(context: context, snapshot: nil, movement: nil,
                                             collections: ["Изолированная приёмка"])
                try store.save()
                let center = RefreshCenter(store: store, client: client, captchaSolver: solver,
                                           captchaSettings: settings,
                                           serviceBuilder: { ctx in ctx.makeService(client: client) },
                                           fsspAutoModelEnabled: false)
                let refreshed = await center.refresh(key: record.key)?.value
                guard refreshed?.outcome == .refreshed, let movement = record.movement else {
                    try (center.lastErrors[record.key] ?? "refresh incomplete").write(
                        to: directory.appendingPathComponent("\(reference.label)-refresh-error.txt"),
                        atomically: true, encoding: .utf8)
                    throw LiveFailure.refresh
                }
                let instance = try XCTUnwrap(movement.instances.first { $0.caseNumber == reference.number })
                guard movement.uid == reference.uid,
                      instance.sourceURL == parsed.sanitizedURL else { throw LiveFailure.sourceURL }
                let displayed = CourtActPresentation.rows(in: movement)
                    .filter { $0.instanceLevel == .cassation && !$0.text.isEmpty
                        && $0.sourceIDs.contains(where: instance.linkedActIDs.contains) }
                guard !instance.sessions.isEmpty, !reference.requiresAct || !displayed.isEmpty else {
                    throw LiveFailure.cardOrAct
                }
                let journal = record.eventJournal
                let savedActs = movement.acts
                let savedBodies = movement.actBodies
                let html = try await client.fetchHTML(url)
                try html.write(to: directory.appendingPathComponent("\(reference.label)-card-decoded.html"),
                               atomically: true, encoding: .utf8)
                let bytes = try JSONEncoder().encode(movement)
                try bytes.write(to: directory.appendingPathComponent("\(reference.label)-movement.json"), options: .atomic)
                let reopened = try TrackedStore(container: SudrfModelContainerFactory.make(
                    inMemory: false, storeURL: storeURL), prepared: true)
                let persisted = try XCTUnwrap(reopened.record(forKey: record.key)?.movement)
                guard persisted == movement,
                      persisted.instances.first(where: { $0.caseNumber == reference.number })?.sourceURL == parsed.sanitizedURL,
                      persisted.acts == savedActs, persisted.actBodies == savedBodies,
                      CourtActPresentation.rows(in: persisted).map(\.id) == CourtActPresentation.rows(in: movement).map(\.id)
                else { throw LiveFailure.persistence }
                // Refresh the saved production through the same native service/client path.
                let repeated = await center.refresh(key: record.key)?.value
                guard repeated?.outcome == .refreshed else { throw LiveFailure.repeatRefresh }
                guard record.eventJournal == journal,
                      record.movement?.instances.filter({ $0.caseNumber == reference.number }).count == 1,
                      record.movement?.instances.first(where: { $0.caseNumber == reference.number })?.sourceURL == parsed.sanitizedURL,
                      record.movement?.acts == savedActs, record.movement?.actBodies == savedBodies
                else { throw LiveFailure.repeatPersistence }
                let finalStore = try TrackedStore(container: SudrfModelContainerFactory.make(
                    inMemory: false, storeURL: storeURL), prepared: true)
                guard finalStore.record(forKey: record.key)?.movement == record.movement,
                      finalStore.record(forKey: record.key)?.eventJournal == journal
                else { throw LiveFailure.repeatPersistence }
                report.append(["reference": reference.label, "status": "success",
                    "startedAt": ISO8601DateFormatter().string(from: started),
                    "finishedAt": ISO8601DateFormatter().string(from: Date()),
                    "events": instance.sessions.count, "displayedActs": displayed.count,
                    "movementSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()])
            } catch {
                // Avoid leaking source URLs/captcha query strings in public XCTest output.
                report.append(["reference": reference.label, "status": "incomplete",
                    "startedAt": ISO8601DateFormatter().string(from: started),
                    "finishedAt": ISO8601DateFormatter().string(from: Date()),
                    "errorType": String(describing: type(of: error))])
                let privateError = String(describing: error)
                try privateError.write(to: directory.appendingPathComponent("\(reference.label)-error.txt"),
                                       atomically: true, encoding: .utf8)
                XCTFail("#241 \(reference.label): live criterion incomplete; see private evidence")
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
    }

    private enum LiveFailure: Error {
        case captchaExhausted, discovery, refresh, cardOrAct, repeatRefresh, sourceURL, persistence, repeatPersistence
    }

    private func makeSolver(directory: URL) throws -> CaptchaSolver {
        // Native production providers, default threshold, with only logging redirected.
        let vision = VisionOCRStrategy()
        var provider: any CaptchaSolvingProvider = vision
        let modelDirectory = try XCTUnwrap(ProcessInfo.processInfo.environment["SUDRF_241_MODEL_DIR"])
        let url = URL(fileURLWithPath: modelDirectory)
            .appendingPathComponent("model-captcha-numeric.mlmodelc")
        let coreML = try CoreMLCaptchaStrategy(modelURL: url, kind: .sudrfToken)
        do {
            var numeric: any CaptchaSolvingProvider = coreML
            if let specialistURL = CoreMLModelDiscovery.discoverNumericSpecialistURL(beside: url),
               let specialist = try? CoreMLCaptchaStrategy(modelURL: specialistURL, kind: .sudrfToken) {
                numeric = HighestConfidenceStrategy(first: coreML, second: specialist)
            }
            provider = KindDispatchingStrategy(primary: numeric, fallback: vision,
                minPrimaryConfidence: 0.55,
                primaryAttemptIsCompatible: { CoreMLCaptchaStrategy.isCompatibleOutput($0.value) })
        }
        return CaptchaSolver(provider: provider, log: CaptchaSolverLog(
            fileURL: directory.appendingPathComponent("captcha-private.log"),
            failuresDir: directory, diagnosticsDir: directory))
    }
}
