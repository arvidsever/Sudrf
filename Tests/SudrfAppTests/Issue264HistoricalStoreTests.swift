import XCTest
import SwiftData
import SudrfKit
@testable import SudrfApp

final class Issue264HistoricalStoreTests: XCTestCase {
    private struct Fixture {
        let name: String
        let readsJudicialUID: Bool
        let hasSummaryProjection: Bool
    }

    private func assertFixtureContext(_ context: MovementContext, index: Int,
                                      fixture: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(context.searchDomain, "fixture-\(index).invalid", fixture,
                       file: file, line: line)
        XCTAssertEqual(context.displayDomain, "fixture.invalid", fixture, file: file, line: line)
        XCTAssertEqual(context.caseID, "fixture-card-\(index)", fixture, file: file, line: line)
        XCTAssertEqual(context.caseUID, "fixture-link-\(index)", fixture, file: file, line: line)
        XCTAssertEqual(context.courtLevelRaw, CourtLevel.district.rawValue, fixture,
                       file: file, line: line)
        XCTAssertEqual(context.cartotekaId, "g1", fixture, file: file, line: line)
        XCTAssertEqual(context.cartotekaLevelRaw, CourtLevel.district.rawValue, fixture,
                       file: file, line: line)
    }

    @MainActor
    func testHistoricalStoreFixturesMigrateToV7AndReopenWithUserData() throws {
        let fixtures = [
            Fixture(name: "pre-uid-v0.38.0", readsJudicialUID: false,
                    hasSummaryProjection: false),
            Fixture(name: "unversioned-v0.40.0", readsJudicialUID: true,
                    hasSummaryProjection: false),
            Fixture(name: "v1-0.42.30", readsJudicialUID: true,
                    hasSummaryProjection: false),
            Fixture(name: "v2-0.42.30", readsJudicialUID: true,
                    hasSummaryProjection: false),
            Fixture(name: "v3-0.42.30", readsJudicialUID: true,
                    hasSummaryProjection: true),
        ]

        for fixture in fixtures {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Issue264-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let storeURL = directory.appendingPathComponent("default.store")
            let sourceURL = try XCTUnwrap(Bundle.module.url(
                forResource: fixture.name, withExtension: "store",
                subdirectory: "Fixtures/issue-264"))
            try FileManager.default.copyItem(at: sourceURL, to: storeURL)

            var firstIdentities: [String: UUID] = [:]
            do {
                let (container, store) = try openCurrentStore(at: storeURL)
                let records = store.all()
                XCTAssertEqual(records.count, 2, fixture.name)
                XCTAssertEqual(Set(records.map(\.caseNumber)), ["2-1/2024", "2-2/2024"],
                               fixture.name)
                XCTAssertEqual(Set(records.map(\.key)), [
                    "fixture.invalid/2-1/2024", "fixture.invalid/2-2/2024",
                ], fixture.name)

                for index in 1...2 {
                    let key = "fixture.invalid/2-\(index)/2024"
                    let record = try XCTUnwrap(store.record(forKey: key), fixture.name)
                    let context = try XCTUnwrap(record.context, fixture.name)
                    assertFixtureContext(context, index: index, fixture: fixture.name)
                    XCTAssertEqual(record.collectionNames, ["Fixture", "Archive"], fixture.name)
                    XCTAssertEqual(record.folderName, "", fixture.name)
                    XCTAssertEqual(record.snapshot?.partiesShort, "Synthetic parties \(index)",
                                   fixture.name)
                    XCTAssertEqual(record.movement?.actBodies["fixture-act-\(index)"],
                                   "Synthetic judgment text \(index)", fixture.name)
                    XCTAssertEqual(record.movementFetchedAt,
                                   Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                                   fixture.name)
                    XCTAssertEqual(record.judicialUID,
                                   fixture.readsJudicialUID
                                       ? "fixture-uid-\(index)" : "FIXTUREUID\(index)",
                                   fixture.name)
                    let logicalCaseID = try XCTUnwrap(record.logicalCaseID, fixture.name)
                    firstIdentities[key] = logicalCaseID
                    XCTAssertEqual(record.eventJournal, CaseEventJournal(), fixture.name)

                    let acts = try container.mainContext.fetch(
                        FetchDescriptor<CourtActRecord>()).filter { $0.caseKey == key }
                    XCTAssertEqual(acts.count, 1, fixture.name)
                    XCTAssertEqual(acts.first?.document?.sourceActID, "fixture-act-\(index)",
                                   fixture.name)
                    XCTAssertEqual(acts.first?.document?.sourceText,
                                   "Synthetic judgment text \(index)",
                                   fixture.name)
                }

                let summaries = try container.mainContext.fetch(FetchDescriptor<ActSummaryRecord>())
                XCTAssertEqual(summaries.count, fixture.hasSummaryProjection ? 2 : 0,
                               fixture.name)
                if fixture.hasSummaryProjection {
                    for index in 1...2 {
                        let key = "fixture.invalid/2-\(index)/2024"
                        let expectedDocument = ActDocument(
                            caseKey: key, sourceActID: "fixture-act-\(index)",
                            caseNumber: "2-\(index)/2024", judicialUID: "fixture-uid-\(index)",
                            court: "Synthetic Court", instanceLevel: .first, kind: "Решение",
                            date: "01.02.2024", sourceText: "Synthetic judgment text \(index)")
                        let act = try XCTUnwrap(try container.mainContext.fetch(
                            FetchDescriptor<CourtActRecord>()).first { $0.caseKey == key },
                            fixture.name)
                        let summary = try XCTUnwrap(
                            summaries.first { $0.documentID == act.id }, fixture.name)
                        XCTAssertEqual(summary.documentID, expectedDocument.id, fixture.name)
                        XCTAssertEqual(summary.provider, "fixture", fixture.name)
                        XCTAssertEqual(summary.model, "fixture", fixture.name)
                        XCTAssertEqual(summary.promptVersion, "fixture-v1", fixture.name)
                        XCTAssertEqual(summary.pipelineVersion, "fixture-v1", fixture.name)
                        XCTAssertEqual(summary.sourceHash, expectedDocument.sourceHash, fixture.name)
                        XCTAssertEqual(summary.generatedAt,
                                       Date(timeIntervalSince1970: 1_700_000_200 + Double(index)),
                                       fixture.name)
                    }
                }
            }

            // A second V7 container proves the migrated SQLite store, keys,
            // generated identities, movement payloads, and act projection
            // remain durable after closing the first container.
            do {
                let (container, store) = try openCurrentStore(at: storeURL)
                XCTAssertEqual(store.all().count, 2, fixture.name)
                for index in 1...2 {
                    let key = "fixture.invalid/2-\(index)/2024"
                    let logicalCaseID = try XCTUnwrap(firstIdentities[key], fixture.name)
                    let record = try XCTUnwrap(store.record(forKey: key), fixture.name)
                    let context = try XCTUnwrap(record.context, fixture.name)
                    assertFixtureContext(context, index: index, fixture: fixture.name)
                    XCTAssertEqual(record.logicalCaseID, logicalCaseID, fixture.name)
                    XCTAssertNotNil(record.movement?.acts.first, fixture.name)
                    let acts = try container.mainContext.fetch(
                        FetchDescriptor<CourtActRecord>()).filter { $0.caseKey == key }
                    XCTAssertEqual(acts.count, 1, fixture.name)
                }
                let summaries = try container.mainContext.fetch(FetchDescriptor<ActSummaryRecord>())
                XCTAssertEqual(summaries.count, fixture.hasSummaryProjection ? 2 : 0,
                               fixture.name)
            }
        }
    }

    @MainActor
    func testCleanV7StoreRemainsEmptyAndWritable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Issue264-clean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Fixture",
            searchDomain: "fresh.invalid", displayDomain: "fresh.invalid",
            courtTitle: "Synthetic Court", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: nil, cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-1/2024")
        do {
            let (_, store) = try openCurrentStore(
                at: directory.appendingPathComponent("default.store"))
            XCTAssertTrue(store.all().isEmpty)
            _ = try store.upsert(context: context, snapshot: nil, collections: ["Fresh"])
            try store.save()
        }
        let reopened = try openCurrentStore(at: directory.appendingPathComponent("default.store"))
        XCTAssertEqual(reopened.1.all().map(\.key), [context.key])
        XCTAssertEqual(reopened.1.record(forKey: context.key)?.collectionNames, ["Fresh"])
    }

    @MainActor
    private func openCurrentStore(at storeURL: URL) throws -> (ModelContainer, TrackedStore) {
        let schema = Schema(versionedSchema: SudrfSchemaV7.self)
        let configuration = ModelConfiguration(
            "Issue264Fixture", schema: schema, url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: schema, migrationPlan: SudrfSchemaMigrationPlan.self,
            configurations: configuration)
        return (container, try TrackedStore(container: container))
    }
}
