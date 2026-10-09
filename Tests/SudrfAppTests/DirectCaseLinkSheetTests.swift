import XCTest
@testable import SudrfKit
@testable import CaptchaSolver
@testable import SudrfApp

final class DirectCaseLinkSheetTests: XCTestCase {

    private struct PersistedMovementInstance: Equatable {
        let level: String
        let court: String
        let caseNumber: String
        let domain: String
        let foundByUID: Bool
        let hasCaptchaForm: Bool
        let sourceURL: String?
    }

    private struct PersistedDirectLinkState: Equatable {
        let key: String
        let count: Int
        let context: MovementContext?
        let collections: [String]
        let seenAt: Date?
        let eventIDs: [String]
        let movementInstances: [PersistedMovementInstance]
        let movementFetchedAt: Date?
        let sourceRefreshAttemptKind: SourceOutcomeKind?
    }

    private actor LinkedCourtMovement: MovementProviding {
        let snapshots: [CaseMovement]
        private(set) var calls = 0
        private(set) var autoSolveHosts: [String] = []

        init(_ snapshots: [CaseMovement]) { self.snapshots = snapshots }

        func recordAutoSolve(host: String) {
            autoSolveHosts.append(host)
        }

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            defer { calls += 1 }
            return snapshots[min(calls, snapshots.count - 1)]
        }
    }

    private func context() -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001",
            cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-91/2026")
    }

    @MainActor
    func testPreviewProjectsAllConfirmationFieldsAndMissingValues() {
        let preview = DirectCaseLinkPreview(
            context: context(),
            caseNumber: " 2-91/2026 ",
            courtTitle: "Сыктывкарский городской суд",
            judicialUID: "11RS0001-01-2026-000091-00",
            category: "",
            judge: nil,
            result: "Решение")

        XCTAssertEqual(preview.fields.map(\.0),
                       ["Номер дела", "Суд", "УИД", "Категория", "Судья", "Результат"])
        XCTAssertEqual(preview.fields.map(\.1), [
            "2-91/2026",
            "Сыктывкарский городской суд",
            "11RS0001-01-2026-000091-00",
            "—",
            "—",
            "Решение"
        ])
    }

    func testSheetStateKeepsOnlyResolvedPreviewAfterInput() {
        let preview = DirectCaseLinkPreview(
            context: context(), caseNumber: "2-91/2026",
            courtTitle: "Сыктывкарский городской суд")

        XCTAssertEqual(DirectCaseLinkSheetState.input,
                       DirectCaseLinkSheetState.input)
        XCTAssertEqual(DirectCaseLinkSheetState.resolving,
                       DirectCaseLinkSheetState.resolving)
        XCTAssertEqual(DirectCaseLinkSheetState.preview(preview),
                       DirectCaseLinkSheetState.preview(preview))
        XCTAssertEqual(DirectCaseLinkSheetState.failed("Ошибка"),
                       DirectCaseLinkSheetState.failed("Ошибка"))

        var stalePreview = DirectCaseLinkSheetState.preview(preview)
        stalePreview.invalidateForChangedInput()
        XCTAssertEqual(stalePreview, .input)
    }

    @MainActor
    func testTrackReturnsPersistentKeyAndExactContextReusesIt() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let context = context()

        let firstKey = try XCTUnwrap(router.track(context: context, movement: nil))
        let secondKey = try XCTUnwrap(router.track(context: context, movement: nil))
        XCTAssertEqual(secondKey, firstKey)
        XCTAssertEqual(router.cases.count, 1)
    }

    @MainActor
    func testHigherCourtURLReusesSearchTrackedLogicalCaseByJudicialUID() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        var first = context()
        first.caseID = "first-card-id"
        first.caseUID = "first-card-guid"
        first.judicialUID = "11RS0001-01-2026-000091-00"
        let firstKey = try XCTUnwrap(router.track(context: first, movement: nil))

        var appeal = MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Республика Коми",
            searchDomain: "vs--komi.sudrf.ru",
            displayDomain: "vs.komi.sudrf.ru",
            courtTitle: "Верховный суд Республики Коми",
            courtLevelRaw: CourtLevel.subject.rawValue,
            courtCode: nil,
            cartotekaId: "g2",
            cartotekaLevelRaw: CourtLevel.subject.rawValue,
            caseNumber: "33-91/2026",
            caseID: "appeal-card-id",
            caseUID: "appeal-card-guid")
        appeal.judicialUID = first.judicialUID
        appeal.baseInstanceLevelRaw = CaseInstance.Level.appeal.rawValue

        XCTAssertEqual(try XCTUnwrap(router.track(context: appeal, movement: nil)), firstKey)
        XCTAssertEqual(router.cases.count, 1)

        let store = try TrackedStore(container: container, prepared: true)
        let record = try XCTUnwrap(store.record(forKey: firstKey))
        let state = try JSONDecoder().decode(
            LogicalCaseState.self, from: XCTUnwrap(record.identityStateData))
        XCTAssertTrue(state.cards.contains {
            $0.identity.sourceNativeID == "appeal-card-id"
        })
    }

    @MainActor
    func testConfirmDirectLinkContinuesTwoCaptchasAfterSheetClosesAndSurvivesColdReopen()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-339-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let restoreTestDefaults = try isolateTestProcessPreferences()
        defer { restoreTestDefaults() }
        let settings = CaptchaSettings.shared
        guard settings.isEffectivelyEnabled else {
            throw XCTSkip("авторегистрация CAPTCHA отключена в тестовом домене")
        }

        let resolution = try await Self.resolveIssue321DirectLink()
        let ctx = resolution.context
        XCTAssertEqual(resolution.caseNumber, "12-538/2026")
        XCTAssertEqual(resolution.judicialUID, "78RS0001-01-2026-002203-86")
        XCTAssertEqual(ctx.cardURLString, Self.issue321CardURL.absoluteString)
        XCTAssertEqual(ctx.sourceKnownCard?.caseID, "958679833")
        XCTAssertEqual(ctx.sourceKnownCard?.caseUID,
                       "976b38ad-eb63-425e-93d5-b15fa7df355d")

        let service = LinkedCourtMovement(try makeCaptchaSequence(for: ctx))
        let subjectDomain = try XCTUnwrap(ctx.higherCourtTargets?.first {
            $0.courtLevel == .subject
        }?.domain)
        let cassationDomain = try XCTUnwrap(ctx.higherCourtTargets?.first {
            $0.courtLevel == .cassation
        }?.domain)
        let seed = CaseEvent.make(
            kind: .complaintRegistered, occurrence: ["issue-339-existing-event"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())
        let seededSeenAt = Date(timeIntervalSinceReferenceDate: 42)
        let savedTokens = await captureAndClearCaptchaTokens(
            domains: [ctx.searchDomain, ctx.displayDomain] + ctx.expandedHigherDomains())
        do {
            let first = try await importAndRefreshBeforeColdReopen(
                context: ctx, storeURL: storeURL, settings: settings,
                service: service, seed: seed, seenAt: seededSeenAt)

            let firstCalls = await service.calls
            XCTAssertEqual(firstCalls, 3)
            XCTAssertEqual(first.count, 1)
            XCTAssertEqual(first.context, ctx)
            XCTAssertEqual(first.collections, ["Приёмка #339"])
            XCTAssertEqual(first.seenAt, seededSeenAt)
            XCTAssertEqual(first.eventIDs.filter { $0 == seed.id }.count, 1)
            XCTAssertEqual(Set(first.eventIDs).count, first.eventIDs.count)
            XCTAssertEqual(first.movementFetchedAt, nil)
            XCTAssertEqual(first.sourceRefreshAttemptKind, .partial)
            let firstSolveHosts = await service.autoSolveHosts
            XCTAssertEqual(firstSolveHosts, [subjectDomain, cassationDomain])
            let subjectSourceURL = subjectCardSourceURL(domain: subjectDomain).absoluteString
            assertFinalMovement(
                in: first, baseDomain: ctx.searchDomain,
                subjectDomain: subjectDomain, cassationDomain: cassationDomain,
                subjectSourceURL: subjectSourceURL)

            let reopened = try await coldReopenAndReimport(
                context: ctx, storeURL: storeURL, settings: settings,
                service: service, expected: first)
            XCTAssertEqual(reopened.count, 1)
            XCTAssertEqual(reopened.key, first.key)
            XCTAssertEqual(reopened.context, first.context)
            XCTAssertEqual(reopened.collections, first.collections)
            XCTAssertEqual(reopened.eventIDs, first.eventIDs)
            XCTAssertEqual(Set(reopened.eventIDs).count, reopened.eventIDs.count)
            XCTAssertEqual(reopened.sourceRefreshAttemptKind, .partial)
            assertFinalMovement(
                in: reopened, baseDomain: ctx.searchDomain,
                subjectDomain: subjectDomain, cassationDomain: cassationDomain,
                subjectSourceURL: subjectSourceURL)

            let repeatedCalls = await service.calls
            XCTAssertEqual(repeatedCalls, 4)
            let repeatedSolveHosts = await service.autoSolveHosts
            XCTAssertEqual(repeatedSolveHosts, firstSolveHosts)
        } catch {
            await restoreCaptchaTokens(savedTokens)
            throw error
        }
        await restoreCaptchaTokens(savedTokens)
    }

    @MainActor
    private func importAndRefreshBeforeColdReopen(
        context ctx: MovementContext,
        storeURL: URL,
        settings: CaptchaSettings,
        service: LinkedCourtMovement,
        seed: CaseEvent,
        seenAt: Date
    ) async throws -> PersistedDirectLinkState {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        var capturedStore: TrackedStore?
        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true,
            refreshCenterFactory: { store, client in
                capturedStore = store
                return RefreshCenter(
                    store: store, client: client,
                    captchaSolver: CaptchaSolverFactory.make(settings: settings),
                    captchaSettings: settings,
                    autoSolve: { url, _, _, _ in
                        await service.recordAutoSolve(host: url.host ?? "")
                        return AutoCaptchaSolver.SolveResult(
                            token: CaptchaToken(value: "12345", id: url.host ?? ""), png: nil)
                    },
                    serviceBuilder: { _ in service })
            },
            trackedStoreProjectionSynchronizer: { _, _ in })
        router.refreshCenter.repairBeforeRefresh = nil

        let key = try XCTUnwrap(router.addDirectCaseLink(ctx))
        guard router.refreshCenter.isRefreshing(key) else {
            XCTFail("добавление прямой ссылки должно синхронно запустить refresh")
            throw DirectLinkHarnessError.autostartDidNotBegin
        }
        router.closeCase()

        let result = await router.refreshCenter.refresh(key: key)?.value
        XCTAssertTrue(isPartial(result?.outcome),
                      "частичный ответ CAPTCHA-источника должен оставаться partial")
        let record = try XCTUnwrap(capturedStore?.record(forKey: key))
        record.collectionNames = ["Приёмка #339"]
        record.seenAt = seenAt
        record.eventJournal = CaseEventJournal(events: [seed])
        try capturedStore?.save()
        let calls = await service.calls
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(router.cases.count, 1)

        return try persistedState(store: XCTUnwrap(capturedStore), key: key)
    }

    @MainActor
    private func coldReopenAndReimport(
        context ctx: MovementContext,
        storeURL: URL,
        settings: CaptchaSettings,
        service: LinkedCourtMovement,
        expected: PersistedDirectLinkState
    ) async throws -> PersistedDirectLinkState {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let beforeReimport = try persistedState(store: store, key: expected.key)
        XCTAssertEqual(beforeReimport, expected)

        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true,
            refreshCenterFactory: { store, client in
                RefreshCenter(
                    store: store, client: client,
                    captchaSolver: CaptchaSolverFactory.make(settings: settings),
                    captchaSettings: settings,
                    autoSolve: { url, _, _, _ in
                        await service.recordAutoSolve(host: url.host ?? "")
                        return AutoCaptchaSolver.SolveResult(
                            token: CaptchaToken(value: "12345", id: url.host ?? ""), png: nil)
                    },
                    serviceBuilder: { _ in service })
            },
            trackedStoreProjectionSynchronizer: { _, _ in })
        router.refreshCenter.repairBeforeRefresh = nil

        let repeatedImportStartedAt = Date()
        let key = try XCTUnwrap(router.addDirectCaseLink(ctx))
        let repeatedImportFinishedAt = Date()
        XCTAssertEqual(key, expected.key)
        XCTAssertEqual(router.cases.count, 1)
        let stateAfterImport = try persistedState(store: store, key: key)
        XCTAssertEqual(stateAfterImport.count, 1)
        XCTAssertEqual(stateAfterImport.collections, expected.collections)
        XCTAssertEqual(stateAfterImport.eventIDs, expected.eventIDs)
        let seenAtAfterImport = try XCTUnwrap(stateAfterImport.seenAt)
        XCTAssertGreaterThan(seenAtAfterImport, try XCTUnwrap(expected.seenAt))
        XCTAssertGreaterThanOrEqual(seenAtAfterImport, repeatedImportStartedAt)
        XCTAssertLessThanOrEqual(seenAtAfterImport, repeatedImportFinishedAt)
        let result = await router.refreshCenter.refresh(key: expected.key)?.value
        XCTAssertTrue(isPartial(result?.outcome),
                      "повторный refresh после импорта должен оставаться partial")

        let afterReimport = try persistedState(store: store, key: expected.key)
        XCTAssertEqual(afterReimport.count, 1)
        XCTAssertEqual(afterReimport.key, expected.key)
        XCTAssertEqual(afterReimport.context, expected.context)
        XCTAssertEqual(afterReimport.collections, expected.collections)
        XCTAssertEqual(afterReimport.seenAt, seenAtAfterImport)
        XCTAssertEqual(afterReimport.eventIDs, expected.eventIDs)
        XCTAssertEqual(Set(afterReimport.eventIDs).count, afterReimport.eventIDs.count)
        XCTAssertEqual(afterReimport.sourceRefreshAttemptKind, .partial)
        let subjectDomain = try XCTUnwrap(ctx.higherCourtTargets?.first {
            $0.courtLevel == .subject
        }?.domain)
        let cassationDomain = try XCTUnwrap(ctx.higherCourtTargets?.first {
            $0.courtLevel == .cassation
        }?.domain)
        assertFinalMovement(
            in: afterReimport, baseDomain: ctx.searchDomain,
            subjectDomain: subjectDomain, cassationDomain: cassationDomain,
            subjectSourceURL: subjectCardSourceURL(domain: subjectDomain).absoluteString)
        return afterReimport
    }

    @MainActor
    private func persistedState(store: TrackedStore, key: String) throws
        -> PersistedDirectLinkState {
        let record = try XCTUnwrap(store.record(forKey: key))
        return PersistedDirectLinkState(
            key: record.key,
            count: store.all().count,
            context: record.context,
            collections: record.collectionNames,
            seenAt: record.seenAt,
            eventIDs: record.eventJournal?.events.map(\.id) ?? [],
            movementInstances: record.movement?.instances.map {
                PersistedMovementInstance(
                    level: $0.level.rawValue, court: $0.court,
                    caseNumber: $0.caseNumber, domain: $0.domain,
                    foundByUID: $0.foundByUID, hasCaptchaForm: $0.captchaFormURL != nil,
                    sourceURL: $0.sourceURL?.absoluteString)
            } ?? [],
            movementFetchedAt: record.movementFetchedAt,
            sourceRefreshAttemptKind: record.sourceRefreshAttempt?.kind)
    }

    private func assertFinalMovement(in state: PersistedDirectLinkState,
                                     baseDomain: String,
                                     subjectDomain: String,
                                     cassationDomain: String,
                                     subjectSourceURL: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertEqual(state.movementInstances.count, 2, file: file, line: line)
        XCTAssertEqual(state.movementInstances.map(\.domain),
                       [baseDomain, subjectDomain], file: file, line: line)
        XCTAssertFalse(state.movementInstances.contains { $0.domain == cassationDomain },
                       file: file, line: line)
        let subject = state.movementInstances.first { $0.domain == subjectDomain }
        XCTAssertEqual(subject?.caseNumber, "12-538/2026", file: file, line: line)
        XCTAssertEqual(subject?.level, CaseInstance.Level.appeal.rawValue,
                       file: file, line: line)
        XCTAssertEqual(subject?.foundByUID, true, file: file, line: line)
        XCTAssertEqual(subject?.sourceURL, subjectSourceURL, file: file, line: line)
        XCTAssertFalse(state.movementInstances.contains(where: \.hasCaptchaForm),
                       file: file, line: line)
    }

    private struct SavedCaptchaToken {
        let domain: String
        let token: CaptchaToken?
    }

    @MainActor
    private func captureAndClearCaptchaTokens(domains: [String]) async -> [SavedCaptchaToken] {
        var saved = [SavedCaptchaToken]()
        var seenHosts = Set<String>()
        for domain in domains {
            let host = SudrfHost.moduleHost(domain.lowercased())
            guard seenHosts.insert(host).inserted else { continue }
            let token = await CaptchaTokenStore.shared.token(forDomain: domain)
            await CaptchaTokenStore.shared.invalidate(domain: domain)
            saved.append(SavedCaptchaToken(domain: domain, token: token))
        }
        return saved
    }

    @MainActor
    private func restoreCaptchaTokens(_ saved: [SavedCaptchaToken]) async {
        for entry in saved {
            await CaptchaTokenStore.shared.invalidate(domain: entry.domain)
            if let token = entry.token {
                await CaptchaTokenStore.shared.store(token, domain: entry.domain)
            }
        }
    }

    private enum DirectLinkHarnessError: Error {
        case autostartDidNotBegin
    }

    private func isolateTestProcessPreferences() throws -> () -> Void {
        guard Bundle.main.bundleIdentifier != "ru.sudrf.app" else {
            throw XCTSkip("test harness is forbidden in the production app process")
        }
        let defaults = UserDefaults.standard
        let key = SpotlightPreferenceStore.onboardingKey
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        return {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }

    private func isPartial(_ outcome: CaseRefreshOutcome?) -> Bool {
        if case .partial = outcome { return true }
        return false
    }

    private static func resolveIssue321DirectLink() async throws -> DirectCaseLinkResolution {
        let card = CaseCard(
            rawText: "", actText: nil,
            judge: "<скрыто>", result: "Направлено по подведомственности",
            uid: "78RS0001-01-2026-002203-86", caseNumber: "12-538/2026",
            category: "Дело об административном правонарушении",
            receiptDate: "11.03.2026", decisionDate: "16.07.2026")
        let court = DistrictCourt(
            title: "Василеостровский районный суд города Санкт-Петербурга",
            domain: "vos.spb.sudrf.ru", code: "78RS0001", regionCode: "spb",
            kind: .district, portalSubject: "78")
        let resolver = DirectCaseLinkResolver(
            fetchCard: { requestedURL in
                guard (try? SudrfCaseCardLink(url: requestedURL))
                    == (try? SudrfCaseCardLink(url: Self.issue321CardURL)) else {
                    throw ResolverStubError.fetchCalled
                }
                return SudrfCaseCardFetchResult(card: card, responseURL: Self.issue321CardURL)
            },
            districtCourts: { _ in [court] })
        return try await resolver.resolve(Self.issue321CardURL.absoluteString)
    }

    private func makeCaptchaSequence(for context: MovementContext) throws -> [CaseMovement] {
        let base = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: context.judge, domain: context.searchDomain, foundByUID: false,
            result: context.resultText, sessions: [])
        let targets = context.higherCourtTargets ?? []
        let subject = try XCTUnwrap(targets.first { $0.courtLevel == .subject })
        let cassation = try XCTUnwrap(targets.first { $0.courtLevel == .cassation })
        let subjectDomain = subject.domain
        let cassationDomain = cassation.domain
        let subjectTitle = try XCTUnwrap(subject.courtTitle)
        let cassationTitle = try XCTUnwrap(cassation.courtTitle)
        let subjectURL = URL(string: "https://\(subjectDomain)/modules.php?name=sud_delo")!
        let cassationURL = URL(string: "https://\(cassationDomain)/modules.php?name=sud_delo")!
        let subjectStub = CaseInstance(
            level: .appeal, court: subjectTitle, caseNumber: "—", judge: nil,
            domain: subjectDomain, foundByUID: false, result: nil, sessions: [],
            captchaFormURL: subjectURL)
        let cassationStub = CaseInstance(
            level: .cassation, court: cassationTitle, caseNumber: "—", judge: nil,
            domain: cassationDomain, foundByUID: false, result: nil, sessions: [],
            captchaFormURL: cassationURL)
        let subjectCard = CaseInstance(
            level: .appeal, court: subjectTitle, caseNumber: "12-538/2026",
            judge: nil, domain: subjectDomain, foundByUID: true,
            result: "Решение", sessions: [],
            sourceURL: subjectCardSourceURL(domain: subjectDomain))
        let uid = context.judicialUID ?? "78RS0001-01-2026-002203-86"
        let first = CaseMovement(
            uid: uid, caseNumber: context.caseNumber, inForce: false,
            instances: [base, subjectStub, cassationStub], complaints: [:], acts: [],
            incompleteHigherCourtDomains: [subjectDomain, cassationDomain])
        let second = CaseMovement(
            uid: uid, caseNumber: context.caseNumber, inForce: false,
            instances: [base, subjectCard, cassationStub], complaints: [:], acts: [],
            incompleteHigherCourtDomains: [cassationDomain])
        let final = CaseMovement(
            uid: uid, caseNumber: context.caseNumber, inForce: false,
            instances: [base, subjectCard], complaints: [:], acts: [],
            honestZeroDomains: [cassationDomain])
        return [first, second, final]
    }

    private func subjectCardSourceURL(domain: String) -> URL {
        URL(string: "https://\(domain)/modules.php?name=sud_delo&name_op=case"
             + "&case_id=123456789&case_uid=11111111-2222-4333-8444-555555555555"
             + "&delo_id=1502001&case_type=0&new=0&srv_num=1")!
    }

    private static let issue321CardURL = URL(string:
        "http://vos.spb.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=958679833&case_uid=976b38ad-eb63-425e-93d5-b15fa7df355d"
            + "&delo_id=1502001&case_type=0&new=0&srv_num=1")!

    private enum ResolverStubError: Error {
        case fetchCalled
    }
}
