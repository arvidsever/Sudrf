import XCTest
import SudrfKit
@testable import SudrfApp

final class DirectCaseLinkResolverTests: XCTestCase {

    func testResolvesEffectiveDistrictHostIntoCanonicalTrackingContext() async throws {
        let input = url(
            "https://syktsud.komi.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=17&case_uid=source-guid&delo_id=1540005&utm_source=mail")
        let effective = url(
            "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=17&case_uid=source-guid&delo_id=1540005&new=0&srv_num=2"
                + "&source=redirect&utm_campaign=mail")
        let card = CaseCard(rawText: "", actText: nil,
                            judge: "Петров Петр Петрович", result: "Решение принято",
                            uid: "11RS0001-01-2026-000123-00",
                            caseNumber: "2-123/2026", category: "Гражданское дело",
                            receiptDate: "01.09.2026", decisionDate: "02.09.2026",
                            legalForceDate: "03.09.2026")
        let court = DistrictCourt(
            title: "Сыктывкарский городской суд", domain: "syktsud.komi.sudrf.ru",
            code: "11RS0001", regionCode: "komi", kind: .district,
            portalSubject: "11")
        let resolver = stubResolver(responseURL: effective, card: card, courts: [court])

        let resolution = try await resolver.resolve(input.absoluteString)
        let context = resolution.context

        XCTAssertEqual(resolution.caseNumber, "2-123/2026")
        XCTAssertEqual(resolution.courtTitle, "Сыктывкарский городской суд")
        XCTAssertEqual(resolution.judicialUID, card.uid)
        XCTAssertEqual(resolution.category, card.category)
        XCTAssertEqual(resolution.judge, card.judge)
        XCTAssertEqual(resolution.result, card.result)
        XCTAssertEqual(context.branch, .general)
        XCTAssertEqual(context.courtLevel, .district)
        XCTAssertEqual(context.region, "Республика Коми")
        XCTAssertEqual(context.searchDomain, "syktsud--komi.sudrf.ru")
        XCTAssertEqual(context.displayDomain, "syktsud.komi.sudrf.ru")
        XCTAssertEqual(context.courtCode, "11RS0001")
        XCTAssertEqual(context.cartotekaId, "g1")
        XCTAssertEqual(context.caseID, "17")
        XCTAssertEqual(context.caseUID, "source-guid")
        XCTAssertEqual(context.judicialUID, card.uid)
        XCTAssertEqual(context.baseInstanceLevel, .first)
        XCTAssertEqual(context.cardURLString,
                       try SudrfCaseCardLink(url: effective).url.absoluteString)
        let known = try XCTUnwrap(context.sourceKnownCard)
        XCTAssertEqual(known.domain, "syktsud--komi.sudrf.ru")
        XCTAssertEqual(known.caseID, "17")
        XCTAssertEqual(known.caseUID, "source-guid")
        XCTAssertEqual(known.deloID, "1540005")
        XCTAssertEqual(known.new, "0")
        XCTAssertEqual(known.caseNumber, "2-123/2026")
        XCTAssertEqual(known.cartotekaID, "g1")
    }

    func testKoAPCardBuildsExactMovementTargets() async throws {
        let effective = url(
            "https://leninsky--kir.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=20&case_uid=guid&delo_id=1500001&new=0")
        let card = CaseCard(rawText: "", actText: nil,
                            uid: "43RS0001-01-2026-000174-00",
                            caseNumber: "5-174/2026")
        let court = DistrictCourt(
            title: "Ленинский районный суд города Кирова", domain: "leninsky.kir.sudrf.ru",
            code: "43RS0001", regionCode: "kir", kind: .district,
            portalSubject: "43")
        let resolver = stubResolver(responseURL: effective, card: card, courts: [court])

        let resolution = try await resolver.resolve(effective.absoluteString)
        let targets = try XCTUnwrap(resolution.context.higherCourtTargets)

        XCTAssertEqual(resolution.context.cartotekaId, "adm")
        XCTAssertEqual(resolution.context.baseInstanceLevel, .first)
        XCTAssertTrue(targets.contains { $0.cartotekaIDs == ["adm1"] && $0.courtLevel == .subject })
        XCTAssertTrue(targets.contains { $0.cartotekaIDs == ["adm33"] && $0.courtLevel == .subject })
        XCTAssertTrue(targets.contains { $0.cartotekaIDs == ["adm3"] && $0.courtLevel == .cassation })
    }

    func testResolvesSubjectAndMilitaryCardsThroughExistingDirectories() async throws {
        let subjectURL = url(
            "https://vs--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=31&case_uid=subject-guid&delo_id=5&new=5")
        let subjectCard = CaseCard(rawText: "", actText: nil,
                                   uid: "11RS0001-01-2026-000123-00",
                                   caseNumber: "33-1/2026")
        let subjectResolver = stubResolver(responseURL: subjectURL, card: subjectCard)
        let subject = (try await subjectResolver.resolve(subjectURL.absoluteString)).context

        XCTAssertEqual(subject.branch, .general)
        XCTAssertEqual(subject.courtLevel, .subject)
        XCTAssertEqual(subject.courtTitle, "Верховный суд Республики Коми")
        XCTAssertEqual(subject.region, "Республика Коми")
        XCTAssertEqual(subject.cartotekaId, "g2")
        XCTAssertEqual(subject.baseInstanceLevel, .appeal)

        let militaryURL = url(
            "https://gvs--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=41&case_uid=military-guid&delo_id=1540005")
        let militaryCard = CaseCard(rawText: "", actText: nil,
                                    uid: "11GV0001-01-2026-000001-00",
                                    caseNumber: "2-1/2026")
        let garrison = DistrictCourt(
            title: "Сыктывкарский гарнизонный военный суд", domain: "gvs.komi.sudrf.ru",
            code: "11GV0001", regionCode: "komi", kind: .military,
            portalSubject: "11")
        let militaryResolver = stubResolver(responseURL: militaryURL, card: militaryCard,
                                            courts: [garrison])
        let military = (try await militaryResolver.resolve(militaryURL.absoluteString)).context

        XCTAssertEqual(military.branch, .military)
        XCTAssertEqual(military.courtLevel, .district)
        XCTAssertEqual(military.courtTitle, garrison.title)
        XCTAssertEqual(military.region, "Республика Коми")
        XCTAssertEqual(military.courtCode, "11GV0001")
        XCTAssertTrue(military.expandedHigherDomains().contains("vkas.sudrf.ru"))
    }

    func testIncompleteVintageLinkKeepsCanonicalURLButNotKnownCard() async throws {
        let effective = url(
            "https://court--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&_uid=vintage-guid&_deloId=1540005&_new=0&srv_num=3")
        let card = CaseCard(rawText: "", actText: nil,
                            uid: "11RS0001-01-2026-000123-00",
                            caseNumber: "2-123/2026")
        let court = DistrictCourt(
            title: "Условный районный суд", domain: "court.komi.sudrf.ru",
            code: "11RS0002", regionCode: "komi", kind: .district,
            portalSubject: "11")
        let resolver = stubResolver(responseURL: effective, card: card, courts: [court])

        let context = (try await resolver.resolve(effective.absoluteString)).context

        XCTAssertNil(context.caseID)
        XCTAssertEqual(context.caseUID, "vintage-guid")
        XCTAssertEqual(context.cardURLString,
                       try SudrfCaseCardLink(url: effective).url.absoluteString)
        XCTAssertNil(context.sourceKnownCard)
    }

    func testMaterialAndHigherCourtLinksRemainSupported() async throws {
        let materialURL = url(
            "https://court--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=51&case_uid=material-guid&delo_id=1610001&new=0")
        let district = DistrictCourt(
            title: "Условный районный суд", domain: "court.komi.sudrf.ru",
            code: "11RS0002", regionCode: "komi", kind: .district,
            portalSubject: "11")
        let material = (try await stubResolver(
            responseURL: materialURL,
            card: CaseCard(rawText: "", actText: nil,
                           uid: "11RS0002-01-2026-000007-00", caseNumber: "13-7/2026"),
            courts: [district]
        ).resolve(materialURL.absoluteString)).context

        XCTAssertEqual(material.cartotekaId, "m")
        XCTAssertEqual(material.baseInstanceLevel, .material)
        XCTAssertNotNil(material.sourceKnownCard)

        let appealURL = url(
            "https://2ap.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=61&case_uid=appeal-guid&delo_id=5&new=5")
        let appeal = (try await stubResolver(
            responseURL: appealURL,
            card: CaseCard(rawText: "", actText: nil,
                           uid: "11RS0001-01-2026-000001-00", caseNumber: "66-1/2026")
        ).resolve(appealURL.absoluteString)).context

        XCTAssertEqual(appeal.branch, .general)
        XCTAssertEqual(appeal.courtLevel, .appeal)
        XCTAssertEqual(appeal.cartotekaId, "g2")
        XCTAssertEqual(appeal.region, "Республика Коми")
        XCTAssertTrue(appeal.expandedHigherDomains().contains("3kas.sudrf.ru"))

        let cassationURL = url(
            "https://3kas.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=71&case_uid=cassation-guid&delo_id=2800001&new=2800001")
        let cassation = (try await stubResolver(
            responseURL: cassationURL,
            card: CaseCard(rawText: "", actText: nil,
                           uid: "11RS0001-01-2026-000001-00", caseNumber: "8Г-1/2026")
        ).resolve(cassationURL.absoluteString)).context

        XCTAssertEqual(cassation.branch, .general)
        XCTAssertEqual(cassation.courtLevel, .cassation)
        XCTAssertEqual(cassation.cartotekaId, "g3")
        XCTAssertEqual(cassation.region, "Республика Коми")

        let militaryCassationURL = url(
            "https://vkas.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=81&case_uid=military-cassation-guid&delo_id=5&new=2800001")
        let militaryCassation = (try await stubResolver(
            responseURL: militaryCassationURL,
            card: CaseCard(rawText: "", actText: nil,
                           uid: "54GV0001-01-2026-000001-00", caseNumber: "8Г-1/2026")
        ).resolve(militaryCassationURL.absoluteString)).context

        XCTAssertEqual(militaryCassation.branch, .military)
        XCTAssertEqual(militaryCassation.courtLevel, .cassation)
        XCTAssertEqual(militaryCassation.cartotekaId, "g3")
        XCTAssertEqual(militaryCassation.region, "Новосибирская область")
    }

    func testUnsupportedSourcesAndListingsHaveDistinctResolutionErrors() async {
        let resolver = DirectCaseLinkResolver(
            fetchCard: { _ in throw ResolverStubError.fetchCalled },
            districtCourts: { _ in [] })
        let cases: [(String, DirectCaseLinkResolutionError)] = [
            ("https://1.komi.msudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=1&delo_id=1540005",
             .unsupportedMagistrate),
            ("https://mos-gorsud.ru/modules.php?name=sud_delo&name_op=case&case_id=1&delo_id=1540005",
             .unsupportedMosGorSud),
            ("https://vsrf.ru/modules.php?name=sud_delo&name_op=case&case_id=1&delo_id=1540005",
             .unsupportedVSRF),
            ("https://court--komi.sudrf.ru/modules.php?name=sud_delo&name_op=r&case_id=1&delo_id=1540005",
             .notACaseCard)
        ]

        for (rawValue, expected) in cases {
            do {
                _ = try await resolver.resolve(rawValue)
                XCTFail("expected \(expected) for \(rawValue)")
            } catch let error as DirectCaseLinkResolutionError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error \(error) for \(rawValue)")
            }
        }
    }

    func testDeletedCardHasDedicatedError() async {
        let resolver = DirectCaseLinkResolver(
            fetchCard: { _ in throw SudrfError.http(status: 404) },
            districtCourts: { _ in [] })
        let rawURL = "https://court--komi.sudrf.ru/modules.php"
            + "?name=sud_delo&name_op=case&case_id=1&delo_id=1540005"

        do {
            _ = try await resolver.resolve(rawURL)
            XCTFail("expected a deleted-card error")
        } catch let error as DirectCaseLinkResolutionError {
            XCTAssertEqual(error, .cardRemoved)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func stubResolver(responseURL: URL, card: CaseCard,
                              courts: [DistrictCourt] = []) -> DirectCaseLinkResolver {
        DirectCaseLinkResolver(
            fetchCard: { _ in SudrfCaseCardFetchResult(card: card, responseURL: responseURL) },
            districtCourts: { _ in courts })
    }

    private func url(_ value: String) -> URL {
        URL(string: value)!
    }
}

private enum ResolverStubError: Error, Sendable {
    case fetchCalled
}
