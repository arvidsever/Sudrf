import Foundation
import XCTest
@testable import SudrfKit

/// Opt-in, single-case smoke test. Without its private input path it skips
/// before constructing a client, so ordinary CI never contacts mos-sud.ru.
final class MoscowMagistrateKoAPLiveTests: XCTestCase {
    private struct Input: Decodable {
        let uid: String
        let unitPathID: String
        let caseNumber: String
    }

    func testPinnedUIDSearchThenFetchReturnedNativeCard() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUDRF_MOS_SUD_LIVE_INPUT"],
              !path.isEmpty else {
            throw XCTSkip("Live smoke is disabled unless a private input file is supplied.")
        }

        let inputURL = URL(fileURLWithPath: path).standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: inputURL.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              (permissions.intValue & 0o777) == 0o600,
              let data = try? Data(contentsOf: inputURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["uid", "unitPathID", "caseNumber"]),
              let input = try? JSONDecoder().decode(Input.self, from: data),
              input.uid.range(
                  of: #"^\d{2}[A-ZА-Я]{2}\d{4}-\d{2}-\d{4}-\d{6}-\d{2}$"#,
                  options: .regularExpression) != nil,
              input.unitPathID.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
              Int(input.unitPathID).map({ $0 > 0 }) == true,
              MoscowMagistrateKoAPNumber.matchesPublishedNumber(input.caseNumber, input.caseNumber) else {
            XCTFail("The private live input is missing, unsafe, or malformed; values are omitted.")
            return
        }

        guard let cartoteka = CartotekaRegistry.find(level: .magistrate, id: "adm") else {
            XCTFail("The Moscow magistrate administrative cartoteka is unavailable.")
            return
        }
        let court = Court(domain: "mos-sud.ru", title: "Мировые судьи Москвы", level: .magistrate)
        // The default initializer keeps the production strict TLS, ephemeral
        // cookie/cache-free session, two-second throttle and bounded retry policy.
        let client = MoscowMagistrateKoAPClient()

        let outcome: SourceOutcome<[CaseSearchResult]>
        do {
            outcome = try await client.searchForUnit(
                court: court, cartoteka: cartoteka, unitPathID: input.unitPathID,
                field: .uid, value: input.uid, operation: .search)
        } catch {
            XCTFail("The live UID search request failed (\(safeErrorTag(error))).")
            return
        }

        let rows: [CaseSearchResult]
        let searchOutcome: String
        switch outcome {
        case .partial(let value?, _):
            rows = value
            searchOutcome = "partial"
        case .usableSnapshot(let value, _):
            rows = value
            searchOutcome = "usableSnapshot"
        case .captcha:
            XCTFail("The live search reached CAPTCHA; no solving or retry is attempted.")
            return
        case .maintenance:
            XCTFail("The live search endpoint reported maintenance.")
            return
        case .transportFailure:
            XCTFail("The live search transport did not return a usable response.")
            return
        case .parserFailure:
            XCTFail("The live search response did not satisfy the expected result contract.")
            return
        case .partial(nil, _), .honestZero(_):
            XCTFail("The live search did not return candidate rows for the pinned UID.")
            return
        }
        print("SUDRF106_STAGE=search outcome=\(searchOutcome) candidateRows=\(rows.count)")

        let candidates = rows.enumerated().map { index, row in
            let url = row.cardURL
            let locator = url.flatMap {
                SourceNativeCardLocator.moscowMagistrateKoAP(url: $0, cartoteka: cartoteka)
            }
            let nativeRouteMatches = locator != nil
            let unitMatches = locator?.courtKey == input.unitPathID
            let numberMatches = MoscowMagistrateKoAPNumber.matchesPublishedNumber(
                row.caseNumber, input.caseNumber)
            let uidPublished = row.caseUID != nil
            let rowUIDMatches = row.caseUID.map {
                $0.caseInsensitiveCompare(input.uid) == .orderedSame
            } ?? true
            let exact = nativeRouteMatches && unitMatches && numberMatches && rowUIDMatches
            print("SUDRF106_STAGE=candidate index=\(index) hasCardURL=\(url != nil) nativeRoute=\(nativeRouteMatches) unitMatch=\(unitMatches) numberMatch=\(numberMatches) uidPresent=\(uidPublished) uidConsistent=\(rowUIDMatches) exact=\(exact)")
            return (row: row, locator: locator, exact: exact)
        }
        let exactRows = candidates.filter(\.exact)
        guard exactRows.count == 1,
              let candidate = exactRows.first,
              let returnedURL = candidate.row.cardURL,
              let returnedLocator = candidate.locator else {
            XCTFail("The UID search did not produce one exact result for the selected native unit.")
            return
        }
        let result = candidate.row

        let fetched: SudrfCaseCardFetchResult
        do {
            // Fetch only the URL returned by this exact live search result.
            fetched = try await client.fetchCardWithResponseURL(url: returnedURL)
        } catch {
            XCTFail("Fetching the returned native card failed (\(safeErrorTag(error))).")
            return
        }

        let fetchedLocator = SourceNativeCardLocator.moscowMagistrateKoAP(
            url: fetched.responseURL, cartoteka: cartoteka)
        let nativeIdentityMatches = fetchedLocator?.identity == returnedLocator.identity
        let unitMatches = fetchedLocator?.courtKey == input.unitPathID
        let uidMatches = fetched.card.uid?.caseInsensitiveCompare(input.uid) == .orderedSame
        let numberMatches = fetched.card.caseNumber.map {
            MoscowMagistrateKoAPNumber.matchesPublishedNumber($0, input.caseNumber)
        } == true
        let hasUsefulDetails = !fetched.card.sessions.isEmpty
            || !(fetched.card.result?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        print("SUDRF106_STAGE=card nativeIdentity=\(nativeIdentityMatches) unit=\(unitMatches) uid=\(uidMatches) number=\(numberMatches) usefulDetail=\(hasUsefulDetails)")
        XCTAssertTrue(nativeIdentityMatches,
                      "The fetched response must retain the search result's native identity.")
        XCTAssertTrue(unitMatches,
                      "The fetched card must stay in the selected native unit.")
        XCTAssertTrue(uidMatches,
                      "The fetched card must publish the queried UID.")
        XCTAssertTrue(numberMatches,
                      "The fetched card must publish the pinned case number.")
        XCTAssertTrue(hasUsefulDetails, "The fetched card must contain a session or result detail.")
    }

    private func safeErrorTag(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue))"
        }
        return String(describing: type(of: error))
    }
}
