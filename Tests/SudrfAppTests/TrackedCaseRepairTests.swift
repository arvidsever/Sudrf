import XCTest
import SudrfKit
import CaptchaSolver
@testable import SudrfApp

private actor StubOriginResolver: CaseOriginResolving {
    enum Mode: Sendable { case resolved(ResolvedCaseOrigin), ambiguous, noReference, notFound, transient }
    let mode: Mode
    private(set) var calls = 0

    init(_ mode: Mode) { self.mode = mode }

    func resolve(anchorContext: MovementContext,
                 anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        calls += 1
        switch mode {
        case .resolved(let origin): return origin
        case .ambiguous: throw CaseOriginResolutionError.ambiguous
        case .noReference: throw CaseOriginResolutionError.noReference
        case .notFound: throw CaseOriginResolutionError.notFound
        case .transient:
            throw SudrfError.transientNetworkError(
                domain: anchorContext.searchDomain, code: .timedOut, attempt: 3)
        }
    }
}

private actor PromotionOriginResolver: CaseOriginResolving {
    let origin: ResolvedCaseOrigin
    init(origin: ResolvedCaseOrigin) { self.origin = origin }
    func resolve(anchorContext: MovementContext,
                 anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        throw CaseOriginResolutionError.noReference
    }
    func resolveMainCase(anchorContext: MovementContext,
                         anchorCard: CaseCard) async throws -> ResolvedCaseOrigin { origin }
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

    /// Inserts the shape an existing V5 database can contain before V6 runs
    /// its common reconciler. Normal `store.upsert` deliberately cannot create
    /// these duplicates anymore.
    private func insertLegacy(
        into store: TrackedStore,
        context: MovementContext,
        snapshot: CaseSnapshot?,
        movement: CaseMovement? = nil,
        collections: [String]
    ) throws -> TrackedCaseRecord {
        let record = TrackedCaseRecord(
            key: context.key, collections: collections,
            caseNumber: context.caseNumber, courtTitle: context.courtTitle,
            displayDomain: context.displayDomain,
            contextData: try JSONEncoder().encode(context),
            snapshotData: snapshot.flatMap { try? JSONEncoder().encode($0) })
        record.judicialUID = context.judicialUID.map(TrackedStore.normalizedUID)
        record.movement = movement
        if movement != nil { record.movementFetchedAt = .now }
        store.container.mainContext.insert(record)
        XCTAssertTrue(store.save(projection: movement == nil ? .none : .cases([record.key])))
        return record
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
        let survivor = try insertLegacy(
            into: store, context: first, snapshot: firstSnapshot,
            movement: firstMovement, collections: ["A"])
        let duplicate = try insertLegacy(
            into: store, context: appeal, snapshot: appealSnapshot,
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

    func testUIDMergePreservesExecutionDocumentsAndEnforcementHistory() async throws {
        let store = TrackedStore(inMemory: true)
        let first = context(level: .first, number: "2-7212/2025",
                            domain: "syktsud--komi.sudrf.ru", cartoteka: "g1",
                            courtLevel: .district)
        let appeal = context(level: .appeal, number: "33-4818/2025",
                             domain: "vs--komi.sudrf.ru", cartoteka: "g2",
                             courtLevel: .subject)
        let sharedWrit = CourtEnforcementDocument(id: "writ-shared", blankNumber: "ФС № 1")
        let appealWrit = CourtEnforcementDocument(id: "writ-appeal", blankNumber: "ФС № 2")
        var firstMovement = movement(level: .first, number: first.caseNumber,
                                     domain: first.searchDomain, actID: "first-act")
        var appealMovement = movement(level: .appeal, number: appeal.caseNumber,
                                      domain: appeal.searchDomain, actID: "appeal-act")
        firstMovement.executionDocuments = [sharedWrit]
        appealMovement.executionDocuments = [sharedWrit, appealWrit]
        let survivor = try insertLegacy(
            into: store, context: first, snapshot: nil,
            movement: firstMovement, collections: [])
        let duplicate = try insertLegacy(
            into: store, context: appeal, snapshot: nil,
            movement: appealMovement, collections: [])
        let oldEvent = EnforcementEvent(guid: "rss-old", date: .now, text: "Принят", sourceOrder: 0)
        let freshEvent = EnforcementEvent(guid: "rss-fresh", date: .now, text: "Исполнен", sourceOrder: 1)
        survivor.enforcementRecords = [EnforcementRecord(
            courtDocumentID: sharedWrit.id, source: .treasury, sourceRecordID: "source-1",
            status: "Исполнен", events: [freshEvent],
            lastAttemptAt: Date(timeIntervalSince1970: 200),
            lastSuccessAt: Date(timeIntervalSince1970: 200))]
        duplicate.enforcementRecords = [
            EnforcementRecord(courtDocumentID: sharedWrit.id, source: .treasury,
                              sourceRecordID: "source-1", status: "Исполняется", events: [oldEvent],
                              lastAttemptAt: Date(timeIntervalSince1970: 100),
                              lastSuccessAt: Date(timeIntervalSince1970: 100)),
            EnforcementRecord(courtDocumentID: appealWrit.id, source: .treasury,
                              discoveryState: .notFound, status: "",
                              lastAttemptAt: Date(timeIntervalSince1970: 100),
                              lastSuccessAt: Date(timeIntervalSince1970: 100))
        ]
        store.save()

        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: unusedResolver(), defaults: defaults())
        _ = await coordinator.runAll()

        let merged = try XCTUnwrap(store.record(forKey: first.key))
        XCTAssertEqual(Set(merged.movement?.executionDocuments?.map(\.id) ?? []),
                       Set([sharedWrit.id, appealWrit.id]))
        XCTAssertEqual(merged.enforcementRecords.count, 2)
        let shared = try XCTUnwrap(merged.enforcementRecords.first {
            $0.courtDocumentID == sharedWrit.id
        })
        XCTAssertEqual(shared.status, "Исполнен", "более свежая запись survivor имеет приоритет")
        XCTAssertEqual(Set(shared.events.map(\.id)), Set([oldEvent.id, freshEvent.id]))
        XCTAssertEqual(merged.enforcementRecords.first {
            $0.courtDocumentID == appealWrit.id
        }?.discoveryState, .notFound)
    }

    func testPromotesPreliminaryNumberAndPrunesItsMovement() async throws {
        let store = TrackedStore(inMemory: true)
        let preliminary = context(level: .first, number: "М-2417/2026",
                                  domain: "vyborgsky--lo.sudrf.ru", cartoteka: "p1",
                                  courtLevel: .district)
        let main = context(level: .first, number: "2а-5090/2026",
                           domain: "vyborgsky--lo.sudrf.ru", cartoteka: "p1",
                           courtLevel: .district)
        var preliminaryMovement = movement(level: .first, number: preliminary.caseNumber,
                                            domain: preliminary.searchDomain,
                                            actID: "preliminary-act")
        preliminaryMovement.instances.append(CaseInstance(
            level: .first, court: preliminary.courtTitle,
            caseNumber: "2а-5090/2026 ~ М-2417/2026", judge: nil,
            domain: preliminary.searchDomain, foundByUID: true, result: "Назначено заседание",
            sessions: preliminaryMovement.instances[0].sessions))
        let old = store.upsert(context: preliminary, snapshot: nil, movement: preliminaryMovement,
                               collections: ["Импорт"])
        old.seenAt = nil
        let origin = ResolvedCaseOrigin(
            court: main.searchCourt, branch: .general, region: main.region, courtCode: main.courtCode,
            cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "p1")),
            result: CaseSearchResult(caseNumber: "2а-5090/2026 ~ М-2417/2026",
                                     caseID: "main-id", caseUID: "main-guid"),
            card: CaseCard(rawText: "", actText: nil, uid: uid,
                           caseNumber: "2а-5090/2026 ~ М-2417/2026"))
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: PromotionOriginResolver(origin: origin),
            defaults: defaults(), anchorCardFetcher: { _ in
                CaseCard(rawText: "", actText: nil, uid: self.uid, caseNumber: preliminary.caseNumber)
            })

        let summary = await coordinator.runAll()

        XCTAssertEqual(summary.reanchored, 1)
        let saved = try XCTUnwrap(store.record(forKey: preliminary.key))
        XCTAssertTrue(store.record(forLocator: main.key) === saved)
        XCTAssertTrue(saved.legacyKeyAliases.contains(main.key))
        XCTAssertEqual(saved.collectionNames, ["Импорт"])
        XCTAssertEqual(saved.movement?.instances.map(\.caseNumber), [main.caseNumber])
        XCTAssertEqual(saved.movement?.instances.first?.sessions,
                       preliminaryMovement.instances.first?.sessions,
                       "sparse canonical card must not erase cached sessions")
        XCTAssertEqual(saved.movement?.instances.first?.result, "Назначено заседание")
        XCTAssertTrue(saved.movement?.acts.isEmpty == true)
    }

    func testCompleteUIDMergesPreliminaryAndHigherCourtCardsUnderIdentityPolicy() async throws {
        let store = TrackedStore(inMemory: true)
        let preliminary = context(level: .first, number: "М-2417/2026",
                                  domain: "vyborgsky--lo.sudrf.ru", cartoteka: "p1",
                                  courtLevel: .district)
        let appeal = context(level: .appeal, number: "33а-4818/2026",
                             domain: "lo.sudrf.ru", cartoteka: "ga",
                             courtLevel: .subject)
        _ = try insertLegacy(into: store, context: preliminary, snapshot: nil,
                             collections: ["M"])
        _ = try insertLegacy(into: store, context: appeal, snapshot: nil,
                             collections: ["A"])
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(),
            originResolver: StubOriginResolver(.noReference), defaults: defaults(),
            anchorCardFetcher: { context in
                CaseCard(rawText: "", actText: nil, uid: context.judicialUID,
                         caseNumber: context.caseNumber)
            })

        let summary = await coordinator.runAll()

        XCTAssertEqual(summary.merged, 1)
        XCTAssertEqual(store.all().count, 1,
                       "a shared complete judicial UID is sufficient under #178")
        let saved = try XCTUnwrap(store.record(forLocator: preliminary.key))
        XCTAssertTrue(store.record(forLocator: appeal.key) === saved)
        XCTAssertEqual(Set(saved.collectionNames), ["M", "A"])
    }

    func testExistingMainRecordWinsUIDMergeAndPreservesPreliminaryUserState() async throws {
        let store = TrackedStore(inMemory: true)
        let preliminary = context(level: .first, number: "М-2417/2026",
                                  domain: "vyborgsky--lo.sudrf.ru", cartoteka: "p1",
                                  courtLevel: .district)
        let main = context(level: .first, number: "2а-5090/2026",
                           domain: "vyborgsky--lo.sudrf.ru", cartoteka: "p1",
                           courtLevel: .district)
        let preliminaryRecord = try insertLegacy(
            into: store, context: preliminary, snapshot: nil,
            movement: movement(level: .first, number: preliminary.caseNumber,
                               domain: preliminary.searchDomain, actID: "preliminary-act"),
            collections: ["Предварительная"])
        let mainRecord = try insertLegacy(
            into: store, context: main, snapshot: nil,
            movement: movement(level: .first, number: main.caseNumber,
                               domain: main.searchDomain, actID: "main-act"),
            collections: ["Основная"])
        preliminaryRecord.addedAt = Date(timeIntervalSince1970: 100)
        preliminaryRecord.seenAt = nil
        mainRecord.addedAt = Date(timeIntervalSince1970: 200)
        mainRecord.seenAt = Date(timeIntervalSince1970: 300)
        store.save()
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: unusedResolver(),
            defaults: defaults())

        let summary = await coordinator.runAll()

        XCTAssertEqual(summary.merged, 1)
        XCTAssertNil(store.record(forKey: preliminary.key))
        let saved = try XCTUnwrap(store.record(forKey: main.key))
        XCTAssertEqual(Set(saved.collectionNames), ["Предварительная", "Основная"])
        XCTAssertEqual(saved.addedAt, Date(timeIntervalSince1970: 100))
        XCTAssertNil(saved.seenAt)
        XCTAssertEqual(saved.movement?.instances.map(\.caseNumber), [main.caseNumber])
        XCTAssertEqual(saved.movement?.acts.map(\.id), ["main-act"])
    }

    func testExistingMainUIDMergePreservesSharedActReferencedBySurvivingInstance() async throws {
        let store = TrackedStore(inMemory: true)
        let preliminary = context(level: .first, number: "М-2417/2026",
                                  domain: "vyborgsky--lo.sudrf.ru", cartoteka: "p1",
                                  courtLevel: .district)
        let main = context(level: .first, number: "2а-5090/2026",
                           domain: "vyborgsky--lo.sudrf.ru", cartoteka: "p1",
                           courtLevel: .district)
        let sharedActID = "act_\(main.searchDomain)"
        _ = try insertLegacy(
            into: store, context: preliminary, snapshot: nil,
            movement: movement(level: .first, number: preliminary.caseNumber,
                               domain: preliminary.searchDomain, actID: sharedActID),
            collections: [])
        _ = try insertLegacy(
            into: store, context: main, snapshot: nil,
            movement: movement(level: .first, number: main.caseNumber,
                               domain: main.searchDomain, actID: sharedActID),
            collections: [])
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: unusedResolver(),
            defaults: defaults())

        let summary = await coordinator.runAll()

        XCTAssertEqual(summary.merged, 1)
        let saved = try XCTUnwrap(store.record(forKey: main.key))
        XCTAssertEqual(saved.movement?.instances.map(\.caseNumber), [main.caseNumber])
        XCTAssertEqual(saved.movement?.instances.first?.actID, sharedActID)
        XCTAssertEqual(saved.movement?.acts.map(\.id), [sharedActID])
        XCTAssertEqual(saved.movement?.actBodies[sharedActID], "Текст \(sharedActID)")
    }

    func testReanchorsHigherCardAndKeepsOriginalKnownCard() async throws {
        let store = TrackedStore(inMemory: true)
        let replacementUID = "11RS0001-01-2026-009999-11"
        let appeal = context(level: .appeal, number: "33-4818/2025",
                             domain: "vs--komi.sudrf.ru", cartoteka: "g2",
                             courtLevel: .subject)
        let cachedAppeal = movement(level: .appeal, number: appeal.caseNumber,
                                    domain: appeal.searchDomain, actID: "appeal-act")
        store.upsert(context: appeal, snapshot: nil, movement: cachedAppeal,
                     collections: ["Import"])
        let lowerCard = CaseCard(rawText: "", actText: nil, uid: replacementUID,
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
        XCTAssertNil(summary.keyRemaps[appeal.key])
        let canonical = try XCTUnwrap(store.record(forKey: appeal.key))
        XCTAssertTrue(store.record(forLocator: canonicalKey) === canonical)
        XCTAssertTrue(canonical.legacyKeyAliases.contains(canonicalKey))
        XCTAssertEqual(canonical.context?.baseInstanceLevel, .first)
        XCTAssertEqual(canonical.context?.knownCards?.first?.caseNumber, "33-4818/2025")
        XCTAssertEqual(canonical.movement?.caseNumber, "2-7212/2025")
        XCTAssertEqual(Set(canonical.movement?.instances.map(\.caseNumber) ?? []),
                       ["2-7212/2025", "33-4818/2025"])
        let identity = TrackedCaseIdentity.state(for: canonical)
        XCTAssertEqual(Set(identity.judicialUIDs), [
            JudicialUIDObservation.normalize(uid),
            JudicialUIDObservation.normalize(replacementUID),
        ])
        XCTAssertTrue(identity.cards.contains { $0.identity.sourceNativeID == "lower-id" })
        XCTAssertTrue(identity.officialRelations.contains { relation in
            relation.kind == .sourceNative
                && relation.relatedCard?.sourceNativeID == appeal.caseID
        })

        let second = await coordinator.runAll()
        XCTAssertFalse(second.hasReport)
    }

    func testOfficialReanchorDoesNotMergeUnrelatedOwnerOfDisplayLocator() async throws {
        let store = TrackedStore(inMemory: true)
        var unrelated = context(
            level: .first, number: "2-7212/2025",
            domain: "syktsud--komi.sudrf.ru", cartoteka: "g1",
            courtLevel: .district)
        unrelated.judicialUID = "11RS0001-01-2026-008888-10"
        let unrelatedRecord = store.upsert(
            context: unrelated, snapshot: nil, collections: ["Unrelated"])

        let appeal = context(
            level: .appeal, number: "33-4818/2025",
            domain: "vs--komi.sudrf.ru", cartoteka: "g2",
            courtLevel: .subject)
        let anchor = store.upsert(
            context: appeal, snapshot: nil, collections: ["Anchor"])
        let replacementUID = "11RS0001-01-2026-009999-11"
        let lowerCard = CaseCard(
            rawText: "", actText: nil, uid: replacementUID,
            caseNumber: unrelated.caseNumber)
        let origin = ResolvedCaseOrigin(
            court: unrelated.searchCourt, branch: .general,
            region: unrelated.region, courtCode: unrelated.courtCode,
            cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1")),
            result: CaseSearchResult(
                caseNumber: unrelated.caseNumber,
                caseID: "official-lower-id", caseUID: "official-lower-guid"),
            card: lowerCard)
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(),
            originResolver: StubOriginResolver(.resolved(origin)),
            defaults: defaults(), anchorCardFetcher: { _ in
                CaseCard(
                    rawText: "", actText: nil, uid: self.uid,
                    caseNumber: appeal.caseNumber,
                    lowerCourt: LowerCourtReference(
                        courtTitle: unrelated.courtTitle,
                        caseNumber: unrelated.caseNumber))
            })

        let summary = await coordinator.runAll()

        XCTAssertEqual(summary.reanchored, 1)
        XCTAssertEqual(store.all().count, 2)
        XCTAssertTrue(store.record(forLocator: unrelated.key) === unrelatedRecord)
        let repaired = try XCTUnwrap(store.record(forKey: anchor.key))
        XCTAssertEqual(repaired.context?.caseNumber, unrelated.caseNumber)
        XCTAssertFalse(repaired.legacyKeyAliases.contains(unrelated.key))
        XCTAssertNotEqual(repaired.logicalCaseID, unrelatedRecord.logicalCaseID)
        XCTAssertTrue(TrackedCaseIdentity.state(for: repaired).cards.contains {
            $0.identity.sourceNativeID == "official-lower-id"
        })
    }

    func testReanchoredMaterialKeepsItsRealBaseLevelAndChain() async throws {
        let store = TrackedStore(inMemory: true)
        let appeal = context(level: .appeal, number: "33-4818/2025",
                             domain: "vs--komi.sudrf.ru", cartoteka: "g2",
                             courtLevel: .subject)
        store.upsert(context: appeal, snapshot: nil, collections: ["Import"])
        let material = CaseCard(rawText: "", actText: nil, uid: uid,
                                caseNumber: "13-2/2025")
        let origin = ResolvedCaseOrigin(
            court: Court(domain: "syktsud--komi.sudrf.ru",
                         title: "Сыктывкарский городской суд", level: .district),
            branch: .general, region: "Республика Коми", courtCode: "11RS0001",
            cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "m")),
            result: CaseSearchResult(caseNumber: "13-2/2025", caseID: "material-id",
                                     caseUID: "material-guid"), card: material)
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: StubOriginResolver(.resolved(origin)),
            defaults: defaults(), anchorCardFetcher: { _ in
                CaseCard(rawText: "", actText: nil, uid: self.uid,
                         caseNumber: "33-4818/2025",
                         lowerCourt: LowerCourtReference(courtTitle: "Сыктывкарский городской суд",
                                                         caseNumber: "13-2/2025"))
            })

        let summary = await coordinator.runAll()

        XCTAssertEqual(summary.reanchored, 0)
        XCTAssertEqual(summary.restoredMaterials, 1)
        let saved = try XCTUnwrap(store.record(forLocator: "syktsud.komi.sudrf.ru/13-2/2025"))
        XCTAssertEqual(saved.context?.baseInstanceLevel, .material)
        XCTAssertEqual(saved.context?.knownCards?.first?.caseNumber, appeal.caseNumber)
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

    func testCaptchaIsReportedSeparatelyAndGroupedByCanonicalHost() async {
        let store = TrackedStore(inMemory: true)
        let first = context(level: .appeal, number: "33-9/2026",
                            domain: "vs--komi.sudrf.ru", cartoteka: "g2",
                            courtLevel: .subject)
        var second = context(level: .appeal, number: "33-10/2026",
                             domain: "vs.komi.sudrf.ru", cartoteka: "g2",
                             courtLevel: .subject)
        second.judicialUID = "11RS0001-01-2026-000010-10"
        store.upsert(context: first, snapshot: nil, collections: [])
        store.upsert(context: second, snapshot: nil, collections: [])
        let formURL = URL(string: "https://vs--komi.sudrf.ru/modules.php?name=sud_delo")!
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: StubOriginResolver(.ambiguous),
            defaults: defaults(), anchorCardFetcher: { _ in
                throw SudrfError.captchaRequired(formURL: formURL)
            })

        let summary = await coordinator.runAll()

        XCTAssertTrue(summary.unresolved.isEmpty)
        XCTAssertEqual(summary.captchaRequests.count, 2)
        XCTAssertEqual(summary.captchaGroups.count, 1)
        XCTAssertEqual(summary.captchaGroups.first?.host, "vs--komi.sudrf.ru")
        XCTAssertEqual(summary.captchaGroups.first?.caseNumbers, ["33-10/2026", "33-9/2026"])
        XCTAssertTrue(summary.hasReport)
    }

    func testRegularSudrfCaptchaIsAutoSolvedOnceBeforeReporting() async throws {
        let store = TrackedStore(inMemory: true)
        let appeal = context(level: .appeal, number: "33-4818/2025",
                             domain: "vs--komi.sudrf.ru", cartoteka: "g2",
                             courtLevel: .subject)
        store.upsert(context: appeal, snapshot: nil, collections: [])
        let origin = ResolvedCaseOrigin(
            court: Court(domain: "syktsud--komi.sudrf.ru",
                         title: "Сыктывкарский городской суд", level: .district),
            branch: .general, region: "Республика Коми", courtCode: "11RS0001",
            cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1")),
            result: CaseSearchResult(caseNumber: "2-7212/2025",
                                     caseID: "lower-id", caseUID: "lower-guid"),
            card: CaseCard(rawText: "", actText: nil, uid: uid,
                           caseNumber: "2-7212/2025"))
        let formURL = URL(string: "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo")!
        var fetchCalls = 0
        var solveCalls = 0
        let settings = CaptchaSettings.shared
        let wasDisabled = settings.forceDisabled
        let wasEnabled = settings.autoSolveEnabled
        settings.forceDisabled = false
        settings.autoSolveEnabled = true
        defer {
            settings.forceDisabled = wasDisabled
            settings.autoSolveEnabled = wasEnabled
        }
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(),
            originResolver: StubOriginResolver(.resolved(origin)), defaults: defaults(),
            captchaSolver: CaptchaSolver(), captchaSettings: settings,
            autoSolve: { _, _, _, _ in
                solveCalls += 1
                return AutoCaptchaSolver.SolveResult(
                    token: CaptchaToken(value: "12345", id: "captcha-id"), png: nil)
            },
            anchorCardFetcher: { _ in
                fetchCalls += 1
                if fetchCalls == 1 { throw SudrfError.captchaRequired(formURL: formURL) }
                return CaseCard(
                    rawText: "", actText: nil, uid: self.uid,
                    caseNumber: appeal.caseNumber,
                    lowerCourt: LowerCourtReference(
                        courtTitle: "Сыктывкарский городской суд",
                        caseNumber: "2-7212/2025"))
            })

        let summary = await coordinator.runAll()

        XCTAssertEqual(solveCalls, 1)
        XCTAssertEqual(fetchCalls, 2)
        XCTAssertTrue(summary.captchaRequests.isEmpty)
        XCTAssertEqual(summary.reanchored, 1)
    }

    func testRSAdmjRemainsFirstJudicialAnchor() async throws {
        let store = TrackedStore(inMemory: true)
        let anchor = context(level: .first, number: "12-10/2026",
                             domain: "syktsud--komi.sudrf.ru", cartoteka: "admj",
                             courtLevel: .district)
        store.upsert(context: anchor, snapshot: nil, collections: [])
        let resolver = StubOriginResolver(.ambiguous)
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: resolver,
            defaults: defaults(), anchorCardFetcher: { _ in
                XCTFail("RS-admj must not be resolved downward")
                throw CaseOriginResolutionError.notFound
            })

        let summary = await coordinator.runAll()
        let calls = await resolver.calls

        XCTAssertEqual(summary.reanchored, 0)
        XCTAssertEqual(calls, 0)
        let saved = try XCTUnwrap(store.record(forKey: anchor.key)?.context)
        XCTAssertEqual(saved.baseInstanceLevel, .first)
        XCTAssertTrue(saved.higherCourtTargets?.contains { $0.cartotekaIDs == ["adm2"] } == true)
    }

    func testPublishedAppealWithoutLowerReferenceIsNotReportedAsFailure() async throws {
        let store = TrackedStore(inMemory: true)
        var appeal = context(level: .appeal, number: "12-743/2025",
                             domain: "syktsud--komi.sudrf.ru", cartoteka: "admj",
                             courtLevel: .district)
        appeal.judicialUID = "11MS0062-01-2025-001355-63"
        store.upsert(context: appeal, snapshot: nil, collections: [])
        let resolver = StubOriginResolver(.noReference)
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: resolver,
            defaults: defaults(), anchorCardFetcher: { _ in
                CaseCard(rawText: "", actText: nil, uid: appeal.judicialUID,
                         caseNumber: appeal.caseNumber)
            })

        let first = await coordinator.runAll()
        let second = await coordinator.runAll()
        let calls = await resolver.calls

        XCTAssertTrue(first.unresolved.isEmpty)
        XCTAssertTrue(first.notFound.isEmpty)
        XCTAssertTrue(first.ambiguous.isEmpty)
        XCTAssertFalse(second.hasReport)
        XCTAssertEqual(calls, 1, "завершённый v5-проход не должен повторяться на каждом запуске")
        XCTAssertNotNil(store.record(forKey: appeal.key))
    }

    func testOfficialLowerCardAbsentFromPublicRegistryIsDeferredSilently() async throws {
        let store = TrackedStore(inMemory: true)
        let appeal = context(level: .appeal, number: "33-14101/2026",
                             domain: "oblsud--spb.sudrf.ru", cartoteka: "g2",
                             courtLevel: .subject)
        store.upsert(context: appeal, snapshot: nil, collections: [])
        let resolver = StubOriginResolver(.notFound)
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: resolver,
            defaults: defaults(), now: { Date(timeIntervalSince1970: 1_000) },
            anchorCardFetcher: { _ in
                CaseCard(rawText: "", actText: nil, uid: self.uid,
                         caseNumber: appeal.caseNumber,
                         lowerCourt: LowerCourtReference(
                            courtTitle: "Василеостровский районный суд",
                            caseNumber: "13-98/2026"))
            })

        let first = await coordinator.runAll()
        let second = await coordinator.runAll()
        let calls = await resolver.calls

        XCTAssertFalse(first.hasReport)
        XCTAssertTrue(first.notFound.isEmpty)
        XCTAssertFalse(second.hasReport)
        XCTAssertEqual(calls, 1, "повторный поиск должен ждать backoff, а не запускаться сразу")
        XCTAssertNotNil(store.record(forKey: appeal.key))
    }

    func testPublishedKoAPAppealParsingFailureIsCompletedInsteadOfUnsupported() async throws {
        let store = TrackedStore(inMemory: true)
        var appeal = context(level: .appeal, number: "12-966/2025",
                             domain: "syktsud--komi.sudrf.ru", cartoteka: "admj",
                             courtLevel: .district)
        appeal.judicialUID = "11MS0062-01-2025-001355-63"
        store.upsert(context: appeal, snapshot: nil, collections: [])
        let suite = defaults()
        var fetchCalls = 0
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: unusedResolver(),
            defaults: suite, anchorCardFetcher: { _ in
                fetchCalls += 1
                throw SudrfError.parsing("нижестоящий номер не опубликован")
            })

        let first = await coordinator.runAll()
        let second = await coordinator.runAll()

        XCTAssertTrue(first.notFound.isEmpty)
        XCTAssertTrue(first.ambiguous.isEmpty)
        XCTAssertFalse(second.hasReport)
        XCTAssertEqual(fetchCalls, 1)
        XCTAssertTrue((suite.stringArray(forKey: "importChainRepair.v6.completed") ?? [])
            .contains(appeal.key))
        XCTAssertFalse((suite.stringArray(forKey: "importChainRepair.v6.unsupported") ?? [])
            .contains(appeal.key))
        XCTAssertNotNil(store.record(forKey: appeal.key))
    }

    func testV5RetriesKeyPreviouslyExcludedByV4() async throws {
        let store = TrackedStore(inMemory: true)
        var cassation = context(level: .cassation, number: "7У-3061/2026",
                                domain: "3kas.sudrf.ru", cartoteka: "u3",
                                courtLevel: .cassation)
        cassation.judicialUID = nil
        store.upsert(context: cassation, snapshot: nil, collections: [])
        let materialCard = CaseCard(rawText: "", actText: nil, uid: uid,
                                    caseNumber: "3/12-25/2026")
        let origin = ResolvedCaseOrigin(
            court: Court(domain: "syktsud--komi.sudrf.ru",
                         title: "Сыктывкарский городской суд", level: .district),
            branch: .general, region: "Республика Коми", courtCode: "11RS0001",
            cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "m")),
            result: CaseSearchResult(caseNumber: "3/12-25/2026",
                                     caseID: "material-id", caseUID: "material-guid"),
            card: materialCard)
        let suite = defaults()
        suite.set([cassation.key], forKey: "importChainRepair.v4.unsupported")
        let resolver = StubOriginResolver(.resolved(origin))
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: resolver, defaults: suite,
            anchorCardFetcher: { _ in
                CaseCard(rawText: "", actText: nil, caseNumber: cassation.caseNumber,
                         lowerCourt: LowerCourtReference(
                            region: "11 - Республика Коми",
                            courtTitle: "Сыктывкарский городской суд",
                            caseNumber: "3/12-25/2026"))
            })

        let summary = await coordinator.runAll()

        XCTAssertEqual(summary.restoredMaterials, 1)
        let saved = try XCTUnwrap(store.record(forKey: cassation.key))
        XCTAssertTrue(store.record(forLocator: "syktsud.komi.sudrf.ru/3/12-25/2026") === saved)
        XCTAssertEqual(saved.context?.knownCards?.map(\.caseNumber), [cassation.caseNumber])
    }

    func testLegacyMSAdmjIsReclassifiedAndReanchoredToMagistrate() async throws {
        let store = TrackedStore(inMemory: true)
        var anchor = context(level: .first, number: "12-11/2026",
                             domain: "syktsud--komi.sudrf.ru", cartoteka: "admj",
                             courtLevel: .district)
        let msUID = "11MS0062-01-2026-000011-11"
        anchor.judicialUID = msUID
        store.upsert(context: anchor, snapshot: nil, collections: ["Import"])
        let lowerCard = CaseCard(rawText: "", actText: nil, uid: msUID,
                                 caseNumber: "5-11/2026")
        let origin = ResolvedCaseOrigin(
            court: Court(domain: "62.komi.msudrf.ru", title: "Судебный участок № 62",
                         level: .magistrate),
            branch: .general, region: "Республика Коми", courtCode: "11MS0062",
            cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm")),
            result: CaseSearchResult(caseNumber: "5-11/2026",
                                     caseID: "lower-id", caseUID: "lower-guid"),
            card: lowerCard,
            districtAppealCourts: [OriginTargetCourt(
                domain: "syktsud.komi.sudrf.ru", title: "Сыктывкарский городской суд")])
        let resolver = StubOriginResolver(.resolved(origin))
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: resolver,
            defaults: defaults(), anchorCardFetcher: { _ in
                CaseCard(rawText: "", actText: nil, uid: msUID,
                         caseNumber: "12-11/2026",
                         lowerCourt: LowerCourtReference(
                            courtTitle: "Судебный участок № 62", caseNumber: "5-11/2026"))
            })

        let summary = await coordinator.runAll()

        XCTAssertEqual(summary.reanchored, 1)
        XCTAssertGreaterThanOrEqual(summary.rerouted, 1)
        let canonical = try XCTUnwrap(store.record(forLocator: "62.komi.msudrf.ru/5-11/2026"))
        XCTAssertEqual(canonical.context?.baseInstanceLevel, .first)
        XCTAssertTrue(canonical.context?.higherCourtTargets?.contains {
            $0.courtLevel == .district && $0.cartotekaIDs == ["admj"]
        } == true)
        XCTAssertTrue(store.record(forKey: anchor.key) === canonical)

        let second = await coordinator.runAll()
        XCTAssertFalse(second.hasReport)
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
