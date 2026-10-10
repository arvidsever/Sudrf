import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

/// Tests disk store → fresh registry installation, not an OS cold launch.
final class Issue46CatalogBootstrapTests: XCTestCase {
    @MainActor
    func testFreshRegistryResolvesDurableCasesAliasesAndActsAfterDiskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue46-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "Issue46CatalogBootstrapTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storeURL = directory.appendingPathComponent("test.store")
        let alias = "legacy/issue46/case"
        let sourceText = "Первый синтетический абзац.\n\nВторой синтетический абзац."
        let context = MovementContext(branchRaw: CourtBranch.general.rawValue,
            region: "Москва", searchDomain: "court--msk.sudrf.ru",
            displayDomain: "court.msk.sudrf.ru", courtTitle: "Тестовый суд",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "77",
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-46/2026")
        let act = CaseAct(id: "issue46-act", title: "Решение", date: "01.07.2026",
            courtShort: "Тестовый суд", instanceLevel: .first)
        let movement = CaseMovement(uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: [], complaints: [:], acts: [act], actBodies: [act.id: sourceText])
        var caseID = ""
        var expectedDocument: ActDocument?
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.upsert(context: context, snapshot: nil,
                movement: movement, collections: [])
            record.addLegacyKeyAlias(alias)
            try store.save()
            caseID = record.key
            expectedDocument = try XCTUnwrap(store.courtActDocument(caseKey: caseID, sourceActID: act.id))
        }
        let expected = try XCTUnwrap(expectedDocument)
        let container = try await PersistentStoreBootstrapper(
            recoveryRoot: directory.appendingPathComponent("backup"))
            .prepareProduction(storeURL: storeURL, defaultsSuiteName: suiteName)
        let reopened = try TrackedStore(container: container, prepared: true)
        XCTAssertEqual(reopened.record(forLocator: alias)?.key, caseID)
        let registry = CaseCatalogRegistry()
        let beforeCases = try await registry.caseEntities()
        let beforeActs = try await registry.courtActEntities()
        XCTAssertTrue(beforeCases.isEmpty)
        XCTAssertTrue(beforeActs.isEmpty)
        let catalog = CaseCatalog(container: container)
        await registry.install(catalog)
        let cases = try await registry.caseEntities(for: [alias, caseID, "foreign-case"])
        let acts = try await registry.courtActEntities()
        XCTAssertEqual(cases.map(\.id), [caseID])
        XCTAssertEqual(acts.map(\.id), [expected.id])
        let reopenedAct = try await catalog.act(id: expected.id)
        let document = try XCTUnwrap(reopenedAct?.document)
        XCTAssertEqual(document.sourceText, sourceText)
        XCTAssertEqual(document.sourceHash, expected.sourceHash)
        XCTAssertEqual(document.paragraphs.count, 2)
        XCTAssertEqual(document.paragraphs, expected.paragraphs)
        XCTAssertEqual(document.paragraphizerVersion, expected.paragraphizerVersion)
        XCTAssertEqual(document.paragraphs.map(\.id), expected.paragraphs.map(\.id))
        let foreignAct = try await catalog.act(id: "foreign-act")
        XCTAssertNil(foreignAct)
        await registry.install(CaseCatalog(container: container))
        let repeatedCases = try await registry.caseEntities()
        let repeatedActs = try await registry.courtActEntities()
        XCTAssertEqual(repeatedCases.map(\.id), [caseID])
        XCTAssertEqual(repeatedActs.map(\.id), [expected.id])
    }
}
