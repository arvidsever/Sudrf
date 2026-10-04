import Foundation
import SwiftData
import XCTest
@testable import SudrfKit
@testable import SudrfApp

private let issue241RootDomain = "district--issue241.sudrf.ru"
private let issue241CassationDomain = "3kas.sudrf.ru"

private final class Issue241FlappingURLProtocol: URLProtocol {
    enum Mode: Sendable { case exhaustedMaintenance, exhaustedCardMaintenance, captchaRejected, flapping, steady }

    private struct Reply {
        let body: String
        let kind: String
    }

    nonisolated(unsafe) private static var mode: Mode = .steady
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var recorded: [(URL, String)] = []

    static func configure(_ mode: Mode) {
        self.mode = mode
        counts = [:]
        recorded = []
    }

    static func requests() -> [(URL, String)] { recorded }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = Self.reply(for: url)
        Self.recorded.append((url, reply.kind))
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func reply(for url: URL) -> Reply {
        let host = url.host?.lowercased() ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let operation = items.first { $0.name == "name_op" }?.value
        let key = url.absoluteString
        let count = counts[key, default: 0] + 1
        counts[key] = count

        if host == issue241CassationDomain {
            switch operation {
            case "sf": return Reply(body: formHTML, kind: "form")
            case "r":
                switch mode {
                case .exhaustedMaintenance:
                    return Reply(body: maintenanceHTML, kind: "maintenance")
                case .exhaustedCardMaintenance:
                    return Reply(body: searchResultsHTML, kind: "results")
                case .captchaRejected:
                    return Reply(body: rejectedHTML, kind: "captchaRejected")
                case .flapping:
                    if count < 3 { return Reply(body: maintenanceHTML, kind: "maintenance") }
                    return Reply(body: searchResultsHTML, kind: "results")
                case .steady:
                    return Reply(body: searchResultsHTML, kind: "results")
                }
            case "case":
                switch mode {
                case .exhaustedMaintenance, .exhaustedCardMaintenance, .captchaRejected:
                    return Reply(body: maintenanceHTML, kind: "maintenance")
                case .flapping where count < 3:
                    return Reply(body: maintenanceHTML, kind: "maintenance")
                case .flapping, .steady:
                    return Reply(body: cassationCardHTML, kind: "card")
                }
            default: break
            }
        }

        if host == issue241RootDomain {
            switch operation {
            case "sf": return Reply(body: formHTML, kind: "form")
            case "r": return Reply(body: rootSearchResultsHTML, kind: "results")
            case "case": return Reply(body: rootCardHTML, kind: "card")
            default: break
            }
        }
        return Reply(body: emptyHTML, kind: "empty")
    }

    private static let maintenanceHTML =
        "<main>Информация временно недоступна. Попробуйте обратиться позже.</main>"
    private static let rejectedHTML = "<main>Неверно указан проверочный код с картинки</main>"
    private static let emptyHTML = "<main>Данных по запросу не обнаружено</main>"
    private static let formHTML = "<html><body><form id='search-form'></form></body></html>"

    private static let rootSearchResultsHTML = """
        <html><body><table id="tablcont"><tbody><tr><td>
          <a href="/modules.php?name=sud_delo&amp;srv_num=1&amp;name_op=case&amp;case_id=issue241-root-card&amp;case_uid=issue241-root-guid&amp;delo_id=1540005&amp;new=0">
            2-241/2026
          </a>
        </td></tr></tbody></table></body></html>
        """

    private static let searchResultsHTML = """
        <html><body><table id="tablcont"><tbody><tr><td>
          <a href="/modules.php?name=sud_delo&amp;srv_num=2&amp;name_op=case&amp;case_id=issue241-synthetic-3kas-card&amp;case_uid=issue241-synthetic-3kas-guid&amp;delo_id=2800001&amp;new=2800001&amp;case_type=0">
            8Г-241/2026 [88-241/2026]
          </a>
        </td></tr></tbody></table></body></html>
        """

    private static let rootCardHTML = """
        <html><body>
          <div class="casenumber">ДЕЛО № 2-241/2026</div>
          <ul class="tabs"><li id="tab1"><a>ДЕЛО</a></li></ul>
          <div id="cont1"><table>
            <tr><td>Уникальный идентификатор дела</td><td>99RS0001-01-2026-000241-10</td></tr>
          </table></div>
        </body></html>
        """

    private static let cassationCardHTML = """
        <html><body>
          <div class="casenumber">ДЕЛО № 8Г-241/2026 [88-241/2026]</div>
          <ul class="tabs">
            <li id="tab1"><a>ДЕЛО</a></li>
            <li id="tab_doc1"><a>Судебный акт #1 (Кассационное определение)</a></li>
          </ul>
          <div id="cont1"><table>
            <tr><td>Уникальный идентификатор дела</td><td>99RS0001-01-2026-000241-10</td></tr>
            <tr><td>Дата рассмотрения</td><td>14.05.2026</td></tr>
            <tr><td>Результат рассмотрения</td><td>Оставлено без изменения</td></tr>
          </table></div>
          <div id="cont_doc1"><p>Синтетический опубликованный акт #241.</p></div>
        </body></html>
        """
}

@MainActor
final class Issue241AcceptanceTests: XCTestCase {
    private let rootNumber = "2-241/2026"
    private let cassationNumber = "8Г-241/2026 [88-241/2026]"
    private let judicialUID = "99RS0001-01-2026-000241-10"
    private let cassationActID = "act_3kas.sudrf.ru#8Г-241/2026 [88-241/2026]"
    private let publishedActText = "Синтетический опубликованный акт #241."

    func testFlappingCassationSearchAndCardPreserveCacheThenRecoverAfterCaptchaRejection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-241-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let diagnostics = directory.appendingPathComponent("diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        let previousDiagnosticsDirectory = SearchDiagnostics.setDirForTesting(diagnostics)
        defer { SearchDiagnostics.setDirForTesting(previousDiagnosticsDirectory) }

        let storeURL = directory.appendingPathComponent("tracked.store")
        let rootURL = URL(string:
            "https://\(issue241RootDomain)/modules.php?name=sud_delo&srv_num=1"
            + "&name_op=case&case_id=issue241-root-card"
            + "&case_uid=issue241-root-guid&delo_id=1540005&new=0"
        )!
        let cassationURL = URL(string:
            "https://3kas.sudrf.ru/modules.php?name=sud_delo&srv_num=2&name_op=case"
            + "&case_id=issue241-synthetic-3kas-card"
            + "&case_uid=issue241-synthetic-3kas-guid"
            + "&delo_id=2800001&new=2800001&case_type=0"
        )!
        let context = makeContext(rootURL: rootURL)
        var expectedSuccessfulRefresh = Date(timeIntervalSince1970: 1_700_000_000)
        let seenAt = Date(timeIntervalSince1970: 1_700_000_100)
        let seedEvent = CaseEvent.make(
            kind: .complaintRegistered, occurrence: ["issue-241-synthetic-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())
        let manualDeadline = StoredDeadline(
            kind: "custom", what: "Пользовательский срок", basis: "Синтетическая проверка #241",
            calLabel: "ручной", dateRef: DateUtil.parse("01.01.2035")!.timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue,
            occurrenceKey: "issue-241-manual-deadline",
            lifecycleRaw: DeadlineLifecycle.active.rawValue)

        let rootCard = try CaseCardParser.parse(html: Issue241FlappingURLProtocolRoot.html,
                                                 cardURL: rootURL)
        let root = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: rootNumber,
            judge: nil, domain: issue241RootDomain, foundByUID: false, result: nil,
            sessions: [], sourceURL: rootURL,
            sourceEvidence: .init(card: rootCard, cartotekaID: "g1",
                                  courtLevel: .district, branch: .general))
        let oldCassation = CaseInstance(
            level: .cassation, court: "Третий кассационный суд общей юрисдикции",
            caseNumber: cassationNumber, judge: nil, domain: issue241CassationDomain,
            foundByUID: true, result: "Оставлено без изменения", sessions: [],
            actID: cassationActID, actIDs: [cassationActID])
        let oldMovement = CaseMovement(
            uid: judicialUID, caseNumber: rootNumber, inForce: false,
            instances: [root, oldCassation], complaints: [:],
            acts: [CaseAct(id: cassationActID,
                           title: MovementService.actTitle(cartotekaID: "g3", level: .cassation),
                           date: "14.05.2026",
                           courtShort: MovementService.shortCourtName(forDomain: issue241CassationDomain),
                           instanceLevel: .cassation)],
            actBodies: [cassationActID: "Старый синтетический текст акта #241."])

        var key = ""
        var savedMovement = oldMovement
        var savedSnapshot = MovementDerivation.snapshot(from: oldMovement, context: context)
        savedSnapshot.deadlines.append(manualDeadline)
        let savedJournal = CaseEventJournal(events: [seedEvent])

        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.upsert(
                context: context, snapshot: savedSnapshot, movement: oldMovement,
                collections: ["Проверка #241"])
            key = record.key
            record.movementFetchedAt = expectedSuccessfulRefresh
            record.seenAt = seenAt
            record.eventJournal = savedJournal
            try store.save()
            savedMovement = try XCTUnwrap(record.movement)
            savedSnapshot = try XCTUnwrap(record.snapshot)

            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.protocolClasses = [Issue241FlappingURLProtocol.self]
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            sessionConfiguration.httpCookieStorage = nil
            sessionConfiguration.httpShouldSetCookies = false
            let session = URLSession(configuration: sessionConfiguration)
            defer { session.invalidateAndCancel() }

            let captchaStore = CaptchaTokenStore()
            let client = SudrfClient(
                session: session, minInterval: 0,
                variantStore: WorkingVariantStore(cacheURL: directory.appendingPathComponent("variants.json")),
                captchaStore: captchaStore)
            let center = RefreshCenter(
                store: store, client: client,
                serviceBuilder: { ctx in ctx.makeService(client: client) },
                fsspAutoModelEnabled: false)

            // Three maintenance replies to one unchanged 3KSOU search URL must not
            // replace the saved instance, act, snapshot, or last-success timestamp.
            Issue241FlappingURLProtocol.configure(.exhaustedMaintenance)
            let maintenance = await center.refresh(key: key, manually: true)?.value
            guard case .partial = maintenance?.outcome else {
                return XCTFail("техработы 3 КСОЮ должны сохранить доступное частичное движение")
            }
            let maintenanceRequests = Issue241FlappingURLProtocol.requests()
            let exhaustedSearch = maintenanceRequests.filter {
                $0.0.host == issue241CassationDomain && queryValue("name_op", in: $0.0) == "r"
            }
            XCTAssertEqual(exhaustedSearch.map(\.1), ["maintenance", "maintenance", "maintenance"])
            XCTAssertEqual(Set(exhaustedSearch.map { $0.0.absoluteString }).count, 1,
                           "все три попытки должны повторить тот же URL выдачи")
            try assertPreserved(store: store, key: key,
                                movement: savedMovement, snapshot: savedSnapshot,
                                oldSuccessfulRefresh: expectedSuccessfulRefresh, seenAt: seenAt,
                                journal: savedJournal, manualDeadline: manualDeadline)

            // Card requests have their own exact-URL host fallbacks. Three
            // maintenance replies must preserve the card, act, snapshot and TTL.
            Issue241FlappingURLProtocol.configure(.exhaustedCardMaintenance)
            let failedCardRefresh = await center.refresh(key: key, manually: true)?.value
            XCTAssertEqual(failedCardRefresh?.outcome, .partial(
                "Не обновился источник 3kas.sudrf.ru; сохранены последние успешные данные."))
            let failedCardRequests = Issue241FlappingURLProtocol.requests().filter {
                $0.0.host == issue241CassationDomain && queryValue("name_op", in: $0.0) == "case"
            }
            XCTAssertEqual(failedCardRequests.map(\.1), Array(repeating: "maintenance", count: 3))
            XCTAssertEqual(Set(failedCardRequests.map { $0.0.absoluteString }).count, 1,
                           "повторные card-запросы должны использовать одну и ту же ссылку")
            try assertPreserved(store: store, key: key,
                                movement: savedMovement, snapshot: savedSnapshot,
                                oldSuccessfulRefresh: expectedSuccessfulRefresh, seenAt: seenAt,
                                journal: savedJournal, manualDeadline: manualDeadline)

            // A server-rejected cached code is a distinct captcha outcome; it
            // invalidates the token instead of masquerading as maintenance.
            let rejectedToken = CaptchaToken(value: "synthetic-code", id: "synthetic-token")
            await captchaStore.store(rejectedToken, domain: issue241CassationDomain)
            Issue241FlappingURLProtocol.configure(.captchaRejected)
            do {
                _ = try await client.search(
                    court: Court(domain: issue241CassationDomain,
                                 title: "Третий кассационный суд общей юрисдикции", level: .cassation),
                    cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .cassation, id: "g3")),
                    field: .uid, value: judicialUID)
                XCTFail("ожидался отдельный исход captchaRejected/captchaRequired")
            } catch SudrfError.captchaRequired {
                // Expected client boundary for a source-rejected token.
            } catch SudrfError.sourceMaintenance {
                XCTFail("отклонённая captcha не должна классифицироваться как maintenance")
            }
            let remainingToken = await captchaStore.token(forDomain: issue241CassationDomain)
            XCTAssertNil(remainingToken,
                         "отвергнутая пара captcha должна быть инвалидирована")
            let rejectionRequests = Issue241FlappingURLProtocol.requests().filter {
                $0.0.host == issue241CassationDomain && queryValue("name_op", in: $0.0) == "r"
            }
            XCTAssertTrue(rejectionRequests.contains {
                queryValue("captcha", in: $0.0) == rejectedToken.value
            })
            XCTAssertTrue(rejectionRequests.allSatisfy { $0.1 == "captchaRejected" })
            try assertPreserved(store: store, key: key,
                                movement: savedMovement, snapshot: savedSnapshot,
                                oldSuccessfulRefresh: expectedSuccessfulRefresh, seenAt: seenAt,
                                journal: savedJournal, manualDeadline: manualDeadline)

            let captchaRefresh = await center.refresh(key: key, manually: true)?.value
            XCTAssertEqual(captchaRefresh?.outcome, .partial(
                "Не обновился источник 3kas.sudrf.ru; сохранены последние успешные данные."))
            XCTAssertEqual(center.captchaPendingCount(forHost: issue241CassationDomain), 1,
                           "server rejection must reach RefreshCenter's captcha queue")
            XCTAssertNotEqual(store.record(forKey: key)?.sourceRefreshAttempt?.kind, .maintenance,
                              "captcha rejection must remain distinct from maintenance")
            let afterCaptcha = try XCTUnwrap(store.record(forKey: key))
            XCTAssertEqual(afterCaptcha.movementFetchedAt, expectedSuccessfulRefresh)
            XCTAssertEqual(afterCaptcha.seenAt, seenAt,
                           "captcha availability must not make unchanged case history unread")
            XCTAssertEqual(afterCaptcha.movement?.actBodies[cassationActID],
                           savedMovement.actBodies[cassationActID])
            XCTAssertEqual(afterCaptcha.snapshot?.deadlines.first {
                $0.occurrenceKey == manualDeadline.occurrenceKey
            }, manualDeadline)
            XCTAssertEqual(afterCaptcha.collectionNames, ["Проверка #241"])
            XCTAssertEqual(afterCaptcha.eventJournal, savedJournal)

            // The same search URL and the exact linked card URL each recover
            // independently after two maintenance replies.
            Issue241FlappingURLProtocol.configure(.flapping)
            let recovered = await center.refresh(key: key, manually: true)?.value
            XCTAssertEqual(recovered?.outcome, .refreshed)
            let recoveryRequests = Issue241FlappingURLProtocol.requests()
            let recoverySearch = recoveryRequests.filter {
                $0.0.host == issue241CassationDomain && queryValue("name_op", in: $0.0) == "r"
            }
            let recoveryCard = recoveryRequests.filter {
                $0.0.host == issue241CassationDomain && queryValue("name_op", in: $0.0) == "case"
            }
            XCTAssertEqual(Array(recoverySearch.prefix(3).map(\.1)), ["maintenance", "maintenance", "results"])
            XCTAssertEqual(Set(recoverySearch.map { $0.0.absoluteString }).count, 1,
                           "повторы выдачи должны отправлять идентичный URL")
            XCTAssertEqual(recoveryCard.map(\.1), ["maintenance", "maintenance", "card"])
            XCTAssertEqual(recoveryCard.map { $0.0.absoluteString },
                           Array(repeating: cassationURL.absoluteString, count: 3),
                           "повторы карточки должны отправлять опубликованный URL без реконструкции")

            let updated = try XCTUnwrap(store.record(forKey: key))
            let successfulRefresh = try XCTUnwrap(updated.movementFetchedAt)
            XCTAssertGreaterThan(successfulRefresh, expectedSuccessfulRefresh)
            XCTAssertEqual(successfulRefresh, updated.sourceRefreshAttempt?.provenance.observedAt)
            expectedSuccessfulRefresh = successfulRefresh
            XCTAssertEqual(updated.collectionNames, ["Проверка #241"])
            XCTAssertEqual(updated.snapshot?.deadlines.first {
                $0.occurrenceKey == manualDeadline.occurrenceKey
            }, manualDeadline)
            XCTAssertEqual(updated.movement?.instances.filter {
                $0.domain == issue241CassationDomain && $0.caseNumber == cassationNumber
            }.count, 1)
            XCTAssertEqual(updated.movement?.acts.filter { $0.id == cassationActID }.count, 1)
            XCTAssertEqual(updated.movement?.actBodies[cassationActID], publishedActText)
            XCTAssertEqual(updated.movement?.instances.first {
                $0.domain == issue241CassationDomain && $0.caseNumber == cassationNumber
            }?.sourceURL?.absoluteString, cassationURL.absoluteString)
            XCTAssertTrue(updated.eventJournal?.events.contains(seedEvent) == true)
            XCTAssertEqual(Set(updated.eventJournal?.events.map(\.id) ?? []).count,
                           updated.eventJournal?.events.count,
                           "журнал не должен повторять старые события")
        }

        // A fresh disk container reads the recovered link/act exactly once. A
        // further refresh from that reopened store must not duplicate either.
        let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        try assertRecoveredState(store: reopened, key: key,
                                 cassationURL: cassationURL,
                                 cassationNumber: cassationNumber,
                                 actID: cassationActID,
                                 actText: publishedActText,
                                 seedEventID: seedEvent.id,
                                 manualDeadline: manualDeadline)

        do {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.protocolClasses = [Issue241FlappingURLProtocol.self]
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            sessionConfiguration.httpCookieStorage = nil
            sessionConfiguration.httpShouldSetCookies = false
            let session = URLSession(configuration: sessionConfiguration)
            defer { session.invalidateAndCancel() }
            let client = SudrfClient(
                session: session, minInterval: 0,
                variantStore: WorkingVariantStore(cacheURL: directory.appendingPathComponent("reopened-variants.json")),
                captchaStore: CaptchaTokenStore())
            let center = RefreshCenter(
                store: reopened, client: client,
                serviceBuilder: { ctx in ctx.makeService(client: client) },
                fsspAutoModelEnabled: false)
            Issue241FlappingURLProtocol.configure(.steady)
            let beforeRepeat = try XCTUnwrap(reopened.record(forKey: key))
            let beforeRepeatJournal = beforeRepeat.eventJournal
            let beforeRepeatSuccess = try XCTUnwrap(beforeRepeat.movementFetchedAt)
            let repeated = await center.refresh(key: key, manually: true)?.value
            XCTAssertEqual(repeated?.outcome, .refreshed)
            let afterRepeat = try XCTUnwrap(reopened.record(forKey: key))
            XCTAssertEqual(afterRepeat.eventJournal, beforeRepeatJournal,
                           "an identical refresh must not replay old event notifications")
            XCTAssertGreaterThan(try XCTUnwrap(afterRepeat.movementFetchedAt), beforeRepeatSuccess)
        }
        try assertRecoveredState(store: reopened, key: key,
                                 cassationURL: cassationURL,
                                 cassationNumber: cassationNumber,
                                 actID: cassationActID,
                                 actText: publishedActText,
                                 seedEventID: seedEvent.id,
                                 manualDeadline: manualDeadline)
    }

    private func makeContext(rootURL: URL) -> MovementContext {
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Синтетический регион",
            searchDomain: issue241RootDomain,
            displayDomain: "district-issue241.sudrf.ru",
            courtTitle: "Синтетический районный суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "99RS0001",
            cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: rootNumber,
            caseID: "issue241-root-card",
            caseUID: "issue241-root-guid",
            judicialUID: judicialUID,
            baseInstanceLevelRaw: CaseInstance.Level.first.rawValue)
        context.cardURLString = rootURL.absoluteString
        context.higherCourtTargets = [MovementSearchTarget(
            domain: issue241CassationDomain,
            courtTitle: "Третий кассационный суд общей юрисдикции",
            courtLevel: .cassation,
            instanceLevel: .cassation,
            cartotekaIDs: ["g3"])]
        return context
    }

    private func assertPreserved(
        store: TrackedStore, key: String, movement: CaseMovement, snapshot: CaseSnapshot,
        oldSuccessfulRefresh: Date, seenAt: Date, journal: CaseEventJournal,
        manualDeadline: StoredDeadline,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(store.all().count, 1, file: file, line: line)
        let record = try XCTUnwrap(store.record(forKey: key), file: file, line: line)
        XCTAssertEqual(record.movement, movement, "cached movement/act changed on outage", file: file, line: line)
        XCTAssertEqual(record.snapshot, snapshot, "snapshot changed on outage", file: file, line: line)
        XCTAssertEqual(record.movementFetchedAt, oldSuccessfulRefresh, file: file, line: line)
        XCTAssertEqual(record.seenAt, seenAt, "user read state changed on outage", file: file, line: line)
        XCTAssertEqual(record.collectionNames, ["Проверка #241"], file: file, line: line)
        XCTAssertEqual(record.eventJournal, journal, "old event notifications were replayed", file: file, line: line)
        XCTAssertEqual(record.snapshot?.deadlines.first {
            $0.occurrenceKey == manualDeadline.occurrenceKey
        }, manualDeadline, file: file, line: line)
    }

    private func assertRecoveredState(
        store: TrackedStore, key: String, cassationURL: URL, cassationNumber: String,
        actID: String, actText: String, seedEventID: String, manualDeadline: StoredDeadline,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(store.all().count, 1, file: file, line: line)
        let record = try XCTUnwrap(store.record(forKey: key), file: file, line: line)
        let movement = try XCTUnwrap(record.movement, file: file, line: line)
        let cards = movement.instances.filter {
            $0.domain == issue241CassationDomain && $0.caseNumber == cassationNumber
        }
        XCTAssertEqual(cards.count, 1, "card was duplicated after reopen", file: file, line: line)
        XCTAssertEqual(cards.first?.sourceURL?.absoluteString, cassationURL.absoluteString, file: file, line: line)
        XCTAssertEqual(cards.first?.linkedActIDs, [actID], file: file, line: line)
        XCTAssertEqual(movement.acts.filter { $0.id == actID }.count, 1, file: file, line: line)
        XCTAssertEqual(movement.actBodies[actID], actText, file: file, line: line)
        XCTAssertTrue(CourtActPresentation.rows(in: movement).contains {
            $0.sourceIDs.contains(actID) && $0.text == actText
        }, "persisted act must remain available through the panel model", file: file, line: line)
        XCTAssertEqual(record.collectionNames, ["Проверка #241"], file: file, line: line)
        XCTAssertEqual(record.snapshot?.deadlines.first {
            $0.occurrenceKey == manualDeadline.occurrenceKey
        }, manualDeadline, file: file, line: line)
        let events = record.eventJournal?.events ?? []
        XCTAssertEqual(events.filter { $0.id == seedEventID }.count, 1,
                       "the prior event must remain singular after disk reopen", file: file, line: line)
        XCTAssertEqual(Set(events.map(\.id)).count, events.count,
                       "repeated refresh must not duplicate event notifications", file: file, line: line)
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == name }?.value
    }
}

private enum Issue241FlappingURLProtocolRoot {
    static let html = """
        <html><body>
          <div class="casenumber">ДЕЛО № 2-241/2026</div>
          <ul class="tabs"><li id="tab1"><a>ДЕЛО</a></li></ul>
          <div id="cont1"><table>
            <tr><td>Уникальный идентификатор дела</td><td>99RS0001-01-2026-000241-10</td></tr>
          </table></div>
        </body></html>
        """
}
