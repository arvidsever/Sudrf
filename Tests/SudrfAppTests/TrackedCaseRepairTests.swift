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
        let cachedAppeal = movement(level: .appeal, number: appeal.caseNumber,
                                    domain: appeal.searchDomain, actID: "appeal-act")
        store.upsert(context: appeal, snapshot: nil, movement: cachedAppeal,
                     collections: ["Import"])
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
        XCTAssertEqual(canonical.movement?.caseNumber, "2-7212/2025")
        XCTAssertEqual(Set(canonical.movement?.instances.map(\.caseNumber) ?? []),
                       ["2-7212/2025", "33-4818/2025"])

        let second = await coordinator.runAll()
        XCTAssertFalse(second.hasReport)
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
        let saved = try XCTUnwrap(store.record(forKey: "syktsud.komi.sudrf.ru/13-2/2025"))
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
        XCTAssertTrue((suite.stringArray(forKey: "importChainRepair.v5.completed") ?? [])
            .contains(appeal.key))
        XCTAssertFalse((suite.stringArray(forKey: "importChainRepair.v5.unsupported") ?? [])
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
        XCTAssertNil(store.record(forKey: cassation.key))
        let saved = try XCTUnwrap(store.record(forKey: "syktsud.komi.sudrf.ru/3/12-25/2026"))
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
        let canonical = try XCTUnwrap(store.record(forKey: "62.komi.msudrf.ru/5-11/2026"))
        XCTAssertEqual(canonical.context?.baseInstanceLevel, .first)
        XCTAssertTrue(canonical.context?.higherCourtTargets?.contains {
            $0.courtLevel == .district && $0.cartotekaIDs == ["admj"]
        } == true)
        XCTAssertNil(store.record(forKey: anchor.key))

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
