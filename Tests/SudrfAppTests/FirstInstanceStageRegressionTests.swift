import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class FirstInstanceStageRegressionTests: XCTestCase {
    private let today = DateUtil.parse("01.09.2026")!

    private func card(_ level: CaseInstance.Level, _ number: String, court: String,
                      result: String?, sessions: [CaseSession],
                      evidence: CaseInstance.SourceEvidence? = nil,
                      actID: String? = nil) -> CaseInstance {
        CaseInstance(level: level, court: court, caseNumber: number, judge: nil,
                     domain: "court.sudrf.ru", foundByUID: true, result: result,
                     sessions: sessions, actID: actID, sourceEvidence: evidence)
    }

    private func resolve(_ number: String, _ instances: [CaseInstance],
                         production: ProductionType = .civil,
                         acts: [CaseAct] = [],
                         actBodies: [String: String] = [:]) -> CaseLifecycleResolver.Resolution {
        let movement = CaseMovement(uid: "11RS0001-01-2025-000100-11", caseNumber: number,
                                    inForce: false, instances: instances, complaints: [:],
                                    acts: acts, actBodies: actBodies)
        return CaseLifecycleResolver.resolve(movement: movement, production: production,
                                             deadlines: [], today: today)
    }

    func testElectionCaseWithWithdrawnAppealIsCompleted() {
        let main = card(.first, "2а-3591/2019", court: "Районный суд",
                        result: "Отказано в удовлетворении иска", sessions: [
                            CaseSession(date: "12.08.2019", event: "Вынесено решение по делу",
                                        result: "Отказано в удовлетворении иска"),
                        ])
        let appeal = card(.appeal, "33а-30784/2019", court: "Городской суд",
                          result: "Производство по жалобе прекращено - отказ от жалобы", sessions: [
                            CaseSession(date: "23.12.2019", event: "Судебное заседание",
                                        result: "Производство по жалобе прекращено"),
                          ])

        let resolution = resolve("2а-3591/2019", [main, appeal], production: .kas)

        XCTAssertEqual(resolution.stage, .done)
        XCTAssertTrue(resolution.isCompleted)
    }

    func testEarlierPrivateAppealAndLaterMaterialDoNotReopenMainReview() {
        let main = card(.first, "2-284/2023", court: "Районный суд",
                        result: "Иск удовлетворён частично", sessions: [
                            CaseSession(date: "24.01.2023", event: "Вынесено решение по делу",
                                        result: "Иск удовлетворён частично"),
                        ], evidence: .init(appealKinds: ["Частная жалоба", "Апелляционная жалоба"],
                                           decisionDate: "24.01.2023"))
        let earlyAppeal = card(.appeal, "33-7231/2022", court: "Областной суд",
                               result: "Определение отменено с разрешением вопроса по существу",
                               sessions: [CaseSession(date: "20.10.2022", event: "Судебное заседание",
                                                      result: "Определение отменено с разрешением вопроса по существу")],
                               evidence: .init(lowerCourt: .init(caseNumber: "2-284/2023")))
        let mainAppeal = card(.appeal, "33-2998/2023", court: "Областной суд",
                              result: "Решение изменено без направления на новое рассмотрение",
                              sessions: [CaseSession(date: "06.04.2023", event: "Судебное заседание",
                                                     result: "Решение изменено без направления на новое рассмотрение")],
                              evidence: .init(lowerCourt: .init(caseNumber: "2-284/2023")))
        let material = card(.material, "13-1834/2024", court: "Районный суд",
                            result: "Удовлетворено частично", sessions: [
                                CaseSession(date: "24.04.2024", event: "Судебное заседание",
                                            result: "Удовлетворено частично"),
                            ])

        let resolution = resolve("2-284/2023", [main, earlyAppeal, mainAppeal, material])

        XCTAssertEqual(resolution.stage, .done)
        XCTAssertTrue(resolution.isCompleted)
    }

    func testEarlyPrivateAppealDoesNotKeepLaterOrdinaryAppealActive() {
        let main = card(.first, "2-4227/2019", court: "Районный суд",
                        result: "Иск удовлетворён", sessions: [
                            CaseSession(date: "01.05.2019", event: "Иск принят к производству"),
                            CaseSession(date: "20.11.2019", event: "Решение по делу", result: "Иск удовлетворён"),
                        ], evidence: .init(appealKinds: ["Частная жалоба"], decisionDate: "20.11.2019"))
        let privateAppeal = card(.appeal, "33-1234/2019", court: "Областной суд",
                                 result: "Частная жалоба оставлена без удовлетворения", sessions: [
                                    CaseSession(date: "15.05.2019", event: "Рассмотрение частной жалобы",
                                                result: "Частная жалоба оставлена без удовлетворения"),
                                 ], evidence: .init(lowerCourt: .init(caseNumber: "2-4227/2019")))
        let ordinaryAppeal = card(.appeal, "33-5678/2020", court: "Областной суд",
                                  result: "Решение оставлено без изменения", sessions: [
                                    CaseSession(date: "20.01.2020", event: "Рассмотрение апелляционной жалобы",
                                                result: "Решение оставлено без изменения"),
                                  ], evidence: .init(lowerCourt: .init(caseNumber: "2-4227/2019")))

        let resolution = resolve("2-4227/2019", [main, privateAppeal, ordinaryAppeal])

        XCTAssertEqual(resolution.stage, .done)
        XCTAssertTrue(resolution.isCompleted)
    }

    func testTerminatedRootWithUnchangedAppealAndRejectedCassationIsDone() {
        let main = card(.first, "2а-11046/2024", court: "Районный суд",
                        result: "Производство по делу прекращено", sessions: [
                            CaseSession(date: "20.02.2024", event: "Производство по делу прекращено",
                                        result: "Производство по делу прекращено"),
                        ])
        let appeal = card(.appeal, "33а-1100/2024", court: "Областной суд",
                          result: "Оставлено без изменения", sessions: [
                            CaseSession(date: "15.04.2024", event: "Рассмотрение апелляционной жалобы",
                                        result: "Оставлено без изменения"),
                          ])
        let cassation = card(.cassation, "8а-9000/2024", court: "Кассационный суд",
                             result: "Отказано в передаче кассационной жалобы для рассмотрения",
                             sessions: [CaseSession(date: "20.12.2024", event: "Результат рассмотрения",
                                                   result: "Отказано в передаче кассационной жалобы для рассмотрения")])

        let resolution = resolve("2а-11046/2024", [main, appeal, cassation])

        XCTAssertEqual(resolution.stage, .done)
        XCTAssertTrue(resolution.isCompleted)
    }

    func testReviewOfAncillaryMaterialDoesNotReactivateCompletedMainCase() {
        let main = card(.first, "2-4869/2025", court: "Районный суд",
                        result: "Иск удовлетворён", sessions: [
                            CaseSession(date: "10.12.2025", event: "Решение по делу", result: "Иск удовлетворён"),
                        ], evidence: .init(decisionDate: "10.12.2025"))
        let material = card(.material, "13-630/2026", court: "Районный суд",
                             result: nil, sessions: [
                                CaseSession(date: "10.06.2026", event: "Материал принят к производству"),
                             ])
        let materialReview = card(.appeal, "33-7000/2026", court: "Областной суд",
                                  result: "Постановление оставлено без изменения", sessions: [
                                    CaseSession(date: "20.06.2026", event: "Рассмотрение жалобы",
                                                result: "Постановление оставлено без изменения"),
                                  ], evidence: .init(lowerCourt: .init(courtTitle: "Районный суд",
                                                                       caseNumber: "13-630/2026")))

        let resolution = resolve("2-4869/2025", [main, material, materialReview])

        XCTAssertEqual(materialReview.sourceEvidence?.lowerCourt?.caseNumber, "13-630/2026")
        XCTAssertEqual(resolution.stage, .done)
        XCTAssertTrue(resolution.isCompleted)
    }

    func testAncillaryMaterialReviewChainStaysVisibleButIsExcludedFromLifecycle() {
        let main = card(.first, "2-777/2025", court: "Районный суд",
                        result: "Иск удовлетворён", sessions: [
                            CaseSession(date: "10.12.2025", event: "Решение по делу", result: "Иск удовлетворён"),
                        ], evidence: .init(decisionDate: "10.12.2025"))
        let material = card(.material, "13-222/2026", court: "Районный суд",
                            result: nil, sessions: [])
        let materialAppeal = card(.appeal, "33-333/2026", court: "Областной суд",
                                  result: nil, sessions: [
                                    CaseSession(date: "23.04.2026", event: "Рассмотрение жалобы"),
                                  ], evidence: .init(lowerCourt: .init(caseNumber: "13-222/2026")))
        let materialCassation = card(.cassation, "88-444/2026",
                                     court: "Третий кассационный суд общей юрисдикции",
                                     result: nil, sessions: [
                                        CaseSession(date: "05.08.2026", event: "Результат рассмотрения жалобы"),
                                     ], evidence: .init(lowerCourt: .init(caseNumber: "33-333/2026")))
        let movement = CaseMovement(uid: "11RS0001-01-2025-000100-11", caseNumber: "2-777/2025",
                                    inForce: false, instances: [main, material, materialAppeal, materialCassation],
                                    complaints: [:], acts: [])
        let timeline = CaseLifecycleResolver.timeline(in: movement, production: .civil)
        let resolution = CaseLifecycleResolver.resolve(movement: movement, production: .civil,
                                                       deadlines: [], today: today)

        for number in ["33-333/2026", "88-444/2026"] {
            XCTAssertTrue(timeline.instances.contains { $0.caseNumber == number }, number)
            XCTAssertFalse(timeline.lifecycleOrdered.contains { $0.instance.caseNumber == number }, number)
        }
        XCTAssertEqual(resolution.stage, .done)
        XCTAssertTrue(resolution.isCompleted)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, "2-777/2025")
    }

    func testTerminalRootAfterEarlyPrivateAppealWithoutMainReviewIsDone() {
        let main = card(.first, "2-4227/2019", court: "Районный суд",
                        result: "Иск удовлетворён", sessions: [
                            CaseSession(date: "01.05.2019", event: "Иск принят к производству"),
                            CaseSession(date: "20.11.2019", event: "Решение по делу", result: "Иск удовлетворён"),
                        ], evidence: .init(appealKinds: ["Частная жалоба"], decisionDate: "20.11.2019"))
        let privateAppeal = card(.appeal, "33-1234/2019", court: "Областной суд",
                                 result: "Частная жалоба оставлена без удовлетворения", sessions: [
                                    CaseSession(date: "15.05.2019", event: "Рассмотрение частной жалобы",
                                                result: "Частная жалоба оставлена без удовлетворения"),
                                 ], evidence: .init(lowerCourt: .init(caseNumber: "2-4227/2019")))

        let resolution = resolve("2-4227/2019", [main, privateAppeal])

        XCTAssertEqual(resolution.stage, .done)
        XCTAssertTrue(resolution.isCompleted)
    }

    func testStandaloneMaterialUsesDatedSessionResultWhenCardResultIsMissing() {
        let material = card(.material, "3/10-84/2016", court: "Мировой суд",
                            result: nil, sessions: [
                                CaseSession(date: "12.05.2016", event: "Судебное заседание",
                                            result: "Удовлетворено"),
                            ])

        let resolution = resolve("3/10-84/2016", [material])

        XCTAssertEqual(resolution.stage, .done)
        XCTAssertTrue(resolution.isCompleted)
    }

    func testPostJudgmentMotionDoesNotReopenCompletedMainCase() {
        let scenarios: [(number: String, result: String, decision: String,
                         registered: String, assigned: String, hearing: String, returned: String)] = [
            ("2-3767/2014", "Иск (заявление, жалоба) УДОВЛЕТВОРЕН",
             "25.07.2014", "24.03.2017", "29.03.2017", "05.05.2017", "07.06.2017"),
            ("2-3109/2017", "ОТКАЗАНО в удовлетворении иска (заявлении, жалобы)",
             "17.07.2017", "16.10.2017", "17.10.2017", "01.12.2017", "08.12.2017"),
        ]

        for scenario in scenarios {
            let main = card(.first, scenario.number, court: "Районный суд",
                            result: scenario.result, sessions: [
                                CaseSession(date: scenario.decision, event: "Судебное заседание",
                                            result: "Вынесено решение по делу"),
                                CaseSession(date: scenario.decision,
                                            event: "Изготовлено мотивированное решение в окончательной форме"),
                                CaseSession(date: scenario.registered,
                                            event: "Регистрация ходатайства/заявления лица, участвующего в деле"),
                                CaseSession(date: scenario.assigned,
                                            event: "Изучение поступившего ходатайства/заявления",
                                            result: "Назначено судебное заседание для рассмотрения ходатайства/заявления/вопроса"),
                                CaseSession(date: scenario.hearing, event: "Судебное заседание",
                                            result: "Ходатайство/заявление УДОВЛЕТВОРЕНО"),
                                CaseSession(date: scenario.returned,
                                            event: "Дело сдано в отдел судебного делопроизводства после рассмотрения ходатайства/заявления/вопроса"),
                            ])

            let resolution = resolve(scenario.number, [main])

            XCTAssertEqual(resolution.stage, .done, scenario.number)
            XCTAssertTrue(resolution.isCompleted, scenario.number)
        }
    }

    func testNewMainProceedingAfterTerminalRemainsActive() {
        let main = card(.first, "2-100/2025", court: "Районный суд",
                        result: "Иск удовлетворён", sessions: [
                            CaseSession(date: "12.12.2025", event: "Судебное заседание",
                                        result: "Вынесено решение по делу"),
                            CaseSession(date: "02.09.2026",
                                        event: "Исковое заявление принято к производству"),
                            CaseSession(date: "20.09.2026", event: "Судебное заседание"),
                        ], evidence: .init(decisionDate: "12.12.2025"))

        let resolution = resolve("2-100/2025", [main])

        XCTAssertEqual(resolution.stage, .first)
        XCTAssertFalse(resolution.isCompleted)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, "2-100/2025")
    }

    func testRealRemandAndFutureFirstInstanceHearingRemainActive() {
        let main = card(.first, "2-100/2025", court: "Районный суд",
                        result: "Иск удовлетворён", sessions: [
                            CaseSession(date: "12.12.2025", event: "Решение по делу", result: "Иск удовлетворён"),
                            CaseSession(date: "15.03.2026", event: "Иск принят к производству"),
                            CaseSession(date: "05.09.2026", event: "Судебное заседание"),
                        ], evidence: .init(decisionDate: "12.12.2025"))
        let appeal = card(.appeal, "33-1000/2026", court: "Областной суд",
                          result: "Оставлено без изменения", sessions: [
                            CaseSession(date: "20.01.2026", event: "Рассмотрение апелляционной жалобы",
                                        result: "Оставлено без изменения"),
                          ])
        let remand = card(.cassation, "88-5000/2026", court: "Кассационный суд",
                          result: "Решение отменено, дело направлено на новое рассмотрение в суд первой инстанции",
                          sessions: [CaseSession(date: "10.02.2026", event: "Результат рассмотрения",
                                                result: "Решение отменено, дело направлено на новое рассмотрение в суд первой инстанции")])

        let resolution = resolve("2-100/2025", [main, appeal, remand])

        XCTAssertEqual(resolution.stage, .first)
        XCTAssertFalse(resolution.isCompleted)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, "2-100/2025")
    }

    func testCase2a5428LaterOrdinaryAppealActCompletesAfterEarlierReviews() {
        let main = card(.first, "2а-5428/2023", court: "Сыктывкарский городской суд",
                        result: "Иск (заявление, жалоба) УДОВЛЕТВОРЕН ЧАСТИЧНО", sessions: [
                            CaseSession(date: "14.02.2023", event: "Регистрация административного искового заявления"),
                            CaseSession(date: "29.05.2023", event: "Судебное заседание",
                                        result: "Вынесено решение по делу"),
                            CaseSession(date: "13.06.2023", event: "Изготовлено мотивированное решение в окончательной форме"),
                            CaseSession(date: "30.06.2023", event: "Дело сдано в отдел судебного делопроизводства"),
                        ], evidence: .init(appealKinds: ["Частная жалоба", "Апелляционная жалоба"],
                                           decisionDate: "29.05.2023"))
        let earlyPrivateAppeal = card(.appeal, "33а-2564/2023", court: "Верховный суд Республики Коми",
                                      result: "Определение отменено полностью с разрешением вопроса по существу",
                                      sessions: [CaseSession(date: "23.03.2023", event: "Судебное заседание",
                                                             result: "Определение отменено полностью с разрешением вопроса по существу")],
                                      evidence: .init(lowerCourt: .init(caseNumber: "М-1522/2023")))
        let otherEarlyAppeal = card(.appeal, "33а-4639/2023", court: "Верховный суд Республики Коми",
                                    result: "Определение оставлено без изменения", sessions: [
                                        CaseSession(date: "01.06.2023", event: "Судебное заседание",
                                                    result: "Определение оставлено без изменения"),
                                    ], evidence: .init(lowerCourt: .init(caseNumber: "2а-5428/2023 ~ М-1522/2023")))
        let appealActID = "case-5428-appeal-act"
        let laterAppeal = card(.appeal, "33а-7520/2023", court: "Верховный суд Республики Коми",
                               result: "Решение оставлено без изменения", sessions: [
                                   CaseSession(date: "25.09.2023", event: "Судебное заседание",
                                               result: "Решение оставлено без изменения"),
                               ], evidence: .init(lowerCourt: .init(
                                    courtTitle: "Сыктывкарский городской суд",
                                    caseNumber: "2а-5428/2023"), decisionDate: "25.09.2023"),
                               actID: appealActID)

        let resolution = resolve("2а-5428/2023", [main, earlyPrivateAppeal, otherEarlyAppeal, laterAppeal],
                                 production: .kas,
                                 acts: [CaseAct(id: appealActID, title: "Апелляционное определение",
                                                date: "25.09.2023", courtShort: "Верховный суд Республики Коми",
                                                instanceLevel: .appeal)],
                                 actBodies: [appealActID: "ОПРЕДЕЛИЛ: решение Сыктывкарского городского суда Республики Коми от 29 мая 2023 года оставить без изменения.\n\nАпелляционное определение вступает в законную силу со дня его принятия."])

        XCTAssertEqual(resolution.stage, .done)
        XCTAssertTrue(resolution.isCompleted)
        XCTAssertEqual(resolution.completionReason, .legalForce)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, "33а-7520/2023")
    }

    func testCase2a354LaterOrdinaryAppealActCompletesAfterPriorRegistrationAppeal() {
        let main = card(.first, "2а-354/2023", court: "Сыктывкарский городской суд",
                        result: "ОТКАЗАНО в удовлетворении иска (заявлении, жалобы)", sessions: [
                            CaseSession(date: "27.07.2022", event: "Регистрация административного искового заявления"),
                            CaseSession(date: "07.08.2023", event: "Судебное заседание",
                                        result: "Вынесено решение по делу"),
                            CaseSession(date: "15.08.2023", event: "Изготовлено мотивированное решение в окончательной форме"),
                        ], evidence: .init(appealKinds: ["Частная жалоба", "Апелляционная жалоба"],
                                           decisionDate: "07.08.2023"))
        let earlierPrivateAppeal = card(.appeal, "33а-7164/2022", court: "Верховный суд Республики Коми",
                                         result: "Определение оставлено без изменения", sessions: [
                                             CaseSession(date: "31.10.2022", event: "Судебное заседание",
                                                         result: "Определение оставлено без изменения"),
                                         ], evidence: .init(lowerCourt: .init(
                                            courtTitle: "Сыктывкарский городской суд",
                                            caseNumber: "2а-8584/2022")))
        let appealActID = "case-2a354-appeal-act"
        let laterAppeal = card(.appeal, "33а-8830/2023", court: "Верховный суд Республики Коми",
                               result: "Решение оставлено без изменения", sessions: [
                                   CaseSession(date: "23.11.2023", event: "Судебное заседание",
                                               result: "Решение оставлено без изменения"),
                               ], evidence: .init(lowerCourt: .init(
                                    courtTitle: "Сыктывкарский городской суд",
                                    caseNumber: "2а-354/2023"), decisionDate: "23.11.2023"),
                               actID: appealActID)

        let resolution = resolve("2а-354/2023", [main, earlierPrivateAppeal, laterAppeal],
                                 production: .kas,
                                 acts: [CaseAct(id: appealActID, title: "Апелляционное определение",
                                                date: "23.11.2023", courtShort: "Верховный суд Республики Коми",
                                                instanceLevel: .appeal)],
                                 actBodies: [appealActID: "ОПРЕДЕЛИЛ: решение Сыктывкарского городского суда Республики Коми от 7 августа 2023 года оставить без изменения.\n\nАпелляционное определение вступает в законную силу со дня его принятия."])

        XCTAssertEqual(resolution.stage, .done)
        XCTAssertTrue(resolution.isCompleted)
        XCTAssertEqual(resolution.completionReason, .legalForce)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, "33а-8830/2023")
    }

    func testEarlierAmbiguousAppealDoesNotCloseUnresolvedNewFirstInstanceRound() {
        let main = card(.first, "2а-354/2023", court: "Сыктывкарский городской суд",
                        result: "ОТКАЗАНО в удовлетворении иска (заявлении, жалобы)", sessions: [
                            CaseSession(date: "27.07.2022", event: "Регистрация административного искового заявления"),
                            CaseSession(date: "07.08.2023", event: "Судебное заседание",
                                        result: "Вынесено решение по делу"),
                            CaseSession(date: "15.08.2023", event: "Изготовлено мотивированное решение в окончательной форме"),
                            CaseSession(date: "12.02.2024", event: "Административное исковое заявление принято к производству"),
                            CaseSession(date: "15.03.2024", event: "Судебное заседание"),
                        ], evidence: .init(appealKinds: ["Частная жалоба", "Апелляционная жалоба"],
                                           decisionDate: "07.08.2023"))
        let earlierPrivateAppeal = card(.appeal, "33а-7164/2022", court: "Верховный суд Республики Коми",
                                         result: "Определение оставлено без изменения", sessions: [
                                             CaseSession(date: "31.10.2022", event: "Судебное заседание",
                                                         result: "Определение оставлено без изменения"),
                                         ], evidence: .init(lowerCourt: .init(
                                            courtTitle: "Сыктывкарский городской суд",
                                            caseNumber: "2а-8584/2022")))

        let resolution = resolve("2а-354/2023", [main, earlierPrivateAppeal], production: .kas)

        XCTAssertEqual(resolution.stage, .first)
        XCTAssertFalse(resolution.isCompleted)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, "2а-354/2023")
    }

    func testCase3a178UsesMainAppealWhenSameUIDAlsoFindsAnotherLowerCase() {
        let uid = "78OS0000-01-2020-000134-67"
        let root = card(.first, "3а-178/2020 ~ М-127/2020", court: "Санкт-Петербургский городской суд",
                        result: "Производство по делу прекращено", sessions: [
                            CaseSession(date: "29.05.2020", event: "Вынесено решение по делу",
                                        result: "Производство по делу прекращено"),
                        ], evidence: .init(decisionDate: "29.05.2020", judicialUID: uid))
        let julyReview = card(.appeal, "66а-604/2020", court: "Второй апелляционный суд",
                              result: "Определение оставлено без изменения", sessions: [
                                  CaseSession(date: "15.07.2020", event: "Судебное заседание",
                                              result: "Определение оставлено без изменения"),
                              ], evidence: .init(lowerCourt: .init(caseNumber: "3а-218/2020"),
                                                 receiptDate: "13.07.2020", decisionDate: "15.07.2020",
                                                 judicialUID: uid))
        let newFirst = card(.first, "3а-218/2020", court: "Санкт-Петербургский городской суд",
                            result: "Иск (заявление, жалоба) УДОВЛЕТВОРЕН", sessions: [
                                CaseSession(date: "03.08.2020", event: "Судебное заседание",
                                            result: "Вынесено решение по делу"),
                            ], evidence: .init(decisionDate: "03.08.2020", judicialUID: uid))
        let privateAppeal = card(.appeal, "66а-1096/2020", court: "Второй апелляционный суд",
                                 result: "Определение оставлено без изменения", sessions: [
                                     CaseSession(date: "13.10.2020", event: "Передача дела судье"),
                                     CaseSession(date: "19.10.2020", event: "Судебное заседание",
                                                 result: "Определение оставлено без изменения"),
                                 ], evidence: .init(lowerCourt: .init(caseNumber: "3а-218/2020"),
                                                    receiptDate: "13.10.2020", decisionDate: "19.10.2020",
                                                    judicialUID: uid))
        let unrelatedAppeal = card(.appeal, "66а-1111/2020", court: "Второй апелляционный суд",
                                   result: "Определение оставлено без изменения", sessions: [
                                       CaseSession(date: "16.10.2020", event: "Передача дела судье"),
                                       CaseSession(date: "19.10.2020", event: "Судебное заседание",
                                                   result: "Определение оставлено без изменения"),
                                   ], evidence: .init(lowerCourt: .init(caseNumber: "3а-128/2020"),
                                                      receiptDate: "16.10.2020", decisionDate: "19.10.2020",
                                                      judicialUID: uid))
        let mainAppeal = card(.appeal, "66а-1110/2020", court: "Второй апелляционный суд",
                              result: "Решение (осн. требов.) отменено полностью с вынесением нового решения",
                              sessions: [
                                  CaseSession(date: "16.10.2020", event: "Передача дела судье"),
                                  CaseSession(date: "21.10.2020", event: "Судебное заседание",
                                              result: "Вынесено решение"),
                              ], evidence: .init(lowerCourt: .init(caseNumber: "3а-218/2020"),
                                                 receiptDate: "16.10.2020", decisionDate: "21.10.2020",
                                                 judicialUID: uid))

        let arrangements = [
            [root, julyReview, newFirst, privateAppeal, unrelatedAppeal, mainAppeal],
            [mainAppeal, unrelatedAppeal, privateAppeal, newFirst, julyReview, root],
            [root, newFirst, mainAppeal, julyReview, unrelatedAppeal, privateAppeal],
        ]
        for instances in arrangements {
            let movement = CaseMovement(uid: uid, caseNumber: root.caseNumber, inForce: false,
                                        instances: instances, complaints: [:], acts: [])
            let resolution = CaseLifecycleResolver.resolve(movement: movement, production: .kas,
                                                           deadlines: [], today: today)
            XCTAssertEqual(resolution.stage, .done)
            XCTAssertEqual(resolution.currentInstance?.caseNumber, mainAppeal.caseNumber)
        }
    }

    func testCompoundFirstNumberMatchesItsPrimaryLowerCourtReference() {
        let uid = "78OS0000-01-2020-000134-67"
        let first = card(.first, "3а-178/2020 ~ М-127/2020", court: "Санкт-Петербургский городской суд",
                         result: "Производство по делу прекращено", sessions: [
                             CaseSession(date: "29.05.2020", event: "Вынесено решение по делу",
                                         result: "Производство по делу прекращено"),
                         ], evidence: .init(decisionDate: "29.05.2020", judicialUID: uid))
        let appeal = card(.appeal, "66а-604/2020", court: "Второй апелляционный суд",
                          result: "Определение оставлено без изменения", sessions: [
                              CaseSession(date: "15.07.2020", event: "Судебное заседание",
                                          result: "Определение оставлено без изменения"),
                          ], evidence: .init(lowerCourt: .init(caseNumber: "3а-178/2020"),
                                             receiptDate: "13.07.2020", decisionDate: "15.07.2020",
                                             judicialUID: uid))
        let movement = CaseMovement(uid: uid, caseNumber: first.caseNumber, inForce: false,
                                    instances: [first, appeal], complaints: [:], acts: [])

        let timeline = CaseLifecycleResolver.timeline(in: movement, production: .kas)

        XCTAssertFalse(timeline.hasAmbiguousAppealEffect)
    }
}
