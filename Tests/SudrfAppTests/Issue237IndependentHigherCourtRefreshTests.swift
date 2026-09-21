import Foundation
import SwiftData
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue237MovementSequence: MovementProviding {
    let values: [CaseMovement]
    private var index = 0

    init(_ values: [CaseMovement]) {
        self.values = values
    }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

@MainActor
final class Issue237IndependentHigherCourtRefreshTests: XCTestCase {
    private let uid = "11RS0001-01-2026-000237-11"

    func testPartialHigherCourtRefreshSurvivesRepeatAndDiskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-237-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let context = makeContext()
        let cached = cachedMovement()
        let previousSuccess = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try store.upsert(
            context: context,
            snapshot: MovementDerivation.snapshot(from: cached, context: context),
            movement: cached,
            collections: ["Регрессия #237"])
        let stableKey = record.key
        record.movementFetchedAt = previousSuccess
        let seed = CaseEvent.make(
            kind: .complaintRegistered,
            occurrence: ["issue-237-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1),
            evidence: .init())
        record.eventJournal = CaseEventJournal(events: [seed])
        try store.save()

        let partial = partialMovement()
        let sequence = Issue237MovementSequence([partial, partial])
        let center = RefreshCenter(
            store: store, client: SudrfClient(), serviceBuilder: { _ in sequence })

        for _ in 0..<2 {
            let execution = await center.refresh(key: stableKey)?.value
            guard case .partial = execution?.outcome else {
                return XCTFail("недоступные base/appeal hosts должны дать partial")
            }
            try assertPartialState(
                store: store, key: stableKey, previousSuccess: previousSuccess, seed: seed)
        }

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        XCTAssertEqual(reopened.all().count, 1)
        try assertPartialState(
            store: reopened, key: stableKey, previousSuccess: previousSuccess, seed: seed)

        let complete = completeMovement()
        let reopenedCenter = RefreshCenter(
            store: reopened, client: SudrfClient(),
            serviceBuilder: { _ in Issue237MovementSequence([complete]) })
        let final = await reopenedCenter.refresh(key: stableKey)?.value

        XCTAssertEqual(final?.outcome, .refreshed)
        let saved = try XCTUnwrap(reopened.record(forKey: stableKey))
        XCTAssertNotEqual(saved.movementFetchedAt, previousSuccess)
        XCTAssertEqual(saved.sourceRefreshAttempt?.kind, .usableSnapshot)
        XCTAssertEqual(saved.eventJournal?.events, [seed])
        XCTAssertEqual(saved.collectionNames, ["Регрессия #237"])
        XCTAssertEqual(saved.movement?.instances.filter {
            $0.caseNumber == "8Г-237/2026"
        }.count, 1)
    }

    private func assertPartialState(
        store: TrackedStore,
        key: String,
        previousSuccess: Date,
        seed: CaseEvent
    ) throws {
        let saved = try XCTUnwrap(store.record(forKey: key))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(saved.movementFetchedAt, previousSuccess)
        XCTAssertEqual(saved.sourceRefreshAttempt?.kind, .partial)
        XCTAssertEqual(saved.eventJournal?.events, [seed])
        XCTAssertEqual(saved.collectionNames, ["Регрессия #237"])
        XCTAssertEqual(saved.movement?.instances.first {
            $0.domain == "syktsud--komi.sudrf.ru"
        }?.judge, "Сохранённый судья")
        XCTAssertEqual(saved.movement?.instances.first {
            $0.domain == "vs--komi.sudrf.ru"
        }?.caseNumber, "33-237/2026")
        XCTAssertEqual(saved.movement?.instances.first {
            $0.domain == "3kas.sudrf.ru"
        }?.caseNumber, "8Г-237/2026")
        XCTAssertEqual(saved.movement?.instances.filter {
            $0.caseNumber == "8Г-237/2026"
        }.count, 1)
        XCTAssertEqual(saved.movement?.acts.map(\.id).sorted(), ["appeal-act", "base-act"])
        XCTAssertEqual(saved.movement?.actBodies["base-act"], "Сохранённый акт")
    }

    private func makeContext() -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001",
            cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-237/2026",
            caseID: "base-card",
            caseUID: "base-link-guid",
            judicialUID: uid)
    }

    private func cachedMovement() -> CaseMovement {
        let base = CaseInstance(
            level: .first,
            court: "Сыктывкарский городской суд",
            caseNumber: "2-237/2026",
            judge: "Сохранённый судья",
            domain: "syktsud--komi.sudrf.ru",
            foundByUID: false,
            result: "В производстве",
            sessions: [CaseSession(date: "01.09.2026", event: "Судебное заседание")],
            actID: "base-act")
        let appeal = CaseInstance(
            level: .appeal,
            court: "Верховный суд Республики Коми",
            caseNumber: "33-237/2026",
            judge: "Апелляционный судья",
            domain: "vs--komi.sudrf.ru",
            foundByUID: true,
            result: "Оставлено без изменения",
            sessions: [],
            actID: "appeal-act")
        let oldCassation = CaseInstance(
            level: .cassation,
            court: "Третий кассационный суд общей юрисдикции",
            caseNumber: "8Г-100/2026",
            judge: nil,
            domain: "3kas.sudrf.ru",
            foundByUID: true,
            result: nil,
            sessions: [])
        let acts = [
            CaseAct(id: "base-act", title: "Решение", date: "01.09.2026",
                    courtShort: "Сыктывкарский городской суд", instanceLevel: .first),
            CaseAct(id: "appeal-act", title: "Определение", date: "10.09.2026",
                    courtShort: "Верховный суд Республики Коми", instanceLevel: .appeal)
        ]
        return CaseMovement(
            uid: uid,
            caseNumber: "2-237/2026",
            inForce: false,
            instances: [base, appeal, oldCassation],
            complaints: [:],
            acts: acts,
            actBodies: ["base-act": "Сохранённый акт", "appeal-act": "Апелляционный акт"])
    }

    private func partialMovement() -> CaseMovement {
        let sparseBase = CaseInstance(
            level: .first,
            court: "Сыктывкарский городской суд",
            caseNumber: "2-237/2026",
            judge: nil,
            domain: "syktsud--komi.sudrf.ru",
            foundByUID: false,
            result: nil,
            sessions: [])
        let cassation = CaseInstance(
            level: .cassation,
            court: "Третий кассационный суд общей юрисдикции",
            caseNumber: "8Г-237/2026",
            judge: "Кассационный судья",
            domain: "3kas.sudrf.ru",
            foundByUID: true,
            result: "Оставлено без изменения",
            sessions: [])
        return CaseMovement(
            uid: uid,
            caseNumber: "2-237/2026",
            inForce: false,
            instances: [sparseBase, cassation],
            complaints: [:],
            acts: [],
            incompleteHigherCourtDomains: [
                "syktsud--komi.sudrf.ru", "vs--komi.sudrf.ru"
            ])
    }

    private func completeMovement() -> CaseMovement {
        var complete = cachedMovement()
        complete.instances.removeAll { $0.domain == "3kas.sudrf.ru" }
        complete.instances.append(partialMovement().instances[1])
        return complete
    }
}
