import Foundation
import SwiftData
import XCTest
@testable import SudrfKit
@testable import SudrfApp

private actor Issue431PartialMovementProvider: MovementProviding {
    private let response: CaseMovement

    init(response: CaseMovement) { self.response = response }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        response
    }
}

private final class Issue431UnexpectedNetworkURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTFail("Unexpected network request in offline #431 test: \(request.url?.absoluteString ?? "<missing URL>")")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}

@MainActor
final class Issue431CalendarCourtLabelTests: XCTestCase {
    private let hearingDate = DateUtil.parse("21.10.2026")!
    private let today = DateUtil.parse("01.10.2026")!

    private struct FixtureKeys {
        var target: String
        var companion: String
        var seedEventID: String
    }

    private struct HearingProjection: Equatable {
        var id: String
        var recordKey: String
        var date: Date
        var time: String
        var caseNumber: String
        var instanceCaseNumber: String?
        var rawCourt: String
        var displayCourt: String
    }

    private struct CalendarProjection: Equatable {
        var hearings: [HearingProjection]
        var calendarCount: Int
        var eventSubtitles: [String]
        var monthCourtShort: String
        var isSubjectTier: Bool
        var monthOverlapIDs: [String]
        var weekConflictIDs: [String]
        var weekFooter: String
        var weekConflictDetails: String
        var intent: String
        var collectionNames: [String]
        var journalIDs: [String]
    }

    func testMissingOrAmbiguousSourceDoesNotReplaceTechnicalNameWithRootCourt() throws {
        let context = context(number: "2-4461/2026", court: "Корневой городской суд",
                              caseID: "synthetic-base-431")
        let technical = session(court: "OBLSUD--MO")
        XCTAssertEqual(MovementDerivation.calendarCourtLabel(
            for: technical, movement: nil, context: context), "Суд не установлен")

        let readable = session(court: "Московский областной суд")
        XCTAssertEqual(MovementDerivation.calendarCourtLabel(
            for: readable, movement: nil, context: context), "Московский областной суд")

        let root = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.displayDomain, foundByUID: false,
            result: nil, sessions: [])
        let unmatched = CaseMovement(
            uid: "synthetic-431", caseNumber: context.caseNumber, inForce: false,
            instances: [root], complaints: [:], acts: [])
        XCTAssertEqual(MovementDerivation.calendarCourtLabel(
            for: technical, movement: unmatched, context: context), "Суд не установлен")

        let firstReview = CaseInstance(
            level: .appeal, court: "OBLSUD--MO", caseNumber: "33-42895/2026",
            judge: nil, domain: "OBLSUD--MO.SUDRF.RU", foundByUID: true,
            result: nil, sessions: [CaseSession(
                date: "21.10.2026", time: "12:05", event: "Судебное заседание")])
        let duplicateReview = CaseInstance(
            level: .appeal, court: "OBLSUD--MO", caseNumber: "33-9548/2026",
            judge: nil, domain: "OBLSUD--MO.SUDRF.RU", foundByUID: true,
            result: nil, sessions: [CaseSession(
                date: "21.10.2026", time: "12:05", event: "Судебное заседание")])
        let ambiguous = CaseMovement(
            uid: "synthetic-431-ambiguous", caseNumber: context.caseNumber,
            inForce: false, instances: [root, firstReview, duplicateReview],
            complaints: [:], acts: [])
        var legacyWithoutInstanceNumber = technical
        legacyWithoutInstanceNumber.caseNumber = nil
        let unchangedLegacy = legacyWithoutInstanceNumber
        XCTAssertEqual(MovementDerivation.calendarCourtLabel(
            for: legacyWithoutInstanceNumber, movement: ambiguous, context: context),
            "Московский областной суд",
            "The court is proved for both candidates without choosing a registration.")
        XCTAssertEqual(legacyWithoutInstanceNumber, unchangedLegacy)
        XCTAssertNil(legacyWithoutInstanceNumber.caseNumber)
        XCTAssertNil(legacyWithoutInstanceNumber.sourceCardID)

        var otherCourt = duplicateReview
        otherCourt.domain = "vs--komi.sudrf.ru"
        var conflictingCourts = ambiguous
        conflictingCourts.instances = [root, firstReview, otherCourt]
        XCTAssertEqual(MovementDerivation.calendarCourtLabel(
            for: legacyWithoutInstanceNumber, movement: conflictingCourts, context: context),
            "Суд не установлен", "Matching raw labels do not prove a common court.")

        otherCourt.domain = "unconfirmed.example"
        conflictingCourts.instances = [root, firstReview, otherCourt]
        XCTAssertEqual(MovementDerivation.calendarCourtLabel(
            for: legacyWithoutInstanceNumber, movement: conflictingCourts, context: context),
            "Суд не установлен", "One unproved candidate prevents the common-court fallback.")

        var sharedPortalFirst = firstReview
        sharedPortalFirst.court = "www.mos-gorsud.ru"
        sharedPortalFirst.domain = "www.mos-gorsud.ru"
        var sharedPortalSecond = sharedPortalFirst
        sharedPortalSecond.caseNumber = duplicateReview.caseNumber
        conflictingCourts.instances = [root, sharedPortalFirst, sharedPortalSecond]
        var sharedPortalSession = legacyWithoutInstanceNumber
        sharedPortalSession.court = "www.mos-gorsud.ru"
        XCTAssertEqual(MovementDerivation.calendarCourtLabel(
            for: sharedPortalSession, movement: conflictingCourts, context: context),
            "Суд не установлен", "The shared portal host alone does not prove the own court.")

        var sameNumberContext = context
        sameNumberContext.knownCards = [KnownCard(
            domain: "www.mos-gorsud.ru", courtTitle: "Дорогомиловский районный суд",
            caseID: "district-a", caseUID: "synthetic-a", deloID: "g2", new: "0",
            caseNumber: firstReview.caseNumber, levelRaw: CaseInstance.Level.appeal.rawValue)]
        sharedPortalFirst.sourceURL = URL(string:
            "https://www.mos-gorsud.ru/rs/dorogomilovskij/services/cases/appeal-admin/details/district-a")!
        sharedPortalSecond.caseNumber = sharedPortalFirst.caseNumber
        sharedPortalSecond.sourceURL = URL(string:
            "https://www.mos-gorsud.ru/rs/hamovnicheskij/services/cases/appeal-admin/details/district-b")!
        conflictingCourts.instances = [root, sharedPortalFirst, sharedPortalSecond]
        XCTAssertEqual(MovementDerivation.calendarCourtLabel(
            for: sharedPortalSession, movement: conflictingCourts, context: sameNumberContext),
            "Суд не установлен", "A weak KnownCard number match must not hide different own court aliases.")
        sharedPortalSecond.sourceURL = URL(string:
            "https://www.mos-gorsud.ru/rs/dorogomilovskij/services/cases/appeal-admin/details/district-b")!
        conflictingCourts.instances = [root, sharedPortalFirst, sharedPortalSecond]
        XCTAssertEqual(MovementDerivation.calendarCourtLabel(
            for: sharedPortalSession, movement: conflictingCourts, context: sameNumberContext),
            "Дорогомиловский районный суд", "Two validated native aliases prove the common court.")

        var exactContext = self.context(number: "2-4461/2026",
                                        court: "Сыктывкарский городской суд Республики Коми",
                                        caseID: "synthetic-base-431")
        exactContext.knownCards = [KnownCard(
            domain: "OBLSUD--MO.SUDRF.RU", courtTitle: "Московский областной суд",
            caseID: "appealA", caseUID: "synthetic-appeal-guid", deloID: "g2", new: "0",
            caseNumber: "33-42895/2026", levelRaw: CaseInstance.Level.appeal.rawValue)]
        let exactReview = CaseInstance(
            level: .appeal, court: "OBLSUD--MO", caseNumber: "33-42895/2026",
            judge: nil, domain: "OBLSUD--MO.SUDRF.RU", foundByUID: true,
            result: nil, sessions: [])
        let exactMovement = CaseMovement(
            uid: "synthetic-431-exact-source", caseNumber: "2-4461/2026", inForce: false,
            instances: [root, exactReview], complaints: [:], acts: [])
        let exactSourceID = try XCTUnwrap(
            CaseSnapshotSourceIdentity.sourceCardID(for: exactReview, context: exactContext))
        var blankCourt = session(court: "")
        blankCourt.caseNumber = nil // sourceCardID is the identity evidence.
        blankCourt.sourceCardID = exactSourceID
        XCTAssertEqual(MovementDerivation.calendarCourtLabel(
            for: blankCourt, movement: exactMovement, context: exactContext),
            "Московский областной суд",
            "An exact source card should restore its own court name even if the old saved label is empty.")

        var districtContext = self.context(number: "2-9000/2026",
                                           court: "Сыктывкарский городской суд Республики Коми",
                                           caseID: "synthetic-mgs-base-431")
        districtContext.knownCards = [KnownCard(
            domain: "www.mos-gorsud.ru", courtTitle: "Дорогомиловский районный суд",
            caseID: "district-appeal", caseUID: "synthetic-district-guid", deloID: "g2",
            new: "0", caseNumber: "77-42895/2026",
            levelRaw: CaseInstance.Level.appeal.rawValue)]
        let mgsInstance = CaseInstance(
            level: .appeal, court: "www.mos-gorsud.ru", caseNumber: "77-42895/2026",
            judge: nil, domain: "www.mos-gorsud.ru", foundByUID: true,
            result: nil, sessions: [])
        let mgsMovement = CaseMovement(
            uid: "synthetic-431-mgs-source", caseNumber: districtContext.caseNumber,
            inForce: false, instances: [root, mgsInstance], complaints: [:], acts: [])
        let mgsSourceID = try XCTUnwrap(
            CaseSnapshotSourceIdentity.sourceCardID(for: mgsInstance, context: districtContext))
        var blankMGSLabel = session(court: "")
        blankMGSLabel.caseNumber = nil
        blankMGSLabel.sourceCardID = mgsSourceID
        XCTAssertEqual(MovementDerivation.calendarCourtLabel(
            for: blankMGSLabel, movement: mgsMovement, context: districtContext),
            "Дорогомиловский районный суд",
            "The exact source's saved district title should survive when its shared MGS domain is not in the official district directory.")
    }

    func testSharedTechnicalCourtKeyKeepsPerHearingLabelsAndStackProjection() {
        let city = calendarEvent(
            "mgs-city", on: hearingDate, court: "www.mos-gorsud.ru",
            displayCourt: "Московский городской суд", room: "каб. 5")
        let district = calendarEvent(
            "mgs-district", on: hearingDate, court: "www.mos-gorsud.ru",
            displayCourt: "Дорогомиловский районный суд", room: "каб. 5")
        let outsideMonth = calendarEvent(
            "mgs-outside", on: DateUtil.parse("15.11.2026")!,
            court: "www.mos-gorsud.ru", displayCourt: "Московский областной суд")
        let model = CalendarScreen.buildMonthModel(
            month: DateUtil.startOfMonth(hearingDate), events: [city, district, outsideMonth])

        XCTAssertEqual(model.itemsByDay[DateUtil.startOfDay(hearingDate)]?.map(\.id).sorted(),
                       [city.id, district.id].sorted())
        XCTAssertEqual(model.courtShort[city.displayCourtLabel], "Московский горсуд")
        XCTAssertEqual(model.courtShort[district.displayCourtLabel], "Дорогомиловский")
        XCTAssertEqual(model.courtShort[outsideMonth.displayCourtLabel], "Московский облсуд")
        XCTAssertEqual(model.courtTier[city.displayCourtLabel] ?? nil, .subject)
        XCTAssertEqual(model.courtTier[district.displayCourtLabel] ?? nil, .district)
        XCTAssertEqual(model.courtTier[outsideMonth.displayCourtLabel] ?? nil, .subject)
        XCTAssertTrue(model.overlapByID.isEmpty,
                      "Identical raw court keys still mean no cross-court overlap.")
        XCTAssertTrue(model.overlapDays.isEmpty)

        let inputs = [city, district].map(CalendarWeekHearingLayoutInput.init(event:))
        let blocks = CalendarWeekLayout.blocks(for: inputs)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .stack,
                       "Week grouping continues to use the unchanged raw court key.")
        XCTAssertEqual(Set(blocks[0].hearings.map(\.id)), Set([city.id, district.id]))
        XCTAssertFalse(blocks[0].isConflict)
        XCTAssertEqual(CalendarWeekLayout.itemDetails(
            inputs[0], conflict: false, common: inputs[0], includeCourt: true),
            "\(city.displayCourtLabel) · каб. 5")
        XCTAssertEqual(CalendarWeekLayout.itemDetails(
            inputs[1], conflict: false, common: inputs[0], includeCourt: true),
            "\(district.displayCourtLabel) · каб. 5")
    }

    func testOldSnapshotCalendarProjectionSurvivesPartialRefreshAndDiskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-431-calendar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let keys = try seedStore(at: storeURL)

        let before = try capture(storeURL: storeURL, keys: keys)
        assertIssueProjection(before, seedID: keys.seedEventID)

        let partialSucceeded = try await applyPartialRefresh(storeURL: storeURL, key: keys.target)
        XCTAssertTrue(partialSucceeded, "The synthetic failed higher-court source should be partial")
        let afterPartial = try capture(storeURL: storeURL, keys: keys)
        XCTAssertEqual(afterPartial, before,
                       "A partial source response must preserve the calendar, conflict, and journal projection")

        // capture() opens a fresh SwiftData container after each helper returns,
        // so the second projection checks a real disk reopen, not an in-memory reload.
        let reopened = try capture(storeURL: storeURL, keys: keys)
        XCTAssertEqual(reopened, before)
        assertIssueProjection(reopened, seedID: keys.seedEventID)
    }

    private func assertIssueProjection(_ projection: CalendarProjection,
                                       seedID: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertEqual(projection.calendarCount, 2, file: file, line: line)
        let target = projection.hearings.first { $0.caseNumber == "2-4461/2026" }
        XCTAssertEqual(target?.instanceCaseNumber, "33-42895/2026", file: file, line: line)
        XCTAssertEqual(target?.date, hearingDate, file: file, line: line)
        XCTAssertEqual(target?.time, "12:05", file: file, line: line)
        XCTAssertEqual(target?.rawCourt, "OBLSUD--MO", file: file, line: line)
        XCTAssertEqual(target?.displayCourt, "Московский областной суд", file: file, line: line)
        XCTAssertTrue(projection.eventSubtitles.contains {
            $0.contains("Московский областной суд")
        }, file: file, line: line)
        XCTAssertEqual(projection.monthCourtShort, "Московский облсуд", file: file, line: line)
        XCTAssertTrue(projection.isSubjectTier, file: file, line: line)
        XCTAssertEqual(projection.monthOverlapIDs.count, 2, file: file, line: line)
        XCTAssertEqual(projection.weekConflictIDs.count, 2, file: file, line: line)
        XCTAssertTrue(projection.weekFooter.contains("Московский областной суд"), file: file, line: line)
        XCTAssertTrue(projection.weekConflictDetails.contains("Московский областной суд"),
                      file: file, line: line)
        XCTAssertTrue(projection.intent.contains("Московский областной суд"), file: file, line: line)
        XCTAssertTrue(projection.journalIDs.contains(seedID), file: file, line: line)
        XCTAssertEqual(projection.collectionNames, ["Синтетическая проверка #431"],
                       file: file, line: line)
    }

    private func seedStore(at storeURL: URL) throws -> FixtureKeys {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let targetContext = context(number: "2-4461/2026",
                                    court: "Сыктывкарский городской суд Республики Коми",
                                    domain: "syktsud.komi.sudrf.ru",
                                    searchDomain: "syktsud--komi.sudrf.ru",
                                    courtCode: "11RS0001", caseID: "synthetic-base-431")
        let targetMovement = targetMovement(context: targetContext)
        var targetSnapshot = MovementDerivation.snapshot(
            from: targetMovement, context: targetContext, today: today)
        targetSnapshot.sessions = targetSnapshot.sessions.map { value in
            var value = value
            value.sourceCardID = nil // Synthetic pre-#155 snapshot shape.
            return value
        }
        let legacyData = try legacySnapshotData(targetSnapshot)
        let targetRecord = TrackedCaseRecord(
            key: targetContext.key, collections: ["Синтетическая проверка #431"],
            caseNumber: targetContext.caseNumber, courtTitle: targetContext.courtTitle,
            displayDomain: targetContext.displayDomain,
            contextData: try JSONEncoder().encode(targetContext), snapshotData: legacyData)
        targetRecord.movement = targetMovement
        targetRecord.movementFetchedAt = Date(timeIntervalSince1970: 1_797_000_000)
        let seed = CaseEvent.make(kind: .complaintRegistered,
                                  occurrence: ["issue-431-seed"],
                                  observedAt: Date(timeIntervalSinceReferenceDate: 1),
                                  evidence: .init())
        targetRecord.eventJournal = CaseEventJournal(events: [seed])
        container.mainContext.insert(targetRecord)

        let companionContext = context(
            number: "2-731/2026", court: "Усть-Вымский районный суд Республики Коми",
            domain: "uwsud.komi.sudrf.ru", searchDomain: "uwsud--komi.sudrf.ru",
            courtCode: "11RS0020", caseID: "synthetic-companion-431")
        let companionMovement = companionMovement(context: companionContext)
        let companionSnapshot = MovementDerivation.snapshot(
            from: companionMovement, context: companionContext, today: today)
        let companionRecord = TrackedCaseRecord(
            key: companionContext.key, collections: [],
            caseNumber: companionContext.caseNumber, courtTitle: companionContext.courtTitle,
            displayDomain: companionContext.displayDomain,
            contextData: try JSONEncoder().encode(companionContext),
            snapshotData: try JSONEncoder().encode(companionSnapshot))
        companionRecord.movement = companionMovement
        companionRecord.movementFetchedAt = Date(timeIntervalSince1970: 1_797_000_000)
        container.mainContext.insert(companionRecord)
        try container.mainContext.save()

        let decodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        let rows = try XCTUnwrap(decodedObject["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?["sourceCardID"])

        return FixtureKeys(target: targetRecord.key, companion: companionRecord.key,
                           seedEventID: seed.id)
    }

    private func capture(storeURL: URL, keys: FixtureKeys) throws -> CalendarProjection {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: today)

        let target = try XCTUnwrap(router.calendarHearings.first {
            $0.recordKey == keys.target && $0.caseNumber == "2-4461/2026"
        })
        let companion = try XCTUnwrap(router.calendarHearings.first {
            $0.recordKey == keys.companion
        })
        let eventValues = router.calendarHearings.map { hearing in
            CalEvent.hearing(hearing, id: "hearing#\(hearing.id)")
        }
        let targetEvent = try XCTUnwrap(eventValues.first { $0.caseNumber == target.caseNumber })
        let calendarWeekInputs = eventValues.map(CalendarWeekHearingLayoutInput.init(event:))
        let targetWeekInput = try XCTUnwrap(calendarWeekInputs.first { $0.id == targetEvent.id })
        let companionWeekInput = try XCTUnwrap(calendarWeekInputs.first {
            $0.caseNumber == companion.caseNumber
        })
        let month = CalendarScreen.buildMonthModel(
            month: DateUtil.startOfMonth(hearingDate), events: eventValues)
        let weekConflicts = CalendarWeekLayout.blocks(for: calendarWeekInputs)
            .filter(\.isConflict).flatMap { $0.hearings.map(\.id) }.sorted()
        let records = try container.mainContext.fetch(FetchDescriptor<TrackedCaseRecord>())
        let record = try XCTUnwrap(records.first { $0.key == keys.target })

        return CalendarProjection(
            hearings: router.calendarHearings.map {
                HearingProjection(id: $0.id, recordKey: $0.recordKey, date: $0.date,
                    time: $0.time, caseNumber: $0.caseNumber,
                    instanceCaseNumber: $0.instanceCaseNumber, rawCourt: $0.court,
                    displayCourt: $0.displayCourtLabel)
            }.sorted { $0.id < $1.id },
            calendarCount: router.calendarHearings.count,
            eventSubtitles: eventValues.map(\.sub).sorted(),
            monthCourtShort: month.courtShort[target.displayCourtLabel] ?? "",
            isSubjectTier: (month.courtTier[target.displayCourtLabel] ?? nil) == .subject,
            monthOverlapIDs: month.overlapByID.keys.sorted(),
            weekConflictIDs: weekConflicts,
            weekFooter: targetWeekInput.displayCourtLabel,
            weekConflictDetails: CalendarWeekLayout.itemDetails(
                targetWeekInput, conflict: true, common: companionWeekInput),
            intent: router.intentUpcomingHearings(today: today),
            collectionNames: record.collectionNames.sorted(),
            journalIDs: (record.eventJournal?.events.map(\.id) ?? []).sorted())
    }

    private func applyPartialRefresh(storeURL: URL, key: String) async throws -> Bool {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let cached = try XCTUnwrap(store.record(forKey: key)?.movement)
        let root = try XCTUnwrap(cached.instances.first { $0.level == .first })
        let failedDomain = try XCTUnwrap(cached.instances.first {
            $0.level == .appeal
        }?.domain)
        let partial = CaseMovement(
            uid: cached.uid, caseNumber: cached.caseNumber, inForce: cached.inForce,
            instances: [root], complaints: [:], acts: [],
            incompleteHigherCourtDomains: [failedDomain])
        let provider = Issue431PartialMovementProvider(response: partial)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue431UnexpectedNetworkURLProtocol.self]
        let offlineClient = SudrfClient(
            session: URLSession(configuration: configuration), minInterval: 0,
            variantStore: WorkingVariantStore(cacheURL: nil),
            captchaStore: CaptchaTokenStore())
        let center = RefreshCenter(store: store, client: offlineClient,
                                   serviceBuilder: { _ in provider })
        guard let task = center.refresh(key: key, manually: true) else {
            XCTFail("The synthetic tracked case should start a refresh")
            return false
        }
        let execution = await task.value
        guard case .partial = execution.outcome else { return false }
        return store.record(forKey: key)?.movement?.instances.contains {
            $0.level == .appeal && $0.caseNumber == "33-42895/2026"
        } == true
    }

    private func targetMovement(context: MovementContext) -> CaseMovement {
        let root = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.displayDomain, foundByUID: false,
            result: nil, sessions: [])
        let appeal = CaseInstance(
            level: .appeal, court: "OBLSUD--MO", caseNumber: "33-42895/2026",
            judge: nil, domain: "OBLSUD--MO.SUDRF.RU", foundByUID: true,
            result: nil, sessions: [CaseSession(
                date: "21.10.2026", time: "12:05", event: "Судебное заседание")])
        return CaseMovement(
            uid: "11RS0001-01-2026-004461-00", caseNumber: context.caseNumber,
            inForce: false, instances: [root, appeal], complaints: [:], acts: [])
    }

    private func companionMovement(context: MovementContext) -> CaseMovement {
        let root = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.displayDomain, foundByUID: false,
            result: nil, sessions: [])
        let appeal = CaseInstance(
            level: .appeal, court: "Верховный Суд Республики Коми",
            caseNumber: "33-731/2026", judge: nil, domain: "vs--komi.sudrf.ru",
            foundByUID: true, result: nil, sessions: [CaseSession(
                date: "21.10.2026", time: "12:05", event: "Судебное заседание")])
        return CaseMovement(
            uid: "11RS0020-01-2026-000731-00", caseNumber: context.caseNumber,
            inForce: false, instances: [root, appeal], complaints: [:], acts: [])
    }

    private func context(number: String, court: String,
                         domain: String = "syktsud.komi.sudrf.ru",
                         searchDomain: String = "syktsud--komi.sudrf.ru",
                         courtCode: String = "11RS0001",
                         caseID: String) -> MovementContext {
        MovementContext(
            branchRaw: "general", region: "Республика Коми",
            searchDomain: searchDomain, displayDomain: domain, courtTitle: court,
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: courtCode,
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number, caseID: caseID, caseUID: "synthetic-link-\(caseID)",
            judicialUID: nil)
    }

    private func session(court: String) -> StoredSession {
        StoredSession(dateRaw: "21.10.2026", time: "12:05", room: nil,
                      event: "Судебное заседание", result: nil, court: court,
                      levelRaw: CaseInstance.Level.appeal.rawValue,
                      caseNumber: "33-42895/2026")
    }

    private func calendarEvent(_ id: String, on date: Date, court: String,
                               displayCourt: String, room: String = "") -> CalEvent {
        CalEvent(id: id, date: date, sortTime: "12:05", kind: .hearing,
                 chip: id, time: "12:05", heading: "ЗАСЕДАНИЕ", title: id,
                 sub: displayCourt, caseNumber: id, displayCaseNumber: nil,
                 secondaryLabel: nil, deadlineId: nil, court: court,
                 displayCourt: displayCourt, room: room)
    }

    private func legacySnapshotData(_ snapshot: CaseSnapshot) throws -> Data {
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        for index in sessions.indices { sessions[index].removeValue(forKey: "sourceCardID") }
        object["sessions"] = sessions
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
