import XCTest
import SwiftData
import SudrfKit
@testable import SudrfApp

@MainActor
final class Issue324MyCasesFilterTests: XCTestCase {
    func testIndependentSelectionsUseOrWithinAndAcrossGroupsAndContextualCounts() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let otherWindow = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        var civil = row("2-1/2026", production: .civil, stage: .first, tier: .district,
                        collection: "Alpha", historyStages: [.first, .appeal],
                        historyTiers: [.district, .cassation])
        var kas = row("2а-2/2026", production: .kas, stage: .appeal, tier: .cassation,
                      collection: "Beta", historyStages: [.first, .appeal],
                      historyTiers: [.district, .cassation])
        var completed = row("2-3/2025", production: .civil, stage: .done, tier: nil,
                            collection: "Alpha", historyStages: [.first, .appeal],
                            historyTiers: [.district, .cassation])
        var unknown = row("2-4/2026", production: nil, stage: .first, tier: nil,
                          collection: nil, historyStages: [], historyTiers: [])
        civil.searchFields = [.init(kind: .number, value: civil.caseNumber)]
        kas.searchFields = [.init(kind: .number, value: kas.caseNumber)]
        completed.searchFields = [.init(kind: .number, value: completed.caseNumber)]
        unknown.searchFields = [.init(kind: .number, value: unknown.caseNumber)]
        router.cases = [civil, kas, completed, unknown]
        router.collections = [("Все дела", 4), ("Alpha", 2), ("Beta", 1)]

        XCTAssertFalse(router.showCompleted)
        XCTAssertEqual(Set(router.filteredCases().map(\.caseNumber)),
                       Set([civil.caseNumber, kas.caseNumber, unknown.caseNumber]))

        router.productionFilters = [.civil, .kas]
        router.stageFilters = [.first, .appeal]
        router.tierFilters = [.district, .cassation]
        XCTAssertEqual(Set(router.filteredCases().map(\.caseNumber)),
                       Set([civil.caseNumber, kas.caseNumber]))
        for mode in MyCasesMode.allCases {
            router.myView = mode
            XCTAssertEqual(Set(router.filteredCases().map(\.caseNumber)),
                           Set([civil.caseNumber, kas.caseNumber]))
        }

        router.productionFilters.remove(.civil)
        XCTAssertEqual(router.filteredCases().map(\.caseNumber), [kas.caseNumber])
        router.productionFilters.remove(.kas)
        XCTAssertTrue(router.productionFilters.isEmpty)
        router.stageFilters = []
        router.tierFilters = []
        router.folder = "Alpha"
        router.query = civil.caseNumber
        XCTAssertEqual(router.filteredCases().map(\.caseNumber), [civil.caseNumber])

        router.folder = "Все дела"
        router.query = ""
        router.showCompleted = true
        router.productionFilters = [.kas]
        router.stageFilters = [.appeal]
        router.tierFilters = [.cassation]
        XCTAssertEqual(router.filteredCases().map(\.caseNumber), [kas.caseNumber])
        XCTAssertEqual(router.productionFilterCounts.first { $0.0 == .civil }?.1, 2,
                       "Production choices must keep alternatives visible.")
        XCTAssertEqual(router.stageFilterCounts.first { $0.0 == .appeal }?.1, 1,
                       "Stage counts ignore their own selected group.")
        XCTAssertEqual(router.tierFilterCounts.first { $0.0 == .cassation }?.1, 1,
                       "Tier counts ignore their own selected group.")
        XCTAssertEqual(router.collectionFilterCounts.first { $0.0 == "Beta" }?.1, 1,
                       "Collection counts reflect the other active filters.")
        XCTAssertFalse(router.stageFilterCounts.contains { $0.0 == .done })
        XCTAssertEqual(router.tierFilterCounts.count, CourtTier.allCases.count)

        router.showCompleted = false
        router.productionFilters = []
        router.stageFilters = []
        router.tierFilters = []
        XCTAssertEqual(Set(router.filteredCases().map(\.caseNumber)),
                       Set([civil.caseNumber, kas.caseNumber, unknown.caseNumber]))

        router.productionFilters = [.civil]
        router.stageFilters = [.appeal, .done]
        router.tierFilters = [.district, .supreme]
        router.showCompleted = true
        XCTAssertEqual(MyCasesFilterStorage.decode(
            MyCasesFilterStorage.encode(router.productionFilters), as: ProductionType.self),
            router.productionFilters)
        XCTAssertEqual(MyCasesFilterStorage.decode(
            MyCasesFilterStorage.encode(router.stageFilters), as: CaseStageKind.self),
            router.stageFilters)
        XCTAssertEqual(MyCasesFilterStorage.decode(
            MyCasesFilterStorage.encode(router.tierFilters), as: CourtTier.self),
            router.tierFilters)
        XCTAssertEqual(MyCasesFilterStorage.decode("civil,invalid,civil", as: ProductionType.self),
                       [.civil], "Stored raw values ignore invalid entries and duplicate values.")

        XCTAssertTrue(otherWindow.productionFilters.isEmpty)
        XCTAssertTrue(otherWindow.stageFilters.isEmpty)
        XCTAssertTrue(otherWindow.tierFilters.isEmpty)
        XCTAssertFalse(otherWindow.showCompleted)
    }

    func testHistoryUsesConfirmedInstancesMaterialsAndOwnProductionWithoutGuessing() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let civilUID = "11RS0001-01-2026-000001-11"
        let civilContext = context(number: "2-1/2026", domain: "qa-district.sudrf.ru",
                                   level: "district", cartoteka: "g1", uid: civilUID)
        let civilRoot = instance(.first, number: civilContext.caseNumber,
            domain: civilContext.searchDomain, id: "civil-root", cartoteka: "g1",
            courtLevel: .district, uid: civilUID, kind: .civil)
        var anchoredCivilRoot = civilRoot
        anchoredCivilRoot.sourceURL = URL(string: civilContext.cardURLString!)
        let material = instance(.material, number: "13-1/2026", domain: "3kas.sudrf.ru",
            id: "civil-material", cartoteka: "m", courtLevel: .cassation,
            uid: civilUID, kind: nil)
        try add(civilContext, movement: movement(civilContext, [anchoredCivilRoot, material]), store: store)

        let koapUID = "11RS0001-01-2026-000002-94"
        let koapContext = context(number: "5-2/2026", domain: "qa-district.sudrf.ru",
                                  level: "district", cartoteka: "adm", uid: koapUID)
        let koapRoot = instance(.first, number: koapContext.caseNumber,
            domain: koapContext.searchDomain, id: "koap-root", cartoteka: "adm",
            courtLevel: .district, uid: koapUID, kind: .koap)
        var anchoredKoAPRoot = koapRoot
        anchoredKoAPRoot.sourceURL = URL(string: koapContext.cardURLString!)
        let koapCassation = instance(.cassation, number: "88-2/2026",
            domain: "3kas.sudrf.ru", id: "koap-cassation", cartoteka: "adm3",
            courtLevel: .cassation, uid: koapUID, kind: .koap)
        try add(koapContext, movement: movement(koapContext, [anchoredKoAPRoot, koapCassation]), store: store)

        let unknownUID = "11RS0001-01-2026-000003-11"
        let unknownContext = context(number: "2-3/2026", domain: "unknown.sudrf.ru",
                                     level: "not-a-court-level", cartoteka: "g1", uid: unknownUID)
        let unknownRoot = instance(.first, number: unknownContext.caseNumber,
            domain: unknownContext.searchDomain, id: "unknown-root", cartoteka: "g1",
            courtLevel: nil, uid: unknownUID, kind: .civil)
        var anchoredUnknownRoot = unknownRoot
        anchoredUnknownRoot.sourceURL = URL(string: unknownContext.cardURLString!)
        try add(unknownContext, movement: movement(unknownContext, [anchoredUnknownRoot]), store: store)

        let stubUID = "11RS0001-01-2026-000004-11"
        let stubContext = context(number: "2-4/2026", domain: "qa-district.sudrf.ru",
                                  level: "district", cartoteka: "g1", uid: stubUID)
        let stubRoot = instance(.first, number: stubContext.caseNumber,
            domain: stubContext.searchDomain, id: "stub-root", cartoteka: "g1",
            courtLevel: .district, uid: stubUID, kind: .civil)
        var anchoredStubRoot = stubRoot
        anchoredStubRoot.sourceURL = URL(string: stubContext.cardURLString!)
        var stub = instance(.cassation, number: "88-4/2026", domain: "3kas.sudrf.ru",
            id: "network-stub", cartoteka: "g3", courtLevel: .cassation,
            uid: stubUID, kind: .civil)
        stub.transientError = true
        let emptyNumberStub = instance(.cassation, number: "—", domain: "3kas.sudrf.ru",
            id: "empty-number-stub", cartoteka: "g3", courtLevel: .cassation,
            uid: stubUID, kind: .civil)
        try add(stubContext, movement: movement(stubContext, [anchoredStubRoot, stub, emptyNumberStub]),
                store: store)

        let completedContext = context(number: "2-5/2025", domain: "qa-district.sudrf.ru",
                                       level: "district", cartoteka: "g1",
                                       uid: "11RS0001-01-2025-000005-11")
        let completedRecord = try store.upsert(context: completedContext, snapshot: nil,
                                                collections: [])
        completedRecord.snapshot = legacySnapshot(stage: .done)
        try store.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        XCTAssertFalse(router.showCompleted)
        XCTAssertEqual(router.filteredCases().count, 4)
        let civilCase = try XCTUnwrap(router.cases.first { $0.caseNumber == civilContext.caseNumber })
        XCTAssertEqual(civilCase.stage, .first)
        XCTAssertEqual(civilCase.historicalTiers, [.district, .cassation])
        XCTAssertEqual(civilCase.historicalStages, [.first])

        router.showCompleted = true
        router.tierFilters = [.cassation]
        XCTAssertEqual(Set(router.filteredCases().map(\.caseNumber)),
                       Set([civilContext.caseNumber, koapContext.caseNumber]))
        XCTAssertEqual(router.filteredCases().filter { $0.caseNumber == civilContext.caseNumber }.count, 1)

        router.showCompleted = true
        router.tierFilters = []
        router.stageFilters = [.supervisory]
        XCTAssertEqual(router.filteredCases().map(\.caseNumber), [koapContext.caseNumber])
        XCTAssertFalse(try XCTUnwrap(router.cases.first { $0.caseNumber == koapContext.caseNumber })
            .historicalStages.contains(.cassation))

        router.stageFilters = [.cassation]
        router.tierFilters = [.cassation]
        XCTAssertTrue(router.filteredCases().isEmpty,
                      "KoAP cassation is a supervisory stage, not a guessed cassation facet.")

        router.stageFilters = []
        router.tierFilters = [.district]
        XCTAssertFalse(router.filteredCases().contains { $0.caseNumber == unknownContext.caseNumber },
                       "An unknown source level must not be guessed from its instance label.")
        XCTAssertTrue(router.filteredCases().contains { $0.caseNumber == completedContext.caseNumber })

        router.tierFilters = [.cassation]
        router.stageFilters = [.cassation]
        XCTAssertFalse(router.filteredCases().contains { $0.caseNumber == stubContext.caseNumber },
                       "A transient network placeholder cannot add historical facets.")
        let stubCase = try XCTUnwrap(router.cases.first { $0.caseNumber == stubContext.caseNumber })
        XCTAssertEqual(stubCase.historicalStages, [.first],
                       "An empty-number higher-court placeholder cannot add historical stages.")
        XCTAssertEqual(stubCase.historicalTiers, [.district],
                       "An empty-number higher-court placeholder cannot add historical tiers.")
        XCTAssertEqual(router.cases.first { $0.caseNumber == completedContext.caseNumber }?.stage, .done)
    }

    func testConflictingCassationCardsDoNotBorrowRootKindForHistoricalFacets() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let scenarios: [(number: String, cartoteka: String, uid: String, kind: ProcessKind, id: String)] = [
            ("2-301/2026", "g1", "11RS0001-01-2026-000301-11", .civil, "301"),
            ("5-302/2026", "adm", "11RS0001-01-2026-000302-94", .koap, "302")
        ]

        for scenario in scenarios {
            let ctx = context(number: scenario.number, domain: "qa-district.sudrf.ru",
                              level: "district", cartoteka: scenario.cartoteka, uid: scenario.uid)
            var root = instance(.first, number: ctx.caseNumber, domain: ctx.searchDomain,
                id: "conflict-root-\(scenario.id)", cartoteka: scenario.cartoteka,
                courtLevel: .district, uid: scenario.uid, kind: scenario.kind)
            root.sourceURL = URL(string: ctx.cardURLString!)
            var cassation = instance(.cassation, number: "88-\(scenario.id)/2026",
                domain: "3kas.sudrf.ru", id: "conflict-cassation-\(scenario.id)",
                cartoteka: "g3", courtLevel: .cassation, uid: scenario.uid, kind: scenario.kind)
            cassation.sourceEvidence?.ownProcessKindConflict = true
            let dossier = movement(ctx, [root, cassation])
            let classification = MaterialProductionContext.resolve(
                instance: cassation, movement: dossier, baseContext: ctx)
            XCTAssertEqual(classification.basis, .conflict)
            XCTAssertFalse(classification.isMaterial)
            XCTAssertNil(classification.production)
            try add(ctx, movement: dossier, store: store)
        }

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        for scenario in scenarios {
            let tracked = try XCTUnwrap(router.cases.first { $0.caseNumber == scenario.number })
            XCTAssertEqual(tracked.historicalStages, [.first],
                           "A conflicting own process kind cannot guess cassation or supervisory history.")
            XCTAssertEqual(tracked.historicalTiers, [.district],
                           "A conflicting cassation card cannot add a higher-court tier.")
        }
    }

    func testCurrentTierUsesLifecycleInstanceWhileHistoryIncludesLaterMaterial() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let uid = "11RS0001-01-2026-000101-11"
        let ctx = context(number: "2-101/2026", domain: "qa-district.sudrf.ru",
                          level: "district", cartoteka: "g1", uid: uid)
        var root = instance(.first, number: ctx.caseNumber, domain: ctx.searchDomain,
            id: "current-main", cartoteka: "g1", courtLevel: .district,
            uid: uid, kind: .civil)
        root.sourceURL = URL(string: ctx.cardURLString!)
        var laterMaterial = instance(.material, number: "13-101/2026",
            domain: "subject.sudrf.ru", id: "later-subject-material",
            cartoteka: "m", courtLevel: .subject, uid: uid, kind: .civil)
        laterMaterial.sessions = [CaseSession(date: "31.12.2099", event: "Материал зарегистрирован")]
        try add(ctx, movement: movement(ctx, [root, laterMaterial]), store: store)

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let tracked = try XCTUnwrap(router.cases.first { $0.caseNumber == ctx.caseNumber })
        XCTAssertEqual(tracked.stage, .first)
        XCTAssertEqual(tracked.filterTier, .district,
                       "The selected main production sets the active tier even when a later material is in the array.")
        XCTAssertEqual(tracked.historicalStages, [.first])
        XCTAssertEqual(tracked.historicalTiers, [.district, .subject],
                       "The material remains available as a historical facet.")
    }

    func testProviderAwareMGSAndVSRFCardsKeepHistoricalFacets() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)

        let mgsRootURL = URL(string:
            "https://mos-gorsud.ru/rs/basmannyj/services/cases/civil/details/mgs-root")!
        let mgsAppealURL = URL(string:
            "https://mos-gorsud.ru/mgs/services/cases/appeal-civil/details/mgs-appeal")!
        let mgsUID = "77RS0002-01-2026-000201-11"
        let mgsContext = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "mos-gorsud.ru", displayDomain: "mos-gorsud.ru",
            courtTitle: "Басманный районный суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77RS0002", cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-201/2026", caseID: "mgs-root", cardURLString: mgsRootURL.absoluteString,
            judicialUID: mgsUID)
        let mgsRoot = CaseInstance(level: .first, court: "Басманный районный суд",
            caseNumber: mgsContext.caseNumber, judge: nil, domain: "mos-gorsud.ru",
            foundByUID: false, result: nil, sessions: [], sourceURL: mgsRootURL)
        let mgsAppeal = CaseInstance(level: .appeal, court: "Московский городской суд",
            caseNumber: "33-201/2026", judge: nil, domain: "mos-gorsud.ru",
            foundByUID: true, result: nil, sessions: [], sourceURL: mgsAppealURL)
        try add(mgsContext, movement: CaseMovement(uid: mgsUID, caseNumber: mgsContext.caseNumber,
            inForce: false, instances: [mgsRoot, mgsAppeal], complaints: [:], acts: []), store: store)

        let vsrfContext = context(number: "2-202/2026", domain: "qa-district.sudrf.ru",
                                  level: "district", cartoteka: "g1",
                                  uid: "11RS0001-01-2026-000202-11")
        var vsrfRoot = instance(.first, number: vsrfContext.caseNumber,
            domain: vsrfContext.searchDomain, id: "vsrf-root", cartoteka: "g1",
            courtLevel: .district, uid: vsrfContext.judicialUID!, kind: .civil)
        vsrfRoot.sourceURL = URL(string: vsrfContext.cardURLString!)
        let vsrfCard = CaseInstance(level: .vsCassation, court: "Верховный Суд РФ",
            caseNumber: "АКПИ26-1", judge: nil, domain: "www.vsrf.ru", foundByUID: true,
            result: nil, sessions: [],
            sourceURL: URL(string: "https://www.vsrf.ru/lk/practice/cases/5500001"),
            sourceEvidence: .init(ownProcessKind: .civil))
        try add(vsrfContext, movement: movement(vsrfContext, [vsrfRoot, vsrfCard]), store: store)

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let mgsCase = try XCTUnwrap(router.cases.first { $0.caseNumber == mgsContext.caseNumber })
        XCTAssertEqual(mgsCase.historicalStages, [.first, .appeal])
        XCTAssertEqual(mgsCase.historicalTiers, [.district, .subject],
                       "MGS's exact card aliases distinguish a district court from the subject court on their shared portal host.")
        let vsrfCase = try XCTUnwrap(router.cases.first { $0.caseNumber == vsrfContext.caseNumber })
        XCTAssertTrue(vsrfCase.historicalStages.contains(.cassation))
        XCTAssertTrue(vsrfCase.historicalTiers.contains(.supreme),
                      "A validated VSRF native card is a real production and carries its authoritative tier.")
    }

    private func row(_ number: String, production: ProductionType?, stage: CaseStageKind,
                     tier: CourtTier?, collection: String?, historyStages: Set<CaseStageKind>,
                     historyTiers: Set<CourtTier>) -> TrackedCase {
        TrackedCase(recordKey: "court/\(number)", caseNumber: number,
            collections: collection.map { [$0] } ?? [], stage: stage,
            filterStage: stage, filterTier: tier, historicalStages: historyStages,
            historicalTiers: historyTiers, stageTag: "", subject: "", court: "",
            recordCourt: "", courtTier: tier, production: production,
            partiesShort: "", leadCharges: nil, secondPartyLine: nil,
            statusText: "", statusChip: .gray, last: "", next: "—", nextChip: .gray,
            isNew: false, steps: [], newDot: false, lastEventDate: nil, nextEventDate: nil)
    }

    private func context(number: String, domain: String, level: String,
                         cartoteka: String, uid: String) -> MovementContext {
        let rootURL = URL(string: "https://\(domain)/modules.php?name=sud_delo&srv_num=1"
            + "&name_op=case&case_id=\(number.hashValue.magnitude)&case_uid=fixture-\(uid)"
            + "&delo_id=1540005")!
        return MovementContext(branchRaw: CourtBranch.general.rawValue, region: "Тест",
            searchDomain: domain, displayDomain: domain, courtTitle: "Проверочный суд",
            courtLevelRaw: level, courtCode: "11RS0001", cartotekaId: cartoteka,
            cartotekaLevelRaw: level == "not-a-court-level" ? "district" : level,
            caseNumber: number, caseID: String(number.hashValue.magnitude),
            caseUID: "fixture-\(uid)", cardURLString: rootURL.absoluteString,
            judicialUID: uid)
    }

    private func instance(_ level: CaseInstance.Level, number: String, domain: String,
                          id: String, cartoteka: String, courtLevel: CourtLevel?,
                          uid: String, kind: ProcessKind?) -> CaseInstance {
        let cardURL = URL(string: "https://\(domain)/modules.php?name=sud_delo&srv_num=1"
            + "&name_op=case&case_id=\(id)&case_uid=fixture-\(id)&delo_id=1540005")!
        return CaseInstance(level: level, court: "Проверочный суд", caseNumber: number,
            judge: nil, domain: domain, foundByUID: level != .first,
            result: nil, sessions: [], sourceURL: cardURL,
            sourceEvidence: .init(judicialUID: uid, cartotekaID: cartoteka,
                sourceCourtLevel: courtLevel, sourceBranch: .general,
                ownProcessKind: kind))
    }

    private func movement(_ context: MovementContext, _ instances: [CaseInstance]) -> CaseMovement {
        CaseMovement(uid: context.judicialUID ?? "", caseNumber: context.caseNumber,
            inForce: false, instances: instances, complaints: [:], acts: [])
    }

    private func add(_ context: MovementContext, movement: CaseMovement,
                     store: TrackedStore) throws {
        let snapshot = MovementDerivation.snapshot(from: movement, context: context)
        _ = try store.upsert(context: context, snapshot: snapshot,
                             movement: movement, collections: [])
    }

    private func legacySnapshot(stage: CaseStageKind) -> CaseSnapshot {
        CaseSnapshot(uid: "completed", inForce: false, category: nil,
            partiesShort: "", leadCharges: nil, secondPartyLine: nil,
            stageRaw: stage.rawValue, stageTag: "legacy", statusText: "Завершено",
            statusChipRaw: Palette.Chip.gray.rawValue, lastEvent: "—", nextEvent: "—",
            nextChipRaw: Palette.Chip.gray.rawValue, steps: [], sessions: [],
            deadlines: [], actsFingerprint: nil)
    }
}
