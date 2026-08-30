import XCTest
import Foundation
@testable import SudrfKit

/// Round-trip CaseMovement через JSON — фундамент кэша карточек в приложении.
/// CaseSession.id (UUID, пересоздаётся при декодировании) в == не участвует,
/// поэтому равенство проверяется напрямую по целым структурам.
final class MovementCodableTests: XCTestCase {

    func testTreasuryEligibilityExcludesElectronicAndBailiffDocuments() {
        let treasury = CourtEnforcementDocument(blankNumber: "ФС № 123")
        let electronic = CourtEnforcementDocument(electronicID: "11RS#1")
        let bailiff = CourtEnforcementDocument(
            blankNumber: "ФС № 456", recipient: "ОСП ФССП России")

        XCTAssertTrue(treasury.isTreasuryEligible)
        XCTAssertFalse(electronic.isTreasuryEligible)
        XCTAssertFalse(bailiff.isTreasuryEligible)
    }

    func testMovementRoundTrip() throws {
        let mv = MovementService.demoMovement(uid: "11RS0001-01-2026-000001-11",
                                              caseNumber: "2-3204/2026")
        let data = try JSONEncoder().encode(mv)
        let back = try JSONDecoder().decode(CaseMovement.self, from: data)

        XCTAssertEqual(back, mv)
    }

    /// Регресс на ловушку синтезированного ==: раньше UUID-поле id делало
    /// декодированную сессию НЕ равной свежей с тем же содержимым, и сравнение
    /// «кэш vs свежие данные» всегда давало false.
    func testDecodedSessionEqualsFresh() throws {
        let s = CaseSession(date: "23.04.2026", time: "14:00", room: "215",
                            event: "Судебное заседание", result: "иск удовлетворён частично")
        let back = try JSONDecoder().decode(CaseSession.self,
                                            from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertNotEqual(back.id, s.id)   // id эфемерен — и это нормально
    }

    /// URL формы капчи переживает round-trip (в кэш заглушки не пишутся, но
    /// кодек обязан быть корректным для промежуточных состояний).
    func testCaptchaInstanceRoundTrip() throws {
        let inst = CaseInstance(level: .appeal, court: "ВС Коми", caseNumber: "—",
                                judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: false,
                                result: nil, sessions: [],
                                captchaFormURL: URL(string: "https://vs--komi.sudrf.ru/modules.php?name=sud_delo"))
        let back = try JSONDecoder().decode(CaseInstance.self,
                                            from: JSONEncoder().encode(inst))
        XCTAssertEqual(back.captchaFormURL, inst.captchaFormURL)
        XCTAssertEqual(back.level, .appeal)
    }

    func testOldMovementWithoutExecutionDocumentsStillDecodes() throws {
        let movement = MovementService.demoMovement(uid: "uid", caseNumber: "2-1/2026")
        let encoded = try JSONEncoder().encode(movement)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "executionDocuments")
        object["instances"] = (object["instances"] as? [[String: Any]])?.map { value in
            var value = value
            value.removeValue(forKey: "actIDs")
            value.removeValue(forKey: "actFileError")
            return value
        }
        object["acts"] = (object["acts"] as? [[String: Any]])?.map { value in
            var value = value
            value.removeValue(forKey: "fileProvenance")
            return value
        }
        let oldData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(CaseMovement.self, from: oldData)
        XCTAssertNil(decoded.executionDocuments)
        XCTAssertEqual(decoded.uid, movement.uid)
    }

    func testPublishedFileProvenanceRoundTrip() throws {
        let source = URL(string: "https://mos-gorsud.ru/mgs/cases/docs/content/abc")!
        let provenance = PublishedActProvenance(
            sourceURL: source, finalURL: source, format: .docx,
            contentType: "application/octet-stream", contentHash: "abc123",
            byteCount: 42, fetchedAt: Date(timeIntervalSince1970: 100), extractorVersion: 1)
        let act = CaseAct(id: "act-file", title: "Решение", date: "01.08.2026",
                          courtShort: "МГС", instanceLevel: .first,
                          fileProvenance: provenance)
        let instance = CaseInstance(
            level: .first, court: "МГС", caseNumber: "3а-1/2026", judge: nil,
            domain: MosGorSudEndpoint.host, foundByUID: false, result: nil,
            sessions: [], actID: act.id, actIDs: [act.id])
        let movement = CaseMovement(uid: "", caseNumber: instance.caseNumber, inForce: false,
                                    instances: [instance], complaints: [:], acts: [act],
                                    actBodies: [act.id: "Текст решения"])

        let decoded = try JSONDecoder().decode(
            CaseMovement.self, from: JSONEncoder().encode(movement))
        XCTAssertEqual(decoded, movement)
        XCTAssertEqual(decoded.acts.first?.fileProvenance, provenance)
    }

    func testCourtExecutionDocumentStableIDPrefersPaperNumber() throws {
        let paper = CourtEnforcementDocument(date: "21.08.2025",
                                             blankNumber: "ФС № 049373812",
                                             electronicID: "11RS0001#2-7212/2025#4",
                                             courtStatus: "Выдан", recipient: "Взыскатель")
        let same = CourtEnforcementDocument(date: "21.08.2025",
                                            blankNumber: "ФС № 049373812",
                                            electronicID: "different", courtStatus: "Выдан",
                                            recipient: "Взыскатель")
        XCTAssertEqual(paper.id, same.id)
        XCTAssertEqual(paper.normalizedBlankNumber, "ФС049373812")
        XCTAssertEqual(CourtEnforcementDocument.normalizedNumber("фс № 049373812"),
                       paper.normalizedBlankNumber)
        let back = try JSONDecoder().decode(CourtEnforcementDocument.self,
                                            from: JSONEncoder().encode(paper))
        XCTAssertEqual(back, paper)
    }
}
