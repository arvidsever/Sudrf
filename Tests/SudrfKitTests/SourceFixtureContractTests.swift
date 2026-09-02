import Foundation
import XCTest
@testable import SudrfKit

@MainActor
final class SourceFixtureContractTests: XCTestCase {

    func testCatalogIntegrityAndMetadataSafety() throws {
        let catalog = try SourceFixtureCatalog.load()
        let records = catalog.manifest.fixtures
        let missing = catalog.manifest.missing
        let allIDs = records.map(\.id) + missing.map(\.id)

        XCTAssertEqual(Set(allIDs).count, allIDs.count, "fixture and missing IDs must be unique")
        XCTAssertTrue(records.allSatisfy { $0.contractLevel == .L1 })
        XCTAssertTrue(records.allSatisfy { $0.relatedIssue == 181 })
        XCTAssertFalse(missing.isEmpty, "unavailable real captures must remain visible")
        XCTAssertTrue(missing.allSatisfy {
            !($0.reason ?? "").isEmpty && !($0.pathologies ?? []).isEmpty
        })

        let forbiddenQueryNames = [
            "captcha", "captchaid", "captcha-response", "token", "cookie",
            "authorization", "password"
        ]
        for fixture in records {
            let artifacts = try catalog.loadArtifacts(for: fixture)
            XCTAssertFalse(artifacts.isEmpty, fixture.id)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: try catalog.expectedURL(for: fixture).path), fixture.id)
            for artifact in fixture.artifacts {
                guard let request = artifact.request,
                      let components = URLComponents(string: request.url) else { continue }
                XCTAssertNil(components.user, fixture.id)
                XCTAssertNil(components.password, fixture.id)
                let names = Set((components.queryItems ?? []).map { $0.name.lowercased() })
                XCTAssertTrue(names.isDisjoint(with: forbiddenQueryNames),
                              "\(fixture.id): secret-bearing query metadata")
            }
            switch fixture.redaction.status {
            case "none":
                XCTAssertNil(fixture.redaction.originalSHA256, fixture.id)
            case "applied":
                XCTAssertNotNil(fixture.redaction.originalSHA256, fixture.id)
                XCTAssertNotEqual(fixture.redaction.originalSHA256,
                                  fixture.redaction.committedSHA256, fixture.id)
            default:
                XCTFail("\(fixture.id): unknown redaction status")
            }
        }
    }

    /// One serial runner keeps the URLProtocol replay registry deterministic
    /// even when XCTest enables parallel test execution for the target.
    func testLevel1ManifestFixturesOffline() async throws {
        let catalog = try SourceFixtureCatalog.load()

        let runner = SourceFixtureRunnerSupport(catalog: catalog)
        for fixture in catalog.manifest.fixtures {
            let activityName = "[\(fixture.contractLevel.rawValue)] \(fixture.id)"
            do {
                let actual = try await runner.run(fixture)
                let expectedData = try Data(contentsOf: catalog.expectedURL(for: fixture))

                XCTContext.runActivity(named: activityName) { activity in
                    activity.add(XCTAttachment(string: summary(of: fixture)))
                    do {
                        switch fixture.expected.kind {
                        case .caseMovement:
                            let expected = try expectedDecoder().decode(
                                CaseMovement.self, from: expectedData)
                            guard case .movement(let value) = actual else {
                                XCTFail("\(activityName): runner returned SourceAttempt; expected CaseMovement")
                                return
                            }
                            XCTAssertEqual(value, expected,
                                           "\(activityName): normalized movement mismatch")

                        case .sourceAttempt:
                            let expected = try expectedDecoder().decode(
                                SourceAttempt.self, from: expectedData)
                            guard case .attempt(var value) = actual else {
                                XCTFail("\(activityName): runner returned CaseMovement; expected SourceAttempt")
                                return
                            }
                            // Dates in a source attempt describe observation time,
                            // not parser output. Use the deterministic date stored
                            // in the expected artifact before the Equatable check.
                            value.provenance.observedAt = expected.provenance.observedAt
                            XCTAssertEqual(value, expected,
                                           "\(activityName): source outcome mismatch")
                        }
                    } catch {
                        XCTFail("\(activityName): expected artifact could not be decoded: \(error)")
                    }
                }
            } catch {
                XCTFail("\(activityName): \(error)")
            }
        }
    }

    func testReplayRejectsUnexpectedRequestWithFixtureIDAndURL() async throws {
        let fixtureID = "replay-unexpected-request"
        let url = try XCTUnwrap(URL(string: "https://unexpected.example.invalid/path"))
        let session = try SourceFixtureReplayURLProtocol.install(
            fixtureID: fixtureID, effectiveHost: "unexpected.example.invalid",
            artifacts: [], statusCode: 200, contentType: "text/html")
        defer {
            session.invalidateAndCancel()
            SourceFixtureReplayURLProtocol.uninstall(fixtureID: fixtureID)
        }

        do {
            _ = try await session.data(for: URLRequest(url: url))
            XCTFail("unexpected replay request should fail")
        } catch {
            let message = (error as NSError).localizedDescription
            XCTAssertTrue(message.contains(fixtureID), message)
            XCTAssertTrue(message.contains(url.absoluteString), message)
        }
    }

    func testReplayIsByteForByteDeterministic() async throws {
        let catalog = try SourceFixtureCatalog.load()
        let runner = SourceFixtureRunnerSupport(catalog: catalog)

        for fixture in catalog.manifest.fixtures {
            let expectedData = try Data(contentsOf: catalog.expectedURL(for: fixture))
            let expectedDate: Date? = fixture.expected.kind == .sourceAttempt
                ? try expectedDecoder().decode(SourceAttempt.self, from: expectedData)
                    .provenance.observedAt
                : nil
            let first = try await runner.run(fixture)
            let second = try await runner.run(fixture)
            XCTAssertEqual(
                try canonicalData(first, observedAt: expectedDate),
                try canonicalData(second, observedAt: expectedDate),
                "[L1] \(fixture.id): repeated replay changed normalized bytes")
        }
    }

    func testCP1251FixtureStaysRawAndDecodesStrictly() throws {
        let catalog = try SourceFixtureCatalog.load()
        let fixture = try XCTUnwrap(catalog.manifest.fixtures.first {
            $0.id == "sudrf-cp1251-captcha-form"
        })
        let artifact = try XCTUnwrap(catalog.loadArtifacts(for: fixture).first)

        XCTAssertNil(String(data: artifact.data, encoding: .utf8))
        XCTAssertTrue(artifact.text.contains("Проверочный код"))
    }

    private func summary(of fixture: SourceFixtureRecord) -> String {
        let pathologies = fixture.pathologies.joined(separator: ", ")
        return "portal=\(fixture.portalFamily); requested=\(fixture.requestedHost); "
            + "effective=\(fixture.effectiveHost); charset=\(fixture.charset); "
            + "pathologies=[\(pathologies)]"
    }

    private func expectedDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func canonicalData(_ result: SourceFixtureResult,
                               observedAt: Date?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        switch result {
        case .movement(let value):
            return try encoder.encode(value)
        case .attempt(var value):
            if let observedAt { value.provenance.observedAt = observedAt }
            return try encoder.encode(value)
        }
    }
}
