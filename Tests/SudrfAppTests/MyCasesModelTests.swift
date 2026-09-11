import XCTest
import Foundation
import SudrfKit
import SwiftData
import CaptchaSolver
@testable import SudrfApp

/// Модель редизайна «Моих дел» (v20): вид производства по номеру дела,
/// разделитель сторон «⚔», сортировка и живой фильтр таблицы «Списком».
final class MyCasesModelTests: XCTestCase {

    @MainActor
    func testDeadlineRepeatedConfirmationAndEarlyJournalFailureAreAtomic() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let ctx = projectionContext(number: "2-261/2026", cartotekaID: "g1", suffix: "261")
        var snapshot = legacySnapshot(steps: ["active"])
        let date = DateUtil.parse("10.03.2027")!
        snapshot.deadlines = [StoredDeadline(
            kind: "appeal", what: "Апелляционная жалоба", basis: "Тест",
            calLabel: "апелл.", dateRef: date.timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.proposed.rawValue, occurrenceKey: "rule|round|trigger",
            provenance: DeadlineProvenance(
                ruleID: "GPK-APPEAL-GENERAL", registryRevision: 1,
                trigger: DeadlineTriggerProvenance(
                    event: "Решение", result: nil, dateRaw: "10.02.2027",
                    court: "Суд", levelRaw: "first", caseNumber: ctx.caseNumber),
                policyIDs: [], formula: "one month", source: "ГПК РФ",
                calculatedDateRef: date.timeIntervalSinceReferenceDate))]
        let record = try store.upsert(context: ctx, snapshot: snapshot, collections: [])
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let id = "\(record.key)#rule|round|trigger"
        router.confirm(id)
        for _ in 0..<2 {
            router.draftDate = date.addingTimeInterval(86_400)
            router.save(id)
            router.confirm(id)
        }
        let events = try XCTUnwrap(record.eventJournal?.events)
        XCTAssertEqual(events.filter { $0.kind == .deadlineConfirmed }.count, 3)
        XCTAssertEqual(events.filter { $0.kind == .deadlineChanged }.count, 2)
        XCTAssertEqual(Set(events.map(\.id)).count, 5)
        record.eventJournalData = Data("broken".utf8)
        try store.save()
        let before = record.snapshotData
        router.draftDate = date.addingTimeInterval(172_800)
        router.save(id)
        XCTAssertEqual(record.snapshotData, before)
        XCTAssertFalse(container.mainContext.hasChanges)
        try store.save()
        XCTAssertEqual(record.snapshotData, before)
        XCTAssertEqual(record.eventJournalData, Data("broken".utf8))
    }

    private func projectionContext(number: String, cartotekaID: String,
                                   suffix: String) -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "\(suffix)--komi.sudrf.ru",
            displayDomain: "\(suffix).komi.sudrf.ru",
            courtTitle: "Суд \(suffix)",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS\(suffix)",
            cartotekaId: cartotekaID, cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number)
    }

    private func legacySnapshot(stageRaw: String = CaseStageKind.first.rawValue,
                                steps: [String]) -> CaseSnapshot {
        CaseSnapshot(
            uid: "legacy-uid", inForce: false, category: nil,
            partiesShort: "Иванов А. А.", leadCharges: nil, secondPartyLine: nil,
            stageRaw: stageRaw, stageTag: "legacy", statusText: "В производстве",
            statusChipRaw: Palette.Chip.blue.rawValue, lastEvent: "—", nextEvent: "—",
            nextChipRaw: Palette.Chip.gray.rawValue, steps: steps, sessions: [],
            deadlines: [], actsFingerprint: nil)
    }

    private func legacyRecord(number: String, cartotekaID: String, suffix: String,
                              stageRaw: String = CaseStageKind.first.rawValue,
                              steps: [String]) throws -> TrackedCaseRecord {
        let context = projectionContext(number: number, cartotekaID: cartotekaID,
                                         suffix: suffix)
        return TrackedCaseRecord(
            key: context.key, collections: [], caseNumber: number,
            courtTitle: context.courtTitle, displayDomain: context.displayDomain,
            contextData: try JSONEncoder().encode(context),
            snapshotData: try JSONEncoder().encode(
                legacySnapshot(stageRaw: stageRaw, steps: steps)))
    }

    private func stepKindRaw(_ kind: StepState.Kind) -> String {
        switch kind {
        case .done: return "done"
        case .active: return "active"
        case .todo: return "todo"
        }
    }

    @MainActor
    func testRouterStoresAcceptedMagistrateCaptchaInInjectedCorpus() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppRouterKCaptchaCorpusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let corpus = CorpusStore(baseDir: dir)
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let router = try AppRouter(
            modelContainer: container,
            modelContainerIsPrepared: true,
            captchaCorpus: corpus)

        _ = await router.storeAcceptedMagistrateCaptcha(
            png: Data([0x89, 0x50, 0x4e, 0x47]),
            code: "дягше",
            host: "pushkinsky.komi.msudrf.ru")

        let textCount = await corpus.currentCount(kind: .kcaptcha)
        XCTAssertEqual(textCount, 1)
    }

    @MainActor
    func testHigherCourtCaptchaCTAOpensManualFallback() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let formURL = try XCTUnwrap(
            URL(string: "https://3kas.sudrf.ru/modules.php?name=sud_delo"))
        let stub = CaseInstance(
            level: .cassation,
            court: "Третий кассационный суд общей юрисдикции",
            caseNumber: "8Г-10837/2026",
            judge: nil,
            domain: "3kas.sudrf.ru",
            foundByUID: false,
            result: nil,
            sessions: [],
            captchaFormURL: formURL)
        let movement = CaseMovement(
            uid: "3fa48ca6-b23d-46dd-b245-91dff823e62b",
            caseNumber: "2-100/2026",
            inForce: false,
            instances: [stub],
            complaints: [:],
            acts: [])
        router.liveMovement = movement
        let refreshNote = router.refreshNote

        router.beginCaptcha(for: stub)

        let context = try XCTUnwrap(router.captcha)
        XCTAssertEqual(context.formURL, formURL)
        XCTAssertEqual(context.uid, movement.uid)
        XCTAssertEqual(context.instanceID, stub.id)
        XCTAssertEqual(context.level.rawValue, stub.level.rawValue)
        XCTAssertEqual(context.courtTitle, stub.court)
        guard case .sudrfToken = context.kind else {
            return XCTFail("КСОЮ должна открыть ручной WebView fallback")
        }
        XCTAssertEqual(context.pendingCaseCount, 0)
        XCTAssertTrue(context.pendingCaseNumbers.isEmpty)
        XCTAssertEqual(router.liveMovement, movement)
        XCTAssertEqual(router.refreshNote, refreshNote)
        XCTAssertTrue(router.refreshCenter.captchaPendingGroups.isEmpty)
        XCTAssertFalse(router.isRefreshingOpenCase)
    }

    @MainActor
    func testTrackUntrackReloadAndTrackAgainUpdatesEveryProjection() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-91/2026")
        let sessions = [
            CaseSession(date: "29.08.2026", event: "Передача материалов судье"),
            CaseSession(date: "15.09.2026", event: "Судебное заседание"),
        ]
        let movement = CaseMovement(
            uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
                judge: nil, domain: context.searchDomain, foundByUID: false,
                result: nil, sessions: sessions)],
            complaints: [:], acts: [])

        router.track(context: context, movement: movement)
        let key = try XCTUnwrap(router.cases.first?.recordKey)
        XCTAssertFalse(router.hearings.isEmpty)
        XCTAssertFalse(router.feed.isEmpty)
        XCTAssertEqual(router.collections.first?.1, 1)
        router.openCase(key: key)

        router.untrackOpenCase()
        router.reload()

        XCTAssertTrue(router.cases.isEmpty)
        XCTAssertTrue(router.hearings.isEmpty)
        XCTAssertTrue(router.deadlines.isEmpty)
        XCTAssertTrue(router.feed.isEmpty)
        XCTAssertEqual(router.collections.first?.1, 0)
        XCTAssertTrue(router.stageCounts.allSatisfy { $0.1 == 0 })
        XCTAssertTrue(router.tierCounts.allSatisfy { $0.1 == 0 })
        XCTAssertNil(router.openedCase)

        router.track(context: context, movement: movement)

        XCTAssertEqual(router.cases.map(\.recordKey), [key])
        XCTAssertEqual(router.collections.first?.1, 1)
        XCTAssertFalse(router.hearings.isEmpty)
    }

    @MainActor
    func testLegacyThreeStepSnapshotsUseProductionSpecificLabels() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let modelContext = container.mainContext
        let koap = try legacyRecord(
            number: "12-5/2026", cartotekaID: "adm1", suffix: "koap",
            steps: ["done", "active", "todo"])
        let civil = try legacyRecord(
            number: "2-5/2026", cartotekaID: "g1", suffix: "civil",
            steps: ["done", "active", "done"])
        modelContext.insert(koap)
        modelContext.insert(civil)
        try modelContext.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let koapCase = try XCTUnwrap(router.cases.first { $0.caseNumber == "12-5/2026" })
        let civilCase = try XCTUnwrap(router.cases.first { $0.caseNumber == "2-5/2026" })

        XCTAssertEqual(koapCase.steps.map(\.label), ["1-я инст.", "Апелляция", "Надзор"])
        XCTAssertEqual(koapCase.steps.map { stepKindRaw($0.kind) },
                       ["done", "active", "todo"])
        XCTAssertEqual(civilCase.steps.map(\.label),
                       ["1-я инст.", "Апелляция", "Кассация", "Надзор"])
        XCTAssertEqual(civilCase.steps.map { stepKindRaw($0.kind) },
                       ["done", "active", "done", "todo"])
    }

    @MainActor
    func testStageCountsUseFirstAppealCassationSupervisoryDoneOrder() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let modelContext = container.mainContext
        let stages: [CaseStageKind] = [.first, .appeal, .cassation, .supervisory, .done]
        for (index, stage) in stages.enumerated() {
            let record = try legacyRecord(
                number: "2-\(index + 1)/2026", cartotekaID: "g1", suffix: "stage\(index)",
                stageRaw: stage.rawValue, steps: ["todo", "todo", "todo"])
            modelContext.insert(record)
        }
        try modelContext.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)

        XCTAssertEqual(router.stageCounts.map { $0.0.rawValue },
                       stages.map(\.rawValue))
        XCTAssertEqual(router.stageCounts.map(\.1), [1, 1, 1, 1, 1])
    }

    // MARK: Вид производства по префиксу номера

    func testProductionTypeByPrefix() {
        XCTAssertEqual(ProductionType.of("1-45/2026"), .crim)
        XCTAssertEqual(ProductionType.of("5-120/2026"), .koap)
        XCTAssertEqual(ProductionType.of("2а-77/2026"), .kas)
        XCTAssertEqual(ProductionType.of("3а-5/2026"), .kas)
        XCTAssertEqual(ProductionType.of("8а-1/2026"), .kas)
        XCTAssertEqual(ProductionType.of("33а-9/2026"), .kas)
        XCTAssertEqual(ProductionType.of("2-115/2026"), .civil)
        XCTAssertEqual(ProductionType.of("33-4/2026"), .civil)
        // Жалобы/кассация по КоАП и уголовная апелляция — раньше падали в civil.
        XCTAssertEqual(ProductionType.of("12-466/2026"), .koap)  // жалоба по делу об АП
        XCTAssertEqual(ProductionType.of("4а-321/2025"), .koap)  // кассация КоАП
        XCTAssertEqual(ProductionType.of("22-77/2026"), .crim)   // уголовная апелляция
        XCTAssertEqual(ProductionType.of("7у-15/2026"), .crim)   // кассация КСОЮ, не КоАП
    }

    func testProductionTypeUppercaseLetter() {
        // На портале встречается заглавная «А» в индексе.
        XCTAssertEqual(ProductionType.of("2А-77/2026"), .kas)
    }

    // MARK: Вид производства с учётом звена суда

    func testProductionTypeByCourtLevel() {
        // «2-…» неоднозначен без звена: район — гражданское, субъект — уголовное.
        XCTAssertEqual(ProductionType.of("2-1/2026", level: .district), .civil)
        XCTAssertEqual(ProductionType.of("2-1/2026", level: .subject), .crim)
        // «12-…» на районном звене — жалоба по делу об АП.
        XCTAssertEqual(ProductionType.of("12-5/2026", level: .district), .koap)
        // «33-…» суда субъекта — гражданская апелляция.
        XCTAssertEqual(ProductionType.of("33-9/2026", level: .subject), .civil)
    }

    func testProductionTypeFromCartotekaId() {
        XCTAssertEqual(ProductionType(cartotekaId: "u1"), .crim)
        XCTAssertEqual(ProductionType(cartotekaId: "u33"), .crim)
        XCTAssertEqual(ProductionType(cartotekaId: "g33"), .civil)
        XCTAssertEqual(ProductionType(cartotekaId: "m"), .civil)
        XCTAssertEqual(ProductionType(cartotekaId: "p2"), .kas)
        XCTAssertEqual(ProductionType(cartotekaId: "adm1"), .koap)
        XCTAssertEqual(ProductionType(cartotekaId: "admj"), .koap)
    }

    func testMaterialProductionUsesIndexClassifier() {
        XCTAssertEqual(ProductionType.classified(
            caseNumber: "3/12-31/2026", level: .district,
            branch: .general, cartotekaID: "m"), .crim)
        XCTAssertEqual(ProductionType.classified(
            caseNumber: "13-128/2025", level: .district,
            branch: .general, cartotekaID: "m"), .civil)
        XCTAssertEqual(ProductionType.classified(
            caseNumber: "13а-8/2025", level: .district,
            branch: .general, cartotekaID: "m"), .kas)
        XCTAssertEqual(ProductionType.classified(
            caseNumber: "ДА-4/2026", level: .district,
            branch: .military, cartotekaID: "m"), .koap)
    }

    func testUnknownMaterialsHaveNoProductionGroup() {
        XCTAssertNil(ProductionType.classified(
            caseNumber: "М-12/2026", level: .district,
            branch: .general, cartotekaID: "m"))
        XCTAssertNil(ProductionType.classified(
            caseNumber: "15-12/2026", level: .district,
            branch: .general, cartotekaID: "m"))
        XCTAssertNil(ProductionType.classified(
            caseNumber: "XYZ-12/2026", level: .district,
            branch: .general, cartotekaID: "m"))
    }

    // MARK: Стороны через «⚔»

    func testPartiesShortUsesCrossedSwords() {
        let p = CaseParties(plaintiffs: ["Новожилова Е. В."], defendants: ["ООО «Северлес»"])
        XCTAssertEqual(MovementDerivation.partiesShort(p), "Новожилова Е. В. ⚔ ООО «Северлес»")
    }

    func testPartiesShortListsTwoWithI() {
        let p = CaseParties(plaintiffs: ["Иванов А.", "Петров Б."], defendants: ["Сидоров В."])
        XCTAssertEqual(MovementDerivation.partiesShort(p), "Иванов А. и Петров Б. ⚔ Сидоров В.")
    }

    func testPartiesShortCountsThreeOrMore() {
        let p = CaseParties(plaintiffs: ["Иванов А.", "Петров Б.", "Сидоров В."],
                            defendants: ["ООО «Ромашка»"])
        XCTAssertEqual(MovementDerivation.partiesShort(p),
                       "Иванов А. и 2 других ⚔ ООО «Ромашка»")
    }

    func testPartiesShortForKoapOrganisation() {
        var p = CaseParties()
        p.add(role: "Привлекаемое лицо", name: "ООО «Севертранс»", articles: "ст.12.21.2 ч.1 КоАП РФ")
        XCTAssertEqual(MovementDerivation.partiesShort(p), "ООО «Севертранс»")
        XCTAssertEqual(p.leadCharges, "ст.12.21.2 ч.1 КоАП РФ")
        XCTAssertNil(MovementDerivation.partiesSecondLine(p))
    }

    func testKoapPrincipalsUseExplicitRolesAndStableNameOrder() {
        let roles = [
            "  ЛИЦО   В ОТНОШЕНИИ КОТОРОГО ВЕДЁТСЯ ПРОИЗВОДСТВО  ",
            "лицо привлекаемое к административной ответственности",
            "Привлекаемое лицо"
        ]
        for items in [
            [RoleItem(role: roles[0], name: "Яковлев Я. Я.", articles: "ст. 1"),
             RoleItem(role: roles[1], name: "ООО «Альфа»"),
             RoleItem(role: roles[2], name: "борисов Б. Б.", articles: "ст. 2")],
            [RoleItem(role: roles[2], name: "борисов Б. Б.", articles: "ст. 2"),
             RoleItem(role: roles[0], name: "Яковлев Я. Я.", articles: "ст. 1"),
             RoleItem(role: roles[1], name: "ООО «Альфа»")]
        ] {
            let p = CaseParties(kind: .koap, roleItems: items)
            XCTAssertEqual(p.koapPrincipalMembers.map(\.name),
                           ["борисов Б. Б.", "ООО «Альфа»", "Яковлев Я. Я."])
            XCTAssertEqual(MovementDerivation.partiesShort(p),
                           "борисов Б. Б. и 2 других")
            XCTAssertNil(p.leadCharges)
            XCTAssertNil(MovementDerivation.partiesSecondLine(p))
        }
    }

    func testKoapPrincipalFallsBackToExplicitColumnRole() {
        let principal = PartyMember(name: "ООО «Право»",
                                    sub: "ПРИВЛЕКАЕМОЕ ЛИЦО")
        let p = CaseParties(kind: .koap, columns: [
            PartyColumn(id: "zashita", title: "Сторона защиты",
                        titleMany: "Сторона защиты", icon: .shield,
                        members: [principal])
        ])
        XCTAssertEqual(p.koapPrincipalMembers, [principal])
        XCTAssertEqual(MovementDerivation.partiesShort(p), "ООО «Право»")
        XCTAssertNil(p.leadCharges)
    }

    func testKoapDoesNotInferPrincipalFromRepresentativeOrArticles() {
        let p = CaseParties(kind: .koap, roleItems: [
            RoleItem(role: "Представитель привлекаемого лица",
                     name: "Петров П. П.", articles: "ст. 12.1 КоАП РФ"),
            RoleItem(role: "Защитник (адвокат)",
                     name: "Иванов И. И.", articles: "ст. 12.2 КоАП РФ")
        ])
        XCTAssertTrue(p.koapPrincipalMembers.isEmpty)
        XCTAssertEqual(MovementDerivation.partiesShort(p),
                       "Петров П. П. · Представитель привлекаемого лица")
        XCTAssertNil(p.leadCharges)
        XCTAssertNil(MovementDerivation.partiesSecondLine(p))
    }

    func testKoapLeadChargesBelongOnlyToSinglePrincipal() {
        let p = CaseParties(kind: .koap, roleItems: [
            RoleItem(role: "Защитник", name: "Адвокат А. А.",
                     articles: "ошибочная статья защитника"),
            RoleItem(role: "Лицо, привлекаемое к административной ответственности",
                     name: "ООО «Ответ»", articles: "ст. 12.1 КоАП РФ")
        ])
        XCTAssertEqual(p.koapPrincipalMembers.map(\.name), ["ООО «Ответ»"])
        XCTAssertEqual(MovementDerivation.partiesShort(p), "ООО «Ответ»")
        XCTAssertEqual(p.leadCharges, "ст. 12.1 КоАП РФ")
        XCTAssertNil(MovementDerivation.partiesSecondLine(p))
    }

    func testEmptyKoapPartiesStayUnpublished() {
        let p = CaseParties(kind: .koap)
        XCTAssertTrue(p.koapPrincipalMembers.isEmpty)
        XCTAssertEqual(MovementDerivation.partiesShort(p), "стороны не опубликованы")
        XCTAssertNil(p.leadCharges)
        XCTAssertNil(MovementDerivation.partiesSecondLine(p))
    }

    // MARK: Категория на карточке — хвост рубрикатора
    //
    // Строки взяты из живых фикстур: sgs_card, ksoyu_case_card,
    // samara_kas_appeal_card. Разделителя два — «→» и «->».

    func testShortCategoryStaysWhole() {
        XCTAssertEqual(MovementDerivation.categoryTail("Иные жилищные споры"),
                       "Иные жилищные споры")
    }

    func testLongCategoryCollapsesToLastSection() {
        let cat = "Споры, связанные с имущественными правами → "
            + "Иски о взыскании сумм по договору займа, кредитному договору"
        XCTAssertEqual(MovementDerivation.categoryTail(cat),
                       "Иски о взыскании сумм по договору займа, кредитному договору")
    }

    func testStubSectionIsSkipped() {
        let cat = "Споры, возникающие из трудовых отношений → "
            + "Трудовые споры (независимо от форм собственности работодателя): → "
            + "Дела о восстановлении на работе, государственной (муниципальной) службе → "
            + "иные споры по делам о восстановлении на работе, государственной (муниципальной) службе"
        XCTAssertEqual(MovementDerivation.categoryTail(cat),
                       "Дела о восстановлении на работе, государственной (муниципальной) службе")
    }

    func testAsciiArrowAndRubricatorPrefix() {
        let cat = "3.025 - Гл. 22 КАС РФ -> об оспаривании решений, действий (бездействия) "
            + "должностных лиц -> прочие (об оспаривании решений, действий (бездействия) "
            + "должностных лиц (не явл. госслужащими) органов, организаций)"
        XCTAssertEqual(MovementDerivation.categoryTail(cat),
                       "об оспаривании решений, действий (бездействия) должностных лиц")
    }

    /// Длинная категория без разделов сворачивать некуда — отдаём как есть,
    /// обрезкой занимается сама карточка.
    func testLongCategoryWithoutSectionsIsKept() {
        let cat = "Дела о взыскании страхового возмещения по договору обязательного страхования"
        XCTAssertEqual(MovementDerivation.categoryTail(cat), cat)
    }

    /// Единственный раздел-заглушка не должен схлопнуться в пустоту.
    func testLoneStubSectionIsKept() {
        let cat = "иные споры по делам о восстановлении на работе, государственной службе"
        XCTAssertEqual(MovementDerivation.categoryTail(cat), cat)
    }

    // MARK: Подсудимые — многострочная раскладка «Списком»

    private func upkParties(_ defendants: [(String, String)]) -> CaseParties {
        var p = CaseParties()
        for (name, arts) in defendants { p.add(role: "Подсудимый", name: name, articles: arts) }
        return p
    }

    func testTwoDefendantsSecondLineHasName() {
        let p = upkParties([("Иванов И.", "ст.158 УК РФ"), ("Петров П.", "ст.159 УК РФ")])
        XCTAssertEqual(p.chargedMembers.count, 2)
        // Первая строка — ФИО первого, статьи — отдельно (щит).
        XCTAssertEqual(MovementDerivation.partiesShort(p), "Иванов И.")
        XCTAssertEqual(p.leadCharges, "ст.158 УК РФ")
        // Вторая строка — ФИО второго со своими статьями.
        let second = MovementDerivation.partiesSecondLine(p)
        XCTAssertEqual(second?.name, "Петров П.")
        XCTAssertEqual(second?.articles, "ст.159 УК РФ")
        XCTAssertNil(second?.more)
    }

    func testThreeDefendantsSecondLineCounts() {
        let p = upkParties([("Иванов И.", "ст.158 УК РФ"),
                            ("Петров П.", "ст.159 УК РФ"),
                            ("Сидоров С.", "ст.160 УК РФ")])
        let second = MovementDerivation.partiesSecondLine(p)
        XCTAssertEqual(second?.more, "и 2 других")
        XCTAssertNil(second?.name)
    }

    func testCivilHasNoSecondLine() {
        let p = CaseParties(plaintiffs: ["Иванов А.", "Петров Б."], defendants: ["Сидоров В."])
        XCTAssertNil(MovementDerivation.partiesSecondLine(p))
    }

    // MARK: Сортировка таблицы

    private func tracked(_ number: String, last: Date? = nil, next: Date? = nil) -> TrackedCase {
        TrackedCase(recordKey: "court/" + number, caseNumber: number, collections: [],
                    stage: .first, stageTag: "1-я инст.", subject: "—", court: "Сыктывкарский городской суд",
                    recordCourt: "Сыктывкарский городской суд",
                    courtTier: .district,
                    production: ProductionType.of(number),
                    partiesShort: "Иванов А. А. ⚔ ООО «Ромашка»", statusText: "В производстве",
                    statusChip: .blue, last: "—", next: "—", nextChip: .gray,
                    isNew: false, steps: [], newDot: false,
                    lastEventDate: last, nextEventDate: next)
    }

    func testSortByActivityFreshFirst() {
        let d1 = DateUtil.parse("01.04.2026")!, d2 = DateUtil.parse("20.04.2026")!
        let rows = [tracked("2-1/2026", last: d1), tracked("2-2/2026", last: d2),
                    tracked("2-3/2026", last: nil)]
        let sorted = AppRouter.sorted(rows, by: .activity).map(\.caseNumber)
        XCTAssertEqual(sorted, ["2-2/2026", "2-1/2026", "2-3/2026"])   // nil — в конец
    }

    func testSortByNextEventNearestFirst() {
        let d1 = DateUtil.parse("10.05.2026")!, d2 = DateUtil.parse("03.05.2026")!
        let rows = [tracked("2-1/2026", next: d1), tracked("2-2/2026", next: d2),
                    tracked("2-3/2026", next: nil)]
        let sorted = AppRouter.sorted(rows, by: .nextEvent).map(\.caseNumber)
        XCTAssertEqual(sorted, ["2-2/2026", "2-1/2026", "2-3/2026"])   // без события — в конец
    }

    @MainActor
    func testTierCountsPartitionCasesIncludingInactiveOnly() {
        var magistrate = tracked("1-1/2026")
        magistrate.courtTier = .magistrate
        var completed = tracked("2-2/2026")
        completed.stage = .done
        completed.courtTier = nil
        let counts = AppRouter.buildTierCounts([magistrate, tracked("2-3/2026"), completed])
        XCTAssertEqual(counts.reduce(0) { $0 + $1.1 }, 3)
        XCTAssertEqual(counts.first(where: { $0.0 == .magistrate })?.1, 1)
        XCTAssertEqual(counts.first(where: { $0.0 == .district })?.1, 1)
        XCTAssertEqual(counts.first(where: { $0.0 == nil })?.1, 1)
    }

    // MARK: Живой фильтр

    func testCaseNumberAliasesSeparateCurrentCardHistoryFromKnownCards() {
        let currentCard = SourceNativeCardIdentity(
            sourceFamily: "sudrf", courtKey: "11RS0001",
            cartotekaKey: "p1", sourceNativeID: "card-current")
        let previousCard = SourceNativeCardIdentity(
            sourceFamily: "sudrf", courtKey: "11RS0001",
            cartotekaKey: "p1", sourceNativeID: "card-previous")
        let provenance = SourceProvenance(
            operation: .movement, sourceFamily: "sudrf", host: "court--komi.sudrf.ru",
            observedAt: Date(timeIntervalSince1970: 1_725_000_000))
        let projection = AppRouter.caseNumberAliases(
            currentNumber: "3а-100/2026", currentCard: currentCard,
            history: [
                CaseNumberBinding(rawValue: "3а-100/2026 ~ М-100/2026",
                                  cardIdentity: currentCard,
                                  provenance: provenance),
                CaseNumberBinding(rawValue: "9а-10/2026", cardIdentity: previousCard,
                                  provenance: provenance),
            ],
            knownCards: [KnownCard(
                domain: "court--komi.sudrf.ru", courtTitle: "Суд",
                caseID: "card-known", caseUID: "known", deloID: "1540005", new: "5",
                caseNumber: "9а-20/2026", levelRaw: CaseInstance.Level.first.rawValue,
                cartotekaID: "p1")])

        XCTAssertEqual(projection.previous, ["М-100/2026"])
        XCTAssertEqual(projection.searchable,
                       ["3а-100/2026 ~ М-100/2026", "9а-10/2026", "9а-20/2026"])
        var row = tracked("3а-100/2026")
        row.searchCaseNumbers = projection.searchable
        XCTAssertTrue(AppRouter.matches(row, query: "м-100"))
        XCTAssertTrue(AppRouter.matches(row, query: "9а-20"))
    }

    @MainActor
    func testMalformedIdentityFallsBackToKnownCardNumberWithoutMutation() throws {
        var context = projectionContext(
            number: "3а-101/2026", cartotekaID: "p1", suffix: "aliases")
        context.knownCards = [KnownCard(
            domain: context.searchDomain, courtTitle: context.courtTitle,
            caseID: "old-card", caseUID: "old-uid", deloID: "1540005", new: "5",
            caseNumber: "М-101/2026", levelRaw: CaseInstance.Level.first.rawValue,
            cartotekaID: "p1")]
        let record = TrackedCaseRecord(
            key: context.key, collections: [], caseNumber: context.caseNumber,
            courtTitle: context.courtTitle, displayDomain: context.displayDomain,
            contextData: try JSONEncoder().encode(context),
            snapshotData: try JSONEncoder().encode(legacySnapshot(steps: ["active"])))
        let malformed = Data("not identity json".utf8)
        record.identityStateData = malformed
        let logicalCaseID = record.logicalCaseID

        let aliases = AppRouter.caseNumberAliases(for: record)

        XCTAssertEqual(aliases.previous, [])
        XCTAssertEqual(aliases.searchable, ["М-101/2026"])
        var projected = tracked(context.caseNumber)
        projected.searchCaseNumbers = aliases.searchable
        XCTAssertTrue(AppRouter.matches(projected, query: "м-101"))
        XCTAssertEqual(record.logicalCaseID, logicalCaseID)
        XCTAssertEqual(record.identityStateData, malformed)
    }

    @MainActor
    func testCurrentNumberFeedsMonitoringWhileSourceNumberAndFeedIDsStayStable() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        var context = projectionContext(
            number: "М-102/2026", cartotekaID: "p1", suffix: "current-number")
        var snapshot = legacySnapshot(steps: ["active"])
        snapshot.sessions = [
            StoredSession(
                dateRaw: "10.09.2026", time: "10:00", room: "1",
                event: "Регистрация административного искового заявления", result: nil,
                court: context.courtTitle, levelRaw: CaseInstance.Level.first.rawValue,
                caseNumber: "М-102/2026"),
            StoredSession(
                dateRaw: "12.09.2026", time: "11:00", room: "2",
                event: "Судебное заседание", result: nil,
                court: context.courtTitle, levelRaw: CaseInstance.Level.first.rawValue,
                caseNumber: "М-102/2026"),
        ]
        snapshot.deadlines = [StoredDeadline(
            kind: "test", what: "Проверочный срок", basis: "Тест",
            calLabel: "тест", dateRef: try XCTUnwrap(DateUtil.parse("13.09.2026"))
                .timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.proposed.rawValue)]
        let record = TrackedCaseRecord(
            key: context.key, collections: [], caseNumber: context.caseNumber,
            courtTitle: context.courtTitle, displayDomain: context.displayDomain,
            contextData: try JSONEncoder().encode(context),
            snapshotData: try JSONEncoder().encode(snapshot))
        container.mainContext.insert(record)
        try container.mainContext.save()
        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true)
        let day = try XCTUnwrap(DateUtil.parse("11.09.2026"))
        router.reload(today: day)
        let originalFeedIDs = router.feed.map(\.id)

        context.caseNumber = "3а-102/2026"
        record.caseNumber = context.caseNumber
        record.context = context
        try container.mainContext.save()
        router.reload(today: day)

        XCTAssertEqual(router.cases.map(\.caseNumber), ["3а-102/2026"])
        XCTAssertTrue(router.hearings.allSatisfy { $0.caseNumber == "3а-102/2026" })
        XCTAssertTrue(router.calendarHearings.allSatisfy { $0.caseNumber == "3а-102/2026" })
        XCTAssertTrue(router.deadlines.allSatisfy { $0.caseNumber == "3а-102/2026" })
        XCTAssertTrue(router.feed.allSatisfy {
            $0.caseNumber == "3а-102/2026" && $0.notificationSubtitle == "3а-102/2026"
        })
        XCTAssertEqual(router.feed.map(\.id), originalFeedIDs)
        XCTAssertEqual(router.hearings.first?.instanceCaseNumber, "М-102/2026")
        XCTAssertEqual(router.feed.first?.instanceCaseNumber, "М-102/2026")
    }

    @MainActor
    func testHistoricalFirstInstanceNumberIsResolvedFromExactSourceCard() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        var context = projectionContext(
            number: "3а-103/2026", cartotekaID: "p1", suffix: "source-number")
        context.caseID = "current-card"
        context.caseUID = "current-link"
        context.knownCards = [KnownCard(
            domain: context.searchDomain, courtTitle: context.courtTitle,
            caseID: "previous-card", caseUID: "previous-link",
            deloID: "1540005", new: "5", caseNumber: "9а-103/2026",
            levelRaw: CaseInstance.Level.first.rawValue, cartotekaID: "p1")]
        let historical = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: "9а-103/2026",
            judge: nil, domain: context.searchDomain, foundByUID: false,
            result: nil, sessions: [CaseSession(
                date: "10.09.2026", time: "10:00", room: nil,
                event: "Судебное заседание", result: "Отложено")],
            note: "Предыдущая регистрация")
        let current = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.searchDomain, foundByUID: false,
            result: nil, sessions: [])
        let movement = CaseMovement(
            uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: [historical, current], complaints: [:], acts: [])
        let snapshot = MovementDerivation.snapshot(
            from: movement, context: context,
            today: try XCTUnwrap(DateUtil.parse("11.09.2026")))
        XCTAssertNil(snapshot.sessions.first?.caseNumber)
        XCTAssertNotNil(snapshot.sessions.first?.sourceCardID)
        let record = TrackedCaseRecord(
            key: context.key, collections: [], caseNumber: context.caseNumber,
            courtTitle: context.courtTitle, displayDomain: context.displayDomain,
            contextData: try JSONEncoder().encode(context),
            snapshotData: try JSONEncoder().encode(snapshot))
        record.movement = movement
        container.mainContext.insert(record)
        try container.mainContext.save()
        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: try XCTUnwrap(DateUtil.parse("11.09.2026")))

        let feed = try XCTUnwrap(router.feed.first { $0.text == "Отложено" })
        XCTAssertEqual(feed.caseNumber, "3а-103/2026")
        XCTAssertEqual(feed.instanceCaseNumber, "9а-103/2026")
        XCTAssertEqual(feed.previousRegistrationNumber, "9а-103/2026")
        XCTAssertEqual(feed.secondaryLabel, "Предыдущая регистрация № 9а-103/2026")
        XCTAssertEqual(feed.notificationSubtitle,
                       "3а-103/2026 · Предыдущая регистрация № 9а-103/2026")
        let calendar = try XCTUnwrap(router.calendarHearings.first)
        XCTAssertEqual(calendar.caseNumber, "3а-103/2026")
        XCTAssertEqual(calendar.instanceCaseNumber, "9а-103/2026")
        XCTAssertEqual(calendar.secondaryLabel,
                       "Предыдущая регистрация № 9а-103/2026")
    }

    @MainActor
    func testAmbiguousPreviousRegistrationSourceDoesNotLabelCurrentEvents() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        var context = projectionContext(
            number: "3а-104/2026", cartotekaID: "p1", suffix: "ambiguous-source")
        context.caseID = "current-card"
        context.caseUID = "current-link"
        let historical = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: "9а-104/2026",
            judge: nil, domain: context.searchDomain, foundByUID: false,
            result: nil, sessions: [CaseSession(
                date: "10.09.2026", time: "09:00", room: nil,
                event: "Регистрация заявления", result: nil)],
            note: "Предыдущая регистрация")
        XCTAssertNil(AppRouter.previousRegistrationSourceCardID(
            for: historical, context: context))
        context.knownCards = [KnownCard(
            domain: context.searchDomain, courtTitle: context.courtTitle,
            caseID: "wrong-card", caseUID: "wrong-link",
            deloID: "1540005", new: "5", caseNumber: "9а-999/2026",
            levelRaw: CaseInstance.Level.first.rawValue, cartotekaID: "p1")]
        XCTAssertNil(AppRouter.previousRegistrationSourceCardID(
            for: historical, context: context))
        context.knownCards = [KnownCard(
            domain: context.searchDomain, courtTitle: context.courtTitle,
            caseID: "previous-card", caseUID: "previous-link",
            deloID: "1540005", new: "5", caseNumber: historical.caseNumber,
            levelRaw: CaseInstance.Level.first.rawValue, cartotekaID: "p1")]
        var conflictingURL = historical
        conflictingURL.sourceURL = URL(string:
            "https://\(context.searchDomain)/modules.php?name=sud_delo&name_op=case&case_id=different-card&case_uid=different-link&delo_id=1540005&new=5")
        XCTAssertNil(AppRouter.previousRegistrationSourceCardID(
            for: conflictingURL, context: context))
        context.knownCards = nil
        let current = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.searchDomain, foundByUID: false,
            result: nil, sessions: [CaseSession(
                date: "10.09.2026", time: "10:00", room: nil,
                event: "Принято к производству", result: nil)])
        let movement = CaseMovement(
            uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: [historical, current], complaints: [:], acts: [])
        let day = try XCTUnwrap(DateUtil.parse("11.09.2026"))
        let snapshot = MovementDerivation.snapshot(from: movement, context: context, today: day)
        XCTAssertEqual(Set(snapshot.sessions.compactMap(\.sourceCardID)).count, 1)
        let record = TrackedCaseRecord(
            key: context.key, collections: [], caseNumber: context.caseNumber,
            courtTitle: context.courtTitle, displayDomain: context.displayDomain,
            contextData: try JSONEncoder().encode(context),
            snapshotData: try JSONEncoder().encode(snapshot))
        record.movement = movement
        container.mainContext.insert(record)
        try container.mainContext.save()
        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: day)

        XCTAssertTrue(router.feed.allSatisfy { $0.previousRegistrationNumber == nil })
        let currentEvent = try XCTUnwrap(router.feed.first {
            $0.text == "Принято к производству"
        })
        XCTAssertNil(currentEvent.secondaryLabel)
        XCTAssertEqual(currentEvent.notificationSubtitle, context.caseNumber)
    }

    func testQueryMatchesNumberPartiesCollectionsCourt() {
        var c = tracked("2-115/2026")
        c.collections = ["Новожилова"]
        XCTAssertTrue(AppRouter.matches(c, query: "2-115"))
        XCTAssertTrue(AppRouter.matches(c, query: "ромашка"))       // стороны, регистр
        XCTAssertTrue(AppRouter.matches(c, query: "новожилова"))    // подборка
        XCTAssertTrue(AppRouter.matches(c, query: "сыктывкарский"))  // суд
        XCTAssertFalse(AppRouter.matches(c, query: "петров"))
    }

    /// #100 сменил показываемый суд на инстанцию ближайшего события. Дело,
    /// ушедшее в апелляцию, обязано находиться и по новому суду, и по суду
    /// первой инстанции: номер дела у него по-прежнему её, и в голове
    /// пользователя оно остаётся делом своего районного суда.
    func testQueryMatchesBothDisplayedAndRecordCourt() {
        var c = tracked("2-8236/2025")
        c.court = "Верховный суд Республики Коми"

        XCTAssertTrue(AppRouter.matches(c, query: "верховный"))
        XCTAssertTrue(AppRouter.matches(c, query: "сыктывкарский"))
        XCTAssertFalse(AppRouter.matches(c, query: "выборгский"))
    }

    @MainActor
    func testDeleteCollectionKeepsCasesAndRefreshesCounters() throws {
        let defaults = UserDefaults.standard
        let collectionsKey = "myCollections"
        let oldCollections = defaults.object(forKey: collectionsKey)
        let oldSpotlightOnboarding = defaults.object(forKey: SpotlightPreferenceStore.onboardingKey)
        let deleted = "Удалить-\(UUID().uuidString)"
        let kept = "Оставить-\(UUID().uuidString)"
        let empty = "Пустая-\(UUID().uuidString)"
        defaults.set([deleted, kept, empty], forKey: collectionsKey)
        defaults.set(false, forKey: SpotlightPreferenceStore.onboardingKey)
        defer {
            if let oldCollections { defaults.set(oldCollections, forKey: collectionsKey) }
            else { defaults.removeObject(forKey: collectionsKey) }
            if let oldSpotlightOnboarding {
                defaults.set(oldSpotlightOnboarding, forKey: SpotlightPreferenceStore.onboardingKey)
            } else {
                defaults.removeObject(forKey: SpotlightPreferenceStore.onboardingKey)
            }
        }

        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let context = container.mainContext
        let first = TrackedCaseRecord(
            key: "court/1-1/2026", collections: [deleted, kept],
            caseNumber: "1-1/2026", courtTitle: "Суд", displayDomain: "court",
            contextData: Data(), snapshotData: nil)
        let second = TrackedCaseRecord(
            key: "court/1-2/2026", collections: [deleted],
            caseNumber: "1-2/2026", courtTitle: "Суд", displayDomain: "court",
            contextData: Data(), snapshotData: nil)
        context.insert(first)
        context.insert(second)
        try context.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        XCTAssertEqual(router.collections.map(\.0), ["Все дела", deleted, kept, empty])
        XCTAssertEqual(router.collections.map(\.1), [2, 2, 1, 0])

        router.folder = deleted
        XCTAssertTrue(router.deleteCollection(named: deleted))
        XCTAssertEqual(router.folder, "Все дела")
        XCTAssertEqual(router.cases.count, 2)
        XCTAssertEqual(router.collections.map(\.0), ["Все дела", kept, empty])
        XCTAssertEqual(router.collections.map(\.1), [2, 1, 0])
        XCTAssertEqual(Set(first.collectionNames), [kept])
        XCTAssertTrue(second.collectionNames.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: collectionsKey), [kept, empty])

        XCTAssertTrue(router.deleteCollection(named: empty))
        XCTAssertFalse(router.deleteCollection(named: "Все дела"))
        XCTAssertFalse(router.deleteCollection(named: "Неизвестная подборка"))
        XCTAssertEqual(router.collections.map(\.0), ["Все дела", kept])

        // Не оставляем уникальное тестовое имя для позднего reload из init Task.
        XCTAssertTrue(router.deleteCollection(named: kept))
    }

    @MainActor
    func testRefreshCallbackRemapsOpenedAliasToSurvivor() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let context = container.mainContext
        let old = TrackedCaseRecord(
            key: "old/2-100/2026", collections: [], caseNumber: "2-100/2026",
            courtTitle: "Старый суд", displayDomain: "old.sudrf.ru",
            contextData: Data(), snapshotData: nil)
        let survivor = TrackedCaseRecord(
            key: "survivor/2-200/2026", collections: [], caseNumber: "2-200/2026",
            courtTitle: "Канонический суд", displayDomain: "survivor.sudrf.ru",
            contextData: Data(), snapshotData: nil)
        let refreshedAt = Date(timeIntervalSince1970: 1_700_000_000)
        survivor.movementFetchedAt = refreshedAt
        context.insert(old)
        context.insert(survivor)
        try context.save()

        let defaults = UserDefaults.standard
        let readKey = "overviewReadFeedIDs.v1"
        let knownKey = "notifiedFeedIDs.v1"
        let savedRead = defaults.object(forKey: readKey)
        let savedKnown = defaults.object(forKey: knownKey)
        defer {
            if let savedRead { defaults.set(savedRead, forKey: readKey) }
            else { defaults.removeObject(forKey: readKey) }
            if let savedKnown { defaults.set(savedKnown, forKey: knownKey) }
            else { defaults.removeObject(forKey: knownKey) }
        }
        let oldFeedID = "\(old.key)#feed#123#—#Судебное заседание"
        defaults.set([oldFeedID], forKey: readKey)

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.openCase(old.caseNumber)

        survivor.addLegacyKeyAlias(old.key)
        context.delete(old)
        try context.save()
        XCTAssertEqual(store.record(forLocator: old.key)?.key, survivor.key)

        let fresh = CaseMovement(uid: "uid", caseNumber: survivor.caseNumber,
                                 inForce: false, instances: [], complaints: [:], acts: [])
        router.refreshCenter.onRefreshed?(
            survivor.key, fresh, [old.key: survivor.key])

        XCTAssertEqual(router.openedCase, survivor.caseNumber)
        XCTAssertEqual(router.liveMovement, fresh)
        XCTAssertEqual(router.movementFetchedAt, refreshedAt)
        XCTAssertEqual(router.refreshCenter.openedKey?(), survivor.key,
                       "следующий refresh должен искать survivor, а не удалённый alias")
        XCTAssertEqual(router.cases.map(\.recordKey), [survivor.key],
                       "scoped reload не должен оставлять alias или дублировать survivor")
        XCTAssertEqual(defaults.stringArray(forKey: readKey), [
            "\(survivor.key)#feed#123#—#Судебное заседание",
        ])
    }
}
