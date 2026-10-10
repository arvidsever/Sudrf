// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import XCTest
import Foundation
@testable import SudrfKit
@testable import SudrfApp

private final class Magistrate450NoNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

private struct Magistrate450NoVSRF: VSRFProviding {
    func search(uniqueNumber: String?, oldCaseNumber: String?,
                keywords: String?) async throws -> VSRFSearchResults { throw CancellationError() }
    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard {
        throw CancellationError()
    }
}

@MainActor
final class MagistrateTransitionRefreshTests: XCTestCase {
    private actor MagistrateRouteClient: CaseProviding {
        let base: CaseCard
        let rows: [String: [CaseSearchResult]]
        let cards: [String: CaseCard]
        var partialHost: String?

        init(base: CaseCard, rows: [String: [CaseSearchResult]], cards: [String: CaseCard]) {
            self.base = base; self.rows = rows; self.cards = cards
        }

        func setPartialHost(_ host: String?) { partialHost = host }

        func search(court: Court, cartoteka: Cartoteka,
                    field: SearchField, value: String) async throws -> [CaseSearchResult] {
            rows[court.domain + "/" + cartoteka.id] ?? []
        }

        func searchOutcome(court: Court, cartoteka: Cartoteka,
                           field: SearchField, value: String,
                           operation: SourceOperation) async throws
            -> SourceOutcome<[CaseSearchResult]> {
            let attempt = SourceAttempt(
                kind: partialHost == court.domain ? .partial : .usableSnapshot,
                provenance: SourceProvenance(operation: operation,
                                             sourceFamily: "sudrf", host: court.domain))
            if partialHost == court.domain { return .partial(nil, attempt) }
            let found = rows[court.domain + "/" + cartoteka.id] ?? []
            return found.isEmpty ? .honestZero(attempt) : .usableSnapshot(found, attempt)
        }

        func fetchCard(court: Court, caseID: String, caseUID: String,
                       deloID: String, new: String) async throws -> CaseCard {
            if caseID == "base" { return base }
            guard let card = cards[caseID] else { throw SudrfError.http(status: 404) }
            return card
        }

        func fetchCard(url: URL) async throws -> CaseCard {
            if url.host == "example.komi.msudrf.ru" { return base }
            let id = try XCTUnwrap(SudrfCaseCardLink(url: url).caseID)
            guard let card = cards[id] else { throw SudrfError.http(status: 404) }
            return card
        }
    }

    func testMagistrateTransitionDiskRefreshPreservesCardsJournalAndTTL() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("magistrate-450-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let localStore = try TrackedStore(container: container, prepared: true)
        let uid = "11MS0001-01-2025-000001-01"
        var context = MovementContext(
            branchRaw: "general", region: "Республика Коми",
            searchDomain: "example.komi.msudrf.ru", displayDomain: "example.komi.msudrf.ru",
            courtTitle: "Мировой судья", courtLevelRaw: "magistrate", courtCode: "11MS0001",
            cartotekaId: "g1", cartotekaLevelRaw: "magistrate",
            caseNumber: "2-12/2025", caseID: "base", caseUID: "base-link",
            cardURLString: "https://example.komi.msudrf.ru/modules.php?name=sud_delo&op=cs&case_id=base&delo_id=1540005&new=0",
            judicialUID: uid)
        context.higherCourtTargets = [
            MovementSearchTarget(domain: "3kas.sudrf.ru", courtLevel: .cassation,
                                 instanceLevel: .cassation, cartotekaIDs: ["g3"],
                                 dateRule: .before2026),
            MovementSearchTarget(domain: "vs--komi.sudrf.ru", courtLevel: .subject,
                                 instanceLevel: .cassation, cartotekaIDs: ["g33"],
                                 dateRule: .from2026)]
        let g3 = try XCTUnwrap(CartotekaRegistry.find(level: .cassation, id: "g3"))
        let g33 = try XCTUnwrap(CartotekaRegistry.find(level: .subject, id: "g33"))
        func row(_ host: String, _ id: String, _ number: String,
                 _ level: CourtLevel, _ cart: Cartoteka) throws -> CaseSearchResult {
            let url = try SudrfURLBuilder(court: Court(domain: host, title: host, level: level))
                .cardURL(caseID: id, caseUID: "link-\(id)",
                         deloID: cart.deloID, new: cart.new)
            return CaseSearchResult(caseNumber: number, caseID: id,
                                    caseUID: "link-\(id)", cardURL: url)
        }
        let k = try row("3kas.sudrf.ru", "k", "8Г-10/2026", .cassation, g3)
        let s = try row("vs--komi.sudrf.ru", "s", "4Г-10/2026", .subject, g33)
        let source = MagistrateRouteClient(
            base: CaseCard(rawText: "", actText: nil, uid: uid,
                           caseNumber: "2-12/2025", legalForceDate: "01.01.2026",
                           processKind: .civil),
            rows: ["3kas.sudrf.ru/g3": [k], "vs--komi.sudrf.ru/g33": [s]],
            cards: ["k": CaseCard(rawText: "", actText: nil, uid: uid,
                                  caseNumber: "8Г-10/2026"),
                    "s": CaseCard(rawText: "", actText: nil, uid: uid,
                                  caseNumber: "4Г-10/2026")])
        let record = try localStore.upsert(context: context, snapshot: nil,
                                           movement: nil, collections: ["Личное"])
        let key = record.key
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Magistrate450NoNetwork.self]
        let tokenStore = CaptchaTokenStore()
        let privateClient = SudrfClient(
            session: URLSession(configuration: configuration), minInterval: 0,
            variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: tokenStore)
        func center(_ store: TrackedStore) -> RefreshCenter {
            RefreshCenter(store: store, client: privateClient,
                          captchaTokenStore: tokenStore,
                          serviceBuilder: { ctx in ctx.makeService(client: source) },
                          treasuryDiscover: { _, _, _ in throw CancellationError() },
                          vsrfProvider: Magistrate450NoVSRF(),
                          fsspAutoModelEnabled: false,
                          fsspDiscover: { _ in throw CancellationError() })
        }
        let firstCenter = center(localStore)
        let first = await firstCenter.refresh(key: key)?.value
        XCTAssertEqual(first?.outcome, .refreshed)
        let full = try XCTUnwrap(localStore.record(forKey: key))
        XCTAssertEqual(Set(full.movement?.instances.filter { $0.level == .cassation }
            .map(\.caseNumber) ?? []), ["8Г-10/2026", "4Г-10/2026"])
        XCTAssertEqual(full.collectionNames, ["Личное"])
        let ttl = full.movementFetchedAt
        let journal = full.eventJournal

        await source.setPartialHost("vs--komi.sudrf.ru")
        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        XCTAssertEqual(reopened.record(forKey: key)?.context?.higherCourtTargets?
            .map(\.dateRule), [.before2026, .from2026])
        let reopenedCenter = center(reopened)
        _ = await reopenedCenter.refresh(key: key)?.value
        let partial = try XCTUnwrap(reopened.record(forKey: key))
        XCTAssertEqual(partial.movementFetchedAt, ttl)
        XCTAssertEqual(partial.eventJournal, journal)
        XCTAssertEqual(partial.collectionNames, ["Личное"])
        XCTAssertEqual(Set(partial.movement?.instances.filter { $0.level == .cassation }
            .map(\.caseNumber) ?? []), ["8Г-10/2026", "4Г-10/2026"])

        await source.setPartialHost(nil)
        _ = await reopenedCenter.refresh(key: key)?.value
        let after = try XCTUnwrap(reopened.record(forKey: key))
        XCTAssertEqual(after.eventJournal, journal)
        XCTAssertEqual(Set(after.movement?.instances.filter { $0.level == .cassation }
            .map(\.caseNumber) ?? []), ["8Г-10/2026", "4Г-10/2026"])
    }

}
