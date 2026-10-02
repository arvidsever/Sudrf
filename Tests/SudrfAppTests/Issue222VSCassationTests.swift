import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

/// Black-box regressions for the Supreme Court route and deadlines scoped to
/// an owned material. The assertions describe published procedural facts.
final class Issue222VSCassationTests: XCTestCase {
    private let today = DateUtil.parse("01.10.2026")!

    private func context(_ number: String, kas: Bool = false,
                         level: CourtLevel = .district) -> MovementContext {
        MovementContext(branchRaw: "general", region: "Республика Коми",
                        searchDomain: "syktsud--komi.sudrf.ru",
                        displayDomain: "syktsud.komi.sudrf.ru",
                        courtTitle: "Сыктывкарский городской суд",
                        courtLevelRaw: level.rawValue, courtCode: "11RS0001",
                        cartotekaId: kas ? "p1" : "g1",
                        cartotekaLevelRaw: level.rawValue, caseNumber: number)
    }

    private func sourceContext(for movement: CaseMovement, kas: Bool = false) throws -> MovementContext {
        let first = try XCTUnwrap(movement.instances.first { $0.level == .first })
        var value = context(movement.caseNumber, kas: kas)
        value.searchDomain = first.domain
        value.displayDomain = first.domain.replacingOccurrences(of: "--", with: ".")
        value.courtTitle = first.court
        value.cardURLString = first.sourceURL?.absoluteString
        if let url = first.sourceURL,
           let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            value.caseID = query.first { $0.name == "case_id" }?.value
            value.caseUID = query.first { $0.name == "case_uid" }?.value
        }
        return value
    }

    private func evaluation(_ movement: CaseMovement, context: MovementContext) throws
        -> DeadlineRuleEngine.Evaluation {
        let production = ProductionType(cartotekaId: context.cartotekaId)
        return DeadlineRuleEngine.evaluate(
            registry: try LegalDeadlineRegistry.load(), movement: movement,
            context: .init(movementContext: context),
            timeline: CaseLifecycleResolver.timeline(in: movement, production: production),
            today: today)
    }

    private func first(_ number: String, date: String = "01.01.2025",
                       court: String = "Сыктывкарский городской суд",
                       domain: String = "syktsud.komi.sudrf.ru") -> CaseInstance {
        CaseInstance(level: .first, court: court, caseNumber: number, judge: nil,
            domain: domain, foundByUID: false, result: "Иск удовлетворён",
            sessions: [
                CaseSession(date: date, event: "Судебное заседание", result: "Вынесено решение"),
                CaseSession(date: date, event: "Изготовлено мотивированное решение в окончательной форме")
            ], sourceEvidence: .init(decisionDate: date, category: "Споры из договоров"))
    }

    private func appeal(_ number: String = "33-100/2025", lower: String = "2-100/2025",
                        announcement: String = "01.03.2025", fullForm: String = "03.03.2025") -> CaseInstance {
        CaseInstance(level: .appeal, court: "Верховный суд Республики Коми", caseNumber: number,
            judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "Апелляционная жалоба оставлена без удовлетворения",
            sessions: [
                CaseSession(date: announcement, event: "Судебное заседание",
                            result: "Апелляционная жалоба оставлена без удовлетворения"),
                CaseSession(date: fullForm,
                            event: "Составлено мотивированное апелляционное определение в окончательной форме")
            ], sourceEvidence: .init(lowerCourt: .init(courtTitle: "Сыктывкарский городской суд",
                caseNumber: lower), decisionDate: announcement))
    }

    private func cassation(_ number: String = "8Г-100/2025", lower: String = "33-100/2025",
                           announcement: String = "01.06.2025", fullForm: String? = "04.06.2025",
                           result: String = "Кассационная жалоба оставлена без удовлетворения",
                           receipt: String? = nil, sessions extra: [CaseSession] = []) -> CaseInstance {
        var sessions = [CaseSession(date: announcement, event: "Судебное заседание", result: result)]
        if let fullForm {
            sessions.append(CaseSession(date: fullForm,
                event: "Составлено мотивированное кассационное определение в окончательной форме"))
        }
        sessions += extra
        return CaseInstance(level: .cassation, court: "Третий кассационный суд общей юрисдикции",
            caseNumber: number, judge: nil, domain: "3kas.sudrf.ru", foundByUID: true,
            result: result, sessions: sessions,
            sourceEvidence: .init(lowerCourt: .init(courtTitle: "Верховный суд Республики Коми",
                caseNumber: lower), receiptDate: receipt, decisionDate: announcement))
    }

    private func civilCase(cassation instance: CaseInstance) -> CaseMovement {
        CaseMovement(uid: "11RS0001-01-2025-000100-11", caseNumber: "2-100/2025",
            inForce: true, instances: [first("2-100/2025"), appeal(), instance],
            complaints: [:], acts: [], category: "Споры из договоров")
    }

    private func cassationDeadline(_ value: DeadlineRuleEngine.Evaluation) -> StoredDeadline? {
        value.deadlines.first { $0.kind == "cassation" }
    }

    private func assessment(_ value: DeadlineRuleEngine.Evaluation, _ id: String)
        -> DeadlineRuleAssessment? {
        value.assessments.first { $0.ruleID == id }
    }

    func testModernGPKSupremeDeadlineUsesOwnKSOYUFinalForm() throws {
        let movement = civilCase(cassation: cassation(announcement: "01.06.2025", fullForm: "10.06.2025"))
        let value = try evaluation(movement, context: context(movement.caseNumber))
        let deadline = try XCTUnwrap(cassationDeadline(value))

        XCTAssertEqual(deadline.provenance?.ruleID, "GPK-CASSATION-SUPREME-COURT")
        XCTAssertEqual(deadline.provenance?.trigger.dateRaw, "10.06.2025")
        XCTAssertEqual(deadline.date, DateUtil.parse("10.09.2025"))
    }

    func testHistoricalGPKSupremeDecisionDoesNotReceiveModernThreeMonthRule() throws {
        let movement = civilCase(cassation: cassation(
            announcement: "01.06.2023", fullForm: "10.06.2023"))
        let value = try evaluation(movement, context: context(movement.caseNumber))
        let assessment = try XCTUnwrap(assessment(value, "GPK-CASSATION-SUPREME-COURT"))

        XCTAssertNil(cassationDeadline(value))
        XCTAssertEqual(assessment.status, .unsupportedCalculation)
        XCTAssertTrue(assessment.missingPolicyIDs.contains("historicalVSCassationRegime"))
    }

    func testGPKCutoverUsesAnnouncementEvenWhenOwnFinalFormIsAfterCutover() throws {
        var movement = civilCase(cassation: cassation(announcement: "30.08.2024", fullForm: "03.09.2024"))
        let index = try XCTUnwrap(movement.instances.firstIndex { $0.level == .appeal })
        movement.instances[index].sessions = [
            CaseSession(date: "01.06.2024", event: "Судебное заседание",
                        result: "Апелляционная жалоба оставлена без удовлетворения")
        ]
        movement.instances[index].sourceEvidence?.decisionDate = "01.06.2024"
        let value = try evaluation(movement, context: context(movement.caseNumber))
        XCTAssertNil(cassationDeadline(value))
        XCTAssertEqual(assessment(value, "GPK-CASSATION-SUPREME-COURT")?.status, .unsupportedCalculation)
        XCTAssertTrue(assessment(value, "GPK-CASSATION-SUPREME-COURT")?.missingPolicyIDs.contains("historicalVSCassationRegime") == true)
    }

    func testQuotedLowerCourtFinalFormInOwnCassationActIsNotItsTrigger() throws {
        var movement = civilCase(cassation: cassation(fullForm: nil))
        let cassationIndex = try XCTUnwrap(movement.instances.firstIndex { $0.level == .cassation })
        movement.instances[cassationIndex].actID = "own-cassation-act"
        movement.acts = [CaseAct(id: "own-cassation-act", title: "Определение суда кассационной инстанции",
            date: "01.06.2025", courtShort: "Третий КСОЮ", instanceLevel: .cassation)]
        movement.actBodies["own-cassation-act"] =
            "Апелляционное определение от 18 мая 2025 года изготовлено в окончательной форме.\n\n" +
            "ОПРЕДЕЛИЛ: кассационную жалобу оставить без удовлетворения."
        let value = try evaluation(movement, context: context(movement.caseNumber))
        let assessment = try XCTUnwrap(assessment(value, "GPK-CASSATION-SUPREME-COURT"))

        XCTAssertNil(cassationDeadline(value))
        XCTAssertTrue(assessment.isIndeterminate)
        XCTAssertTrue(assessment.missingEvidenceRaw.contains(DeadlineEvidenceRequirement.finalForm.rawValue))
    }

    func testRemandOnMeritsStillStartsGPKSupremeDeadlineAtOwnFinalForm() throws {
        let remand = cassation(announcement: "01.06.2025", fullForm: "10.06.2025",
            result: "Определение отменено, дело направлено на новое рассмотрение")
        let movement = civilCase(cassation: remand)
        let value = try evaluation(movement, context: context(movement.caseNumber))
        let deadline = try XCTUnwrap(cassationDeadline(value))

        XCTAssertEqual(deadline.provenance?.trigger.dateRaw, "10.06.2025")
        XCTAssertEqual(deadline.provenance?.trigger.caseNumber, "8Г-100/2025")
    }

    func testKASSupremeRouteKeepsOneSixMonthWindowAndCountsUnionElapsedDays() throws {
        let number = "2а-100/2026"
        let firstInstance = CaseInstance(level: .first, court: "Сыктывкарский городской суд",
            caseNumber: number, judge: nil, domain: "syktsud.komi.sudrf.ru", foundByUID: false,
            result: "Административный иск удовлетворён",
            sessions: [
                CaseSession(date: "01.01.2026", event: "Решение вступило в законную силу"),
                CaseSession(date: "08.01.2026", event: "Кассационная жалоба поступила в суд первой инстанции")
            ], sourceEvidence: .init(decisionDate: "01.01.2026", category: "Споры, возникающие из публичных правоотношений"))
        let appealCard = CaseInstance(level: .appeal, court: "Верховный суд Республики Коми",
            caseNumber: "66а-100/2026", judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "Апелляционная жалоба оставлена без удовлетворения",
            sessions: [
                CaseSession(date: "01.01.2026", event: "Судебное заседание",
                            result: "Апелляционная жалоба оставлена без удовлетворения"),
                CaseSession(date: "04.01.2026", event: "Составлено мотивированное апелляционное определение в окончательной форме")
            ], sourceEvidence: .init(lowerCourt: .init(courtTitle: firstInstance.court,
                caseNumber: number), decisionDate: "01.01.2026"))
        let supremeCassation = CaseInstance(level: .cassation,
            court: "Кассационный суд общей юрисдикции", caseNumber: "8Г-100/2026", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Кассационная жалоба оставлена без удовлетворения",
            sessions: [
                CaseSession(date: "10.01.2026", event: "Судебное заседание",
                            result: "Кассационная жалоба оставлена без удовлетворения"),
                CaseSession(date: "10.01.2026", event: "Составлено мотивированное кассационное определение в окончательной форме")
            ], sourceEvidence: .init(lowerCourt: .init(courtTitle: appealCard.court,
                caseNumber: appealCard.caseNumber), receiptDate: "10.01.2026", decisionDate: "10.01.2026"))
        let movement = CaseMovement(uid: "11RS0001-01-2026-000100-11", caseNumber: number,
            inForce: true, instances: [firstInstance, appealCard, supremeCassation], complaints: [:],
            acts: [], category: "Споры, возникающие из публичных правоотношений")
        var ctx = context(number, kas: true)
        // This is the original card's filing date, not the KSOYU receipt date.
        ctx.receiptDate = "02.01.2026"
        let value = try evaluation(movement, context: ctx)
        let deadline = try XCTUnwrap(cassationDeadline(value))

        XCTAssertEqual(deadline.provenance?.ruleID, "KAS-CASSATION-SUPREME-COURT")
        XCTAssertEqual(deadline.provenance?.trigger.dateRaw, "01.01.2026")
        // Three elapsed days for the appeal plus two for the first cassation:
        // Jan 1 + six months + five days = July 6, with no extra day.
        XCTAssertEqual(deadline.date, DateUtil.parse("06.07.2026"))
    }

    func testOverlappingKASIntervalsCountTheirUnionOnce() {
        let value = DeadlineRuleEngine.excludedElapsedDays([
            (DateUtil.parse("10.01.2026")!, DateUtil.parse("15.01.2026")!),
            (DateUtil.parse("13.01.2026")!, DateUtil.parse("18.01.2026")!)
        ])

        XCTAssertEqual(value, 8)
    }

    func testKASSupremeAssessmentStaysIndeterminateWithoutOwnReceiptOrFinalForm() throws {
        let number = "2а-101/2026"
        let firstInstance = CaseInstance(level: .first, court: "Сыктывкарский городской суд",
            caseNumber: number, judge: nil, domain: "syktsud.komi.sudrf.ru", foundByUID: false,
            result: "Административный иск удовлетворён",
            sessions: [CaseSession(date: "01.01.2026", event: "Решение вступило в законную силу")],
            sourceEvidence: .init(decisionDate: "01.01.2026", category: "Публичные правоотношения"))
        let accepted = CaseInstance(level: .cassation, court: "Кассационный суд общей юрисдикции",
            caseNumber: "8Г-101/2026", judge: nil, domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Кассационная жалоба оставлена без удовлетворения",
            sessions: [CaseSession(date: "10.01.2026", event: "Судебное заседание",
                result: "Кассационная жалоба оставлена без удовлетворения")],
            sourceEvidence: .init(decisionDate: "10.01.2026"))
        let movement = CaseMovement(uid: "11RS0001-01-2026-000101-11", caseNumber: number,
            inForce: true, instances: [firstInstance, accepted], complaints: [:], acts: [],
            category: "Публичные правоотношения")
        let value = try evaluation(movement, context: context(number, kas: true))
        let assessment = try XCTUnwrap(assessment(value, "KAS-CASSATION-SUPREME-COURT"))

        XCTAssertNil(cassationDeadline(value))
        XCTAssertTrue(assessment.isIndeterminate)
        XCTAssertTrue(assessment.missingEvidenceRaw.contains(DeadlineEvidenceRequirement.firstCourtCassationReceipt.rawValue)
            || assessment.missingEvidenceRaw.contains(DeadlineEvidenceRequirement.cassationFinalForm.rawValue))
    }

    func testReturnedKASComplaintDoesNotCountAsCompletedCassationReview() throws {
        let number = "2а-102/2026"
        let root = first(number, date: "01.01.2026")
        let returned = CaseInstance(level: .cassation, court: "Кассационный суд общей юрисдикции",
            caseNumber: "8Г-102/2026", judge: nil, domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Кассационная жалоба возвращена заявителю",
            sessions: [CaseSession(date: "05.01.2026", event: "Определение о возвращении кассационной жалобы",
                result: "Кассационная жалоба возвращена заявителю")])
        let movement = CaseMovement(uid: "11RS0001-01-2026-000102-11", caseNumber: number,
            inForce: true, instances: [root, returned], complaints: [:], acts: [],
            category: "Публичные правоотношения")
        let value = try evaluation(movement, context: context(number, kas: true))

        XCTAssertNil(cassationDeadline(value))
        XCTAssertEqual(assessment(value, "KAS-CASSATION-SUPREME-COURT")?.status, .notApplicable)
    }

    func testDirectKASSupremeRouteRequiresEligibleCategoryAndSubjectCourt() throws {
        let eligibleCategory = "О расформировании избирательной комиссии"
        func directAppeal(category: String) -> CaseMovement {
            var root = first("2а-103/2026", court: "Верховный суд Республики Коми",
                             domain: "vs--komi.sudrf.ru")
            root.sourceEvidence?.category = category
            let review = CaseInstance(level: .appeal, court: "Второй апелляционный суд общей юрисдикции",
                caseNumber: "66а-103/2026", judge: nil, domain: "2ap.sudrf.ru", foundByUID: true,
                result: "Апелляционная жалоба оставлена без удовлетворения",
                sessions: [CaseSession(date: "01.06.2026", event: "Судебное заседание",
                    result: "Апелляционная жалоба оставлена без удовлетворения"),
                          CaseSession(date: "03.06.2026", event: "Составлено мотивированное апелляционное определение в окончательной форме")],
                actID: "direct-route",
                sourceEvidence: .init(lowerCourt: .init(courtTitle: root.court, caseNumber: root.caseNumber),
                    decisionDate: "01.06.2026"))
            return CaseMovement(uid: "fixture-kas-direct-route", caseNumber: root.caseNumber,
                inForce: true, instances: [root, review], complaints: [:],
                acts: [CaseAct(id: "direct-route", title: "Апелляционное определение",
                    date: "01.06.2026", courtShort: "Второй АСОЮ", instanceLevel: .appeal)],
                actBodies: ["direct-route": "ОПРЕДЕЛИЛ: апелляционное определение может быть обжаловано в Судебную коллегию по административным делам Верховного Суда Российской Федерации."] ,
                category: category)
        }
        let subject = directAppeal(category: eligibleCategory)
        var district = subject
        district.instances[0].court = "Сыктывкарский городской суд"
        district.instances[0].domain = "syktsud.komi.sudrf.ru"
        district.instances[1].sourceEvidence?.lowerCourt?.courtTitle = "Сыктывкарский городской суд"
        let genericSubject = directAppeal(category: "Публичные правоотношения")
        let excludedByArticle20Point12 = directAppeal(category: "Об определении срока назначения выборов")
        let subjectValue = try evaluation(subject,
            context: context(subject.caseNumber, kas: true, level: .subject))
        let districtValue = try evaluation(district,
            context: context(district.caseNumber, kas: true, level: .district))
        let genericValue = try evaluation(genericSubject,
            context: context(genericSubject.caseNumber, kas: true, level: .subject))
        let point12Value = try evaluation(excludedByArticle20Point12,
            context: context(excludedByArticle20Point12.caseNumber, kas: true, level: .subject))

        XCTAssertNotNil(cassationDeadline(subjectValue))
        XCTAssertEqual(assessment(districtValue, "KAS-CASSATION-SUPREME-COURT")?.status, .notApplicable)
        let unknownCategory = try XCTUnwrap(assessment(genericValue, "KAS-CASSATION-SUPREME-COURT"))
        XCTAssertEqual(unknownCategory.status, .insufficientEvidence)
        XCTAssertTrue(unknownCategory.missingEvidenceRaw.contains(DeadlineEvidenceRequirement.caseCategory.rawValue))
        XCTAssertEqual(assessment(point12Value, "KAS-CASSATION-SUPREME-COURT")?.status, .notApplicable)
    }

    func testDirectKASCategoryWithoutOwnSupremeInstructionDoesNotStartDeadline() throws {
        let category = "О расформировании избирательной комиссии"
        var root = first("2а-103/2026", court: "Верховный суд Республики Коми",
                         domain: "vs--komi.sudrf.ru")
        root.sourceEvidence?.category = category
        let review = CaseInstance(level: .appeal, court: "Второй апелляционный суд общей юрисдикции",
            caseNumber: "66а-103/2026", judge: nil, domain: "2ap.sudrf.ru", foundByUID: true,
            result: "Апелляционная жалоба оставлена без удовлетворения",
            sessions: [CaseSession(date: "01.06.2026", event: "Судебное заседание",
                result: "Апелляционная жалоба оставлена без удовлетворения"),
                       CaseSession(date: "03.06.2026", event: "Составлено мотивированное апелляционное определение в окончательной форме")],
            sourceEvidence: .init(lowerCourt: .init(courtTitle: root.court, caseNumber: root.caseNumber),
                decisionDate: "01.06.2026"))
        let movement = CaseMovement(uid: "fixture-kas-direct-route", caseNumber: root.caseNumber,
            inForce: true, instances: [root, review], complaints: [:], acts: [], category: category)
        let value = try evaluation(movement,
            context: context(movement.caseNumber, kas: true, level: .subject))
        let warning = try XCTUnwrap(assessment(value, "KAS-CASSATION-SUPREME-COURT"))

        XCTAssertNil(cassationDeadline(value))
        XCTAssertEqual(warning.status, .insufficientEvidence)
        XCTAssertTrue(warning.missingEvidenceRaw.contains(DeadlineEvidenceRequirement.cassationRoute.rawValue))
    }

    func testIssue372MaterialDateAndResultRemainMaterialOnly() throws {
        let movement = try Issue372CassationFixtures.movement("main-cassation-vs-material-cost")
        let ctx = try sourceContext(for: movement)
        let material = try XCTUnwrap(MaterialDeadlineScope.proven(in: movement, context: ctx)
            .first { $0.movement.caseNumber == "13-630/2026" })
        let snap = MovementDerivation.snapshot(from: movement, context: ctx, today: today)
        let sourceCardID = material.sourceCardID
        let materialDeadline = try XCTUnwrap(snap.deadlines.first {
            MovementDerivation.deadlineScopeKey($0) == sourceCardID
        })

        XCTAssertEqual(material.movement.instances.flatMap(\.sessions).first { $0.event == "Судебное заседание" }?.date,
                       "16.02.2026")
        XCTAssertEqual(material.movement.instances.flatMap(\.sessions).first { $0.event == "Судебное заседание" }?.result,
                       "Удовлетворено частично")
        XCTAssertEqual(DateUtil.parse(materialDeadline.provenance?.trigger.dateRaw), DateUtil.parse("05.08.2026"))
        XCTAssertEqual(materialDeadline.date, DateUtil.parse("05.11.2026"))
        XCTAssertEqual(materialDeadline.provenance?.ruleID, "GPK-CASSATION-SUPREME-COURT")
        XCTAssertEqual(snap.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(snap.deadlines.filter { MovementDerivation.deadlineScopeKey($0) == nil },
                       try evaluation(movement, context: ctx).deadlines)
    }

    func testTwoMaterialsWithSharedUIDNeedOwnBindingsAndKeepSeparateScopes() throws {
        let sharedUID = "11RS0001-01-2026-000200-11"
        func material(_ number: String, id: String) -> CaseInstance {
            CaseInstance(level: .material, court: "Сыктывкарский городской суд", caseNumber: number,
                judge: nil, domain: "syktsud.komi.sudrf.ru", foundByUID: true,
                result: "Производство по делу прекращено",
                sessions: [CaseSession(date: "01.02.2026", event: "Судебное заседание",
                    result: "Производство по делу прекращено")],
                sourceURL: URL(string: "https://syktsud.komi.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=\(id)&case_uid=00000000-0000-0000-0000-000000000\(id)&delo_id=1610001"),
                sourceEvidence: .init(judicialUID: sharedUID,
                    cartotekaID: "m", sourceCourtLevel: .district, ownProcessKind: .civil))
        }
        var root = first("2-200/2026")
        root.sourceEvidence?.judicialUID = sharedUID
        let movement = CaseMovement(uid: sharedUID, caseNumber: root.caseNumber,
            inForce: true, instances: [root, material("13-201/2026", id: "201"),
                material("13-202/2026", id: "202")], complaints: [:], acts: [],
            category: "Споры из договоров")
        let scopes = MaterialDeadlineScope.proven(in: movement, context: context(root.caseNumber))

        XCTAssertEqual(Set(scopes.map(\.movement.caseNumber)), ["13-201/2026", "13-202/2026"])
        XCTAssertEqual(Set(scopes.map(\.sourceCardID)).count, 2)
        XCTAssertTrue(scopes.allSatisfy { $0.movement.instances.allSatisfy { $0.level == .material } })
    }

    func testRealMaterialManualChoiceSurvivesPartialRefreshAndClosedHistoryDoesNotRevive() throws {
        let full = try Issue372CassationFixtures.movement("main-cassation-vs-material-cost")
        let ctx = try sourceContext(for: full)
        let original = MovementDerivation.snapshot(from: full, context: ctx, today: today)
        let scoped = try XCTUnwrap(original.deadlines.first {
            MovementDerivation.deadlineScopeKey($0) != nil
        })
        XCTAssertEqual(scoped.date, DateUtil.parse("05.11.2026"))
        var saved = original
        let deadlineIndex = try XCTUnwrap(saved.deadlines.firstIndex {
            $0.occurrenceKey == scoped.occurrenceKey
        })
        saved.deadlines[deadlineIndex].dateRef = DateUtil.parse("15.11.2026")!.timeIntervalSinceReferenceDate
        saved.deadlines[deadlineIndex].statusRaw = DeadlineStatus.overridden.rawValue
        // Codable round-trip models a saved record loaded again on app launch.
        saved = try JSONDecoder().decode(CaseSnapshot.self, from: JSONEncoder().encode(saved))

        var partial = full
        partial.instances.removeAll { $0.level == .material }
        let partialSnapshot = MovementDerivation.snapshot(from: partial, context: ctx, today: today)
        let retained = MovementDerivation.preservingConfirmedDeadlines(
            partialSnapshot, old: saved, today: today, preserveActiveProposedWhenMissing: true,
            movement: partial, context: ctx)
        let manual = try XCTUnwrap(retained.deadlines.first { $0.occurrenceKey == scoped.occurrenceKey })
        XCTAssertEqual(manual.date, DateUtil.parse("15.11.2026"))
        XCTAssertEqual(manual.status, .overridden)

        var closed = saved
        let closedIndex = try XCTUnwrap(closed.deadlines.firstIndex { $0.occurrenceKey == scoped.occurrenceKey })
        closed.deadlines[closedIndex].lifecycleRaw = DeadlineLifecycle.superseded.rawValue
        let refreshed = MovementDerivation.snapshot(from: full, context: ctx, today: today)
        let afterClosed = MovementDerivation.preservingConfirmedDeadlines(
            refreshed, old: closed, today: today, movement: full, context: ctx)
        let history = try XCTUnwrap(afterClosed.deadlines.first { $0.occurrenceKey == scoped.occurrenceKey })
        XCTAssertEqual(history.lifecycle, .superseded)
    }
    func testNewVSRouteDoesNotInheritMainOrKSOYUManualDate() throws {
        let movement = try Issue372CassationFixtures.movement("main-cassation-vs-material-cost")
        let ctx = try sourceContext(for: movement)
        let fresh = MovementDerivation.snapshot(from: movement, context: ctx, today: today)
        let term = try XCTUnwrap(fresh.deadlines.first { MovementDerivation.deadlineScopeKey($0) != nil })
        for material in [false, true] {
            var previous = term
            previous.occurrenceKey = material
                ? term.occurrenceKey?.replacingOccurrences(of: "GPK-CASSATION-SUPREME-COURT|", with: "GPK-CASSATION-CSOY|")
                : nil
            previous.provenance?.ruleID = "GPK-CASSATION-CSOY"
            previous.dateRef = DateUtil.parse("15.11.2026")!.timeIntervalSinceReferenceDate
            previous.statusRaw = DeadlineStatus.overridden.rawValue
            var old = fresh
            old.deadlines = [previous]
            let retained = MovementDerivation.preservingConfirmedDeadlines(fresh, old: old,
                today: today, movement: movement, context: ctx)
            let current = try XCTUnwrap(retained.deadlines.first { $0.occurrenceKey == term.occurrenceKey })
            XCTAssertEqual(current.date, DateUtil.parse("05.11.2026"))
            XCTAssertEqual(current.status, .proposed)
        }
    }

}
