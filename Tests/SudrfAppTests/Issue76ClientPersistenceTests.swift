import Foundation
import SwiftData
import XCTest
@testable import SudrfKit
@testable import SudrfApp

/// Synthetic HTTP responses only. No installed application or user store is used.
@MainActor
final class Issue76ClientPersistenceTests: XCTestCase {
    func testConfirmedRoleCorrectionDoesNotMarkUnchangedCardUnread() async throws {
        let store = try TrackedStore(container: SudrfModelContainerFactory.make(inMemory: true), prepared: true)
        let context = Self.context()
        let cached = Self.legacyMovement()
        let seenAt = Date(timeIntervalSince1970: 1_700_000_077)
        var old = MovementDerivation.snapshot(from: cached, context: context)
        old.inForce = !old.inForce
        let record = try store.reconcileAndUpsert(context: context, snapshot: old, movement: cached, collections: [])
        record.seenAt = seenAt
        var journal = try store.requiredEventJournal(for: record)
        journal.semanticBaselines = CaseEventBaselines()
        journal.semanticBaselines?.global = CaseEventGlobalBaseline(inForce: old.inForce, deadlines: old.deadlines)
        record.eventJournal = journal
        try store.save()
        var fresh = cached
        // The Kit admission tests establish this fresh role from exact card proof.
        fresh.instances[2].level = .material
        let provider = Issue76FixedMovement(value: fresh)
        let client = SudrfClient(session: URLSession(configuration: .ephemeral), minInterval: 0,
                                 variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: CaptchaTokenStore())
        let center = RefreshCenter(store: store, client: client, serviceBuilder: { _ in provider })
        _ = await center.refresh(key: record.key)?.value
        XCTAssertEqual(record.movement?.instances[2].level, .material)
        XCTAssertEqual(record.seenAt, seenAt)
        XCTAssertEqual(semanticJournalEvents(record.eventJournal), [])
    }

    func testNativeClientRefreshAndReopenPreserveRouteAndLegacyFactsWithoutNewEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue76-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("fixture.store")
        let context = Self.context()
        let originalSuccess = Date(timeIntervalSince1970: 1_700_000_076)
        let seenAt = Date(timeIntervalSince1970: 1_700_000_077)
        var cached = Self.legacyMovement()
        let legacyAct = CaseAct(id: "legacy-related-act", title: "Определение",
                                date: "01.02.2026", courtShort: "Шестой КСОЮ",
                                instanceLevel: .cassation)
        cached.acts = [legacyAct]
        cached.actBodies = [legacyAct.id: "Сохранённый синтетический текст"]
        cached.instances[2].actID = legacyAct.id
        cached.instances.append(CaseInstance(
            level: .cassation, court: "Шестой КСОЮ", caseNumber: "—",
            judge: nil, domain: "6kas.sudrf.ru", foundByUID: false, result: nil, sessions: [], transientError: true))
        let key: String
        do {
            let store = try TrackedStore(container: SudrfModelContainerFactory.make(
                inMemory: false, storeURL: storeURL), prepared: true)
            var old = MovementDerivation.snapshot(from: cached, context: context)
            // Legacy interpretation included an unrelated cassation remand.
            old.inForce = !old.inForce
            // A snapshot written before #76 could label these same facts as main cassation.
            old.sessions = old.sessions.map { value in
                var value = value
                if value.caseNumber == "7У-76/2026" { value.levelRaw = "cassation" }
                return value
            }
            let record = try store.reconcileAndUpsert(
                context: context, snapshot: old, movement: cached,
                collections: ["Синтетическая подборка"], movementFetchedAt: originalSuccess)
            key = record.key
            record.seenAt = seenAt
            try store.save()
        }
        for mode in ["partial", "empty", "empty"] {
            let store = try TrackedStore(container: SudrfModelContainerFactory.make(
                inMemory: false, storeURL: storeURL), prepared: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Issue76HTTP.self]
            configuration.httpAdditionalHeaders = ["X-Issue76-Mode": mode]
            let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0,
                                     variantStore: WorkingVariantStore(cacheURL: nil),
                                     captchaStore: CaptchaTokenStore())
            let center = RefreshCenter(store: store, client: client,
                                       serviceBuilder: { $0.makeService(client: client) })
            let outcome = await center.refresh(key: key)?.value
            XCTAssertNotNil(outcome)
            let record = try XCTUnwrap(store.record(forKey: key))
            let saved = try XCTUnwrap(record.movement)
            XCTAssertEqual(saved.instances.filter { $0.caseNumber == "55-584/2025" }.count, 1)
            XCTAssertEqual(saved.instances.first { $0.caseNumber == "55-584/2025" }?.level, .appeal)
            XCTAssertFalse(saved.instances.contains {
                $0.level == .cassation && ($0.transientError == true || $0.captchaFormURL != nil)
            })
            let related = try XCTUnwrap(saved.instances.first { $0.caseNumber == "7У-76/2026" })
            XCTAssertEqual(related.sourceURL, cached.instances[2].sourceURL)
            XCTAssertEqual(related.sessions, cached.instances[2].sessions)
            XCTAssertTrue(saved.acts.contains(legacyAct))
            XCTAssertEqual(saved.actBodies[legacyAct.id], cached.actBodies[legacyAct.id])
            XCTAssertEqual(record.collectionNames, ["Синтетическая подборка"])
            XCTAssertEqual(record.movementFetchedAt, originalSuccess,
                           "Unavailable/empty search cannot renew the last full-chain success")
            XCTAssertEqual(record.seenAt, seenAt)
            XCTAssertEqual(semanticJournalEvents(record.eventJournal), [])
            XCTAssertNil(saved.sourceRefreshCoverage)
        }
        let reopened = try TrackedStore(container: SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL), prepared: true)
        let record = try XCTUnwrap(reopened.record(forKey: key))
        let raw = try XCTUnwrap(record.movement)
        let storedBytes = record.movementData
        let journalBytes = record.eventJournalData
        _ = try TrackedStorePreparation.prepare(context: reopened.container.mainContext)
        XCTAssertEqual(record.movementData, storedBytes)
        XCTAssertEqual(record.eventJournalData, journalBytes)
        XCTAssertEqual(record.movementFetchedAt, originalSuccess)
        let presentation = MovementDerivation.lifecyclePresentation(
            from: raw, snapshot: try XCTUnwrap(record.snapshot), context: context)
        XCTAssertNotEqual(presentation.nextEventCourt, "Шестой КСОЮ")
        XCTAssertFalse(raw.instances.contains { $0.level == .vsCassation },
                       "Expected Supreme Court route is not a found Supreme Court production")
    }

    private static func context() -> MovementContext {
        var value = MovementContext(
            branchRaw: "general", region: "Самарская область",
            searchDomain: "oblsud--sam.sudrf.ru", displayDomain: "oblsud.sam.sudrf.ru",
            courtTitle: "Самарский областной суд", courtLevelRaw: "subject", courtCode: "63",
            cartotekaId: "u1", cartotekaLevelRaw: "subject", caseNumber: "2-12/2025",
            caseID: "76", caseUID: "fixture-only", cardURLString: Issue76HTTP.baseURL.absoluteString)
        value.judicialUID = Issue76HTTP.uid
        value.baseInstanceLevelRaw = "first"
        // Legacy persisted targets must not bypass the new main/material distinction.
        value.higherCourtTargets = [
            .init(domain: "4ap.sudrf.ru", courtTitle: "Четвёртый апелляционный суд общей юрисдикции",
                  courtLevel: .appeal, instanceLevel: .appeal, cartotekaIDs: ["u2"]),
            .init(domain: "6kas.sudrf.ru", courtTitle: "Шестой КСОЮ",
                  courtLevel: .cassation, instanceLevel: .cassation, cartotekaIDs: ["u3"])
        ]
        return value
    }

    private static func legacyMovement() -> CaseMovement {
        let base = CaseInstance(
            level: .first, court: "Самарский областной суд", caseNumber: "2-12/2025",
            judge: nil, domain: "oblsud--sam.sudrf.ru", foundByUID: false, result: "Вынесен приговор",
            sessions: [], sourceURL: Issue76HTTP.baseURL,
            sourceEvidence: .init(judicialUID: Issue76HTTP.uid, cartotekaID: "u1",
                                  sourceCourtLevel: .subject, sourceBranch: .general))
        let appeal = CaseInstance(
            level: .appeal, court: "Четвёртый апелляционный суд общей юрисдикции",
            caseNumber: "55-584/2025", judge: nil, domain: "4ap.sudrf.ru", foundByUID: true,
            result: "ВЫНЕСЕНО РЕШЕНИЕ (ОПРЕДЕЛЕНИЕ)", sessions: [],
            sourceURL: Issue76HTTP.appealURL,
            sourceEvidence: .init(lowerCourt: .init(courtTitle: base.court, caseNumber: base.caseNumber),
                                  judicialUID: Issue76HTTP.uid, cartotekaID: "u2",
                                  sourceCourtLevel: .appeal, sourceBranch: .general))
        let related = CaseInstance(
            level: .cassation, court: "Шестой КСОЮ", caseNumber: "7У-76/2026",
            judge: nil, domain: "6kas.sudrf.ru", foundByUID: true, result: nil,
            sessions: [CaseSession(date: "01.02.2026", event: "Передача дела судье")],
            sourceURL: URL(string: "https://6kas.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=7676&case_uid=fixture&delo_id=2450001"))
        return CaseMovement(uid: Issue76HTTP.uid, caseNumber: base.caseNumber, inForce: false,
                            instances: [base, appeal, related], complaints: [:], acts: [])
    }
}

private struct Issue76FixedMovement: MovementProviding {
    let value: CaseMovement
    func movement(for base: CaseSearchResult, court: Court, cartoteka: Cartoteka) async throws -> CaseMovement {
        value
    }
}

private final class Issue76HTTP: URLProtocol {
    static let uid = "63OS0000-01-2024-002224-56"
    static let baseURL = URL(string: "https://oblsud--sam.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=76&case_uid=fixture-only&delo_id=1540006")!
    static let appealURL = URL(string: "https://4ap.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=8481895&case_uid=c253619c-4094-4c15-ba1b-7bdc02640ede&delo_id=4&new=4")!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host,
              ["oblsud--sam.sudrf.ru", "4ap.sudrf.ru", "6kas.sudrf.ru"].contains(host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        if host == "6kas.sudrf.ru", request.value(forHTTPHeaderField: "X-Issue76-Mode") == "partial" {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let isCard = query.contains { ["name_op", "_name_op"].contains($0.name) && $0.value == "case" }
        let html: String
        if isCard && host == "oblsud--sam.sudrf.ru" {
            html = Self.card(number: "2-12/2025", result: "Вынесен приговор", lower: "")
        } else if isCard && host == "4ap.sudrf.ru" {
            html = Self.card(number: "55-584/2025", result: "ВЫНЕСЕНО РЕШЕНИЕ (ОПРЕДЕЛЕНИЕ)", lower: """
                <div id="cont2"><table id="tablcont"><tr><th>РАССМОТРЕНИЕ В НИЖЕСТОЯЩЕМ СУДЕ</th></tr>
                <tr><td>Суд первой инстанции</td><td>Самарский областной суд</td></tr>
                <tr><td>Номер дела в первой инстанции</td><td>2-12/2025</td></tr></table></div>
                """)
        } else if host == "4ap.sudrf.ru" {
            html = """
                <div id="content">Всего по запросу найдено — 1. На странице записи с 1 по 1.
                <table id="tablcont"><tr><th>№ дела</th><th>Дата поступления</th></tr><tr>
                <td><a href="\(Self.appealURL.absoluteString.replacingOccurrences(of: "&", with: "&amp;"))">55-584/2025</a></td>
                <td>17.11.2025</td><td></td><td></td><td></td><td>ВЫНЕСЕНО РЕШЕНИЕ (ОПРЕДЕЛЕНИЕ)</td></tr></table></div>
                """
        } else {
            html = "<html><body>По вашему запросу ничего не найдено</body></html>"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    private static func card(number: String, result: String, lower: String) -> String {
        """
        <html><body><div class="casenumber">ДЕЛО № \(number)</div>
        <div id="cont1"><table id="tablcont"><tr><th>ДЕЛО</th></tr>
        <tr><td>Уникальный идентификатор дела</td><td>\(uid)</td></tr>
        <tr><td>Результат рассмотрения</td><td>\(result)</td></tr></table></div>\(lower)</body></html>
        """
    }
    override func stopLoading() {}
}
