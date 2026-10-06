import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

struct Issue406FixtureFile: Decodable {
    struct Entry: Decodable {
        var movement: CaseMovement
        var context: MovementContext
    }

    var entries: [Entry]

    static func load() throws -> [Entry] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "issue406_joined_registrations", withExtension: "json",
            subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).entries
    }
}

final class Issue406LifecycleTests: XCTestCase {
    private let today = DateUtil.parse("22.09.2026")!
    private let joinedStatus = "Присоединено к другому делу"
    private let receivingHelp = "Принимающее дело не установлено по сохранённым сведениям"

    func testFiveSanitizedSourceRowsCompleteStandaloneCivilAndKASCases() throws {
        let entries = try Issue406FixtureFile.load()
        XCTAssertEqual(entries.count, 5)

        for entry in entries {
            let movement = entry.movement
            let production = ProductionType(cartotekaId: entry.context.cartotekaId)
            let first = try XCTUnwrap(movement.instances.first { $0.level == .first })
            XCTAssertTrue(production == .civil || production == .kas, movement.caseNumber)
            XCTAssertFalse(movement.inForce, movement.caseNumber)
            XCTAssertTrue(CaseLifecycleResolver.isJoinedRegistration(first, production: production),
                          movement.caseNumber)

            let resolution = CaseLifecycleResolver.resolve(
                movement: movement, production: production, deadlines: [], today: today)
            XCTAssertEqual(resolution.stage, .done, movement.caseNumber)
            XCTAssertEqual(resolution.currentInstance?.caseNumber, first.caseNumber)
            XCTAssertEqual(resolution.completionReason, .terminalFirst(joinedStatus))
            XCTAssertNil(resolution.graceDeadline, movement.caseNumber)

            let snapshot = MovementDerivation.snapshot(
                from: movement, context: entry.context, today: today)
            let presentation = MovementDerivation.lifecyclePresentation(
                from: movement, snapshot: snapshot, context: entry.context, today: today)
            XCTAssertEqual(snapshot.stageRaw, CaseStageKind.done.rawValue, movement.caseNumber)
            XCTAssertFalse(snapshot.inForce, movement.caseNumber)
            XCTAssertEqual(snapshot.statusText, joinedStatus, movement.caseNumber)
            XCTAssertEqual(snapshot.nextEvent, joinedStatus, movement.caseNumber)
            XCTAssertTrue(presentation.nextEventHelp?.contains(receivingHelp) == true,
                           movement.caseNumber)
            XCTAssertNil(presentation.currentTier, movement.caseNumber)
            XCTAssertFalse(snapshot.deadlines.contains {
                $0.provenance?.ruleID.contains("APPEAL") == true
            }, movement.caseNumber)
            XCTAssertTrue(snapshot.sessions.contains {
                $0.event == "Дело присоединено к другому делу"
                    || $0.result == "Дело присоединено к другому делу"
            }, movement.caseNumber)
        }
    }

    func testReceivingMotionRefusalAndTransferWordingAreNotOutgoingJoins() {
        let nonOutgoing = [
            "К делу присоединено другое дело",
            "Ходатайство о присоединении дел удовлетворено",
            "Отказано в удовлетворении ходатайства о соединении дел",
            "Дело передано для соединения с другим делом",
        ]

        for (index, text) in nonOutgoing.enumerated() {
            let number = "2-406-\(index)/2026"
            let first = CaseInstance(
                level: .first, court: "Синтетический районный суд", caseNumber: number,
                judge: nil, domain: "fixture.example.invalid", foundByUID: false,
                result: text, sessions: [CaseSession(
                    date: "01.09.2026", event: "Результат рассмотрения", result: text)])
            let movement = CaseMovement(
                uid: "issue406-synthetic", caseNumber: number, inForce: false,
                instances: [first], complaints: [:], acts: [])

            XCTAssertFalse(CaseLifecycleResolver.isJoinedRegistration(
                first, production: .civil), text)
            let resolution = CaseLifecycleResolver.resolve(
                movement: movement, production: .civil, deadlines: [], today: today)
            XCTAssertFalse(resolution.isCompleted, text)
            XCTAssertEqual(resolution.stage, .first, text)
        }
    }

    func testOutgoingWordingIsLimitedToCivilAndKASFirstInstances() throws {
        let entry = try XCTUnwrap(Issue406FixtureFile.load().first)
        let first = try XCTUnwrap(entry.movement.instances.first { $0.level == .first })

        for production in [ProductionType.crim, .koap] {
            let resolution = CaseLifecycleResolver.resolve(
                movement: entry.movement, production: production, deadlines: [], today: today)
            XCTAssertFalse(resolution.isCompleted, production.rawValue)
        }

        var appeal = first
        appeal.level = .appeal
        XCTAssertFalse(CaseLifecycleResolver.isJoinedRegistration(appeal, production: .kas))
    }

    func testEarlierReceivingRegistrationWithIncomingFactOnJoinDateStaysActive() throws {
        let entry = try XCTUnwrap(Issue406FixtureFile.load().first)
        let absorbed = try XCTUnwrap(entry.movement.instances.first { $0.level == .first })
        let absorbedAcceptance = try XCTUnwrap(absorbed.sessions.first {
            ($0.result ?? "").contains("принято к производству")
        })
        let absorbedJoin = try XCTUnwrap(absorbed.sessions.first {
            $0.event == "Дело присоединено к другому делу"
                || $0.result == "Дело присоединено к другому делу"
        })
        let receiver = CaseInstance(
            level: .first, court: absorbed.court, caseNumber: "2а-9000/2020",
            judge: nil, domain: absorbed.domain, foundByUID: true,
            result: nil, sessions: [
                CaseSession(date: "16.06.2020",
                            event: "Административное исковое заявление принято к производству"),
                CaseSession(date: absorbedJoin.date, event: "К делу присоединено другое дело"),
            ])
        XCTAssertLessThan(DateUtil.parse(receiver.sessions[0].date)!,
                          DateUtil.parse(absorbedAcceptance.date)!)
        XCTAssertEqual(receiver.sessions[1].date, absorbedJoin.date)

        var movement = entry.movement
        movement.instances = [receiver, absorbed]
        let production = ProductionType(cartotekaId: entry.context.cartotekaId)
        let resolution = CaseLifecycleResolver.resolve(
            movement: movement, production: production, deadlines: [], today: today)
        XCTAssertEqual(resolution.stage, .first)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, receiver.caseNumber)
        XCTAssertFalse(resolution.isCompleted)

        let snapshot = MovementDerivation.snapshot(
            from: movement, context: entry.context, today: today)
        XCTAssertFalse(snapshot.inForce)
    }

    func testJoinedRegistrationDoesNotSuppressReceivingCaseRealOrManualDeadline() throws {
        let entry = try XCTUnwrap(Issue406FixtureFile.load().last {
            $0.context.cartotekaId == "g1"
        })
        let absorbed = try XCTUnwrap(entry.movement.instances.first { $0.level == .first })
        let receiver = CaseInstance(
            level: .first, court: absorbed.court, caseNumber: "2-5551/2017",
            judge: nil, domain: absorbed.domain, foundByUID: true,
            result: "Иск удовлетворён; решение принято в окончательной форме",
            sessions: [
                CaseSession(date: "01.10.2017", event: "Иск принят к производству"),
                CaseSession(date: "20.10.2017", event: "Судебное заседание",
                            result: "Иск удовлетворён; решение принято в окончательной форме"),
            ], sourceEvidence: .init(decisionDate: "20.10.2017"))
        var movement = entry.movement
        movement.category = "Споры из договоров"
        movement.instances = [absorbed, receiver]
        let absorbedJoin = try XCTUnwrap(absorbed.sessions.first {
            $0.event == "Дело присоединено к другому делу"
                || $0.result == "Дело присоединено к другому делу"
        })
        let joinedDate = try XCTUnwrap(DateUtil.parse(absorbedJoin.date))
        XCTAssertLessThan(try XCTUnwrap(DateUtil.parse(receiver.sessions[0].date)), joinedDate)
        XCTAssertGreaterThan(try XCTUnwrap(DateUtil.parse(receiver.sessions[1].date)), joinedDate)
        let today = DateUtil.parse("22.10.2017")!
        let snapshot = MovementDerivation.snapshot(
            from: movement, context: entry.context, today: today)
        let presentation = MovementDerivation.lifecyclePresentation(
            from: movement, snapshot: snapshot, context: entry.context, today: today)
        let resolution = CaseLifecycleResolver.resolve(
            movement: movement, production: .civil, deadlines: snapshot.deadlines, today: today)

        XCTAssertEqual(snapshot.stageRaw, CaseStageKind.first.rawValue)
        XCTAssertFalse(resolution.isCompleted)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, receiver.caseNumber)
        XCTAssertFalse(presentation.nextEventHelp?.contains(receivingHelp) == true,
                       "The absorbed source must not leave its unknown-receiver warning")
        XCTAssertTrue(snapshot.deadlines.contains {
            $0.provenance?.ruleID == "GPK-APPEAL-GENERAL" && $0.isActive
        })

        let manual = StoredDeadline(
            kind: "custom", what: "Пользовательский срок", basis: "Тест #406",
            calLabel: "ручной", dateRef: DateUtil.parse("01.11.2017")!.timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue,
            occurrenceKey: "issue-406-receiver-manual",
            lifecycleRaw: DeadlineLifecycle.active.rawValue)
        var old = snapshot
        old.deadlines.append(manual)
        let retained = MovementDerivation.preservingConfirmedDeadlines(
            snapshot, old: old, today: today, movement: movement, context: entry.context)
        XCTAssertTrue(retained.deadlines.contains {
            $0.provenance?.ruleID == "GPK-APPEAL-GENERAL" && $0.isActive
        })
        XCTAssertTrue(retained.deadlines.contains {
            $0.occurrenceKey == manual.occurrenceKey && $0.status == .confirmed
        })
    }

    func testLaterStaleHearingOnAbsorbedRegistrationDoesNotRestartIt() throws {
        let entry = try XCTUnwrap(Issue406FixtureFile.load().first)
        var movement = entry.movement
        let index = try XCTUnwrap(movement.instances.firstIndex { $0.level == .first })
        movement.instances[index].sessions.append(CaseSession(
            date: "10.10.2026", time: "10:00", event: "Судебное заседание"))

        let snapshot = MovementDerivation.snapshot(
            from: movement, context: entry.context, today: today)
        XCTAssertEqual(snapshot.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(snapshot.nextEvent, joinedStatus)
        XCTAssertTrue(snapshot.sessions.contains {
            $0.event == "Судебное заседание" && $0.dateRaw == "10.10.2026"
        }, "Историческое заседание сохраняется в движении")
        XCTAssertEqual(CaseLifecycleResolver.resolve(
            movement: movement, production: .kas, deadlines: [], today: today).stage, .done)
    }

    func testOnlyAbsorbedAndHistoricalRegistrationsDoNotResurrectAnOlderFirstCase() throws {
        let entry = try XCTUnwrap(Issue406FixtureFile.load().first)
        let absorbed = try XCTUnwrap(entry.movement.instances.first { $0.level == .first })
        let historical = CaseInstance(
            level: .first, court: absorbed.court, caseNumber: "2а-1000/2018",
            judge: nil, domain: absorbed.domain, foundByUID: true, result: nil,
            sessions: [CaseSession(
                date: "10.01.2018", event: "Административное исковое заявление принято к производству")])
        var movement = entry.movement
        movement.instances = [historical, absorbed]

        let resolution = CaseLifecycleResolver.resolve(
            movement: movement, production: .kas, deadlines: [], today: today)
        XCTAssertEqual(resolution.stage, .done)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, absorbed.caseNumber)
    }

    func testEarlierConcludedReviewDoesNotStealStatusFromLaterJoinedRegistration() throws {
        let entry = try XCTUnwrap(Issue406FixtureFile.load().first)
        let absorbed = try XCTUnwrap(entry.movement.instances.first { $0.level == .first })
        let historical = CaseInstance(
            level: .first, court: absorbed.court, caseNumber: "2а-1000/2018",
            judge: nil, domain: absorbed.domain, foundByUID: true,
            result: "Иск удовлетворён", sessions: [
                CaseSession(date: "10.01.2018", event: "Административное исковое заявление принято к производству"),
                CaseSession(date: "10.05.2018", event: "Судебное заседание",
                            result: "Иск удовлетворён; решение принято в окончательной форме"),
            ])
        let appeal = CaseInstance(
            level: .appeal, court: "Санкт-Петербургский городской суд",
            caseNumber: "33а-10000/2018", judge: nil, domain: "appeal.example.invalid",
            foundByUID: true, result: "Оставлено без изменения", sessions: [
                CaseSession(date: "10.06.2018", event: "Судебное заседание",
                            result: "Оставлено без изменения"),
            ])
        var movement = entry.movement
        movement.instances = [historical, appeal, absorbed]

        let resolution = CaseLifecycleResolver.resolve(
            movement: movement, production: .kas, deadlines: [], today: today)
        XCTAssertEqual(resolution.stage, .done)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, absorbed.caseNumber)
        XCTAssertEqual(resolution.completionReason, .terminalFirst(joinedStatus))
    }

    func testOnlyExplicitLaterAcceptanceResumptionOrSeparationReopens() throws {
        let entry = try XCTUnwrap(Issue406FixtureFile.load().first)
        let original = try XCTUnwrap(entry.movement.instances.first { $0.level == .first })
        let resumptions = [
            "Иск (заявление, жалоба) принят к производству",
            "Иск принят к производству",
            "Административное исковое заявление принято к производству",
            "Производство по делу возобновлено",
            "Дело выделено в отдельное производство",
        ]

        for (index, event) in resumptions.enumerated() {
            var first = original
            first.sessions.append(CaseSession(
                date: "\(["01", "02", "03", "04", "05"][index]).10.2026", event: event))
            var movement = entry.movement
            movement.instances = [first]
            XCTAssertFalse(CaseLifecycleResolver.isJoinedRegistration(first, production: .kas), event)
            let resolution = CaseLifecycleResolver.resolve(
                movement: movement, production: .kas, deadlines: [], today: today)
            XCTAssertFalse(resolution.isCompleted, event)
            XCTAssertEqual(resolution.stage, .first, event)
        }
    }

    func testLaterMotionToSeparateDoesNotReopenAbsorbedRegistration() throws {
        let entry = try XCTUnwrap(Issue406FixtureFile.load().first)
        var movement = entry.movement
        let index = try XCTUnwrap(movement.instances.firstIndex { $0.level == .first })
        movement.instances[index].sessions.append(CaseSession(
            date: "02.10.2026", event: "Ходатайство о выделении дела принято к производству"))

        let first = try XCTUnwrap(movement.instances.first { $0.level == .first })
        XCTAssertTrue(CaseLifecycleResolver.isJoinedRegistration(first, production: .kas))
        XCTAssertTrue(CaseLifecycleResolver.resolve(
            movement: movement, production: .kas, deadlines: [], today: today).isCompleted)
    }

    func testMultipleAbsorbedRegistrationsCompleteOnLatestJoin() throws {
        let entries = try Issue406FixtureFile.load().filter {
            $0.context.cartotekaId == "p1"
        }
        XCTAssertGreaterThanOrEqual(entries.count, 2)
        let ordered = entries.sorted { left, right in
            let leftDate = left.movement.instances.first?.sourceEvidence?.decisionDate
                .flatMap(DateUtil.parse) ?? .distantPast
            let rightDate = right.movement.instances.first?.sourceEvidence?.decisionDate
                .flatMap(DateUtil.parse) ?? .distantPast
            return leftDate < rightDate
        }
        let older = try XCTUnwrap(ordered.first?.movement.instances.first { $0.level == .first })
        let latest = try XCTUnwrap(ordered.last?.movement.instances.first { $0.level == .first })
        var movement = try XCTUnwrap(ordered[0]).movement
        movement.caseNumber = try XCTUnwrap(ordered.last).movement.caseNumber
        movement.instances = [older, latest]

        let resolution = CaseLifecycleResolver.resolve(
            movement: movement, production: .kas, deadlines: [], today: today)
        XCTAssertEqual(resolution.stage, .done)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, latest.caseNumber)
        XCTAssertEqual(resolution.completionReason, .terminalFirst(joinedStatus))
    }
}
