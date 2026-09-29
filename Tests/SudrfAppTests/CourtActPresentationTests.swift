import AppKit
import Foundation
import SwiftData
import SwiftUI
import XCTest
import SudrfKit
@testable import SudrfApp

final class CourtActPresentationTests: XCTestCase {
    private let court = "Сыктывкарский городской суд Республики Коми"
    private let domain = "syktsud--komi.sudrf.ru"
    private let cardURL = URL(string:
        "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&srv_num=1"
        + "&name_op=case&case_id=fixture&case_uid=fixture-uid&delo_id=1540005")!

    private struct Source {
        var id: String
        var title: String
        var date: String
        var courtShort: String
        var level: CaseInstance.Level
        var text: String
        var court: String? = nil
        var host: String? = nil
        var linked = true
        var sourceURL: URL? = nil
        var fileProvenance: PublishedActProvenance? = nil
    }

    func testSanitizedCaseCardActTextAndTabBecomeOneFullActAndOldIDResolves() throws {
        let (movement, fullText, genericID, tabID) = try sanitizedCaseMovement()

        let encoded = try JSONEncoder().encode(movement)
        let savedMovement = try JSONDecoder().decode(CaseMovement.self, from: encoded)
        let rows = CourtActPresentation.rows(in: savedMovement)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.title, "Заочное решение")
        XCTAssertEqual(row.date, "18.08.2025")
        XCTAssertEqual(row.stage, "1-я инстанция")
        XCTAssertEqual(row.text, fullText)
        XCTAssertEqual(Set(row.sourceIDs), Set([genericID, tabID]))
        XCTAssertEqual(CourtActPresentation.row(for: genericID, in: savedMovement)?.id, row.id)
        XCTAssertEqual(CourtActPresentation.row(for: tabID, in: savedMovement)?.id, row.id)
        XCTAssertEqual(row.originalURL, cardURL)
    }

    @MainActor
    func testAppRouterSelectsMergedRowFromLegacyActID() throws {
        let (movement, fullText, genericID, _) = try sanitizedCaseMovement()
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: domain, displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: court, courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-7212/2025", caseID: "fixture", caseUID: "fixture-uid",
            cardURLString: cardURL.absoluteString)
        let record = try store.upsert(
            context: context,
            snapshot: MovementDerivation.snapshot(from: movement, context: context),
            movement: movement, collections: [])
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.openCase(key: record.key)
        router.selectAct(genericID)

        let row = try XCTUnwrap(CourtActPresentation.row(for: genericID, in: movement))
        XCTAssertEqual(router.selectedActID, row.id)
        XCTAssertEqual(router.selectedActText, fullText)
    }

    @MainActor
    func testSanitizedActListScreenshotContainsOneDisplayRow() throws {
        let (movement, _, _, _) = try sanitizedCaseMovement()
        let rows = CourtActPresentation.rows(in: movement)
        XCTAssertEqual(rows.count, 1)

        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                CourtActListRow(display: row, selected: false, onSelect: {})
            }
        }
        .padding(8)
        .frame(width: 360, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let bitmap = try XCTUnwrap(renderer.nsImage?.tiffRepresentation
            .flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)

        if let output = ProcessInfo.processInfo.environment["SUDRF_ACT_VISUAL_OUTPUT"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("issue358-one-act-row.png"))
        }
    }

    func testSparseCopyJoinsOnlyWhenThereIsOneMatchingAct() throws {
        let text = "АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ\nОставить решение без изменения."
        let complete = Source(id: "appeal", title: "Апелляционное определение",
                              date: "19.10.2020", courtShort: "Второй апелляционный суд",
                              level: .appeal, text: text,
                              court: "Второй апелляционный суд", host: "2ap.sudrf.ru",
                              sourceURL: URL(string: "https://2ap.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_uid=x&delo_id=42"))
        let sparseCopy = Source(id: "old-copy", title: "Судебный акт #2 (Определение)",
                                date: "", courtShort: "", level: .appeal,
                                text: text, linked: false)
        let secondSparseCopy = Source(id: "old-copy-2",
                                      title: "Судебный акт #3 (Определение)",
                                      date: "", courtShort: "", level: .appeal,
                                      text: text, linked: false)

        let unique = CourtActPresentation.rows(in: movement([complete, sparseCopy]))
        XCTAssertEqual(unique.count, 1)
        XCTAssertEqual(Set(unique[0].sourceIDs), Set([complete.id, sparseCopy.id]))

        let sparsePair = CourtActPresentation.rows(
            in: movement([sparseCopy, secondSparseCopy]))
        XCTAssertEqual(sparsePair.count, 1)
        XCTAssertEqual(Set(sparsePair[0].sourceIDs),
                       Set([sparseCopy.id, secondSparseCopy.id]))

        let defaultLevelCopy = Source(id: "appeal-copy-default-level",
                                      title: "Судебный акт #4 (Определение)",
                                      date: "", courtShort: "", level: .first,
                                      text: text, linked: false)
        let inheritedAppeal = CourtActPresentation.rows(
            in: movement([complete, defaultLevelCopy]))
        XCTAssertEqual(inheritedAppeal.count, 1)
        XCTAssertEqual(Set(inheritedAppeal[0].sourceIDs),
                       Set([complete.id, defaultLevelCopy.id]))
        XCTAssertEqual(inheritedAppeal[0].instanceLevel, .appeal)
        XCTAssertEqual(inheritedAppeal[0].stage, "апелляция")

        let otherComplete = Source(id: "other-court", title: complete.title,
                                   date: "20.10.2020", courtShort: "Первый апелляционный суд",
                                   level: .appeal, text: text,
                                   court: "Первый апелляционный суд", host: "1ap.sudrf.ru")
        let ambiguous = CourtActPresentation.rows(
            in: movement([complete, otherComplete, sparseCopy]))
        XCTAssertEqual(ambiguous.count, 3)
        XCTAssertTrue(ambiguous.allSatisfy { $0.sourceIDs.count == 1 })
    }

    func testSameTextDoesNotMergeAcrossConflictingMetadataOrDifferentText() {
        let sameText = "Судебный акт без распознанного заголовка."
        let sources = [
            Source(id: "date-a", title: "Решение", date: "01.01.2025",
                   courtShort: "Суд", level: .first, text: sameText,
                   court: "Суд", host: "court-a.sudrf.ru"),
            Source(id: "date-b", title: "Решение", date: "02.01.2025",
                   courtShort: "Суд", level: .first, text: sameText,
                   court: "Суд", host: "court-a.sudrf.ru"),
            Source(id: "court-a", title: "Решение", date: "03.01.2025",
                   courtShort: "Суд A", level: .first, text: sameText,
                   court: "Суд A", host: "court-a.sudrf.ru"),
            Source(id: "court-b", title: "Решение", date: "03.01.2025",
                   courtShort: "Суд B", level: .first, text: sameText,
                   court: "Суд B", host: "court-b.sudrf.ru"),
            Source(id: "same-host-court-a", title: "Решение", date: "03.02.2025",
                   courtShort: "Первый суд", level: .first, text: sameText,
                   court: "Первый суд", host: "shared-host.sudrf.ru"),
            Source(id: "same-host-court-b", title: "Решение", date: "03.02.2025",
                   courtShort: "Второй суд", level: .first, text: sameText,
                   court: "Второй суд", host: "shared-host.sudrf.ru"),
            Source(id: "kind-decision", title: "Решение", date: "04.01.2025",
                   courtShort: "Суд", level: .first, text: sameText,
                   court: "Суд", host: "court-a.sudrf.ru"),
            Source(id: "kind-ruling", title: "Определение", date: "04.01.2025",
                   courtShort: "Суд", level: .first, text: sameText,
                   court: "Суд", host: "court-a.sudrf.ru"),
            Source(id: "stage-first", title: "Решение", date: "05.01.2025",
                   courtShort: "Суд", level: .first, text: sameText,
                   court: "Суд", host: "court-a.sudrf.ru"),
            Source(id: "stage-appeal", title: "Решение", date: "05.01.2025",
                   courtShort: "Суд", level: .appeal, text: sameText,
                   court: "Суд", host: "court-a.sudrf.ru"),
            Source(id: "different-text", title: "Решение", date: "03.01.2025",
                   courtShort: "Суд A", level: .first,
                   text: "Другой опубликованный текст акта.",
                   court: "Суд A", host: "court-a.sudrf.ru"),
        ]

        let rows = CourtActPresentation.rows(in: movement(sources))
        XCTAssertEqual(rows.count, sources.count)
    }

    func testUnverifiedSourceCardURLIsNotShownAsOriginal() throws {
        let unsafeURL = try XCTUnwrap(URL(string:
            "https://example.com/modules.php?name=sud_delo&name_op=case&case_id=x&delo_id=1"))
        let source = Source(id: "act", title: "Решение", date: "01.09.2025",
                            courtShort: court, level: .first,
                            text: "РЕШЕНИЕ\nИск удовлетворить.",
                            court: court, host: domain, sourceURL: unsafeURL)

        let row = try XCTUnwrap(CourtActPresentation.rows(in: movement([source])).first)
        XCTAssertNil(row.originalURL)
    }

    func testVerifiedPublishedFileTakesPrecedenceOverVerifiedCardURL() throws {
        let fileURL = try XCTUnwrap(URL(string: "https://mos-gorsud.ru/files/act.pdf?download=1"))
        let provenance = PublishedActProvenance(
            sourceURL: fileURL, finalURL: fileURL, format: .pdf,
            contentType: "application/pdf", contentHash: "fixture-hash",
            byteCount: 123, fetchedAt: Date(timeIntervalSince1970: 0), extractorVersion: 1)
        let source = Source(id: "file-backed", title: "Решение", date: "18.08.2025",
                            courtShort: court, level: .first,
                            text: "РЕШЕНИЕ\nИск удовлетворить.",
                            court: court, host: domain,
                            sourceURL: cardURL, fileProvenance: provenance)

        let row = try XCTUnwrap(CourtActPresentation.rows(in: movement([source])).first)
        XCTAssertEqual(row.originalURL, PublishedActURLPolicy.safeMosGorSudURL(fileURL))
        XCTAssertNotEqual(row.originalURL, cardURL)
    }

    private func movement(_ sources: [Source]) -> CaseMovement {
        let instances = sources.filter(\.linked).map { source in
            CaseInstance(level: source.level, court: source.court ?? "",
                         caseNumber: "2-7212/2025", judge: nil,
                         domain: source.host ?? domain, foundByUID: true,
                         result: nil, sessions: [], actID: source.id,
                         sourceURL: source.sourceURL)
        }
        return CaseMovement(
            uid: "11RS0001-01-2025-011255-03", caseNumber: "2-7212/2025",
            inForce: false, instances: instances, complaints: [:],
            acts: sources.map { CaseAct(id: $0.id, title: $0.title, date: $0.date,
                                        courtShort: $0.courtShort,
                                        instanceLevel: $0.level,
                                        fileProvenance: $0.fileProvenance) },
            actBodies: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.text) }))
    }

    private func sanitizedCaseMovement() throws -> (CaseMovement, String, String, String) {
        let card = try CaseCardParser.parse(html: try syktyvkarCardHTML(), cardURL: cardURL)
        let tab = try XCTUnwrap(card.acts.first)
        let fullText = try XCTUnwrap(card.actText)
        XCTAssertEqual(card.caseNumber, "2-7212/2025 ~ М-5922/2025")
        XCTAssertEqual(fullText, tab.body)

        // Legacy movements can contain both the generic actText entry and the
        // card's tab entry, each with its own ID and label.
        let generic = Source(id: "act_syktsud#2-7212/2025", title: "Решение",
                             date: "18.08.2025", courtShort: "1-я инстанция",
                             level: .first, text: fullText.replacingOccurrences(of: "\n", with: " "),
                             court: court, host: domain, sourceURL: cardURL)
        let tabSource = Source(id: tab.id, title: tab.label,
                               date: "18.08.2025", courtShort: court,
                               level: .first, text: tab.body,
                               court: court, host: domain, sourceURL: cardURL)
        return (movement([generic, tabSource]), fullText, generic.id, tab.id)
    }

    private func syktyvkarCardHTML() throws -> String {
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "issue358_2-7212_2025", withExtension: "html",
            subdirectory: "Fixtures"))
        return try String(contentsOf: fixture, encoding: .utf8)
    }
}
