import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue87Source: CaseProviding {
    private let uid = "11RS0001-01-2026-005022-94"
    private let baseCard: CaseCard
    private let rows: [String: [CaseSearchResult]]
    private let cardsByURL: [URL: CaseCard]
    private(set) var requests: [(String, String, String)] = []

    init(baseCard: CaseCard, rows: [String: [CaseSearchResult]],
         cardsByURL: [URL: CaseCard]) {
        self.baseCard = baseCard
        self.rows = rows
        self.cardsByURL = cardsByURL
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        requests.append((court.domain, cartoteka.id, value))
        guard field == .uid, value == uid else { return [] }
        return rows["\(court.domain)/\(cartoteka.id)"] ?? []
    }

    func searchComplete(court: Court, cartoteka: Cartoteka,
                        field: SearchField, value: String,
                        srvNum: Int) async throws -> [CaseSearchResult] {
        try await search(court: court, cartoteka: cartoteka,
                         field: field, value: value)
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        if (url.host ?? "").contains("syktsud") {
            return cardsByURL[url] ?? baseCard
        }
        guard let card = cardsByURL[url] else { throw SudrfError.http(status: 404) }
        return card
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        guard caseID == "35768698" else { throw SudrfError.http(status: 404) }
        return baseCard
    }

    func searched() -> [(String, String, String)] { requests }
}

@MainActor
final class Issue87BackgroundDiscoveryTests: XCTestCase {
    private let uid = "11RS0001-01-2026-005022-94"

    func testPeriodicRefreshDiscoversKSOYuWithoutOpeningCaseAndPersistsIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-87-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let context = try makeContext()
        let cached = cachedMovement()
        let record = try store.upsert(
            context: context,
            snapshot: MovementDerivation.snapshot(from: cached, context: context),
            movement: cached, collections: ["КоАП"])
        record.movementFetchedAt = .distantPast
        try store.save()

        let fixture = try sourceFixture()
        let source = Issue87Source(
            baseCard: fixture.baseCard, rows: fixture.rows, cardsByURL: fixture.cards)
        let center = RefreshCenter(
            store: store, client: SudrfClient(minInterval: 0),
            serviceBuilder: { context in context.makeService(client: source) },
            initialTimerDelay: .seconds(60), timerInterval: .seconds(60))

        let initialWalk = center.start()
        await initialWalk?.value

        let refreshed = try XCTUnwrap(store.record(forKey: record.key))
        let cassation = try XCTUnwrap(refreshed.movement?.instances.first {
            $0.caseNumber == "16-5132/2026"
        })
        XCTAssertEqual(cassation.level, .cassation)
        XCTAssertEqual(cassation.sourceURL, fixture.cassationURL)
        XCTAssertEqual(
            refreshed.sourceRefreshAttempt?.kind, .usableSnapshot,
            "incomplete=\(refreshed.movement?.incompleteHigherCourtDomains ?? []), "
                + "honestZero=\(refreshed.movement?.honestZeroDomains ?? []), "
                + "affected=\(refreshed.sourceRefreshAttempt?.provenance.affectedSources ?? [])")
        XCTAssertEqual(refreshed.movementFetchedAt,
                       refreshed.sourceRefreshAttempt?.provenance.observedAt)
        XCTAssertTrue(refreshed.eventJournal?.events.contains {
            $0.kind == .instanceDiscovered
                && $0.evidence.caseNumber == "16-5132/2026"
        } == true)
        XCTAssertEqual(store.all().count, 1)
        let requests = await source.searched()
        XCTAssertTrue(requests.contains {
            $0.0 == "3kas.sudrf.ru" && $0.1 == "adm3" && $0.2 == uid
        })

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let persisted = try XCTUnwrap(reopened.record(forKey: record.key))
        XCTAssertEqual(reopened.all().count, 1)
        XCTAssertEqual(persisted.movement?.instances.filter {
            $0.caseNumber == "16-5132/2026"
        }.count, 1)
        XCTAssertEqual(persisted.movement?.instances.first {
            $0.caseNumber == "16-5132/2026"
        }?.sourceURL, fixture.cassationURL)
    }

    func testStartIsIdempotentAndStartsInitialWalkImmediately() async throws {
        let store = TrackedStore(inMemory: true)
        let context = try makeContext()
        _ = try store.upsert(context: context, snapshot: nil,
                             movement: nil, collections: [])
        let fixture = try sourceFixture()
        let source = Issue87Source(
            baseCard: fixture.baseCard, rows: fixture.rows, cardsByURL: fixture.cards)
        let center = RefreshCenter(
            store: store, client: SudrfClient(minInterval: 0),
            serviceBuilder: { context in context.makeService(client: source) },
            initialTimerDelay: .seconds(60), timerInterval: .seconds(60))

        let first = center.start()
        _ = center.start()
        await first?.value

        let baseFetches = await source.searched().filter {
            $0.0 == "syktsud--komi.sudrf.ru"
        }
        XCTAssertFalse(baseFetches.isEmpty)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertNil(center.walkProgress)
    }

    private func makeContext() throws -> MovementContext {
        return MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд Республики Коми",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: "adm", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "5-469/2026", caseID: "35768698", caseUID: "base-guid",
            judicialUID: uid,
            higherCourtTargets: [
                MovementSearchTarget(
                    domain: "vs--komi.sudrf.ru",
                    courtTitle: "Верховный Суд Республики Коми",
                    courtLevel: .subject, instanceLevel: .appeal,
                    cartotekaIDs: ["adm1"]),
                MovementSearchTarget(
                    domain: "3kas.sudrf.ru",
                    courtTitle: "Третий кассационный суд общей юрисдикции",
                    courtLevel: .cassation, instanceLevel: .cassation,
                    cartotekaIDs: ["adm3"])
            ])
    }

    private func cachedMovement() -> CaseMovement {
        CaseMovement(
            uid: uid, caseNumber: "5-469/2026", inForce: true,
            instances: [
                CaseInstance(
                    level: .first,
                    court: "Сыктывкарский городской суд Республики Коми",
                    caseNumber: "5-469/2026", judge: nil,
                    domain: "syktsud--komi.sudrf.ru", foundByUID: false,
                    result: "Назначено административное наказание",
                    sessions: [CaseSession(
                        date: "20.05.2026", event: "Рассмотрение дела по существу",
                        result: "Назначено административное наказание")]),
                CaseInstance(
                    level: .appeal, court: "Верховный Суд Республики Коми",
                    caseNumber: "12-77/2026", judge: nil,
                    domain: "vs--komi.sudrf.ru", foundByUID: true,
                    result: "Оставлено без изменения",
                    sessions: [CaseSession(
                        date: "24.06.2026", event: "Судебное заседание",
                        result: "Оставлено без изменения")])
            ], complaints: [:], acts: [])
    }

    private func sourceFixture() throws -> (
        baseCard: CaseCard,
        rows: [String: [CaseSearchResult]],
        cards: [URL: CaseCard],
        cassationURL: URL
    ) {
        let appealURL = try XCTUnwrap(URL(string:
            "https://vs--komi.sudrf.ru/modules.php?name=sud_delo&srv_num=1"
                + "&name_op=case&case_id=appeal-card&case_uid=appeal-guid"
                + "&delo_id=1502001&new=0"))
        let cassationURL = try XCTUnwrap(URL(string:
            "https://3kas.sudrf.ru/modules.php?name=sud_delo&srv_num=1"
                + "&name_op=case&case_id=25004446&case_uid=cassation-guid"
                + "&delo_id=2550001&new=0"))
        let materialURL = try XCTUnwrap(URL(string:
            "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&srv_num=1"
                + "&name_op=case&case_id=material-card&case_uid=material-guid"
                + "&delo_id=1610001&new=0"))
        let appealRow = CaseSearchResult(
            caseNumber: "12-77/2026", decisionDate: "24.06.2026",
            result: "Оставлено без изменения", caseID: "appeal-card",
            caseUID: "appeal-guid", cardURL: appealURL)
        let baseRow = CaseSearchResult(
            caseNumber: "5-469/2026", receiptDate: "14.05.2026",
            caseID: "35768698", caseUID: "base-guid")
        let cassationRow = CaseSearchResult(
            caseNumber: "16-5132/2026", receiptDate: "19.08.2026",
            caseID: "25004446", caseUID: "cassation-guid", cardURL: cassationURL)
        let materialRow = CaseSearchResult(
            caseNumber: "15-108/2026", receiptDate: "30.06.2026",
            caseID: "material-card", caseUID: "material-guid", cardURL: materialURL)
        return (
            CaseCard(
                rawText: "", actText: nil,
                sessions: [CaseSession(
                    date: "20.05.2026", event: "Рассмотрение дела по существу",
                    result: "Назначено административное наказание")],
                result: "Назначено административное наказание",
                uid: uid, caseNumber: "5-469/2026"),
            [
                "syktsud--komi.sudrf.ru/adm": [baseRow],
                "syktsud--komi.sudrf.ru/m": [materialRow],
                "vs--komi.sudrf.ru/adm1": [appealRow],
                "3kas.sudrf.ru/adm3": [cassationRow]
            ],
            [
                materialURL: CaseCard(
                    rawText: "", actText: nil,
                    sessions: [CaseSession(
                        date: "30.06.2026", event: "Регистрация материала")],
                    uid: uid, caseNumber: "15-108/2026"),
                appealURL: CaseCard(
                    rawText: "", actText: nil,
                    sessions: [CaseSession(
                        date: "24.06.2026", event: "Судебное заседание",
                        result: "Оставлено без изменения")],
                    result: "Оставлено без изменения", uid: uid,
                    caseNumber: "12-77/2026"),
                cassationURL: CaseCard(
                    rawText: "", actText: nil,
                    sessions: [CaseSession(
                        date: "19.08.2026", event: "Поступление жалобы в суд")],
                    uid: uid, caseNumber: "16-5132/2026")
            ],
            cassationURL)
    }
}
