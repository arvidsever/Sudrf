// © 2026 Воробьёв Виктор Викторович. SPDX-License-Identifier: CC-BY-NC-ND-4.0
import Foundation
import AppKit
import CryptoKit
import Synchronization
import XCTest
@testable import SudrfKit
@testable import SudrfApp
@testable import CaptchaSolver

/// Explicitly opt-in; no AppRouter, UI, background timer or system publication.
@MainActor
final class Issue322LiveAcceptanceTests: XCTestCase {
    func testLiveOriginalChainsThroughRepairRefreshDiskAndRepeat() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SUDRF_322_LIVE"] == "1" else { throw XCTSkip("#322 live acceptance is opt-in") }
        guard Bundle.main.bundleIdentifier != "ru.sudrf.app", NSApp == nil else { return XCTFail("Production app or AppKit instance is forbidden") }
        let manifestURL = URL(fileURLWithPath: try XCTUnwrap(env["SUDRF_322_MANIFEST"]))
        let bytes = try Data(contentsOf: manifestURL)
        guard Self.validSHA(bytes, expected: env["SUDRF_322_MANIFEST_SHA256"]) else { return XCTFail("Private manifest SHA mismatch") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
        try manifest.validate()
        try await execute(manifest: manifest, replay: false)
    }

    func testOfflineReplayUsesRealClientsRepairRefreshAndReopen() async throws {
        let output = "/private/tmp/sudrf-322-replay-\(UUID().uuidString)"
        let manifest = Manifest(outputRoot: output, sourceURLs: Self.sources, numericModel: "unused", specialistModel: "unused")
        try await execute(manifest: manifest, replay: true)
        try? FileManager.default.removeItem(atPath: output)
    }

    private func execute(manifest: Manifest, replay: Bool) async throws {
        let root = try Self.privateRoot(manifest.outputRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber == 0o700 else {
            return XCTFail("Private root permissions must be0700")
        }
        let directory = root.appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let priorDir = SearchDiagnostics.setDirForTesting(directory)
        let priorEnabled = SearchDiagnostics.setEnabledForTesting(false)
        defer { SearchDiagnostics.setDirForTesting(priorDir); SearchDiagnostics.setEnabledForTesting(priorEnabled) }
        // Raw responses are captured by the bounded transport, not the global dumper.
        let priorTransport = Issue322BoundedTransport.install(directory: directory, replay: replay)
        defer { Issue322BoundedTransport.restore(priorTransport) }
        let suite = "ru.sudrf.tests.issue322.live.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CaptchaSettings(defaults: defaults)
        let tokens = CaptchaTokenStore()
        let client = SudrfClient(sessionFactory: { delegate in
            URLSession(configuration: Issue322BoundedTransport.configuration(), delegate: delegate, delegateQueue: nil)
        }, trustCourtCertificates: false, variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: tokens)
        let moscowSession = URLSession(configuration: Issue322BoundedTransport.configuration())
        defer { moscowSession.invalidateAndCancel() }
        let moscow = MosGorSudClient(session: moscowSession)
        let vsrfSession = URLSession(configuration: Issue322BoundedTransport.configuration())
        defer { vsrfSession.invalidateAndCancel() }
        let vsrf: any VSRFProviding = replay ? Issue322RejectVS() : VSRFClient(session: vsrfSession)
        let solver: CaptchaSolver? = replay ? nil : try makeSolver(manifest: manifest, settings: settings)
        let district = DistrictCourtResolver(client: client, cacheURL: nil)
        let origin = CaseOriginResolver(client: client, districtResolver: district,
            magistrateResolver: MagistrateCourtResolver(client: client, cacheURL: nil),
            regularProvider: client, magistrateProvider: Issue322RejectCard(), moscowProvider: moscow)
        let storeURL = directory.appendingPathComponent("acceptance.store")
        var report: [[String: String]] = []
        func run(_ store: TrackedStore, phase: String) async throws {
            let repair = TrackedCaseRepairCoordinator(store: store, client: client, originResolver: origin,
                defaults: defaults, captchaSolver: solver, captchaSettings: settings, captchaStore: tokens)
            let center = RefreshCenter(store: store, client: client, captchaSolver: solver,
                captchaSettings: settings, captchaTokenStore: tokens, serviceBuilder: { context in
                    let targets = context.higherCourtTargets ?? context.cartoteka.flatMap {
                        MovementTargetBuilder.targets(branch: context.branch, courtLevel: context.courtLevel,
                            baseCartoteka: $0, caseNumber: context.caseNumber, judicialUID: context.judicialUID,
                            courtTitle: context.courtTitle, courtCode: context.courtCode, region: context.region,
                            displayDomain: context.displayDomain)
                    }
                    return MovementService(client: client, higherCourtDomains: context.expandedHigherDomains(),
                        higherCourtTargets: targets, knownCards: context.knownCards ?? [],
                        baseInstanceLevel: context.baseInstanceLevel, vsrf: vsrf, mosgorsud: moscow,
                        magistrate: Issue322RejectCard(), judicialUID: context.judicialUID, branch: context.branch,
                        transferCourts: { subject in try await district.allCourts(forSubjectCode: subject) })
                }, treasuryDiscover: { _, _, _ in throw GateFailure.unusedProvider },
                vsrfProvider: vsrf, fsspAutoModelEnabled: false,
                fsspDiscover: { _ in throw GateFailure.unusedProvider })
            center.repairBeforeRefresh = { key, force in
                try await repair.repairIfNeeded(key: key, forceAttempt: force).effectiveKey
            }
            let originalKeys = store.all().map(\.key)
            for (index, key) in originalKeys.enumerated() {
                guard store.record(forKey: key) != nil else { continue } // earlier ordinary repair merged this anchor
                let start = Date()
                let result = await center.refresh(key: key, manually: true)?.value
                let complete = result?.outcome == .refreshed
                let attempt = store.record(forKey: result?.effectiveKey ?? key)?.sourceRefreshAttempt
                let expectedReplayPartial: Bool
                if replay, case .partial? = result?.outcome {
                    expectedReplayPartial = attempt?.kind == .partial
                        && Set(attempt?.provenance.affectedSources ?? []) == Set(["2kas.sudrf.ru", "mos-gorsud.ru", "vsrf.ru"])
                } else { expectedReplayPartial = false }
                report.append(["phase": phase, "ordinal": String(index), "status": complete ? "complete" : expectedReplayPartial ? "expectedPartialReplay" : "partial",
                    "elapsedMillis": String(Int(Date().timeIntervalSince(start) * 1000))])
                try Self.privateWrite(JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                    to: directory.appendingPathComponent("report.json"))
                guard complete || expectedReplayPartial else {
                    try Self.privateWrite(Data((center.lastErrors[result?.effectiveKey ?? key] ?? "refresh incomplete").utf8),
                        to: directory.appendingPathComponent("private-stage-error.txt"))
                    if let attempt = store.record(forKey: result?.effectiveKey ?? key)?.sourceRefreshAttempt {
                        try Self.privateWrite(JSONEncoder().encode(attempt), to: directory.appendingPathComponent("private-source-attempt.json"))
                    }
                    if let movement = store.record(forKey: result?.effectiveKey ?? key)?.movement {
                        try Self.privateWrite(JSONEncoder().encode(movement), to: directory.appendingPathComponent("private-partial-movement.json"))
                    }
                    throw GateFailure.incomplete
                }
            }
        }
        let checkpoint: [String: CaseMovement]
        let journalCheckpoint: [String: Data?]
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            for context in try Self.originalContexts().prefix(replay ? 2 : 3) {
                _ = try store.upsert(context: context, snapshot: nil, movement: nil, collections: ["Private #322 acceptance"])
            }
            try store.save()
            try await run(store, phase: "first")
            try assertChains(store, replay: replay)
            checkpoint = try Dictionary(uniqueKeysWithValues: store.all().map { ($0.key, try XCTUnwrap($0.movement)) })
            journalCheckpoint = Dictionary(uniqueKeysWithValues: store.all().map { ($0.key, $0.eventJournalData) })
        }
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            XCTAssertEqual(Set(store.all().map(\.key)), Set(checkpoint.keys))
            for record in store.all() {
                XCTAssertEqual(record.movement, checkpoint[record.key])
                XCTAssertEqual(record.eventJournalData, journalCheckpoint[record.key] ?? nil)
            }
            try await run(store, phase: "repeat")
            try assertChains(store, replay: replay)
            XCTAssertEqual(Set(store.all().map(\.key)), Set(checkpoint.keys))
            for record in store.all() {
                let before = try XCTUnwrap(checkpoint[record.key])
                XCTAssertEqual(record.movement?.instances.map(\.id), before.instances.map(\.id))
                let oldData = try XCTUnwrap(journalCheckpoint[record.key] ?? nil)
                XCTAssertEqual(record.eventJournal, try JSONDecoder().decode(CaseEventJournal.self, from: oldData),
                    "Repeat retains the whole journal; JSON key order is not event identity")
            }
        }
        XCTAssertTrue(Issue322BoundedTransport.deniedHosts().isEmpty, "Unexpected host scope is partial acceptance")
    }

    func testAdditionalProvidersConstructPrivatelyAndScopeRemainsExact() throws {
        let session = URLSession(configuration: Issue322BoundedTransport.configuration())
        defer { session.invalidateAndCancel() }
        _ = VSRFClient(session: session)
        for host in ["sudrf.ru", "www.sudrf.ru", "vsrf.ru", "www.vsrf.ru"] {
            XCTAssertTrue(Issue322BoundedTransport.allowed(URL(string: "https://\(host)/")!))
            XCTAssertFalse(Issue322BoundedTransport.allowed(URL(string: "http://\(host)/")!))
            XCTAssertFalse(Issue322BoundedTransport.allowed(URL(string: "https://\(host).example.com/")!))
        }
        XCTAssertFalse(Issue322BoundedTransport.allowed(URL(string: "https://unknown.sudrf.ru/")!))
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
    }

    func testPreflightRejectsHTTPWrongSourceAndInvalidManifest() throws {
        XCTAssertFalse(Issue322BoundedTransport.allowed(URL(string: "http://1ap.sudrf.ru/modules.php")!))
        XCTAssertFalse(Issue322BoundedTransport.allowed(URL(string: "https://example.com/card")!))
        XCTAssertFalse(Issue322BoundedTransport.allowed(URL(string: "https://mos-gorsud.ru.example.com/card")!))
        XCTAssertTrue(Issue322BoundedTransport.allowed(URL(string: Self.sources[0])!))
        let invalid = Manifest(outputRoot: "/tmp", sourceURLs: Array(Self.sources.dropLast()),
            numericModel: "/tmp/missing", specialistModel: "/tmp/missing")
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertEqual(try Self.originalContexts().count, 3)
        XCTAssertFalse(Self.validSHA(Data("synthetic".utf8), expected: String(repeating: "0", count: 64)))
        XCTAssertTrue(Self.validSHA(Data("synthetic".utf8), expected: Self.sha(Data("synthetic".utf8))))
    }

    func testCrossOriginRedirectUsesOuterClientSessionRotation() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/sudrf-322-redirect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = URL(string: "https://1ap.sudrf.ru/issue322-redirect-start")!
        let target = URL(string: "https://2kas.sudrf.ru/issue322-redirect-target")!
        let previous = Issue322BoundedTransport.install(directory: root, replay: true, redirects: [initial: target])
        defer { Issue322BoundedTransport.restore(previous) }
        let events = Mutex<[String]>([])
        let client = SudrfClient(sessionFactory: { delegate in
            events.withLock { $0.append("create") }
            return URLSession(configuration: Issue322BoundedTransport.configuration(), delegate: delegate, delegateQueue: nil)
        }, minInterval: 0, trustCourtCertificates: false,
            sessionInvalidationObserver: { events.withLock { $0.append("invalidate") } },
            variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: CaptchaTokenStore())
        let html = try await client.fetchHTML(initial)
        XCTAssertTrue(html.contains("synthetic redirect target"))
        XCTAssertEqual(Issue322BoundedTransport.requests(), [initial, target])
        XCTAssertEqual(events.withLock { $0 }, ["create", "invalidate", "create"],
            "Only the ordinary outer client may rotate into the redirected origin")
    }

    func testExactChainRejectsUnverifiedExtraRegistration() {
        let expected = Set(["3а-3696/2020", "66а-2013/2020", "66а-4311/2020"])
        XCTAssertTrue(Self.exactChain(expected, expected: expected))
        let foreign = CaseInstance(level: .material, court: "Неподтверждённый суд",
            caseNumber: "13-1388/2023", judge: nil, domain: "1ap.sudrf.ru", foundByUID: false, result: nil, sessions: [],
            sourceURL: URL(string: "https://1ap.sudrf.ru/unverified-card"))
        XCTAssertFalse(Self.exactChain(expected.union([foreign.caseNumber]), expected: expected))
    }
    nonisolated private static func exactChain(_ actual: Set<String>, expected: Set<String>) -> Bool { actual == expected }

    private func assertChains(_ store: TrackedStore, replay: Bool) throws {
        XCTAssertEqual(store.all().count, replay ? 1 : 2, "The two appeals must converge on one ordinary discovered Moscow anchor")
        let movements = store.all().compactMap(\.movement)
        let chains = movements.map { Set($0.instances.map(\.caseNumber)) }
        let publishedCassation = try Self.cassationNumber()
        XCTAssertTrue(chains.contains { Self.exactChain($0, expected: Set(["3а-3696/2020", "66а-2013/2020", "66а-4311/2020"])) })
        if !replay { XCTAssertTrue(chains.contains { Self.exactChain($0, expected: Set(["02а-0419/2021", "33а-6088/2021", publishedCassation])) }) }
        let expectedNumbers = ["66а-2013/2020", "66а-4311/2020", try Self.cassationNumber(), "3а-3696/2020", "02а-0419/2021", "33а-6088/2021"]
        let expectedLevels: [CaseInstance.Level] = [.appeal, .appeal, .cassation, .first, .first, .appeal]
        for (index, pair) in zip(expectedNumbers, Self.sources).enumerated() {
            let (number, expectedURL) = pair
            if replay && !["66а-2013/2020", "66а-4311/2020", "3а-3696/2020"].contains(number) { continue }
            let matches = movements.flatMap(\.instances).filter { $0.caseNumber == number }
            XCTAssertEqual(matches.count, 1, "Each published own registration must remain distinct")
            XCTAssertEqual(matches.first?.level, expectedLevels[index])
            let actualURL = try XCTUnwrap(matches.first?.sourceURL)
            let expected = try XCTUnwrap(URL(string: expectedURL))
            if let published = try? SudrfCaseCardLink(url: expected) {
                let actual = try SudrfCaseCardLink(url: actualURL)
                XCTAssertEqual(actual.moduleHost, published.moduleHost)
                XCTAssertEqual(actual.caseID, published.caseID)
                XCTAssertEqual(actual.caseUID, published.caseUID)
                XCTAssertEqual(actual.deloID, published.deloID)
                XCTAssertEqual(actual.new, published.new, "Added defaults are not source-published locator fields")
                XCTAssertEqual(actual.srvNum, published.srvNum)
                let publishedType = URLComponents(url: expected, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "case_type" }?.value
                let actualType = URLComponents(url: actualURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "case_type" }?.value
                XCTAssertEqual(actualType, publishedType)
            } else {
                XCTAssertEqual(actualURL.host, expected.host)
                XCTAssertEqual(actualURL.path, expected.path, "Moscow own native locator must match the actual published card")
                for field in ["uid", "formType", "caseNumber"] {
                    let published = URLComponents(url: expected, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == field }?.value
                    let actual = URLComponents(url: actualURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == field }?.value
                    if replay && field == "caseNumber" {
                        XCTAssertNil(actual, "Observed current Moscow sourceURL canonicalizes the number query; replay proves only native path identity")
                    } else {
                        XCTAssertEqual(actual, published, "Exact published query is a separate oracle from native path identity")
                    }
                }
            }
        }
        for movement in movements {
            XCTAssertEqual(Set(movement.instances.map(\.id)).count, movement.instances.count)
            for instance in movement.instances {
                XCTAssertNotNil(instance.sourceURL)
                XCTAssertTrue(instance.sourceURL.map(Issue322BoundedTransport.allowed) ?? false)
                if replay {
                    XCTAssertEqual(instance.sessions.isEmpty, instance.domain == "1ap.sudrf.ru",
                        "ASOY excerpts omit session tables; Moscow excerpt retains its one published session")
                } else {
                    XCTAssertFalse(instance.sessions.isEmpty, "Complete acceptance requires published movement")
                }
            }
            if replay {
                XCTAssertTrue(movement.acts.isEmpty, "Excerpts have no linked published act bytes; replay must not invent acts")
            } else {
                XCTAssertFalse(movement.acts.isEmpty, "Complete acceptance requires actual published acts")
                XCTAssertFalse(movement.actBodies.isEmpty, "Metadata alone is partial diagnostic evidence")
                for actID in movement.actBodies.keys {
                    XCTAssertTrue(movement.instances.contains { $0.linkedActIDs.contains(actID) }, "Every actual act body must retain its own instance owner")
                }
            }
        }
    }

    private func makeSolver(manifest: Manifest, settings: CaptchaSettings) throws -> CaptchaSolver {
        let numeric = try CoreMLCaptchaStrategy(modelURL: URL(fileURLWithPath: manifest.numericModel), kind: .sudrfToken)
        let specialist = try CoreMLCaptchaStrategy(modelURL: URL(fileURLWithPath: manifest.specialistModel), kind: .sudrfToken)
        var vision = VisionOCRStrategy()
        vision.preprocessingProvider = { [weak settings] in settings?.preprocessorEnabled ?? false }
        let provider = KindDispatchingStrategy(primary: HighestConfidenceStrategy(first: numeric, second: specialist),
            fallback: vision, minPrimaryConfidence: settings.minConfidence,
            primaryAttemptIsCompatible: { CoreMLCaptchaStrategy.isCompatibleOutput($0.value) })
        // Files are disabled; the unchanged logger still emits local macOS diagnostic entries.
        return CaptchaSolver(provider: provider, enabledKinds: [.sudrfToken],
            log: CaptchaSolverLog(fileURL: nil, failuresDir: nil, diagnosticsDir: nil))
    }

    nonisolated private static func privateRoot(_ path: String) throws -> URL {
        let supplied = URL(fileURLWithPath: path)
        guard path.hasPrefix("/private/tmp/sudrf-322-"),
              supplied.deletingLastPathComponent().path == "/private/tmp",
              supplied.lastPathComponent.hasPrefix("sudrf-322-") else { throw GateFailure.manifest }
        let root = supplied.standardizedFileURL.resolvingSymlinksInPath()
        let parent = URL(fileURLWithPath: "/private/tmp").standardizedFileURL.resolvingSymlinksInPath()
        guard root.deletingLastPathComponent() == parent,
              root.lastPathComponent == supplied.lastPathComponent else { throw GateFailure.manifest }
        return root
    }

    func testExistingPrivateRootAcceptsCanonicalTmpButRejectsOutsideSymlink() throws {
        let path = "/private/tmp/sudrf-322-root-\(UUID().uuidString)"
        let outside = "/private/tmp/issue322-outside-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = try Self.privateRoot(path)
        XCTAssertEqual(root.deletingLastPathComponent(), URL(fileURLWithPath: "/private/tmp").standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertThrowsError(try Self.privateRoot("/tmp/" + root.lastPathComponent))
        XCTAssertThrowsError(try Self.privateRoot(path + "/child"))
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: outside)
        XCTAssertThrowsError(try Self.privateRoot(path))
    }

    private struct Manifest: Codable {
        let outputRoot: String
        let sourceURLs: [String]
        let numericModel: String
        let specialistModel: String
        func validate() throws {
            guard sourceURLs == Issue322LiveAcceptanceTests.sources,
                  sourceURLs.allSatisfy({ URL(string: $0).map(Issue322BoundedTransport.allowed) ?? false }),
                  (try? Issue322LiveAcceptanceTests.privateRoot(outputRoot)) != nil,
                  numericModel.hasSuffix("model-captcha-numeric.mlmodelc"),
                  specialistModel.hasSuffix("model-captcha-numeric-specialist.mlmodelc") else { throw GateFailure.manifest }
            // Verify full tracked manifests, with no model discovery/fetch or executable shell text.
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let modelsRoot = repo.appendingPathComponent("Tests/CaptchaSolverTests/Fixtures").resolvingSymlinksInPath()
            for (path, name) in [(numericModel, "model-captcha-numeric"), (specialistModel, "model-captcha-numeric-specialist")] {
                let modelURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                guard modelURL.deletingLastPathComponent() == modelsRoot else { throw GateFailure.manifest }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [repo.appendingPathComponent("Scripts/verify-model.sh").path,
                    "--model-dir", path, "--manifest", repo.appendingPathComponent("Tests/CaptchaSolverTests/Fixtures/\(name == "model-captcha-numeric" ? "MODEL_MANIFEST" : "MODEL_NUMERIC_SPECIALIST_MANIFEST").sha256").path,
                    "--model-name", name]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw GateFailure.manifest }
            }
        }
    }
    nonisolated fileprivate static let sources = [
        "https://1ap.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=6724440&case_uid=0cd448a3-5cf2-49bc-99c1-35bf0706c2d5&delo_id=42",
        "https://1ap.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=6749107&case_uid=6dc098e7-acb0-4b6b-b250-fcbb25479004&delo_id=42",
        "https://2kas.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=2723657&case_uid=576e5fae-ee46-434a-99eb-5956562963b0&new=0&delo_id=43",
        "https://mos-gorsud.ru/mgs/services/cases/first-admin/details/49e1e932-ca18-4a54-9797-987d15209322?caseNumber=3%D0%B0-3696/2020",
        "https://mos-gorsud.ru/rs/hamovnicheskij/services/cases/kas/details/1b274aa1-0cb0-11ec-a70f-232197c57890?uid=77RS0030-02-2021-008181-07&formType=fullForm",
        "https://mos-gorsud.ru/mgs/services/cases/appeal-admin/details/b8390500-58cc-11ec-b06c-31916f371c35?uid=77RS0030-02-2021-008181-07&formType=fullForm"]
    private static func cassationNumber() throws -> String {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../SudrfKitTests/Fixtures/issue322_ksoyu_8501.html").standardizedFileURL
        return try XCTUnwrap(CaseCardParser.parse(html: String(contentsOf: fixture, encoding: .utf8)).caseNumber)
    }
    private static func originalContexts() throws -> [MovementContext] {
        try zip(sources.prefix(3), ["66а-2013/2020", "66а-4311/2020", try cassationNumber()]).enumerated().map { index, pair in
            let link = try SudrfCaseCardLink(url: XCTUnwrap(URL(string: pair.0)))
            let cassation = index == 2
            return MovementContext(branchRaw: CourtBranch.general.rawValue, region: "город Москва",
                searchDomain: cassation ? "2kas.sudrf.ru" : "1ap.sudrf.ru", displayDomain: cassation ? "2kas.sudrf.ru" : "1ap.sudrf.ru",
                courtTitle: cassation ? "Второй кассационный суд общей юрисдикции" : "Первый апелляционный суд общей юрисдикции",
                courtLevelRaw: cassation ? CourtLevel.cassation.rawValue : CourtLevel.appeal.rawValue,
                cartotekaId: cassation ? "g3" : "p2", cartotekaLevelRaw: cassation ? CourtLevel.cassation.rawValue : CourtLevel.appeal.rawValue,
                caseNumber: pair.1, caseID: link.caseID, caseUID: link.caseUID, cardURLString: pair.0,
                judicialUID: cassation ? "77RS0030-02-2021-008181-07" : nil,
                baseInstanceLevelRaw: cassation ? CaseInstance.Level.cassation.rawValue : CaseInstance.Level.appeal.rawValue)
        }
    }
    nonisolated private static func validSHA(_ data: Data, expected: String?) -> Bool {
        guard let expected, expected.count == 64, expected.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }
        return sha(data) == expected
    }
    nonisolated fileprivate static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated fileprivate static func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private enum GateFailure: Error { case manifest, incomplete, unusedProvider }
}

/// Test-local bounded forwarding transport; ordinary clients and parsers remain in use.
private final class Issue322BoundedTransport: URLProtocol {
    struct State: Sendable { var directory: URL?; var replay = false; var redirects: [URL: URL] = [:]; var requests: [URL] = []; var denied: Set<String> = [] }
    private static let state = Mutex(State())
    private var forwarding: URLSession?
    private var bridge: DelegateBridge?
    private var forwardingTask: URLSessionDataTask?
    private var body = Data()
    private var response: URLResponse?
    private var rejected = false
    private var handedRedirectToClient = false
    static func install(directory: URL, replay: Bool = false, redirects: [URL: URL] = [:]) -> State { state.withLock { old in let previous = old; old = State(directory: directory, replay: replay, redirects: redirects); return previous } }
    static func restore(_ previous: State) { state.withLock { $0 = previous } }
    static func requests() -> [URL] { state.withLock { $0.requests } }
    static func deniedHosts() -> Set<String> { state.withLock { $0.denied } }
    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && ["1ap.sudrf.ru", "2kas.sudrf.ru", "mos-gorsud.ru", "sudrf.ru", "www.sudrf.ru", "vsrf.ru", "www.vsrf.ru"].contains(url.host?.lowercased() ?? "")
    }
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.protocolClasses = [Issue322BoundedTransport.self]
        return config
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, Self.allowed(url), Self.state.withLock({ $0.directory }) != nil else {
            deny(request.url); client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        Self.state.withLock { $0.requests.append(url) }
        if Self.state.withLock({ $0.replay }), let target = Self.state.withLock({ $0.redirects[url] }) {
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            handRedirectToClient(URLRequest(url: target), response: redirect)
            return
        }
        if Self.state.withLock({ $0.replay }) {
            do {
                body = try Self.replayBody(url)
                response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html; charset=utf-8"])
                complete(error: nil)
            } catch {
                if let directory = Self.state.withLock({ $0.directory }) {
                    try? Issue322LiveAcceptanceTests.privateWrite(Data(url.absoluteString.utf8),
                        to: directory.appendingPathComponent("replay-missing-\(UUID().uuidString).txt"))
                }
                deny(url); client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            }
            return
        }
        let config = Self.configuration(); config.protocolClasses = []
        bridge = DelegateBridge(owner: self)
        forwarding = URLSession(configuration: config, delegate: bridge, delegateQueue: nil)
        forwardingTask = forwarding?.dataTask(with: request); forwardingTask?.resume()
    }
    override func stopLoading() { forwardingTask?.cancel(); forwarding?.invalidateAndCancel() }
    private func deny(_ url: URL?) {
        rejected = true
        Self.state.withLock { $0.denied.insert(url?.host ?? "invalid") }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.allowed(url) else { deny(request.url); completionHandler(nil); return }
        handRedirectToClient(request, response: response)
        completionHandler(nil)
    }
    private func handRedirectToClient(_ redirectedRequest: URLRequest, response: HTTPURLResponse) {
        guard let url = redirectedRequest.url, Self.allowed(url) else {
            deny(redirectedRequest.url)
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        handedRedirectToClient = true
        if let directory = Self.state.withLock({ $0.directory }) {
            let record: [String: Any] = ["requestURL": request.url?.absoluteString ?? "",
                "effectiveURL": response.url?.absoluteString ?? "", "redirectURL": url.absoluteString,
                "status": response.statusCode]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                try? Issue322LiveAcceptanceTests.privateWrite(data, to: directory.appendingPathComponent("redirect-\(UUID().uuidString).json"))
            }
        }
        client?.urlProtocol(self, wasRedirectedTo: redirectedRequest, redirectResponse: response)
        // Match the existing transport-policy fixtures: outer delegate captures
        // the hop, then completes the original 302 before replaying it.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let url = response.url, Self.allowed(url), response.expectedContentLength <= 5_242_880 else {
            rejected = true; completionHandler(.cancel); return
        }
        self.response = response; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= 5_242_880 else { rejected = true; dataTask.cancel(); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        guard !handedRedirectToClient else { return }
        complete(error: error)
    }
    private func complete(error: Error?) {
        guard let directory = Self.state.withLock({ $0.directory }) else { return }
        let responseID = UUID().uuidString
        do {
            try Issue322LiveAcceptanceTests.privateWrite(body, to: directory.appendingPathComponent("\(responseID).body"))
            let summary: [String: Any] = ["status": (response as? HTTPURLResponse)?.statusCode ?? 0,
                "bytes": body.count, "sha256": Issue322LiveAcceptanceTests.sha(body), "rejected": rejected,
                "transportFailure": error != nil, "requestURL": request.url?.absoluteString ?? "",
                "effectiveURL": response?.url?.absoluteString ?? ""]
            try Issue322LiveAcceptanceTests.privateWrite(JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
                to: directory.appendingPathComponent("\(responseID).json"))
        } catch { rejected = true }
        if rejected || error != nil {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        guard let response else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    private static func replayBody(_ url: URL) throws -> Data {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { query.first { $0.name == key }?.value }
        if url.path == "/issue322-redirect-target" { return Data("<html>synthetic redirect target</html>".utf8) }
        let fixture: String
        if url.host == "1ap.sudrf.ru", let id = value("case_id") {
            guard ["6724440", "6749107"].contains(id) else { throw URLError(.unsupportedURL) }
            fixture = id == "6724440" ? "issue322_asoy_2013" : "issue322_asoy_4311"
        } else if url.host == "mos-gorsud.ru", url.path == "/search",
                  value("courtAlias") == "mgs", value("caseNumber") == "3а-3696/2020" {
            fixture = "issue322_mgs_search_first"
        } else if url.host == "mos-gorsud.ru", url.path.hasSuffix("/details/49e1e932-ca18-4a54-9797-987d15209322") {
            fixture = "issue322_mgs_first"
        } else if ["1ap.sudrf.ru", "2kas.sudrf.ru"].contains(url.host ?? ""),
                  value("name_op") == "sf" || (value("name_op") == "r" && value("p33_case__JUDICIAL_UIDSS") == "77OS0000-01-2020-002855-77") {
            // Synthetic transport control, not evidence of any real empty response.
            return Data("<html><body>Ничего не найдено. Всего по запросу найдено - 0</body></html>".utf8)
        } else if url.host == "mos-gorsud.ru", url.path == "/search",
                  value("uid") == "77OS0000-01-2020-002855-77",
                  ["2", "4"].contains(value("instance") ?? "") {
            // Explicit synthetic empty higher-search control, not a live claim.
            return Data("<html><body><table><tr><th>№ дела</th></tr></table></body></html>".utf8)
        } else { throw URLError(.unsupportedURL) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../SudrfKitTests/Fixtures/\(fixture).html").standardizedFileURL
        return try Data(contentsOf: root)
    }
    private final class DelegateBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: Issue322BoundedTransport?
        init(owner: Issue322BoundedTransport) { self.owner = owner }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let owner else { completionHandler(nil); return }
            owner.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let owner else { completionHandler(.cancel); return }
            owner.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.urlSession(session, dataTask: dataTask, didReceive: data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.urlSession(session, task: task, didCompleteWithError: error)
        }
    }

}
private struct Issue322RejectCard: CaseProviding {
    func search(court: Court, cartoteka: Cartoteka, field: SearchField, value: String) async throws -> [CaseSearchResult] { throw URLError(.unsupportedURL) }
    func fetchCard(court: Court, caseID: String, caseUID: String, deloID: String, new: String) async throws -> CaseCard { throw URLError(.unsupportedURL) }
    func fetchCard(url: URL) async throws -> CaseCard { throw URLError(.unsupportedURL) }
}
private struct Issue322RejectVS: VSRFProviding {
    func search(uniqueNumber: String?, oldCaseNumber: String?, keywords: String?) async throws -> VSRFSearchResults { throw URLError(.unsupportedURL) }
    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard { throw URLError(.unsupportedURL) }
}
