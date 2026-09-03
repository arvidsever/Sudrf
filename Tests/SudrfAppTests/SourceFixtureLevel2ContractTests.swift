import CryptoKit
import Foundation
import SudrfKit
import XCTest
@testable import SudrfApp

@MainActor
final class SourceFixtureLevel2ContractTests: XCTestCase {
    private struct Manifest: Decodable {
        var schemaVersion: Int
        var pairs: [Pair]
    }

    private struct Pair: Decodable {
        var id: String
        var portalFamily: String
        var rawArtifactPath: String
        var rawArtifactSHA256: String
        var sourceCardID: String
        var observedAt: Date
        var scenario: String
        var expectedEvents: [CaseEvent]
    }

    func testLevel2ManifestUsesRealHashedArtifactsAndDerivesExpectedEvents() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(Set(manifest.pairs.map(\.id)).count, manifest.pairs.count)
        XCTAssertEqual(Set(manifest.pairs.map(\.portalFamily)), ["sudrf", "ksoyu", "msudrf"])

        for pair in manifest.pairs {
            let raw = try loadRaw(pair)
            let input = try snapshots(pair: pair, raw: raw)
            let first = CaseEventDeriver.derive(
                old: input.old, new: input.new,
                attempt: SourceAttempt(
                    kind: .usableSnapshot,
                    provenance: .init(operation: .movement,
                                      sourceFamily: pair.portalFamily,
                                      host: host(from: pair.sourceCardID),
                                      observedAt: pair.observedAt)),
                observedAt: pair.observedAt)
            let second = CaseEventDeriver.derive(
                old: input.old, new: input.new,
                attempt: SourceAttempt(
                    kind: .usableSnapshot,
                    provenance: .init(operation: .movement,
                                      sourceFamily: pair.portalFamily,
                                      host: host(from: pair.sourceCardID),
                                      observedAt: pair.observedAt)),
                observedAt: pair.observedAt)
            XCTContext.runActivity(named: "[L2] \(pair.id)") { _ in
                XCTAssertEqual(first.events, pair.expectedEvents)
                XCTAssertEqual(first.diagnostics, [])
                XCTAssertEqual(first.events, second.events,
                               "semantic replay must be byte-for-byte deterministic")
            }
        }
    }

    private func snapshots(pair: Pair, raw: Data) throws
        -> (old: CaseSnapshot, new: CaseSnapshot) {
        let html = try XCTUnwrap(String(data: raw, encoding: .utf8), pair.id)
        switch pair.scenario {
        case "explicitPostponementAndSingleNewDate":
            let card = try CaseCardParser.parse(html: html)
            let postponed = try XCTUnwrap(card.sessions.first {
                $0.date == "31.03.2025" && ($0.result ?? "").contains("отложено")
            })
            let next = try XCTUnwrap(card.sessions.first { $0.date == "11.04.2025" })
            var before = postponed
            before.result = nil
            return (
                snapshot(source: pair.sourceCardID, sessions: [before]),
                snapshot(source: pair.sourceCardID, sessions: [postponed, next]))

        case "publishedAct":
            let card = try CaseCardParser.parse(html: html)
            XCTAssertFalse((card.actText ?? "").isEmpty, pair.id)
            let act = StoredActObservation(
                sourceCardID: pair.sourceCardID,
                sourceActID: "fixture:\(pair.rawArtifactSHA256)",
                title: "Определение", dateRaw: card.decisionDate ?? "",
                court: "Второй кассационный суд общей юрисдикции",
                levelRaw: CaseInstance.Level.cassation.rawValue)
            return (snapshot(source: pair.sourceCardID),
                    snapshot(source: pair.sourceCardID, acts: [act]))

        case "instanceDiscovered":
            let court = Court(domain: "petrozavodskoj.komi.msudrf.ru",
                              title: "Судебный участок", level: .magistrate)
            let row = try XCTUnwrap(
                MagistrateResultsParser.parse(html: html, court: court).first)
            XCTAssertEqual(row.caseID, "900000001", pair.id)
            let instance = StoredInstanceObservation(
                sourceCardID: pair.sourceCardID,
                levelRaw: CaseInstance.Level.first.rawValue,
                court: court.title, caseNumber: row.caseNumber,
                judge: row.judge, result: row.result)
            return (snapshot(source: nil, instances: []),
                    snapshot(source: pair.sourceCardID, instances: [instance]))

        default:
            throw NSError(domain: "SourceFixtureLevel2ContractTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unknown scenario \(pair.scenario)"])
        }
    }

    private func snapshot(source: String?, sessions: [CaseSession] = [],
                          instances: [StoredInstanceObservation]? = nil,
                          acts: [StoredActObservation] = []) -> CaseSnapshot {
        let storedSessions = sessions.map {
            StoredSession(dateRaw: $0.date, time: $0.time, room: $0.room,
                          event: $0.event, result: $0.result, court: "Суд",
                          judge: nil, levelRaw: CaseInstance.Level.first.rawValue,
                          caseNumber: nil, sourceCardID: source)
        }
        let defaultInstances = source.map {
            [StoredInstanceObservation(sourceCardID: $0, levelRaw: "first",
                                       court: "Суд", caseNumber: "2-1/2025",
                                       judge: nil, result: nil)]
        } ?? []
        return CaseSnapshot(
            uid: "", inForce: false, category: nil, partiesShort: "",
            leadCharges: nil, secondPartyLine: nil, stageRaw: "first", stageTag: "",
            statusText: "", statusChipRaw: "gray", lastEvent: "", nextEvent: "",
            nextChipRaw: "gray", steps: [], sessions: storedSessions, deadlines: [],
            deadlineAssessments: nil, actsFingerprint: nil,
            semanticProjectionVersion: CaseEventJournal.currentDerivationVersion,
            instanceObservations: instances ?? defaultInstances,
            actObservations: acts, complaintObservations: [])
    }

    private func loadManifest() throws -> Manifest {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "l2-index", withExtension: "json",
            subdirectory: "Fixtures/source-contract"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: Data(contentsOf: url))
    }

    private func loadRaw(_ pair: Pair) throws -> Data {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("../SudrfKitTests/Fixtures")
            .appendingPathComponent(pair.rawArtifactPath).standardizedFileURL
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, pair.rawArtifactSHA256, pair.id)
        return data
    }

    private func host(from sourceCardID: String) -> String {
        sourceCardID.split(separator: "|").dropFirst().first.map(String.init) ?? ""
    }
}
