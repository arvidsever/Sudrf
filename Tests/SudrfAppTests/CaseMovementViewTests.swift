import AppKit
import SwiftUI
import XCTest
@testable import SudrfApp
import SudrfKit

final class CaseMovementViewTests: XCTestCase {
    @MainActor
    func testTwoCassationRoundsRenderInIsolatedView() throws {
        let court = "Третий кассационный суд общей юрисдикции"
        let base = CaseInstance(level: .first, court: "Городской суд",
            caseNumber: "2-402/2025", judge: nil, domain: "district.sudrf.ru",
            foundByUID: false, result: nil,
            sessions: [CaseSession(date: "06.06.2025", event: "Вынесено решение")])
        let older = CaseInstance(level: .cassation, court: court,
            caseNumber: "88-20682/2025", judge: nil, domain: "3kas.sudrf.ru",
            foundByUID: true, result: nil,
            sessions: [CaseSession(date: "01.12.2025", event: "Судебное заседание")])
        let newer = CaseInstance(level: .cassation, court: court,
            caseNumber: "88-14300/2026", judge: nil, domain: "3kas.sudrf.ru",
            foundByUID: true, result: nil,
            sessions: [CaseSession(date: "30.09.2026", event: "Судебное заседание")])
        let movement = CaseMovement(uid: "11RS0001-01-2024-014706-13",
            caseNumber: base.caseNumber, inForce: true,
            instances: [base, older, newer], complaints: [:], acts: [])
        XCTAssertEqual(CaseMovementView.activeInstances(in: movement)
            .filter { $0.level == .cassation }.count, 2)

        let view = VStack(spacing: 10) {
            ForEach(CaseMovementView.activeInstances(in: movement)) { instance in
                InstanceBlock(instance: instance)
            }
        }
            .padding(16)
            .frame(width: 1000)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        let png = try XCTUnwrap(image.tiffRepresentation
            .flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        XCTAssertFalse(png.isEmpty)
        if let output = ProcessInfo.processInfo.environment["SUDRF_MOVEMENT_VISUAL_OUTPUT"] {
            try png.write(to: URL(fileURLWithPath: output))
        }
    }

    @MainActor
    func testCachedAppealBlocksDisplayDirectoryCourtAfterJSONRoundTrip() throws {
        let sessions = [CaseSession(
            date: "15.05.2026", time: "10:00", room: "Зал № 1",
            event: "Судебное заседание", result: nil)]
        let base = CaseInstance(
            level: .first, court: "Химкинский городской суд",
            caseNumber: "2-4461/2026", judge: nil,
            domain: "himki--mo.sudrf.ru", foundByUID: false,
            result: nil, sessions: sessions,
            sourceURL: URL(string:
                "https://himki--mo.sudrf.ru/modules.php?name=sud_delo&case_id=1&delo_id=1540005"))
        let dashedAppeal = CaseInstance(
            level: .appeal, court: "OBLSUD--MO", caseNumber: "33-9548/2026",
            judge: nil, domain: "OBLSUD--MO.SUDRF.RU", foundByUID: true,
            result: nil, sessions: sessions,
            sourceURL: URL(string:
                "https://oblsud--mo.sudrf.ru/modules.php?name=sud_delo&case_id=9548&delo_id=5"))
        let dottedAppeal = CaseInstance(
            level: .appeal, court: "OBLSUD--MO", caseNumber: "33-42895/2026",
            judge: nil, domain: "Oblsud.Mo.Sudrf.Ru", foundByUID: true,
            result: nil, sessions: sessions,
            sourceURL: URL(string:
                "https://oblsud.mo.sudrf.ru/modules.php?name=sud_delo&case_id=42895&delo_id=5"))
        let oldMovement = CaseMovement(
            uid: "issue365-synthetic-uid", caseNumber: base.caseNumber,
            inForce: false, instances: [base, dashedAppeal, dottedAppeal],
            complaints: [:], acts: [])

        let cachedMovement = try JSONDecoder().decode(
            CaseMovement.self, from: JSONEncoder().encode(oldMovement))
        let cachedAppeals = cachedMovement.instances.filter { $0.level == .appeal }
        let blocks = cachedAppeals.map { InstanceBlock(instance: $0) }

        XCTAssertEqual(cachedMovement, oldMovement)
        XCTAssertEqual(cachedAppeals.map(\.caseNumber), ["33-9548/2026", "33-42895/2026"])
        XCTAssertEqual(cachedAppeals.map(\.court), ["OBLSUD--MO", "OBLSUD--MO"])
        XCTAssertEqual(cachedAppeals.map(\.domain), [
            "OBLSUD--MO.SUDRF.RU", "Oblsud.Mo.Sudrf.Ru"])
        XCTAssertEqual(cachedAppeals.map(\.id), oldMovement.instances.dropFirst().map(\.id))
        XCTAssertEqual(cachedAppeals.map(\.sourceURL), oldMovement.instances.dropFirst().map(\.sourceURL))
        XCTAssertEqual(cachedAppeals.map(\.sessions), [sessions, sessions])
        XCTAssertEqual(blocks.map(\.courtName), [
            "Московский областной суд", "Московский областной суд"])

        let view = VStack(spacing: 10) {
            ForEach(cachedAppeals) { InstanceBlock(instance: $0) }
        }
            .padding(16)
            .frame(width: 1000)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        let png = try XCTUnwrap(image.tiffRepresentation
            .flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        XCTAssertFalse(png.isEmpty)
        if let output = ProcessInfo.processInfo.environment["SUDRF_MOVEMENT_VISUAL_OUTPUT"] {
            try png.write(to: URL(fileURLWithPath: output))
        }
    }

    @MainActor
    func testUndatedPublishedFactHasExplicitDateLabel() {
        XCTAssertEqual(CaseMovementView.sessionDateLabel(""), "Дата не опубликована")
        XCTAssertEqual(CaseMovementView.sessionDateLabel("  \n"), "Дата не опубликована")
        XCTAssertEqual(CaseMovementView.sessionDateLabel("18.05.2023"), "18.05.2023")
    }

    @MainActor
    func testMaterialProjectionKeepsPublishedMovementAndSourceState() {
        let session = CaseSession(
            date: "02.09.2026", time: "10:30", room: "Зал № 1",
            event: "Судебное заседание", result: "Удовлетворено")
        let material = CaseInstance(
            level: .material, court: "Районный суд", caseNumber: "13-1/2026",
            judge: "Иванов И.И.", domain: "court.sudrf.ru", foundByUID: true,
            result: "Удовлетворено", sessions: [session],
            note: "Движение временно недоступно")
        let base = CaseInstance(
            level: .first, court: "Районный суд", caseNumber: "2-1/2026",
            judge: nil, domain: "court.sudrf.ru", foundByUID: false,
            result: nil, sessions: [])
        let movement = CaseMovement(
            uid: "11RS0001-01-2026-000001-11", caseNumber: "2-1/2026",
            inForce: false, instances: [base, material], complaints: [:], acts: [])

        let projected = CaseMovementView.materialInstances(in: movement)

        XCTAssertEqual(projected, [material])
        XCTAssertEqual(projected.first?.sessions, [session])
        XCTAssertEqual(projected.first?.note, "Движение временно недоступно")
    }

    @MainActor
    func testPreviousRegistrationProjectionPreservesEventsAndLeavesMaterialsSeparate() {
        let historicalSession = CaseSession(
            date: "01.09.2026", time: "09:00", room: nil,
            event: "Регистрация заявления", result: nil)
        let historical = CaseInstance(
            level: .first, court: "Районный суд", caseNumber: "9а-10/2026",
            judge: nil, domain: "court.sudrf.ru", foundByUID: false,
            result: nil, sessions: [historicalSession],
            note: "Предыдущая регистрация")
        let current = CaseInstance(
            level: .first, court: "Районный суд", caseNumber: "3а-10/2026",
            judge: nil, domain: "court.sudrf.ru", foundByUID: false,
            result: nil, sessions: [CaseSession(
                date: "02.09.2026", event: "Принято к производству")])
        let material = CaseInstance(
            level: .material, court: "Районный суд", caseNumber: "13а-10/2026",
            judge: nil, domain: "court.sudrf.ru", foundByUID: false,
            result: nil, sessions: [], note: "Предыдущая регистрация")
        let movement = CaseMovement(
            uid: "11RS0001-01-2026-000010-11", caseNumber: current.caseNumber,
            inForce: false, instances: [historical, current, material],
            complaints: [:], acts: [])

        XCTAssertEqual(CaseMovementView.activeInstances(in: movement), [historical, current, material])
        XCTAssertEqual(CaseMovementView.previousRegistrationInstances(in: movement),
                       [historical, material])
        XCTAssertEqual(CaseMovementView.previousRegistrationInstances(in: movement)
            .first?.sessions, [historicalSession])
        XCTAssertTrue(CaseMovementView.materialInstances(in: movement).isEmpty)
    }

    @MainActor
    func testChronologyIsStableAndMetadataDoesNotCreateRefreshEvent() {
        let previous = CaseInstance(level: .first, court: "Суд", caseNumber: "9а-77/2026",
            judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true, result: nil,
            sessions: [CaseSession(date: "04.09.2026", event: "Регистрация")], note: "Предыдущая регистрация")
        let appeal = CaseInstance(level: .appeal, court: "АСОЮ", caseNumber: "66а-726/2026",
            judge: nil, domain: "2ap.sudrf.ru", foundByUID: true, result: nil,
            sessions: [CaseSession(date: "07.09.2026", event: "Регистрация")])
        let current = CaseInstance(level: .first, court: "Суд", caseNumber: "3а-681/2026",
            judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true, result: nil,
            sessions: [CaseSession(date: "09.09.2026", event: "Принято к производству")])
        let old = CaseMovement(uid: "uid", caseNumber: current.caseNumber, inForce: false,
                               instances: [current, appeal, previous], complaints: [:], acts: [])
        var enriched = old
        enriched.instances.reverse()
        enriched.instances[0].sourceEvidence = .init(appealKinds: ["Частная жалоба"])
        XCTAssertEqual(CaseMovementView.activeInstances(in: old), [previous, appeal, current])
        XCTAssertEqual(CaseMovementView.activeInstances(in: enriched).map(\.id), [previous.id, appeal.id, current.id])
        XCTAssertTrue(MovementDerivation.hasSameRefreshSource(old, enriched))
        var changed = enriched
        changed.instances[0].sessions.append(CaseSession(date: "06.09.2026", event: "Новое событие"))
        XCTAssertFalse(MovementDerivation.hasSameRefreshSource(old, changed))
    }

    func testHistoricalMaterialSourceUsesRegistrationLabel() {
        let date = Date(timeIntervalSince1970: 1_725_000_000)
        let feed = FeedEntry(
            id: "historical", dayHead: nil, date: date, time: "10:00",
            recordKey: "case", caseNumber: "3а-10/2026", client: "Доверитель",
            kind: .movement, text: "Регистрация", actID: nil, isUnread: false,
            instanceCaseNumber: "9а-10/2026", instanceLevel: .material,
            previousRegistrationNumber: "9а-10/2026")
        let hearing = TrackedHearing(
            recordKey: "case", date: date, time: "10:00",
            caseNumber: "3а-10/2026", parties: "—", court: "Суд", room: "",
            dateLabel: "1 сентября", instanceCaseNumber: "9а-10/2026",
            instanceLevel: .material,
            previousRegistrationNumber: "9а-10/2026")
        let genuineMaterial = FeedEntry(
            id: "material", dayHead: nil, date: date, time: "11:00",
            recordKey: "case", caseNumber: "3а-10/2026", client: "Доверитель",
            kind: .movement, text: "Материал", actID: nil, isUnread: false,
            instanceCaseNumber: "13а-10/2026", instanceLevel: .material)

        XCTAssertEqual(feed.secondaryLabel, "Предыдущая регистрация № 9а-10/2026")
        XCTAssertEqual(feed.notificationSubtitle,
                       "3а-10/2026 · Предыдущая регистрация № 9а-10/2026")
        XCTAssertEqual(hearing.secondaryLabel,
                       "Предыдущая регистрация № 9а-10/2026")
        XCTAssertEqual(genuineMaterial.secondaryLabel, "Материал № 13а-10/2026")
        XCTAssertEqual(genuineMaterial.notificationSubtitle,
                       "3а-10/2026 · Материал № 13а-10/2026")
    }
}
