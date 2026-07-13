import XCTest
import SudrfKit
@testable import SudrfApp

private actor StubOriginResolver: CaseOriginResolving {
    enum Mode: Sendable { case resolved(ResolvedCaseOrigin), ambiguous, transient }
    let mode: Mode
    private(set) var calls = 0

    init(_ mode: Mode) { self.mode = mode }

    func resolve(anchorContext: MovementContext,
                 anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        calls += 1
        switch mode {
        case .resolved(let origin): return origin
        case .ambiguous: throw CaseOriginResolutionError.ambiguous
        case .transient:
            throw SudrfError.transientNetworkError(
                domain: anchorContext.searchDomain, code: .timedOut, attempt: 3)
        }
    }
}

@MainActor
final class TrackedCaseRepairTests: XCTestCase {
    private let uid = "11RS0001-01-2025-011255-03"

    func testKeyRemapResolvesTransitiveMappings() {
        var summary = CaseRepairSummary()
        summary.keyRemaps = ["old": "intermediate", "intermediate": "canonical"]

        XCTAssertEqual(summary.effectiveKey(for: "old"), "canonical")
        XCTAssertEqual(summary.effectiveKey(for: "intermediate"), "canonical")
        XCTAssertEqual(summary.effectiveKey(for: "untouched"), "untouched")
    }

    private func context(level: CaseInstance.Level, number: String,
                         domain: String, cartoteka: String,
                         courtLevel: CourtLevel) -> MovementContext {
        var ctx = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: domain,
            displayDomain: SudrfHost.alternate(domain) ?? domain,
            courtTitle: courtLevel == .district
                ? "Сыктывкарский городской суд"
                : "Верховный Суд Республики Коми",
            courtLevelRaw: courtLevel.rawValue, courtCode: "11RS0001",
            cartotekaId: cartoteka, cartotekaLevelRaw: courtLevel.rawValue,
            caseNumber: number, caseID: "id-\(number)", caseUID: "guid-\(number)",
            cardURLString: "https://\(domain)/modules.php?name=sud_delo&name_op=case&case_id=id-\(number)&case_uid=guid-\(number)&delo_id=5&new=5")
        ctx.judicialUID = uid
        ctx.baseInstanceLevelRaw = level.rawValue
        return ctx
    }

    private func movement(level: CaseInstance.Level, number: String,
                          domain: String, actID: String) -> CaseMovement {
        let session = CaseSession(date: "18.08.2025", event: "Судебное заседание",
                                  result: "Вынесено решение")
        let inForce = CaseSession(date: "20.08.2025",
                                  event: "Вступило в законную силу")
        let instance = CaseInstance(level: level, court: "Суд", caseNumber: number,
                                    judge: nil, domain: domain, foundByUID: level != .first,
                                    result: "Решение", sessions: [session, inForce], actID: actID)
        let act = CaseAct(id: actID, title: "Акт", date: "18.08.2025",
                          courtShort: "Суд", instanceLevel: level)
        return CaseMovement(uid: uid, caseNumber: number, inForce: true,
                            instances: [instance], complaints: [:], acts: [act],
                            actBodies: [actID: "Текст \(actID)"])
    }

    private func defaults() -> UserDefaults {
        let suite = "TrackedCaseRepairTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func unusedResolver() -> StubOriginResolver {
        StubOriginResolver(.ambiguous)
    }

    func testMergesSameUIDPreservingUserStateAndIsIdempotent() async throws {
        let store = TrackedStore(inMemory: true)
        let first = context(level: .first, number: "2-7212/2025",
                            domain: "syktsud--komi.sudrf.ru", cartoteka: "g1",
                            courtLevel: .district)
        let appeal = context(level: .appeal, number: "33-4818/2025",
                             domain: "vs--komi.sudrf.ru", cartoteka: "g2",
                             courtLevel: .subject)
        let firstMovement = movement(level: .first, number: first.caseNumber,
                                     domain: first.searchDomain, actID: "first-act")
        let appealMovement = movement(level: .appeal, number: appeal.caseNumber,
                                      domain: appeal.searchDomain, actID: "appeal-act")
        var firstSnapshot = MovementDerivation.snapshot(from: firstMovement, context: first)
        var appealSnapshot = MovementDerivation.snapshot(from: appealMovement, context: appeal)
        XCTAssertFalse(firstSnapshot.deadlines.isEmpty)
        XCTAssertFalse(appealSnapshot.deadlines.isEmpty)
        firstSnapshot.deadlines[0].statusRaw = "confirmed"
        firstSnapshot.deadlines[0].dateRef = 111
        appealSnapshot.deadlines[0].statusRaw = "confirmed"
        appealSnapshot.deadlines[0].dateRef = 222
        let survivor = store.upsert(context: first,
                                    snapshot: firstSnapshot,
                                    movement: firstMovement, collections: ["A"])
        let duplicate = store.upsert(context: appeal,
                                     snapshot: appealSnapshot,
                                     movement: appealMovement, collections: ["B", "A"])
        survivor.addedAt = Date(timeIntervalSince1970: 200)
        survivor.seenAt = Date(timeIntervalSince1970: 300)
        duplicate.addedAt = Date(timeIntervalSince1970: 100)
        duplicate.seenAt = nil
        store.save()

        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: unusedResolver(),
            defaults: defaults(), anchorCardFetcher: { _ in
                XCTFail("network repair should not run after first-instance UID merge")
                throw CaseOriginResolutionError.notFound
            })
        let summary = await coordinator.runAll()

        XCTAssertEqual(summary.merged, 1)
        XCTAssertEqual(store.all().count, 1)
        let merged = try XCTUnwrap(store.record(forKey: first.key))
        XCTAssertEqual(merged.collectionNames, ["A", "B"])
        XCTAssertEqual(merged.addedAt, Date(timeIntervalSince1970: 100))
        XCTAssertNil(merged.seenAt)
        XCTAssertEqual(Set(merged.movement?.acts.map(\.id) ?? []), ["first-act", "appeal-act"])
        XCTAssertEqual(merged.movement?.actBodies.count, 2)
        XCTAssertEqual(merged.snapshot?.deadlines.first?.statusRaw, "confirmed")
        XCTAssertEqual(merged.snapshot?.deadlines.first?.dateRef, 111,
                       "confirmed deadline of canonical record must win")
        XCTAssertNil(merged.movementFetchedAt)

        let second = await coordinator.runAll()
        XCTAssertFalse(second.hasReport)
        XCTAssertEqual(store.all().count, 1)
    }

    func testReanchorsHigherCardAndKeepsOriginalKnownCard() async throws {
        let store = TrackedStore(inMemory: true)
        let appeal = context(level: .appeal, number: "33-4818/2025",
                             domain: "vs--komi.sudrf.ru", cartoteka: "g2",
                             courtLevel: .subject)
        store.upsert(context: appeal, snapshot: nil, collections: ["Import"])
        let lowerCard = CaseCard(rawText: "", actText: nil, uid: uid,
                                 caseNumber: "2-7212/2025")
        let origin = ResolvedCaseOrigin(
            court: Court(domain: "syktsud--komi.sudrf.ru",
                         title: "Сыктывкарский городской суд", level: .district),
            branch: .general, region: "Республика Коми", courtCode: "11RS0001",
            cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1")),
            result: CaseSearchResult(caseNumber: "2-7212/2025",
                                     caseID: "lower-id", caseUID: "lower-guid"),
            card: lowerCard)
        let resolver = StubOriginResolver(.resolved(origin))
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: resolver,
            defaults: defaults(), anchorCardFetcher: { _ in
                CaseCard(rawText: "", actText: nil, uid: self.uid,
                         caseNumber: "33-4818/2025",
                         lowerCourt: LowerCourtReference(
                            courtTitle: "Сыктывкарский городской суд",
                            caseNumber: "2-7212/2025"))
            })

        let summary = await coordinator.runAll()

        XCTAssertEqual(summary.reanchored, 1)
        let canonicalKey = "syktsud.komi.sudrf.ru/2-7212/2025"
        XCTAssertEqual(summary.keyRemaps[appeal.key], canonicalKey)
        XCTAssertNil(store.record(forKey: appeal.key))
        let canonical = try XCTUnwrap(store.record(forKey: canonicalKey))
        XCTAssertEqual(canonical.context?.baseInstanceLevel, .first)
        XCTAssertEqual(canonical.context?.knownCards?.first?.caseNumber, "33-4818/2025")

        let second = await coordinator.runAll()
        XCTAssertFalse(second.hasReport)
    }

    func testAmbiguousResultDoesNotDeleteRecord() async {
        let store = TrackedStore(inMemory: true)
        let appeal = context(level: .appeal, number: "33-9/2026",
                             domain: "vs--komi.sudrf.ru", cartoteka: "g2",
                             courtLevel: .subject)
        store.upsert(context: appeal, snapshot: nil, collections: [])
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(),
            originResolver: StubOriginResolver(.ambiguous), defaults: defaults(),
            anchorCardFetcher: { _ in CaseCard(rawText: "", actText: nil) })

        let summary = await coordinator.runAll()

        XCTAssertEqual(summary.unresolved, [appeal.caseNumber])
        XCTAssertNotNil(store.record(forKey: appeal.key))
        XCTAssertEqual(store.all().count, 1)
    }

    func testTransientRepairUsesPersistentBackoff() async {
        let store = TrackedStore(inMemory: true)
        let appeal = context(level: .appeal, number: "33-10/2026",
                             domain: "vs--komi.sudrf.ru", cartoteka: "g2",
                             courtLevel: .subject)
        store.upsert(context: appeal, snapshot: nil, collections: [])
        let resolver = StubOriginResolver(.transient)
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: resolver,
            defaults: defaults(), now: { Date(timeIntervalSince1970: 1_000) },
            anchorCardFetcher: { _ in CaseCard(rawText: "", actText: nil) })

        let first = await coordinator.runAll()
        let second = await coordinator.runAll()
        let calls = await resolver.calls

        XCTAssertEqual(first.transient, 1)
        XCTAssertFalse(second.hasReport)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(store.record(forKey: appeal.key))
    }

    func testMovementMergeDeduplicatesDashDotActsByHostAndCaseNumber() throws {
        let first = movement(level: .appeal, number: "33-1/2026",
                             domain: "vs--komi.sudrf.ru",
                             actID: "act_vs--komi.sudrf.ru#33-1/2026")
        let duplicate = movement(level: .appeal, number: "33-1/2026",
                                 domain: "vs.komi.sudrf.ru",
                                 actID: "act_vs.komi.sudrf.ru#33-1/2026")

        let merged = try XCTUnwrap(TrackedCaseRepairCoordinator.mergeMovements([first, duplicate]))

        XCTAssertEqual(merged.instances.count, 1)
        XCTAssertEqual(merged.acts.count, 1)
        XCTAssertEqual(merged.actBodies.count, 1)
    }
}
