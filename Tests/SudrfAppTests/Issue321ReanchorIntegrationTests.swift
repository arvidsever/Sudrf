import Foundation
import SwiftData
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue321MovementSequence: MovementProviding {
    private let values: [CaseMovement]
    private var nextIndex = 0

    init(_ values: [CaseMovement]) { self.values = values }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        let value = values[min(nextIndex, values.count - 1)]
        nextIndex += 1
        return value
    }
}

@MainActor
final class Issue321ReanchorIntegrationTests: XCTestCase {
    private let uid = "11RS0020-01-2026-000655-63"
    private let oldCourt = "Усть-Вымский районный суд Республики Коми"
    private let newCourt = "Сыктывкарский городской суд Республики Коми"
    private let oldHost = "uwsud.komi.sudrf.ru"
    private let newHost = "syktsud.komi.sudrf.ru"

    func testCompleteUIDWalkReanchorsOneDiskRecordAndPartialRefreshCannotUndoIt()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-321-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = makeOldContext()
        let full = makeVerifiedMovement()
        var partial = full
        partial.instances = []
        partial.incompleteHigherCourtDomains = [
            context.searchDomain, "syktsud--komi.sudrf.ru",
        ]

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        var snapshot = MovementDerivation.snapshot(from: makeOldMirrorMovement(), context: context)
        snapshot.deadlines.append(StoredDeadline(
            kind: "custom", what: "Пользовательский срок", basis: "fixture",
            calLabel: "ручной",
            dateRef: try XCTUnwrap(DateUtil.parse("01.01.2030"))
                .timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue,
            occurrenceKey: "issue-321-manual"))
        let record = try store.upsert(
            context: context, snapshot: snapshot, movement: makeOldMirrorMovement(),
            collections: ["Импорт legalhelp", "Регрессия #321"])
        let key = record.key
        let seed = CaseEvent.make(
            kind: .complaintRegistered, occurrence: ["issue-321-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())
        record.eventJournal = CaseEventJournal(events: [seed])
        record.seenAt = Date(timeIntervalSinceReferenceDate: 10)
        try store.save()

        let source = Issue321MovementSequence([full, partial])
        let center = RefreshCenter(
            store: store, client: SudrfClient(), serviceBuilder: { _ in source })

        let first = await center.refresh(key: key)?.value
        XCTAssertEqual(first?.outcome, .refreshed)
        try assertReanchored(store: store, key: key, seed: seed)
        let successfulFetch = try XCTUnwrap(store.record(forKey: key)?.movementFetchedAt)

        let second = await center.refresh(key: key)?.value
        guard case .partial = second?.outcome else {
            return XCTFail("Неполное обновление не должно считаться подтверждённым обходом")
        }
        XCTAssertEqual(store.record(forKey: key)?.movementFetchedAt, successfulFetch)
        try assertReanchored(store: store, key: key, seed: seed)

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        try assertReanchored(store: reopened, key: key, seed: seed)

        let repeatedCenter = RefreshCenter(
            store: reopened, client: SudrfClient(),
            serviceBuilder: { _ in Issue321MovementSequence([full]) })
        let repeated = await repeatedCenter.refresh(key: key)?.value
        XCTAssertEqual(repeated?.outcome, .refreshed)
        try assertReanchored(store: reopened, key: key, seed: seed)
    }

    func testSPBTransferReanchorsAfterFullWalkAndSurvivesPartialRefreshAndReopen()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-321-spb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = makeSPBContext()
        let full = makeSPBMovement(confirmedTransfer: true)
        let oldMirror = makeSPBMovement(confirmedTransfer: false)
        var partial = full
        partial.instances = []
        partial.incompleteHigherCourtDomains = [
            context.searchDomain, "krv--spb.sudrf.ru",
        ]

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let snapshot = MovementDerivation.snapshot(from: oldMirror, context: context)
        let record = try store.upsert(context: context, snapshot: snapshot,
                                      movement: oldMirror, collections: ["Регрессия #321 СПб"])
        let key = record.key
        let seed = CaseEvent.make(
            kind: .complaintRegistered, occurrence: ["issue-321-spb-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 2), evidence: .init())
        record.eventJournal = CaseEventJournal(events: [seed])
        try store.save()

        let source = Issue321MovementSequence([full, partial])
        let center = RefreshCenter(
            store: store, client: SudrfClient(), serviceBuilder: { _ in source })
        let first = await center.refresh(key: key)?.value
        XCTAssertEqual(first?.outcome, .refreshed)
        try assertSPBReanchored(store: store, key: key, seed: seed)

        guard case .partial = await center.refresh(key: key)?.value.outcome else {
            return XCTFail("Частичный обход Петербурга не должен менять текущую регистрацию")
        }
        try assertSPBReanchored(store: store, key: key, seed: seed)

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        try assertSPBReanchored(store: reopened, key: key, seed: seed)
    }

    private func assertReanchored(store: TrackedStore, key: String,
                                  seed: CaseEvent,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        XCTAssertEqual(store.all().count, 1, file: file, line: line)
        let record = try XCTUnwrap(store.record(forKey: key), file: file, line: line)
        XCTAssertEqual(record.key, key, file: file, line: line)
        XCTAssertEqual(record.caseNumber, "12-879/2026", file: file, line: line)
        XCTAssertEqual(record.courtTitle, newCourt, file: file, line: line)
        XCTAssertEqual(record.displayDomain, newHost, file: file, line: line)
        XCTAssertEqual(record.context?.searchDomain, "syktsud--komi.sudrf.ru",
                       file: file, line: line)
        XCTAssertEqual(record.context?.cardURLString, cardURL(
            host: newHost, id: "38789069", guid: "bd3a69d0-4f96-445c-93ca-26ac9d56cee8")
            .absoluteString, file: file, line: line)
        XCTAssertEqual(record.context?.judge, "Леконцев Александр Пантелеевич",
                       file: file, line: line)
        XCTAssertEqual(record.context?.receiptDate, "19.06.2026", file: file, line: line)
        XCTAssertEqual(record.context?.decisionDate, "25.08.2026", file: file, line: line)
        XCTAssertEqual(record.context?.resultText, "Оставлено без изменения",
                       file: file, line: line)
        XCTAssertEqual(record.context?.judicialUID, uid, file: file, line: line)
        XCTAssertEqual(record.collectionNames, ["Импорт legalhelp", "Регрессия #321"],
                       file: file, line: line)
        XCTAssertEqual(record.eventJournal?.events, [seed], file: file, line: line)
        XCTAssertEqual(record.snapshot?.deadlines.first {
            $0.occurrenceKey == "issue-321-manual"
        }?.status, .confirmed, file: file, line: line)

        let movement = try XCTUnwrap(record.movement, file: file, line: line)
        XCTAssertEqual(movement.caseNumber, "12-879/2026", file: file, line: line)
        XCTAssertEqual(movement.instances.filter { $0.caseNumber == "12-879/2026" }.count,
                       1, file: file, line: line)
        XCTAssertEqual(Set(movement.instances.map(\.caseNumber)),
                       ["12-56/2026", "12-461/2026", "12-879/2026"],
                       file: file, line: line)
        let latest = try XCTUnwrap(movement.instances.first { $0.caseNumber == "12-879/2026" },
                                   file: file, line: line)
        XCTAssertEqual(latest.court, newCourt, file: file, line: line)
        XCTAssertEqual(latest.domain, "syktsud--komi.sudrf.ru", file: file, line: line)
        XCTAssertEqual(latest.sourceURL, cardURL(
            host: newHost, id: "38789069", guid: "bd3a69d0-4f96-445c-93ca-26ac9d56cee8"),
                       file: file, line: line)
        XCTAssertEqual(latest.sourceEvidence?.judicialUID, uid, file: file, line: line)
        XCTAssertEqual(latest.sourceEvidence?.receiptDate, "19.06.2026", file: file, line: line)
        XCTAssertEqual(record.snapshot?.instanceObservations?.first {
            $0.caseNumber == "12-879/2026"
        }?.court, newCourt, file: file, line: line)

        let savedCards = (record.context?.knownCards ?? [])
            + [record.context?.sourceKnownCard].compactMap { $0 }
        let importedRegistration = try XCTUnwrap(savedCards.first {
            $0.caseNumber == "12-879/2026"
                && SudrfHost.moduleHost($0.domain) == "syktsud--komi.sudrf.ru"
        }, file: file, line: line)
        XCTAssertEqual(importedRegistration.sourceURL, latest.sourceURL,
                       file: file, line: line)
        XCTAssertFalse(savedCards.contains {
            $0.caseNumber == "12-879/2026"
                && SudrfHost.moduleHost($0.domain) == "uwsud--komi.sudrf.ru"
        }, file: file, line: line)
    }

    private func makeOldContext() -> MovementContext {
        let importedURL = cardURL(
            host: newHost, id: "38789069", guid: "bd3a69d0-4f96-445c-93ca-26ac9d56cee8")
        let importedCard = KnownCard(
            domain: "syktsud--komi.sudrf.ru", courtTitle: newCourt,
            caseID: "38789069", caseUID: "bd3a69d0-4f96-445c-93ca-26ac9d56cee8",
            deloID: "1502001", new: "0", caseNumber: "12-879/2026",
            levelRaw: CaseInstance.Level.first.rawValue, cartotekaID: "admj",
            sourceURL: importedURL)
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "uwsud--komi.sudrf.ru", displayDomain: oldHost,
            courtTitle: oldCourt, courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0020", cartotekaId: "admj",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "12-56/2026", caseID: "34759060",
            caseUID: "d02dc985-3f04-41ce-b8fd-da9418abc717",
            judge: "Балашенко Артем Игоревич", receiptDate: "02.04.2026",
            decisionDate: "06.04.2026", resultText: "Направлено по подведомственности",
            judicialUID: uid, baseInstanceLevelRaw: CaseInstance.Level.first.rawValue,
            knownCards: [importedCard])
        context.cardURLString = cardURL(
            host: oldHost, id: "34759060", guid: "d02dc985-3f04-41ce-b8fd-da9418abc717")
            .absoluteString
        return context
    }

    private func assertSPBReanchored(store: TrackedStore, key: String,
                                     seed: CaseEvent,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        XCTAssertEqual(store.all().count, 1, file: file, line: line)
        let record = try XCTUnwrap(store.record(forKey: key), file: file, line: line)
        XCTAssertEqual(record.key, key, file: file, line: line)
        XCTAssertEqual(record.caseNumber, "12-1156/2026", file: file, line: line)
        XCTAssertEqual(record.courtTitle,
                       "Кировский районный суд города Санкт-Петербурга", file: file, line: line)
        XCTAssertEqual(record.displayDomain, "krv.spb.sudrf.ru", file: file, line: line)
        XCTAssertEqual(record.context?.cardURLString, spbTargetURL.absoluteString,
                       file: file, line: line)
        XCTAssertEqual(record.context?.judge, "Костин Федор Вячеславович",
                       file: file, line: line)
        XCTAssertEqual(record.context?.receiptDate, "27.07.2026", file: file, line: line)
        XCTAssertEqual(record.context?.decisionDate, "23.09.2026", file: file, line: line)
        XCTAssertEqual(record.context?.resultText, "Оставлено без изменения",
                       file: file, line: line)
        XCTAssertEqual(record.context?.judicialUID, spbUID, file: file, line: line)
        XCTAssertEqual(record.collectionNames, ["Регрессия #321 СПб"], file: file, line: line)
        XCTAssertEqual(record.eventJournal?.events, [seed], file: file, line: line)

        let movement = try XCTUnwrap(record.movement, file: file, line: line)
        XCTAssertEqual(movement.instances.filter { $0.caseNumber == "12-1156/2026" }.count,
                       1, file: file, line: line)
        XCTAssertEqual(Set(movement.instances.map(\.caseNumber)),
                       ["12-538/2026", "12-1156/2026"], file: file, line: line)
        let latest = try XCTUnwrap(movement.instances.first {
            $0.caseNumber == "12-1156/2026"
        }, file: file, line: line)
        XCTAssertEqual(latest.court, "Кировский районный суд города Санкт-Петербурга",
                       file: file, line: line)
        XCTAssertEqual(latest.sourceURL, spbTargetURL, file: file, line: line)
        XCTAssertEqual(latest.sourceEvidence?.judicialUID, spbUID, file: file, line: line)
        XCTAssertEqual(latest.sourceEvidence?.receiptDate, "27.07.2026", file: file, line: line)
        XCTAssertEqual(record.snapshot?.instanceObservations?.first {
            $0.caseNumber == "12-1156/2026"
        }?.court, "Кировский районный суд города Санкт-Петербурга", file: file, line: line)
    }

    private func makeSPBContext() -> MovementContext {
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Санкт-Петербург",
            searchDomain: "vos--spb.sudrf.ru", displayDomain: "vos.spb.sudrf.ru",
            courtTitle: "Василеостровский районный суд города Санкт-Петербурга",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "78RS0001",
            cartotekaId: "admj", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "12-538/2026", caseID: "958679833",
            caseUID: "976b38ad-eb63-425e-93d5-b15fa7df355d",
            judge: "Хабарова Елена Михайловна", receiptDate: "11.03.2026",
            decisionDate: "16.07.2026", resultText: "Направлено по подведомственности",
            judicialUID: spbUID, baseInstanceLevelRaw: CaseInstance.Level.first.rawValue)
        context.cardURLString = spbSourceURL.absoluteString
        return context
    }

    private func makeSPBMovement(confirmedTransfer: Bool) -> CaseMovement {
        let old = CaseInstance(
            level: .first,
            court: "Василеостровский районный суд города Санкт-Петербурга",
            caseNumber: "12-538/2026", judge: "Хабарова Елена Михайловна",
            domain: "vos--spb.sudrf.ru", foundByUID: false,
            result: "Направлено по подведомственности", sessions: [],
            sourceURL: spbSourceURL,
            sourceEvidence: CaseInstance.SourceEvidence(
                receiptDate: "11.03.2026", decisionDate: "16.07.2026",
                judicialUID: spbUID, cartotekaID: "admj", sourceCourtLevel: .district,
                sourceBranch: .general))
        let target = CaseInstance(
            level: .first,
            court: confirmedTransfer
                ? "Кировский районный суд города Санкт-Петербурга"
                : "Василеостровский районный суд города Санкт-Петербурга",
            caseNumber: "12-1156/2026", judge: "Костин Федор Вячеславович",
            domain: confirmedTransfer ? "krv--spb.sudrf.ru" : "vos--spb.sudrf.ru",
            foundByUID: confirmedTransfer,
            result: "Оставлено без изменения", sessions: [],
            sourceURL: confirmedTransfer ? spbTargetURL : spbMirrorURL,
            sourceEvidence: CaseInstance.SourceEvidence(
                receiptDate: "27.07.2026", decisionDate: "23.09.2026",
                judicialUID: spbUID, cartotekaID: "admj", sourceCourtLevel: .district,
                sourceBranch: .general))
        return CaseMovement(uid: spbUID, caseNumber: "12-1156/2026", inForce: false,
                            instances: [old, target], complaints: [:], acts: [])
    }

    private var spbUID: String { "78RS0001-01-2026-002203-86" }
    private var spbSourceURL: URL {
        URL(string: "http://vos.spb.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=958679833&case_uid=976b38ad-eb63-425e-93d5-b15fa7df355d"
            + "&delo_id=1502001&case_type=0&new=0&srv_num=1")!
    }
    private var spbTargetURL: URL {
        URL(string: "http://krv.spb.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=984441524&case_uid=94fbe307-53f6-4f36-bf53-fd709a865d09"
            + "&delo_id=1502001&case_type=0&new=0&srv_num=1")!
    }
    private var spbMirrorURL: URL {
        URL(string: "http://vos.spb.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=984441524&case_uid=94fbe307-53f6-4f36-bf53-fd709a865d09"
            + "&delo_id=1502001&case_type=0&new=0&srv_num=1")!
    }

    private func makeVerifiedMovement() -> CaseMovement {
        let instances = [
            makeInstance(number: "12-56/2026", court: oldCourt,
                         domain: "uwsud--komi.sudrf.ru", id: "34759060",
                         guid: "d02dc985-3f04-41ce-b8fd-da9418abc717",
                         receipt: "02.04.2026", decision: "06.04.2026",
                         judge: "Балашенко Артем Игоревич",
                         result: "Направлено по подведомственности", foundByUID: false),
            makeInstance(number: "12-461/2026", court: newCourt,
                         domain: "syktsud--komi.sudrf.ru", id: "35190605",
                         guid: "cff76120-b056-45fc-93cc-55f1ad2fbbbd",
                         receipt: "13.04.2026", decision: "25.05.2026",
                         judge: "Печинина Людмила Анатольевна",
                         result: "Отменено с возвращением на новое рассмотрение", foundByUID: true),
            makeInstance(number: "12-879/2026", court: newCourt,
                         domain: "syktsud--komi.sudrf.ru", id: "38789069",
                         guid: "bd3a69d0-4f96-445c-93ca-26ac9d56cee8",
                         receipt: "19.06.2026", decision: "25.08.2026",
                         judge: "Леконцев Александр Пантелеевич",
                         result: "Оставлено без изменения", foundByUID: true),
        ]
        return CaseMovement(uid: uid, caseNumber: "12-879/2026", inForce: false,
                            instances: instances, complaints: [:], acts: [])
    }

    private func makeOldMirrorMovement() -> CaseMovement {
        let instances = [
            makeInstance(number: "12-56/2026", court: oldCourt,
                         domain: "uwsud--komi.sudrf.ru", id: "34759060",
                         guid: "d02dc985-3f04-41ce-b8fd-da9418abc717",
                         receipt: "02.04.2026", decision: "06.04.2026",
                         judge: "Балашенко Артем Игоревич",
                         result: "Направлено по подведомственности", foundByUID: false),
            makeInstance(number: "12-461/2026", court: oldCourt,
                         domain: "uwsud--komi.sudrf.ru", id: "35190605",
                         guid: "cff76120-b056-45fc-93cc-55f1ad2fbbbd",
                         receipt: "13.04.2026", decision: "25.05.2026",
                         judge: "Печинина Людмила Анатольевна",
                         result: "Отменено с возвращением на новое рассмотрение", foundByUID: false),
            makeInstance(number: "12-879/2026", court: oldCourt,
                         domain: "uwsud--komi.sudrf.ru", id: "38789069",
                         guid: "bd3a69d0-4f96-445c-93ca-26ac9d56cee8",
                         receipt: "19.06.2026", decision: "25.08.2026",
                         judge: "Леконцев Александр Пантелеевич",
                         result: "Оставлено без изменения", foundByUID: false),
        ]
        return CaseMovement(uid: uid, caseNumber: "12-56/2026", inForce: false,
                            instances: instances, complaints: [:], acts: [])
    }

    private func makeInstance(number: String, court: String, domain: String,
                              id: String, guid: String, receipt: String,
                              decision: String, judge: String, result: String,
                              foundByUID: Bool) -> CaseInstance {
        CaseInstance(
            level: .first, court: court, caseNumber: number, judge: judge,
            domain: domain, foundByUID: foundByUID, result: result, sessions: [],
            sourceURL: cardURL(host: domain == "uwsud--komi.sudrf.ru" ? oldHost : newHost,
                               id: id, guid: guid),
            sourceEvidence: CaseInstance.SourceEvidence(
                receiptDate: receipt, decisionDate: decision, judicialUID: uid,
                cartotekaID: "admj", sourceCourtLevel: .district,
                sourceBranch: .general))
    }

    private func cardURL(host: String, id: String, guid: String) -> URL {
        URL(string: "http://\(host)/modules.php?name=sud_delo&name_op=case"
            + "&case_id=\(id)&case_uid=\(guid)&delo_id=1502001"
            + "&case_type=0&new=0&srv_num=1")!
    }
}
