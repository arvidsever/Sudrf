import Foundation
import SudrfKit

enum BenchmarkSummarySection: String, Codable, CaseIterable, Sendable {
    case claims, partyPositions, circumstances, reasoning, disposition
    case amounts, dates, deadlines, appeal
}

/// Portable fixture format. Real published acts and provider responses stay
/// outside Git; only synthetic examples of this schema are committed.
struct SummaryBenchmarkFixture: Codable, Sendable {
    let id: String
    let caseNumber: String
    let court: String
    let kind: String
    let date: String
    let sourceText: String
    let expectedCriticalValues: [String]
    let requiredSections: [BenchmarkSummarySection]

    var document: ActDocument {
        ActDocument(caseKey: "benchmark:\(id)", sourceActID: id,
                    caseNumber: caseNumber, judicialUID: nil, court: court,
                    instanceLevel: .first, kind: kind, date: date,
                    sourceText: sourceText)
    }
}

struct SummaryBenchmarkResult: Codable, Sendable {
    let fixtureID: String
    let citationCount: Int
    let validCitationCount: Int
    let expectedCriticalCount: Int
    let foundCriticalCount: Int
    let requiredSectionCount: Int
    let completedSectionCount: Int
    let error: String?
}

struct SummaryBenchmarkReport: Codable, Sendable {
    let provider: String
    let model: String
    let generatedAt: Date
    let requestedFixtureCount: Int
    let results: [SummaryBenchmarkResult]

    var successfulFixtureCount: Int { successfulResults.count }
    var failedFixtureIDs: [String] {
        results.compactMap { $0.error == nil ? nil : $0.fixtureID }
    }
    var citationAccuracy: Double {
        ratio(\.validCitationCount, over: \.citationCount)
    }
    var criticalAccuracy: Double {
        ratio(\.foundCriticalCount, over: \.expectedCriticalCount)
    }
    var sectionCompleteness: Double {
        ratio(\.completedSectionCount, over: \.requiredSectionCount)
    }
    var passed: Bool {
        !results.isEmpty
            && results.count == requestedFixtureCount
            && failedFixtureIDs.isEmpty
            && citationAccuracy == 1
            && criticalAccuracy >= 0.95
            && sectionCompleteness >= 0.90
    }

    private var successfulResults: [SummaryBenchmarkResult] {
        results.filter { $0.error == nil }
    }

    private func ratio(_ numerator: KeyPath<SummaryBenchmarkResult, Int>,
                       over denominator: KeyPath<SummaryBenchmarkResult, Int>) -> Double {
        guard !successfulResults.isEmpty else { return 0 }
        let total = successfulResults.reduce(0) { $0 + $1[keyPath: denominator] }
        guard total > 0 else { return 1 }
        let value = successfulResults.reduce(0) { $0 + $1[keyPath: numerator] }
        return Double(value) / Double(total)
    }
}

actor SummaryBenchmarkRunner {
    func loadFixtures(from url: URL) throws -> [SummaryBenchmarkFixture] {
        try JSONDecoder().decode([SummaryBenchmarkFixture].self, from: Data(contentsOf: url))
    }

    func run(fixtures: [SummaryBenchmarkFixture],
             configured: ConfiguredActSummarizer) async -> SummaryBenchmarkReport {
        var results: [SummaryBenchmarkResult] = []
        for fixture in fixtures {
            if Task.isCancelled { break }
            do {
                let document = fixture.document
                let summary = try await configured.summarizer.summarize(
                    document: document, options: configured.options)
                let paragraphs = Dictionary(uniqueKeysWithValues:
                    document.paragraphs.map { ($0.id, $0.text) })
                let citations = summary.allClaims.flatMap(\.citations)
                let validCitations = citations.filter {
                    paragraphs[$0.paragraphID]?.contains($0.evidenceQuote) == true
                }.count
                let searchable = summary.allClaims.map(\.text).joined(separator: "\n")
                let foundCritical = fixture.expectedCriticalValues.filter {
                    searchable.localizedCaseInsensitiveContains($0)
                }.count
                let completed = fixture.requiredSections.filter {
                    !claims(in: $0, summary: summary).isEmpty
                }.count
                results.append(SummaryBenchmarkResult(
                    fixtureID: fixture.id, citationCount: citations.count,
                    validCitationCount: validCitations,
                    expectedCriticalCount: fixture.expectedCriticalValues.count,
                    foundCriticalCount: foundCritical,
                    requiredSectionCount: fixture.requiredSections.count,
                    completedSectionCount: completed, error: nil))
            } catch {
                results.append(SummaryBenchmarkResult(
                    fixtureID: fixture.id, citationCount: 0, validCitationCount: 0,
                    expectedCriticalCount: 0,
                    foundCriticalCount: 0, requiredSectionCount: 0,
                    completedSectionCount: 0, error: error.localizedDescription))
            }
        }
        return SummaryBenchmarkReport(
            provider: configured.provider, model: configured.model,
            generatedAt: Date(), requestedFixtureCount: fixtures.count, results: results)
    }

    private func claims(in section: BenchmarkSummarySection,
                        summary: ActSummary) -> [SummaryClaim] {
        switch section {
        case .claims: summary.claims
        case .partyPositions: summary.partyPositions
        case .circumstances: summary.circumstances
        case .reasoning: summary.reasoning
        case .disposition: summary.disposition
        case .amounts: summary.amounts
        case .dates: summary.dates
        case .deadlines: summary.deadlines
        case .appeal: summary.appeal
        }
    }
}
