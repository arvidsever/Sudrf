import Foundation
import Observation
import SudrfKit

@Observable @MainActor
final class PublishedActSelection {
    typealias Fetch = @Sendable (URL, String?) async throws -> PublishedActFile
    typealias Apply = @MainActor @Sendable (
        String, String, String, PublishedActFile
    ) -> Void

    private struct Request {
        let caseKey: String
        let selectedActID: String
        let sourceActID: String
        let url: URL
        let productionNumber: String?
        let cachedProvenance: PublishedActProvenance?
        let existingText: String?
        let apply: Apply

        func sameInput(as other: Request) -> Bool {
            caseKey == other.caseKey
                && selectedActID == other.selectedActID
                && sourceActID == other.sourceActID
                && url == other.url
                && productionNumber == other.productionNumber
                && cachedProvenance?.contentHash == other.cachedProvenance?.contentHash
        }
    }

    private static let sharedCache = ActFileCache()

    private(set) var selectedCaseKey: String?
    private(set) var selectedActID: String?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var data: Data?
    private(set) var text: String?
    private(set) var fileURL: URL?
    private(set) var provenance: PublishedActProvenance?

    @ObservationIgnored private let cache: ActFileCache
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(cache: ActFileCache? = nil, fetch: Fetch? = nil) {
        self.cache = cache ?? Self.sharedCache
        if let fetch {
            self.fetch = fetch
        } else {
            let client = VSRFClient()
            self.fetch = { url, number in
                try await client.fetchPublishedAct(
                    url: url, expectedProductionNumber: number)
            }
        }
    }

    func select(caseKey: String, selectedActID: String, sourceAct: CaseAct,
                existingText: String?, apply: @escaping Apply) {
        guard let candidate = sourceAct.sourceFileURL ?? sourceAct.fileProvenance?.sourceURL else {
            clear()
            return
        }

        let identityChanged = selectedCaseKey != caseKey || self.selectedActID != selectedActID
        let inputURL = PublishedActURLPolicy.isAllowedVSRFPublishedAct(candidate)
            ? PublishedActURLPolicy.safePublishedURL(candidate) : nil
        selectedCaseKey = caseKey
        self.selectedActID = selectedActID
        guard let inputURL else {
            cancelTask()
            request = nil
            isLoading = false
            data = nil
            text = existingText?.nonEmpty
            fileURL = nil
            provenance = sourceAct.fileProvenance
            error = PublishedActFileError.unsafeSourceURL.localizedDescription
            return
        }

        let next = Request(
            caseKey: caseKey,
            selectedActID: selectedActID,
            sourceActID: sourceAct.id,
            url: inputURL,
            productionNumber: sourceAct.productionNumber,
            cachedProvenance: sourceAct.fileProvenance,
            existingText: existingText?.nonEmpty,
            apply: apply)
        if !identityChanged, let current = request, current.sameInput(as: next),
           isLoading || data != nil || error != nil {
            request = next
            return
        }

        request = next
        text = existingText?.nonEmpty
        provenance = sourceAct.fileProvenance
        data = nil
        fileURL = nil
        error = nil
        start(next)
    }

    func retry() {
        guard let request, !isLoading else { return }
        error = nil
        data = nil
        fileURL = nil
        start(request)
    }

    func clear() {
        cancelTask()
        request = nil
        selectedCaseKey = nil
        selectedActID = nil
        isLoading = false
        error = nil
        data = nil
        text = nil
        fileURL = nil
        provenance = nil
    }

    private func start(_ request: Request) {
        cancelTask()
        generation &+= 1
        let currentGeneration = generation
        isLoading = true
        task = Task { [weak self] in
            await self?.load(request, generation: currentGeneration)
        }
    }

    private func load(_ request: Request, generation: Int) async {
        do {
            let file: PublishedActFile
            let localURL: URL?
            if let cached = request.cachedProvenance,
               let cachedData = await cache.load(provenance: cached),
               let cachedURL = await cache.fileURL(provenance: cached) {
                file = PublishedActFile(text: request.existingText ?? "",
                                        provenance: cached, data: cachedData)
                localURL = cachedURL
            } else {
                file = try await fetch(request.url, request.productionNumber)
                try Task.checkCancellation()
                _ = try await cache.save(file: file)
                localURL = await cache.fileURL(provenance: file.provenance)
            }

            try Task.checkCancellation()
            guard isCurrent(request, generation: generation) else { return }
            data = file.data
            text = file.text.nonEmpty
            provenance = file.provenance
            fileURL = localURL
            if localURL == nil {
                error = "Скачанный акт не удалось сохранить в кэш файлов."
            }
            request.apply(request.caseKey, request.selectedActID,
                          request.sourceActID, file)
        } catch {
            guard isCurrent(request, generation: generation) else { return }
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
        guard isCurrent(request, generation: generation) else { return }
        isLoading = false
        task = nil
    }

    private func isCurrent(_ request: Request, generation: Int) -> Bool {
        self.generation == generation
            && selectedCaseKey == request.caseKey
            && selectedActID == request.selectedActID
            && self.request?.sameInput(as: request) == true
    }

    private func cancelTask() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
