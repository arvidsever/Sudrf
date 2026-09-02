import XCTest
@testable import SudrfKit

final class LegacyKASCartotekaTests: XCTestCase {

    func testHistoricalCivilTechnicalPairsResolveToKASCartotekas() {
        let samples: [(CourtLevel, String, String?, String, String)] = [
            (.district, "1540005", nil, "2а-321/2021", "p1"),
            (.district, "1540005", nil, "9а-118/2022", "p1"),
            (.subject, "1540005", nil, "3а-255/2020", "p1"),
            (.subject, "1540005", nil, "9а-96/2020", "p1"),
            (.district, "5", "5", "11а-1/2021", "p2"),
            (.subject, "5", "5", "33а-2760/2021", "p2"),
            (.appeal, "5", "5", "66а-429/2021", "p2"),
            (.cassation, "2800001", "2800001", "8а-1/2021", "p3"),
            (.cassation, "2800001", "2800001", "88а-5376/2021", "p3"),
            (.subject, "2800001", "2800001", "4Га-1/2018", "p33"),
            // Латинская `a` нормализуется тем же путём, что и ручной поиск.
            (.subject, "5", "5", "33a-2760/2021", "p2")
        ]

        for (level, deloID, new, number, expectedID) in samples {
            XCTAssertEqual(
                CartotekaRegistry.resolve(
                    level: level, deloID: deloID, new: new, caseNumber: number)?.id,
                expectedID,
                number)
        }
    }

    func testOverrideDoesNotChangeCivilOrMaterialCartotekas() {
        XCTAssertEqual(
            CartotekaRegistry.resolve(
                level: .district, deloID: "1540005", new: nil,
                caseNumber: "2-321/2021")?.id,
            "g1")
        XCTAssertEqual(
            CartotekaRegistry.resolve(
                level: .subject, deloID: "5", new: "5",
                caseNumber: "33-2760/2021")?.id,
            "g2")
        XCTAssertEqual(
            CartotekaRegistry.resolve(
                level: .cassation, deloID: "2800001", new: "2800001",
                caseNumber: "8Г-1/2021")?.id,
            "g3")
        XCTAssertEqual(
            CartotekaRegistry.resolve(
                level: .district, deloID: "1610001", new: nil,
                caseNumber: "13а-1/2021")?.id,
            "m")
    }
}
