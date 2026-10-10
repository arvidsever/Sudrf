// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0

import Foundation

/// Private local persistence for the already-sanitized per-host health facts.
struct SourceHealthIndex {
    private static let schemaVersion = 1

    private struct Snapshot: Codable {
        let version: Int
        let hosts: [String: SourceHealthState.HostState]
    }

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL ?? support
            .appendingPathComponent("Sudrf", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("source-health-index.json")
    }

    func load() throws -> SourceHealthState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SourceHealthState()
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.version == Self.schemaVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                debugDescription: "Unsupported source health index version"))
        }
        var state = SourceHealthState()
        for (host, savedState) in snapshot.hosts {
            state.restore(savedState, for: host)
        }
        return state
    }

    func save(_ state: SourceHealthState) throws {
        let snapshot = Snapshot(version: Self.schemaVersion, hosts: state.hosts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
