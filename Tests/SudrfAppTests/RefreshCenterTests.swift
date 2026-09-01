import XCTest
import Foundation
import SudrfKit
import CaptchaSolver
@testable import SudrfApp

/// Тесты для `RefreshCenter` — фонового обхода отслеживаемых дел.
/// Сейчас покрывают задачу A1 (FIXPLAN): inline retry после успешного
/// авто-солва капчи потребляет положенный в `CaptchaTokenStore` токен,
/// а не теряется в `tasks[key]` из-за преждевременного `refresh(key:)`.
@MainActor
final class RefreshCenterTests: XCTestCase {

    // MARK: - Fakes

    /// `MovementProviding`-мок: первый вызов `movement(...)` бросает
    /// `.captchaRequired`, второй — возвращает заранее заданный
    /// `successMV`. Считает вызовы, чтобы тест мог проверить, что
    /// inline-retry действительно сработал.
    private actor ScriptedMovement: MovementProviding {
        let formURL: URL
        let successMV: CaseMovement
        private(set) var calls: [String] = []
        init(formURL: URL, successMV: CaseMovement) {
            self.formURL = formURL
            self.successMV = successMV
        }
        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            calls.append(base.caseNumber)
            if calls.count == 1 {
                throw SudrfError.captchaRequired(formURL: formURL)
            }
            return successMV
        }
    }

    private actor EmbeddedCaptchaMovement: MovementProviding {
        let first: CaseMovement
        let retry: CaseMovement
        private(set) var calls = 0

        init(first: CaseMovement, retry: CaseMovement) {
            self.first = first
            self.retry = retry
        }

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            calls += 1
            return calls == 1 ? first : retry
        }
    }

    /// Covers both CAPTCHA entry points with two cards reaching equivalent
    /// dot/dash module hosts at the same time.
    private actor MixedCaptchaMovement: MovementProviding {
        let embeddedFirst: CaseMovement
        let embeddedRetry: CaseMovement
        let topLevelCaseNumber: String
        let topLevelFormURL: URL
        let topLevelRetry: CaseMovement
        private(set) var callsByCase: [String: Int] = [:]

        init(embeddedFirst: CaseMovement,
             embeddedRetry: CaseMovement,
             topLevelCaseNumber: String,
             topLevelFormURL: URL,
             topLevelRetry: CaseMovement) {
            self.embeddedFirst = embeddedFirst
            self.embeddedRetry = embeddedRetry
            self.topLevelCaseNumber = topLevelCaseNumber
            self.topLevelFormURL = topLevelFormURL
            self.topLevelRetry = topLevelRetry
        }

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            let count = (callsByCase[base.caseNumber] ?? 0) + 1
            callsByCase[base.caseNumber] = count
            if base.caseNumber == topLevelCaseNumber {
                if count == 1 {
                    throw SudrfError.captchaRequired(formURL: topLevelFormURL)
                }
                return topLevelRetry
            }
            return count == 1 ? embeddedFirst : embeddedRetry
        }
    }

    private actor BlockingCaptchaSolve {
        let result: AutoCaptchaSolver.SolveResult
        private(set) var calls = 0
        private var continuation: CheckedContinuation<Void, Never>?

        init(result: AutoCaptchaSolver.SolveResult) {
            self.result = result
        }

        func solve() async -> AutoCaptchaSolver.SolveResult {
            calls += 1
            await withCheckedContinuation { continuation = $0 }
            return result
        }

        func waitUntilStarted() async {
            while calls == 0 { await Task.yield() }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor FixedMovement: MovementProviding {
        let value: CaseMovement
        private(set) var calls = 0
        init(_ value: CaseMovement) { self.value = value }
        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            calls += 1
            return value
        }
    }

    private actor UnavailableMovement: MovementProviding {
        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            throw SudrfError.caseCardTemporarilyUnavailable
        }
    }

    private actor NetworkFailureMovement: MovementProviding {
        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            throw URLError(.notConnectedToInternet)
        }
    }

    private actor CancelledMovement: MovementProviding {
        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            throw URLError(.cancelled)
        }
    }

    private actor SuspendedMovement: MovementProviding {
        let value: CaseMovement
        private var started = false
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ value: CaseMovement) { self.value = value }

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            started = true
            await withCheckedContinuation { continuation = $0 }
            return value
        }

        func waitUntilStarted() async {
            while !started { await Task.yield() }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor SuspendedCaptchaRetryMovement: MovementProviding {
        let formURL: URL
        let value: CaseMovement
        private var calls = 0
        private var retryContinuation: CheckedContinuation<Void, Never>?

        init(formURL: URL, value: CaseMovement) {
            self.formURL = formURL
            self.value = value
        }

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            calls += 1
            if calls == 1 {
                throw SudrfError.captchaRequired(formURL: formURL)
            }
            await withCheckedContinuation { retryContinuation = $0 }
            return value
        }

        func waitUntilRetryStarted() async {
            while calls < 2 { await Task.yield() }
        }

        func resumeRetry() {
            retryContinuation?.resume()
            retryContinuation = nil
        }
    }

    private actor CaptchaMovement: MovementProviding {
        let url: URL
        init(url: URL) { self.url = url }
        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            throw SudrfError.captchaRequired(formURL: url)
        }
    }

    private actor ScriptedTreasury {
        enum Outcome: Sendable {
            case lookup(EnforcementLookup)
            case failure
        }

        private var outcomes: [Outcome]
        private(set) var documents: [String] = []

        init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

        func discover(_ document: CourtEnforcementDocument,
                      caseNumber: String?, court: String?) async throws -> EnforcementLookup {
            documents.append(document.id)
            guard !outcomes.isEmpty else {
                return EnforcementLookup(state: .notFound)
            }
            switch outcomes.removeFirst() {
            case .lookup(let value): return value
            case .failure: throw URLError(.notConnectedToInternet)
            }
        }
    }

    private actor ScriptedFSSP {
        enum Outcome: Sendable {
            case step(FSSPSearchStep)
            case failure
        }

        private var outcomes: [Outcome]
        private(set) var documents: [String] = []

        init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

        func discover(_ document: CourtEnforcementDocument) async throws -> FSSPSearchStep {
            documents.append(document.id)
            guard !outcomes.isEmpty else {
                return .notFound(EnforcementLookup(state: .notFound))
            }
            switch outcomes.removeFirst() {
            case .step(let value): return value
            case .failure: throw URLError(.notConnectedToInternet)
            }
        }
    }

    private actor SuspendedFSSP {
        private var started = false
        private var continuation: CheckedContinuation<Void, Never>?
        let step: FSSPSearchStep

        init(step: FSSPSearchStep) { self.step = step }

        func discover(_ document: CourtEnforcementDocument) async -> FSSPSearchStep {
            started = true
            await withCheckedContinuation { continuation = $0 }
            return step
        }

        func waitUntilStarted() async {
            while !started { await Task.yield() }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func noFSSP(_ document: CourtEnforcementDocument) async throws -> FSSPSearchStep {
        .notFound(EnforcementLookup(state: .notFound))
    }

    /// `CaptchaSolvingProvider`-стаб, который `RefreshCenter` не должен
    /// вызывать: шаг авто-решения капчи в тестах перекрыт `autoSolve`-
    /// замыканием в init. Нужен только потому, что `CaptchaSolver`
    /// требует non-nil provider.
    private final class NeverUsedProvider: CaptchaSolvingProvider, @unchecked Sendable {
        func solve(pngData: Data, kind: CaptchaKind,
                   host: String?) async throws -> CaptchaAttempt {
            XCTFail("autoSolve-замыкание должно перекрыть реальный солвер")
            return .empty
        }
    }

    private func makeContext() -> MovementContext {
        MovementContext(branchRaw: "general", region: "Республика Коми",
                        searchDomain: "syktsud--komi.sudrf.ru",
                        displayDomain: "syktsud.komi.sudrf.ru",
                        courtTitle: "Сыктывкарский городской суд",
                        courtLevelRaw: "district", courtCode: "11RS0001",
                        cartotekaId: "g1", cartotekaLevelRaw: "district",
                        caseNumber: "2-100/2026")
    }

    private func makeSuccessMovement(court: Court) -> CaseMovement {
        let inst = CaseInstance(level: .first, court: court.title,
                                caseNumber: "2-100/2026", judge: nil,
                                domain: court.domain, foundByUID: false,
                                result: "Иск удовлетворён", sessions: [])
        return CaseMovement(uid: "uid-A1", caseNumber: "2-100/2026",
                            inForce: false, instances: [inst],
                            complaints: [:], acts: [])
    }

    private func paperWrit(_ id: String = "court-writ-1",
                            blank: String = "ФС № 123456") -> CourtEnforcementDocument {
        CourtEnforcementDocument(id: id, blankNumber: blank, courtStatus: "Выдан")
    }

    private func enforcementRecord(document: CourtEnforcementDocument,
                                   state: EnforcementDiscoveryState = .found,
                                   status: String = "Исполнено",
                                   events: [EnforcementEvent] = [],
                                   attemptedAt: Date? = nil,
                                   error: String? = nil) -> EnforcementRecord {
        EnforcementRecord(courtDocumentID: document.id, source: .treasury,
                          discoveryState: state, sourceRecordID: "source-\(document.id)",
                          status: status, organization: "УФК", subdivision: "Отдел",
                          events: events, lastAttemptAt: attemptedAt,
                          lastSuccessAt: state == .error ? nil : attemptedAt,
                          error: error)
    }

    private func bailiffRecord(document: CourtEnforcementDocument,
                               state: EnforcementDiscoveryState = .found,
                               attemptedAt: Date? = nil,
                               details: BailiffEnforcementDetails? = nil,
                               error: String? = nil) -> EnforcementRecord {
        EnforcementRecord(
            courtDocumentID: document.id, source: .bailiffs,
            discoveryState: state,
            sourceRecordID: details?.proceedingNumber,
            status: "",
            lastAttemptAt: attemptedAt,
            lastSuccessAt: state == .found ? attemptedAt : nil,
            error: error,
            bailiffDetails: details)
    }

    // MARK: - setUp / tearDown

    private var store: TrackedStore!
    private var formURL: URL!
    private var scripted: ScriptedMovement!
    private var successMV: CaseMovement!

    // Состояние `CaptchaSettings.shared` — save/restore, тест не должен
    // оставлять побочных эффектов в UserDefaults пользователя.
    private var savedAutoSolve: Bool!
    private var savedForceDisabled: Bool!
    private var savedMinConf: Double!
    private var savedMaxAttempts: Int!

    override func setUp() async throws {
        try await super.setUp()
        store = TrackedStore(inMemory: true)
        let ctx = makeContext()
        successMV = makeSuccessMovement(court: ctx.searchCourt)
        formURL = URL(string: "https://syktsud--komi.sudrf.ru/modules.php?g1")!
        scripted = ScriptedMovement(formURL: formURL, successMV: successMV)
        _ = try store.upsert(context: ctx, snapshot: nil, movement: nil, collections: [])
        // Чистый стор на нужный домен — иначе возможный хвост от
        // предыдущего тестового прогона даст ложный «успех без solve».
        await CaptchaTokenStore.shared.invalidate(domain: "syktsud--komi.sudrf.ru")
        await CaptchaTokenStore.shared.invalidate(domain: "3kas.sudrf.ru")
        await CaptchaTokenStore.shared.invalidate(domain: "vs--komi.sudrf.ru")

        let s = CaptchaSettings.shared
        savedAutoSolve = s.autoSolveEnabled
        savedForceDisabled = s.forceDisabled
        savedMinConf = s.minConfidence
        savedMaxAttempts = s.maxAttempts
        s.autoSolveEnabled = true
        s.forceDisabled = false
        s.minConfidence = 0.5
    }

    override func tearDown() async throws {
        let s = CaptchaSettings.shared
        s.autoSolveEnabled = savedAutoSolve
        s.forceDisabled = savedForceDisabled
        s.minConfidence = savedMinConf
        s.maxAttempts = savedMaxAttempts
        await CaptchaTokenStore.shared.invalidate(domain: "syktsud--komi.sudrf.ru")
        await CaptchaTokenStore.shared.invalidate(domain: "3kas.sudrf.ru")
        await CaptchaTokenStore.shared.invalidate(domain: "vs--komi.sudrf.ru")
        store = nil
        scripted = nil
        try await super.tearDown()
    }

    private func makeCenter(
        service: (any MovementProviding)? = nil,
        autoSolve: @escaping (URL, SudrfClient, CaptchaSolver,
                              AutoCaptchaSolver.Settings)
            async -> AutoCaptchaSolver.SolveResult
    ) -> RefreshCenter {
        let solver = CaptchaSolver(provider: NeverUsedProvider())
        let provider: any MovementProviding = service ?? scripted
        return RefreshCenter(
            store: store,
            client: SudrfClient(),
            captchaSolver: solver,
            captchaSettings: CaptchaSettings.shared,
            autoSolve: autoSolve,
            serviceBuilder: { _ in provider }
        )
    }

    func testRepairPreflightRefreshesRemappedKey() async throws {
        let old = makeContext()
        var canonical = old
        canonical.displayDomain = "canonical.komi.sudrf.ru"
        canonical.searchDomain = "canonical--komi.sudrf.ru"
        canonical.caseNumber = "2-200/2026"
        let canonicalMovement = makeSuccessMovement(court: canonical.searchCourt)
        let provider = FixedMovement(canonicalMovement)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in provider })
        var callbackKey: String?
        center.onRefreshed = { key, _, _ in callbackKey = key }
        center.repairBeforeRefresh = { [store] key in
            XCTAssertEqual(key, old.key)
            guard let store else { return key }
            _ = try store.upsert(context: canonical, snapshot: nil, collections: [])
            try store.remove(key: old.key)
            return canonical.key
        }

        let execution = await center.refresh(key: old.key)?.value

        XCTAssertNil(store.record(forKey: old.key))
        XCTAssertNotNil(store.record(forKey: canonical.key)?.movement)
        XCTAssertEqual(callbackKey, canonical.key)
        XCTAssertEqual(execution?.effectiveKey, canonical.key)
        XCTAssertEqual(execution?.outcome, .refreshed)
    }

    func testRefreshRecoversBlankContextUIDFromCachedMovement() async throws {
        let key = store.all()[0].key
        let record = try XCTUnwrap(store.record(forKey: key))
        let cachedUID = "11RS0001-01-2023-007662-80"
        var cachedMovement = successMV!
        cachedMovement.uid = cachedUID
        cachedMovement.category = "Уголовное дело"
        cachedMovement.parties = CaseParties(defendants: ["Болобан Илья Сергеевич"])
        cachedMovement.instances[0].judge = "Костюнина Н. Н."
        cachedMovement.instances[0].sessions = [
            CaseSession(date: "10.08.2023", event: "Судебное заседание",
                        result: "Постановление приговора")
        ]
        cachedMovement.instances[0].sourceURL = URL(
            string: "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case")
        let cachedAct = CaseAct(
            id: "cached-verdict", title: "Приговор", date: "10.08.2023",
            courtShort: "Сыктывкарский городской суд", instanceLevel: .first)
        cachedMovement.instances[0].actID = cachedAct.id
        cachedMovement.acts = [cachedAct]
        cachedMovement.actBodies = [cachedAct.id: "Сохранённый текст приговора"]
        record.movement = cachedMovement
        try store.save(projection: .cases([key]))
        XCTAssertNil(record.context?.judicialUID)

        let sparseBase = CaseInstance(
            level: .first, court: "Сыктывкарский городской суд",
            caseNumber: cachedMovement.caseNumber, judge: nil,
            domain: "syktsud--komi.sudrf.ru", foundByUID: false,
            result: nil, sessions: [])
        let freshCassation = CaseInstance(
            level: .cassation, court: "Третий кассационный суд",
            caseNumber: "7У-1077/2024 [77-762/2024]", judge: "Курбатова М. В.",
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "ВЫНЕСЕНО РЕШЕНИЕ ПО СУЩЕСТВУ ДЕЛА", sessions: [])
        let partialMovement = CaseMovement(
            uid: cachedUID, caseNumber: cachedMovement.caseNumber, inForce: false,
            instances: [sparseBase, freshCassation], complaints: [:], acts: [],
            incompleteHigherCourtDomains: ["syktsud--komi.sudrf.ru"])
        let service = FixedMovement(partialMovement)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { context in
            XCTAssertEqual(context.judicialUID, cachedUID)
            return service
        })

        let execution = await center.refresh(key: key)?.value

        guard case .partial = execution?.outcome else {
            return XCTFail("недоступная базовая карточка должна дать partial refresh")
        }
        let saved = try XCTUnwrap(store.record(forKey: key)?.movement)
        let savedBase = try XCTUnwrap(saved.instances.first {
            $0.domain == "syktsud--komi.sudrf.ru"
        })
        XCTAssertEqual(savedBase.judge, cachedMovement.instances[0].judge)
        XCTAssertEqual(savedBase.sessions, cachedMovement.instances[0].sessions)
        XCTAssertEqual(savedBase.result, cachedMovement.instances[0].result)
        XCTAssertEqual(savedBase.sourceURL, cachedMovement.instances[0].sourceURL)
        XCTAssertEqual(saved.category, cachedMovement.category)
        XCTAssertEqual(saved.parties, cachedMovement.parties)
        XCTAssertEqual(saved.acts, cachedMovement.acts)
        XCTAssertEqual(saved.actBodies, cachedMovement.actBodies)
        XCTAssertEqual(saved.instances.first { $0.domain == "3kas.sudrf.ru" }?.caseNumber,
                       "7У-1077/2024 [77-762/2024]")
    }

    func testRefreshRejectsMalformedCachedMovementUID() async throws {
        let key = store.all()[0].key
        let record = try XCTUnwrap(store.record(forKey: key))
        var cachedMovement = successMV!
        cachedMovement.uid = "uid-A1"
        record.movement = cachedMovement

        let service = FixedMovement(successMV)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { context in
            XCTAssertNil(context.judicialUID)
            return service
        })

        let execution = await center.refresh(key: key)?.value

        XCTAssertEqual(execution?.outcome, .refreshed)
    }

    func testUIDMergePublishesPersistedCombinedMovementAndKeyRemap() async throws {
        for key in store.all().map(\.key) { try store.remove(key: key) }
        let judicialUID = "11RS0001-01-2025-011255-03"

        var survivorContext = makeContext()
        survivorContext.caseID = "first-card"
        survivorContext.judicialUID = judicialUID
        let survivorAct = CaseAct(
            id: "survivor-act", title: "Решение", date: "01.08.2026",
            courtShort: survivorContext.courtTitle, instanceLevel: .first)
        let survivorMovement = CaseMovement(
            uid: judicialUID, caseNumber: survivorContext.caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .first, court: survivorContext.courtTitle,
                caseNumber: survivorContext.caseNumber, judge: nil,
                domain: survivorContext.searchDomain, foundByUID: false,
                result: "Решение", sessions: [], actID: survivorAct.id)],
            complaints: [:], acts: [survivorAct])

        var refreshedContext = makeContext()
        refreshedContext.caseNumber = "33-200/2026"
        refreshedContext.caseID = "appeal-card"
        refreshedContext.judicialUID = judicialUID
        refreshedContext.searchDomain = "vs--komi.sudrf.ru"
        refreshedContext.displayDomain = "vs.komi.sudrf.ru"
        refreshedContext.courtTitle = "Верховный суд Республики Коми"
        refreshedContext.courtLevelRaw = CourtLevel.subject.rawValue
        refreshedContext.courtCode = "11VS0001"
        refreshedContext.cartotekaId = "g2"
        refreshedContext.cartotekaLevelRaw = CourtLevel.subject.rawValue
        let refreshedAct = CaseAct(
            id: "appeal-act", title: "Апелляционное определение",
            date: "20.08.2026", courtShort: refreshedContext.courtTitle,
            instanceLevel: .appeal)
        let refreshedMovement = CaseMovement(
            uid: judicialUID, caseNumber: refreshedContext.caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .appeal, court: refreshedContext.courtTitle,
                caseNumber: refreshedContext.caseNumber, judge: nil,
                domain: refreshedContext.searchDomain, foundByUID: true,
                result: "Решение оставлено без изменения", sessions: [],
                actID: refreshedAct.id)],
            complaints: [:], acts: [refreshedAct])

        func insert(_ context: MovementContext, movement: CaseMovement?) throws
            -> TrackedCaseRecord {
            let observation = try XCTUnwrap(
                TrackedCaseIdentity.observation(context: context, movement: movement))
            let state = LogicalCaseState(observation: observation)
            let record = TrackedCaseRecord(
                key: context.key, collections: [], caseNumber: context.caseNumber,
                courtTitle: context.courtTitle, displayDomain: context.displayDomain,
                contextData: try JSONEncoder().encode(context), snapshotData: nil)
            record.logicalCaseID = state.logicalCaseID
            record.identityStateData = try JSONEncoder().encode(state)
            record.judicialUID = judicialUID
            record.movement = movement
            store.container.mainContext.insert(record)
            return record
        }

        let survivor = try insert(survivorContext, movement: survivorMovement)
        let refreshed = try insert(refreshedContext, movement: nil)
        try store.container.mainContext.save()
        let provider = FixedMovement(refreshedMovement)
        let center = makeCenter(service: provider) { _, _, _, _ in
            AutoCaptchaSolver.SolveResult(token: nil, png: nil)
        }
        var callback: (String, CaseMovement, [String: String])?
        center.onRefreshed = { callback = ($0, $1, $2) }

        let execution = await center.refresh(key: refreshed.key)?.value

        XCTAssertEqual(execution?.effectiveKey, survivor.key)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(callback?.0, survivor.key)
        XCTAssertEqual(callback?.2, [refreshed.key: survivor.key])
        let persistedActs = Set(try XCTUnwrap(store.record(forKey: survivor.key)?.movement)
            .acts.map(\.id))
        XCTAssertEqual(persistedActs, [survivorAct.id, refreshedAct.id])
        XCTAssertEqual(Set(callback?.1.acts.map(\.id) ?? []), persistedActs,
                       "open card must receive the full persisted dossier projection")
    }

    func testIntentRefreshUIDMergeSaveFailureRestoresDuplicatesAndReportsFailure() async throws {
        for key in store.all().map(\.key) { try store.remove(key: key) }
        let judicialUID = "11RS0001-01-2025-011255-03"

        var survivorContext = makeContext()
        survivorContext.caseID = "first-card"
        survivorContext.judicialUID = judicialUID

        var refreshedContext = makeContext()
        refreshedContext.caseNumber = "33-200/2026"
        refreshedContext.caseID = "appeal-card"
        refreshedContext.judicialUID = judicialUID
        refreshedContext.searchDomain = "vs--komi.sudrf.ru"
        refreshedContext.displayDomain = "vs.komi.sudrf.ru"
        refreshedContext.courtTitle = "Верховный суд Республики Коми"
        refreshedContext.courtLevelRaw = CourtLevel.subject.rawValue
        refreshedContext.courtCode = "11VS0001"
        refreshedContext.cartotekaId = "g2"
        refreshedContext.cartotekaLevelRaw = CourtLevel.subject.rawValue

        func movement(for context: MovementContext, level: CaseInstance.Level,
                      result: String, actID: String) -> CaseMovement {
            let act = CaseAct(
                id: actID, title: "Определение", date: "20.08.2026",
                courtShort: context.courtTitle, instanceLevel: level)
            return CaseMovement(
                uid: judicialUID, caseNumber: context.caseNumber, inForce: false,
                instances: [CaseInstance(
                    level: level, court: context.courtTitle, caseNumber: context.caseNumber,
                    judge: nil, domain: context.searchDomain, foundByUID: level != .first,
                    result: result, sessions: [], actID: actID)],
                complaints: [:], acts: [act], actBodies: [actID: result])
        }

        func insert(_ context: MovementContext, movement: CaseMovement,
                    collections: [String], fetchedAt: Date, seenAt: Date) throws
            -> TrackedCaseRecord {
            let observation = try XCTUnwrap(
                TrackedCaseIdentity.observation(context: context, movement: movement))
            let state = LogicalCaseState(observation: observation)
            let record = TrackedCaseRecord(
                key: context.key, collections: collections, caseNumber: context.caseNumber,
                courtTitle: context.courtTitle, displayDomain: context.displayDomain,
                contextData: try JSONEncoder().encode(context), snapshotData: nil)
            record.logicalCaseID = state.logicalCaseID
            record.identityStateData = try JSONEncoder().encode(state)
            record.judicialUID = judicialUID
            record.movement = movement
            record.snapshot = MovementDerivation.snapshot(from: movement, context: context)
            record.movementFetchedAt = fetchedAt
            record.seenAt = seenAt
            store.container.mainContext.insert(record)
            return record
        }

        let survivor = try insert(
            survivorContext,
            movement: movement(for: survivorContext, level: .first, result: "Старое решение",
                               actID: "survivor-act"),
            collections: ["Первая инстанция"],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            seenAt: Date(timeIntervalSince1970: 1_700_000_100))
        let refreshed = try insert(
            refreshedContext,
            movement: movement(for: refreshedContext, level: .appeal, result: "Старое определение",
                               actID: "appeal-act"),
            collections: ["Апелляция"],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_200),
            seenAt: Date(timeIntervalSince1970: 1_700_000_300))
        try store.container.mainContext.save()
        let survivorKey = survivor.key
        let refreshedKey = refreshed.key
        try store.save(projection: .cases([survivorKey, refreshedKey]))
        let survivorProjectionID = try XCTUnwrap(
            store.courtActID(caseKey: survivorKey, sourceActID: "survivor-act"))
        let refreshedProjectionID = try XCTUnwrap(
            store.courtActID(caseKey: refreshedKey, sourceActID: "appeal-act"))

        let formURL = URL(string: "https://vs--komi.sudrf.ru/modules.php?g2")!
        let service = ScriptedMovement(
            formURL: formURL,
            successMV: movement(for: refreshedContext, level: .appeal, result: "Новое определение",
                                actID: "appeal-act"))
        let center = makeCenter(service: service) { _, _, _, _ in
            AutoCaptchaSolver.SolveResult(token: nil, png: nil)
        }

        let captchaOutcome = await center.refreshForIntent(key: refreshedKey)
        XCTAssertEqual(captchaOutcome, .captchaRequired)
        let pendingCaptcha = try XCTUnwrap(center.captchaPendingRequest(forKey: refreshedKey))
        XCTAssertEqual(pendingCaptcha.formURL, formURL)

        let beforeSurvivor = try XCTUnwrap(store.record(forKey: survivorKey))
        let beforeRefreshed = try XCTUnwrap(store.record(forKey: refreshedKey))
        let savedSurvivorMovement = beforeSurvivor.movement
        let savedSurvivorSnapshot = beforeSurvivor.snapshot
        let savedSurvivorFetchedAt = beforeSurvivor.movementFetchedAt
        let savedSurvivorSeenAt = beforeSurvivor.seenAt
        let savedSurvivorState = beforeSurvivor.identityStateData
        let savedSurvivorAttempt = beforeSurvivor.sourceRefreshAttempt
        let savedRefreshedMovement = beforeRefreshed.movement
        let savedRefreshedSnapshot = beforeRefreshed.snapshot
        let savedRefreshedFetchedAt = beforeRefreshed.movementFetchedAt
        let savedRefreshedSeenAt = beforeRefreshed.seenAt
        let savedRefreshedState = beforeRefreshed.identityStateData
        let savedRefreshedAttempt = try XCTUnwrap(beforeRefreshed.sourceRefreshAttempt)

        var refreshedCallback: (String, [String: String])?
        var failed: (String, String)?
        center.onRefreshed = { refreshedCallback = ($0, $2) }
        center.onRefreshFailed = { failed = ($0, $1) }
        store.failNextSaveForTesting = true

        let message = "Не удалось сохранить обновление дела в локальной базе. Повторите попытку."
        let outcome = await center.refreshForIntent(key: refreshedKey)

        XCTAssertEqual(outcome, .failed(message))
        XCTAssertFalse(store.failNextSaveForTesting)
        XCTAssertEqual(Set(store.all().map(\.key)), Set([survivorKey, refreshedKey]))
        let persistedSurvivor = try XCTUnwrap(store.record(forKey: survivorKey))
        let persistedRefreshed = try XCTUnwrap(store.record(forKey: refreshedKey))
        XCTAssertEqual(persistedSurvivor.movement, savedSurvivorMovement)
        XCTAssertEqual(persistedSurvivor.snapshot, savedSurvivorSnapshot)
        XCTAssertEqual(persistedSurvivor.movementFetchedAt, savedSurvivorFetchedAt)
        XCTAssertEqual(persistedSurvivor.seenAt, savedSurvivorSeenAt)
        XCTAssertEqual(persistedSurvivor.identityStateData, savedSurvivorState)
        XCTAssertEqual(persistedSurvivor.sourceRefreshAttempt, savedSurvivorAttempt)
        XCTAssertEqual(persistedSurvivor.collectionNames, ["Первая инстанция"])
        XCTAssertEqual(persistedRefreshed.movement, savedRefreshedMovement)
        XCTAssertEqual(persistedRefreshed.snapshot, savedRefreshedSnapshot)
        XCTAssertEqual(persistedRefreshed.movementFetchedAt, savedRefreshedFetchedAt)
        XCTAssertEqual(persistedRefreshed.seenAt, savedRefreshedSeenAt)
        XCTAssertEqual(persistedRefreshed.identityStateData, savedRefreshedState)
        XCTAssertEqual(persistedRefreshed.sourceRefreshAttempt, savedRefreshedAttempt)
        XCTAssertEqual(persistedRefreshed.collectionNames, ["Апелляция"])
        XCTAssertEqual(store.courtActID(caseKey: survivorKey, sourceActID: "survivor-act"),
                       survivorProjectionID)
        XCTAssertEqual(store.courtActID(caseKey: refreshedKey, sourceActID: "appeal-act"),
                       refreshedProjectionID)
        XCTAssertEqual(center.captchaPendingRequest(forKey: refreshedKey), pendingCaptcha)
        XCTAssertNil(refreshedCallback)
        XCTAssertEqual(failed?.0, refreshedKey)
        XCTAssertEqual(failed?.1, message)
        XCTAssertEqual(center.lastErrors[refreshedKey], message)
        let calls = await service.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testCaptchaAttemptCommitFailureKeepsPendingAndReportsPersistenceFailure() async throws {
        let key = try XCTUnwrap(store.all().first?.key)
        let center = makeCenter { _, _, _, _ in
            AutoCaptchaSolver.SolveResult(token: nil, png: nil)
        }
        var refreshed = false
        var failed: (String, String)?
        center.onRefreshed = { _, _, _ in refreshed = true }
        center.onRefreshFailed = { failed = ($0, $1) }
        store.failNextSaveForTesting = true

        let outcome = await center.refreshForIntent(key: key)

        let message = "Не удалось сохранить обновление дела в локальной базе. Повторите попытку."
        XCTAssertEqual(outcome, .failed(message))
        XCTAssertNotNil(center.captchaPendingRequest(forKey: key))
        XCTAssertNil(store.record(forKey: key)?.sourceRefreshAttempt)
        XCTAssertFalse(refreshed)
        XCTAssertEqual(failed?.0, key)
        XCTAssertEqual(failed?.1, message)
        XCTAssertEqual(center.lastErrors[key], message)
    }

    func testIntentRefreshClassifiesFailureUnderReroutedKey() async throws {
        let old = makeContext()
        var canonical = old
        canonical.displayDomain = "canonical.komi.sudrf.ru"
        canonical.searchDomain = "canonical--komi.sudrf.ru"
        canonical.caseNumber = "2-201/2026"
        let unavailable = UnavailableMovement()
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in unavailable })
        center.repairBeforeRefresh = { [store] _ in
            guard let store else { return old.key }
            _ = try store.upsert(context: canonical, snapshot: nil, collections: [])
            try store.remove(key: old.key)
            return canonical.key
        }

        let outcome = await center.refreshForIntent(key: old.key)

        guard case .failed = outcome else {
            return XCTFail("reroute network failure нельзя выдавать за refreshed")
        }
        XCTAssertNotNil(center.lastErrors[canonical.key])
    }

    func testIntentRefreshClassifiesCaptchaUnderReroutedKey() async throws {
        let old = makeContext()
        var canonical = old
        canonical.displayDomain = "canonical.komi.sudrf.ru"
        canonical.searchDomain = "canonical--komi.sudrf.ru"
        canonical.caseNumber = "2-202/2026"
        let captcha = CaptchaMovement(url: formURL)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in captcha })
        center.repairBeforeRefresh = { [store] _ in
            guard let store else { return old.key }
            _ = try store.upsert(context: canonical, snapshot: nil, collections: [])
            try store.remove(key: old.key)
            return canonical.key
        }

        let outcome = await center.refreshForIntent(key: old.key)

        XCTAssertEqual(outcome, .captchaRequired)
        XCTAssertNotNil(center.captchaPendingRequest(forKey: canonical.key))
    }

    // MARK: - A1: inline retry

    /// Позитивный сценарий A1: первый вызов `service.movement` бросает
    /// `.captchaRequired`, авто-солвер возвращает токен, повторный вызов
    /// `service.movement` (inline) должен состояться и принести реальное
    /// движение. До A1 повторный `service.movement` НЕ выполнялся —
    /// `refresh(key:)` возвращал уже идущий task, токен лежал в
    /// `CaptchaTokenStore` не потреблённый.
    func testBackgroundAutoSolveRetryConsumesToken() async throws {
        let token = CaptchaToken(value: "12345", id: "abc")
        let solveResult = AutoCaptchaSolver.SolveResult(token: token, png: Data([0x00]))
        let center = makeCenter { _, _, _, _ in solveResult }

        var refreshedKeys: [String] = []
        center.onRefreshed = { key, _, _ in refreshedKeys.append(key) }

        let key = store.all()[0].key
        _ = await center.refresh(key: key)?.value

        let calls = await scripted.calls
        XCTAssertEqual(calls.count, 2,
                       "после успешного solve должно быть 2 вызова movement (1 captcha + 1 retry)")
        let rec = store.record(forKey: key)
        XCTAssertNotNil(rec?.movementFetchedAt,
                        "movementFetchedAt должен быть выставлен после retry")
        XCTAssertEqual(rec?.sourceRefreshAttempt?.kind, .usableSnapshot)
        XCTAssertEqual(rec?.movementFetchedAt,
                       rec?.sourceRefreshAttempt?.provenance.observedAt)
        XCTAssertEqual(center.lastErrors[key], nil,
                       "успешный retry должен сбросить lastErrors")
        XCTAssertEqual(center.captchaPendingGroups.count, 0,
                       "ключ не должен остаться в captchaPending после успешного retry")
        XCTAssertEqual(refreshedKeys, [key],
                       "onRefreshed должен быть вызван ровно один раз")
        // successMV собран без captcha-стабов → stripped не меняет результат.
        XCTAssertEqual(rec?.movement?.instances.first?.domain,
                       successMV.instances.first?.domain)
        // Подтверждаем, что токен действительно был положен в стор
        // (это часть потока, который A1 чинит).
        let stored = await CaptchaTokenStore.shared.token(forDomain: "syktsud--komi.sudrf.ru")
        XCTAssertEqual(stored?.value, "12345")
    }

    func testEmbeddedHigherCourtCaptchaAutoSolvesBeforePublishing() async throws {
        let key = store.all()[0].key
        let formURL = URL(string: "https://3kas.sudrf.ru/modules.php?name=sud_delo")!
        var first = successMV!
        first.instances.append(CaseInstance(
            level: .cassation,
            court: "Третий кассационный суд общей юрисдикции",
            caseNumber: "—",
            judge: nil,
            domain: "3kas.sudrf.ru",
            foundByUID: false,
            result: nil,
            sessions: [],
            captchaFormURL: formURL))
        first.incompleteHigherCourtDomains = ["3kas.sudrf.ru"]

        var retry = successMV!
        retry.instances.append(CaseInstance(
            level: .cassation,
            court: "Третий кассационный суд общей юрисдикции",
            caseNumber: "8Г-10837/2026",
            judge: "Иванов И. И.",
            domain: "3kas.sudrf.ru",
            foundByUID: true,
            result: "Жалоба оставлена без удовлетворения",
            sessions: [CaseSession(date: "10.06.2026", event: "Судебное заседание")]))

        let movement = EmbeddedCaptchaMovement(first: first, retry: retry)
        let token = CaptchaToken(value: "12345", id: "higher-court")
        let center = makeCenter(service: movement) { _, _, _, _ in
            AutoCaptchaSolver.SolveResult(token: token, png: Data([1]))
        }
        var published: [CaseMovement] = []
        center.onRefreshed = { _, value, _ in published.append(value) }

        let execution = await center.refresh(key: key)?.value

        XCTAssertEqual(execution?.outcome, .refreshed)
        let calls = await movement.calls
        XCTAssertEqual(calls, 2, "embedded CAPTCHA должна дать ровно один retry")
        XCTAssertEqual(published.count, 1, "промежуточный partial не должен публиковаться")
        XCTAssertFalse(published[0].instances.contains { $0.captchaFormURL != nil })
        XCTAssertEqual(published[0].instances.first { $0.domain == "3kas.sudrf.ru" }?.caseNumber,
                       "8Г-10837/2026")
        let saved = try XCTUnwrap(store.record(forKey: key))
        XCTAssertFalse(saved.movement?.instances.contains { $0.captchaFormURL != nil } ?? true)
        XCTAssertEqual(saved.sourceRefreshAttempt?.kind, .usableSnapshot)
        XCTAssertNotNil(saved.movementFetchedAt)
    }

    func testEquivalentEmbeddedAndTopLevelCaptchasShareOneSolve() async throws {
        var secondContext = makeContext()
        secondContext.caseNumber = "2-101/2026"
        _ = try store.upsert(context: secondContext, snapshot: nil, movement: nil, collections: [])

        let embeddedFormURL = URL(string: "https://vs.komi.sudrf.ru/modules.php?name=sud_delo")!
        let topLevelFormURL = URL(string: "https://vs--komi.sudrf.ru/modules.php?name=sud_delo")!
        var embeddedFirst = successMV!
        embeddedFirst.instances.append(CaseInstance(
            level: .cassation,
            court: "Верховный суд Республики Коми",
            caseNumber: "—",
            judge: nil,
            domain: "vs.komi.sudrf.ru",
            foundByUID: false,
            result: nil,
            sessions: [],
            captchaFormURL: embeddedFormURL))
        embeddedFirst.incompleteHigherCourtDomains = ["vs.komi.sudrf.ru"]

        let movement = MixedCaptchaMovement(
            embeddedFirst: embeddedFirst,
            embeddedRetry: successMV!,
            topLevelCaseNumber: secondContext.caseNumber,
            topLevelFormURL: topLevelFormURL,
            topLevelRetry: successMV!)
        let blocker = BlockingCaptchaSolve(result: AutoCaptchaSolver.SolveResult(
            token: CaptchaToken(value: "12345", id: "shared-module"), png: Data([1])))
        let center = makeCenter(service: movement) { _, _, _, _ in
            await blocker.solve()
        }
        let firstKey = store.all().first { $0.caseNumber == "2-100/2026" }!.key
        let secondKey = store.all().first { $0.caseNumber == secondContext.caseNumber }!.key

        let firstTask = center.refresh(key: firstKey)!
        let secondTask = center.refresh(key: secondKey)!
        await blocker.waitUntilStarted()
        for _ in 0..<20 { await Task.yield() }
        let callsBeforeRelease = await blocker.calls
        XCTAssertEqual(callsBeforeRelease, 1,
                       "embedded and top-level CAPTCHA for one module must share a solve")
        await blocker.release()

        let firstExecution = await firstTask.value
        let secondExecution = await secondTask.value
        XCTAssertEqual(firstExecution.outcome, .refreshed)
        XCTAssertEqual(secondExecution.outcome, .refreshed)
        let callsAfterRelease = await blocker.calls
        XCTAssertEqual(callsAfterRelease, 1)
        let calls = await movement.callsByCase
        XCTAssertEqual(calls[store.record(forKey: firstKey)?.caseNumber ?? ""], 2)
        XCTAssertEqual(calls[secondContext.caseNumber], 2)
        XCTAssertTrue(center.captchaPendingGroups.isEmpty)
    }

    func testCancellingOneCaseDoesNotCancelSharedCaptchaSolveForNeighbor() async throws {
        var secondContext = makeContext()
        secondContext.caseNumber = "2-101/2026"
        _ = try store.upsert(context: secondContext, snapshot: nil, movement: nil, collections: [])

        let embeddedFormURL = URL(string: "https://vs.komi.sudrf.ru/modules.php?name=sud_delo")!
        let topLevelFormURL = URL(string: "https://vs--komi.sudrf.ru/modules.php?name=sud_delo")!
        var embeddedFirst = successMV!
        embeddedFirst.instances.append(CaseInstance(
            level: .cassation, court: "Верховный суд Республики Коми",
            caseNumber: "—", judge: nil, domain: "vs.komi.sudrf.ru",
            foundByUID: false, result: nil, sessions: [],
            captchaFormURL: embeddedFormURL))
        embeddedFirst.incompleteHigherCourtDomains = ["vs.komi.sudrf.ru"]
        let movement = MixedCaptchaMovement(
            embeddedFirst: embeddedFirst, embeddedRetry: successMV,
            topLevelCaseNumber: secondContext.caseNumber,
            topLevelFormURL: topLevelFormURL, topLevelRetry: successMV)
        let blocker = BlockingCaptchaSolve(result: AutoCaptchaSolver.SolveResult(
            token: CaptchaToken(value: "12345", id: "shared-after-untrack"), png: Data([1])))
        let center = makeCenter(service: movement) { _, _, _, _ in await blocker.solve() }
        let firstKey = store.all().first { $0.caseNumber == "2-100/2026" }!.key
        let secondKey = store.all().first { $0.caseNumber == secondContext.caseNumber }!.key
        var refreshedKeys: [String] = []
        center.onRefreshed = { key, _, _ in refreshedKeys.append(key) }

        let firstTask = center.refresh(key: firstKey)!
        let secondTask = center.refresh(key: secondKey)!
        await blocker.waitUntilStarted()
        for _ in 0..<20 { await Task.yield() }
        try store.remove(key: firstKey)
        center.cancelTracking(for: firstKey)
        await blocker.release()

        _ = await firstTask.value
        let secondExecution = await secondTask.value
        let solveCalls = await blocker.calls
        XCTAssertEqual(secondExecution.outcome, .refreshed)
        XCTAssertEqual(solveCalls, 1)
        XCTAssertEqual(refreshedKeys, [secondKey])
        XCTAssertNil(store.record(forKey: firstKey))
        XCTAssertNotNil(store.record(forKey: secondKey)?.movement)
    }

    func testEmbeddedHigherCourtCaptchaAutoSolveRemovesStubWhenCaseIsAbsent() async throws {
        let key = store.all()[0].key
        let formURL = URL(string: "https://3kas.sudrf.ru/modules.php?name=sud_delo")!
        var first = successMV!
        first.instances.append(CaseInstance(
            level: .cassation,
            court: "Третий кассационный суд общей юрисдикции",
            caseNumber: "—",
            judge: nil,
            domain: "3kas.sudrf.ru",
            foundByUID: false,
            result: nil,
            sessions: [],
            captchaFormURL: formURL))
        first.incompleteHigherCourtDomains = ["3kas.sudrf.ru"]

        var retry = successMV!
        retry.honestZeroDomains = ["3kas.sudrf.ru"]
        let movement = EmbeddedCaptchaMovement(first: first, retry: retry)
        let center = makeCenter(service: movement) { _, _, _, _ in
            AutoCaptchaSolver.SolveResult(
                token: CaptchaToken(value: "12345", id: "higher-court-empty"),
                png: Data([1]))
        }
        var published: [CaseMovement] = []
        center.onRefreshed = { _, value, _ in published.append(value) }

        let execution = await center.refresh(key: key)?.value

        guard case .partial = execution?.outcome else {
            return XCTFail("honest zero остаётся типизированным partial результата")
        }
        let calls = await movement.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(published.count, 1, "CAPTCHA-stub не должен публиковаться до retry")
        XCTAssertFalse(published[0].instances.contains {
            $0.domain == "3kas.sudrf.ru" || $0.captchaFormURL != nil
        }, "подтверждённая пустая выдача должна убрать фиктивную инстанцию")
        let saved = try XCTUnwrap(store.record(forKey: key))
        XCTAssertFalse(saved.movement?.instances.contains {
            $0.domain == "3kas.sudrf.ru" || $0.captchaFormURL != nil
        } ?? true)
        XCTAssertNil(center.lastErrors[key],
                     "подтверждённое отсутствие дела не является ошибкой обновления")
    }

    func testEmbeddedHigherCourtCaptchaNilTokenKeepsManualStubOnlyInPublishedMovement() async throws {
        let key = store.all()[0].key
        let formURL = URL(string: "https://3kas.sudrf.ru/modules.php?name=sud_delo")!
        var first = successMV!
        first.instances.append(CaseInstance(
            level: .cassation,
            court: "Третий кассационный суд общей юрисдикции",
            caseNumber: "—",
            judge: nil,
            domain: "3kas.sudrf.ru",
            foundByUID: false,
            result: nil,
            sessions: [],
            captchaFormURL: formURL))
        first.incompleteHigherCourtDomains = ["3kas.sudrf.ru"]
        let movement = EmbeddedCaptchaMovement(first: first, retry: successMV!)
        let center = makeCenter(service: movement) { _, _, _, _ in
            AutoCaptchaSolver.SolveResult(token: nil, png: nil)
        }
        var published: [CaseMovement] = []
        center.onRefreshed = { _, value, _ in published.append(value) }

        let execution = await center.refresh(key: key)?.value

        XCTAssertEqual(execution?.outcome, .partial(
            "Не обновился источник 3kas.sudrf.ru; сохранены последние успешные данные."))
        let calls = await movement.calls
        XCTAssertEqual(calls, 1, "без токена полный retry не выполняется")
        XCTAssertEqual(published.count, 1)
        XCTAssertNotNil(published[0].instances.first { $0.captchaFormURL != nil },
                        "manual fallback должен получить CAPTCHA-stub")
        let saved = try XCTUnwrap(store.record(forKey: key))
        XCTAssertFalse(saved.movement?.instances.contains { $0.captchaFormURL != nil } ?? true,
                       "URL CAPTCHA не должен попадать в persistence")
        XCTAssertEqual(saved.sourceRefreshAttempt?.kind, .partial)
    }

    func testIntentRefreshReportsSuccessAfterAutoSolve() async throws {
        let token = CaptchaToken(value: "12345", id: "intent-success")
        let center = makeCenter { _, _, _, _ in
            AutoCaptchaSolver.SolveResult(token: token, png: Data())
        }

        let outcome = await center.refreshForIntent(key: store.all()[0].key)

        XCTAssertEqual(outcome, .refreshed)
    }

    func testBackgroundAutoSolveUsesCaptchaSettings() async throws {
        let settings = CaptchaSettings.shared
        settings.minConfidence = 0.95
        settings.maxAttempts = 4
        var receivedSettings: AutoCaptchaSolver.Settings?
        let center = makeCenter { _, _, _, autoSolverSettings in
            receivedSettings = autoSolverSettings
            return AutoCaptchaSolver.SolveResult(token: nil, png: nil)
        }

        let key = store.all()[0].key
        _ = await center.refresh(key: key)?.value

        let actualSettings = try XCTUnwrap(receivedSettings)
        XCTAssertEqual(actualSettings.minConfidence, 0.95, accuracy: 0.001)
        XCTAssertEqual(actualSettings.maxAttempts, 4)
    }

    /// Sanity: если `autoSolve` вернул nil-токен, inline-retry НЕ идёт,
    /// ключ попадает в `captchaPending`, `lastErrors` заполнен. Без этого
    /// теста позитивный сценарий выше мог бы «проходить» по обходному
    /// пути (например, кто-то вычистил captcha-ветку).
    func testBackgroundAutoSolveNilTokenFallsBackToManual() async throws {
        let center = makeCenter { _, _, _, _ in
            AutoCaptchaSolver.SolveResult(token: nil, png: nil)
        }
        let key = store.all()[0].key
        _ = await center.refresh(key: key)?.value

        let calls = await scripted.calls
        XCTAssertEqual(calls.count, 1,
                       "без токена второй вызов movement не должен состояться")
        XCTAssertEqual(center.captchaPendingGroups.count, 1)
        XCTAssertEqual(center.captchaPendingGroups.first?.keys, [key])
        XCTAssertNotNil(center.lastErrors[key],
                        "ошибка должна быть записана в lastErrors")
        XCTAssertEqual(store.record(forKey: key)?.sourceRefreshAttempt?.kind, .captcha)
        let stored = await CaptchaTokenStore.shared.token(forDomain: "syktsud--komi.sudrf.ru")
        XCTAssertNil(stored, "без токена стор должен остаться пустым")
    }

    func testIntentRefreshReportsCaptchaInsteadOfTryingToPresentIt() async throws {
        let center = makeCenter { _, _, _, _ in
            AutoCaptchaSolver.SolveResult(token: nil, png: nil)
        }

        let outcome = await center.refreshForIntent(key: store.all()[0].key)

        XCTAssertEqual(outcome, .captchaRequired)
        XCTAssertEqual(center.captchaPendingGroups.count, 1)
    }

    func testIntentRefreshSaveFailureKeepsCaptchaPendingAndReportsFailure() async throws {
        func assertRollback(for context: MovementContext, scenario: String) async throws {
            let scenarioStore = TrackedStore(inMemory: true)
            let freshMovement = makeSuccessMovement(court: context.searchCourt)
            let scenarioFormURL = URL(string: "https://\(context.searchDomain)/modules.php?g1")!
            let service = ScriptedMovement(formURL: scenarioFormURL, successMV: freshMovement)
            _ = try scenarioStore.upsert(context: context, snapshot: nil, movement: nil, collections: [])
            let key = try XCTUnwrap(scenarioStore.all().first?.key, scenario)
            let rec = try XCTUnwrap(scenarioStore.record(forKey: key), scenario)
            var savedMovement = freshMovement
            savedMovement.instances[0].judge = "Старый судья"
            let savedSnapshot = MovementDerivation.snapshot(from: savedMovement, context: context)
            let savedFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let savedSeenAt = Date(timeIntervalSince1970: 1_700_000_100)
            rec.movement = savedMovement
            rec.snapshot = savedSnapshot
            rec.movementFetchedAt = savedFetchedAt
            rec.seenAt = savedSeenAt
            try scenarioStore.save(projection: .cases([key]))

            let center = RefreshCenter(
                store: scenarioStore,
                client: SudrfClient(),
                captchaSolver: CaptchaSolver(provider: NeverUsedProvider()),
                captchaSettings: CaptchaSettings.shared,
                autoSolve: { _, _, _, _ in
                    AutoCaptchaSolver.SolveResult(token: nil, png: nil)
                },
                serviceBuilder: { _ in service })
            let captchaOutcome = await center.refreshForIntent(key: key)
            XCTAssertEqual(captchaOutcome, .captchaRequired, scenario)
            let pendingCaptcha = try XCTUnwrap(center.captchaPendingRequest(forKey: key), scenario)
            XCTAssertEqual(pendingCaptcha.formURL, scenarioFormURL, scenario)
            let savedAttempt = try XCTUnwrap(
                scenarioStore.record(forKey: key)?.sourceRefreshAttempt, scenario)
            XCTAssertEqual(savedAttempt.kind, .captcha, scenario)

            var refreshed = false
            var failed: (String, String)?
            center.onRefreshed = { _, _, _ in refreshed = true }
            center.onRefreshFailed = { failed = ($0, $1) }
            scenarioStore.failNextSaveForTesting = true

            let message = "Не удалось сохранить обновление дела в локальной базе. Повторите попытку."
            let outcome = await center.refreshForIntent(key: key)

            XCTAssertEqual(outcome, .failed(message), scenario)
            XCTAssertFalse(scenarioStore.failNextSaveForTesting, scenario)
            let persisted = try XCTUnwrap(scenarioStore.record(forKey: key), scenario)
            XCTAssertEqual(persisted.movement, savedMovement, scenario)
            XCTAssertEqual(persisted.snapshot, savedSnapshot, scenario)
            XCTAssertEqual(persisted.movementFetchedAt, savedFetchedAt, scenario)
            XCTAssertEqual(persisted.seenAt, savedSeenAt, scenario)
            XCTAssertEqual(persisted.sourceRefreshAttempt, savedAttempt, scenario)
            XCTAssertEqual(center.captchaPendingRequest(forKey: key), pendingCaptcha, scenario)
            XCTAssertFalse(refreshed, scenario)
            XCTAssertEqual(failed?.0, key, scenario)
            XCTAssertEqual(failed?.1, message, scenario)
            XCTAssertEqual(center.lastErrors[key], message, scenario)
            let calls = await service.calls
            XCTAssertEqual(calls.count, 2, scenario)
        }

        var fallback = makeContext()
        fallback.caseID = nil
        try await assertRollback(for: fallback, scenario: "fallback final save")

        var identity = makeContext()
        identity.caseID = "card-save-failure"
        try await assertRollback(for: identity, scenario: "identity reconciliation save")
    }

    func testIntentRefreshDistinguishesNotFoundAndNetworkFailure() async throws {
        let missingCenter = RefreshCenter(store: store, client: SudrfClient())
        let missingOutcome = await missingCenter.refreshForIntent(key: "missing")
        XCTAssertEqual(missingOutcome, .notFound)

        let unavailable = NetworkFailureMovement()
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in unavailable })
        let key = store.all()[0].key
        let outcome = await center.refreshForIntent(key: key)
        guard case .failed(let message) = outcome else {
            return XCTFail("ожидалась отдельная сетевая ошибка, получено \(outcome)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(store.record(forKey: key)?.sourceRefreshAttempt?.kind,
                       .transportFailure)
    }

    func testStaleWalkGenerationCannotUpdateNewProgress() {
        XCTAssertFalse(RefreshCenter.acceptsWalkProgress(generation: 4, currentGeneration: 5))
        XCTAssertTrue(RefreshCenter.acceptsWalkProgress(generation: 5, currentGeneration: 5))
    }

    func testNewActMarksPreviouslySeenCaseAsUpdated() async throws {
        let ctx = makeContext()
        let key = store.all()[0].key
        let oldMovement = successMV!
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.snapshot = MovementDerivation.snapshot(from: oldMovement, context: ctx)
        rec.movement = oldMovement
        rec.seenAt = Date()

        var updatedMovement = oldMovement
        updatedMovement.acts = [CaseAct(id: "act-1", title: "Решение", date: "10.04.2026",
                                        courtShort: "СГС", instanceLevel: .first)]
        let service = FixedMovement(updatedMovement)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })

        _ = await center.refresh(key: key)?.value

        XCTAssertNil(rec.seenAt, "новый акт должен вернуть бейдж «обновлено»")
        XCTAssertEqual(rec.snapshot?.actsFingerprint?.count, 1)
    }

    func testDerivedLifecycleRepairDoesNotMarkSeenCaseAsUpdated() async throws {
        let ctx = makeContext()
        let key = store.all()[0].key
        let movement = successMV!
        let rec = try XCTUnwrap(store.record(forKey: key))
        var staleSnapshot = MovementDerivation.snapshot(from: movement, context: ctx)
        staleSnapshot.stageRaw = CaseStageKind.cassation.rawValue
        staleSnapshot.stageTag = "кассация"
        staleSnapshot.statusText = "устаревший статус"
        staleSnapshot.statusChipRaw = Palette.Chip.blue.rawValue
        staleSnapshot.nextEvent = "устаревшее событие"
        staleSnapshot.nextChipRaw = Palette.Chip.blue.rawValue
        staleSnapshot.steps = ["done", "todo", "active"]
        let seenAt = Date(timeIntervalSince1970: 1_700_000_000)
        rec.snapshot = staleSnapshot
        rec.movement = movement
        rec.seenAt = seenAt
        let service = FixedMovement(movement)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })

        _ = await center.refresh(key: key)?.value

        XCTAssertEqual(rec.seenAt, seenAt,
                       "пересчёт только stage/status/steps не должен создавать бейдж")
        XCTAssertEqual(rec.snapshot?.stageRaw, CaseStageKind.first.rawValue)
    }

    func testChangedInstanceResultMarksSeenCaseAsUpdated() async throws {
        let ctx = makeContext()
        let key = store.all()[0].key
        let oldMovement = successMV!
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.snapshot = MovementDerivation.snapshot(from: oldMovement, context: ctx)
        rec.movement = oldMovement
        rec.seenAt = Date(timeIntervalSince1970: 1_700_000_000)

        var updatedMovement = oldMovement
        updatedMovement.instances[0].result = "В иске отказано"
        let service = FixedMovement(updatedMovement)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })

        _ = await center.refresh(key: key)?.value

        XCTAssertNil(rec.seenAt, "новый результат инстанции должен вернуть бейдж")
    }

    func testNewCourtWritMarksSeenCaseAsUpdated() async throws {
        let ctx = makeContext()
        let key = store.all()[0].key
        let oldMovement = successMV!
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.snapshot = MovementDerivation.snapshot(from: oldMovement, context: ctx)
        rec.movement = oldMovement
        rec.seenAt = Date(timeIntervalSince1970: 1_700_000_000)

        var updatedMovement = oldMovement
        updatedMovement.executionDocuments = [CourtEnforcementDocument(
            blankNumber: "ФС № 123456", courtStatus: "Выдан")]
        let service = FixedMovement(updatedMovement)
        let treasury = ScriptedTreasury([.lookup(EnforcementLookup(state: .notFound))])
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service },
                                   treasuryDiscover: { document, number, court in
                                       try await treasury.discover(document, caseNumber: number, court: court)
                                   },
                                   fsspDiscover: noFSSP)

        _ = await center.refresh(key: key)?.value

        XCTAssertNil(rec.seenAt, "новый исполнительный лист должен вернуть бейдж")
    }

    func testTransientHigherCourtStubDoesNotMarkSeenCaseAsUpdated() async throws {
        let ctx = makeContext()
        let key = store.all()[0].key
        let oldMovement = successMV!
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.snapshot = MovementDerivation.snapshot(from: oldMovement, context: ctx)
        rec.movement = oldMovement
        let seenAt = Date(timeIntervalSince1970: 1_700_000_000)
        rec.seenAt = seenAt

        var withStub = oldMovement
        withStub.instances.append(CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "—", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: false, result: nil, sessions: [],
            transientError: true))
        let service = FixedMovement(withStub)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })

        _ = await center.refresh(key: key)?.value

        XCTAssertEqual(rec.seenAt, seenAt,
                       "появление transient-заглушки не является событием дела")
    }

    func testTransientHigherCourtStubDisappearanceDoesNotMarkSeenCaseAsUpdated() async throws {
        let ctx = makeContext()
        let key = store.all()[0].key
        var oldMovement = successMV!
        oldMovement.instances.append(CaseInstance(
            level: .cassation, court: "3 КСОЮ", caseNumber: "—", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: false, result: nil, sessions: [],
            transientError: true))
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.snapshot = MovementDerivation.snapshot(from: oldMovement, context: ctx)
        rec.movement = oldMovement
        let seenAt = Date(timeIntervalSince1970: 1_700_000_000)
        rec.seenAt = seenAt
        let service = FixedMovement(successMV)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })

        _ = await center.refresh(key: key)?.value

        XCTAssertEqual(rec.seenAt, seenAt,
                       "исчезновение transient-заглушки не является событием дела")
    }

    func testActBodyFormattingChangeDoesNotMarkSeenCaseAsUpdated() async throws {
        let ctx = makeContext()
        let key = store.all()[0].key
        var oldMovement = successMV!
        oldMovement.acts = [CaseAct(id: "act-1", title: "Решение", date: "10.04.2026",
                                    courtShort: "СГС", instanceLevel: .first)]
        oldMovement.actBodies = ["act-1": "Иск удовлетворён."]
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.snapshot = MovementDerivation.snapshot(from: oldMovement, context: ctx)
        rec.movement = oldMovement
        let seenAt = Date(timeIntervalSince1970: 1_700_000_000)
        rec.seenAt = seenAt

        var reformatted = oldMovement
        reformatted.actBodies["act-1"] = "  Иск удовлетворён.\n"
        let service = FixedMovement(reformatted)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })

        _ = await center.refresh(key: key)?.value

        XCTAssertEqual(rec.seenAt, seenAt,
                       "форматирование тела уже известного акта не должно создавать бейдж")
    }

    func testUnavailableCourtDoesNotOverwriteSavedCard() async throws {
        let ctx = makeContext()
        let key = store.all()[0].key
        let rec = try XCTUnwrap(store.record(forKey: key))
        let savedMovement = successMV!
        let savedSnapshot = MovementDerivation.snapshot(from: savedMovement, context: ctx)
        let savedFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        rec.movement = savedMovement
        rec.snapshot = savedSnapshot
        rec.movementFetchedAt = savedFetchedAt

        let unavailable = UnavailableMovement()
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in unavailable })

        _ = await center.refresh(key: key)?.value

        XCTAssertEqual(rec.movement, savedMovement,
                       "недоступная карточка суда не должна затирать сохранённое движение")
        XCTAssertEqual(rec.snapshot, savedSnapshot,
                       "недоступная карточка суда не должна затирать снимок")
        XCTAssertEqual(rec.movementFetchedAt, savedFetchedAt,
                       "неудачная попытка не должна выглядеть успешным обновлением")
        XCTAssertEqual(rec.sourceRefreshAttempt?.kind, .maintenance)
        XCTAssertNotNil(center.lastErrors[key])
    }

    func testCancellationDoesNotPersistAttemptOrPublishFailure() async throws {
        let key = store.all()[0].key
        let rec = try XCTUnwrap(store.record(forKey: key))
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in CancelledMovement() })
        var refreshed = false
        var failed = false
        center.onRefreshed = { _, _, _ in refreshed = true }
        center.onRefreshFailed = { _, _ in failed = true }

        let execution = await center.refresh(key: key)?.value

        XCTAssertEqual(execution?.outcome, .cancelled)
        XCTAssertNil(rec.sourceRefreshAttempt)
        XCTAssertNil(center.lastErrors[key])
        XCTAssertFalse(refreshed)
        XCTAssertFalse(failed)
    }

    func testCancelTrackingStopsLateRefreshAndDoesNotRestoreDeletedRecord() async throws {
        let key = store.all()[0].key
        let service = SuspendedMovement(successMV)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })
        var refreshed = false
        var failed = false
        center.onRefreshed = { _, _, _ in refreshed = true }
        center.onRefreshFailed = { _, _ in failed = true }

        let task = center.refresh(key: key)!
        await service.waitUntilStarted()
        try store.remove(key: key)
        center.cancelTracking(for: key)
        await service.resume()
        _ = await task.value

        XCTAssertNil(store.record(forKey: key))
        XCTAssertFalse(center.isRefreshing(key))
        XCTAssertFalse(refreshed)
        XCTAssertFalse(failed)
    }

    func testCancelTrackingStopsPostCaptchaRetryFromWritingIntoRetrackedRecord() async throws {
        let context = makeContext()
        let key = store.all()[0].key
        let service = SuspendedCaptchaRetryMovement(formURL: formURL, value: successMV)
        let center = makeCenter(service: service) { _, _, _, _ in
            AutoCaptchaSolver.SolveResult(
                token: CaptchaToken(value: "12345", id: "cancelled-retry"),
                png: Data([1]))
        }
        var refreshed = false
        var failed = false
        center.onRefreshed = { _, _, _ in refreshed = true }
        center.onRefreshFailed = { _, _ in failed = true }

        let task = center.refresh(key: key)!
        await service.waitUntilRetryStarted()
        try store.remove(key: key)
        center.cancelTracking(for: key)
        _ = try store.upsert(context: context, snapshot: nil, movement: nil, collections: [])
        await service.resumeRetry()
        _ = await task.value

        XCTAssertNil(store.record(forKey: key)?.movement)
        XCTAssertFalse(center.isRefreshing(key))
        XCTAssertFalse(refreshed)
        XCTAssertFalse(failed)
    }

    func testCancelTrackingCanonicalKeyStopsTaskRegisteredBeforeRepairRemap() async throws {
        let old = makeContext()
        var canonical = old
        canonical.displayDomain = "canonical.komi.sudrf.ru"
        canonical.searchDomain = "canonical--komi.sudrf.ru"
        canonical.caseNumber = "2-291/2026"
        let movement = makeSuccessMovement(court: canonical.searchCourt)
        let service = SuspendedMovement(movement)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })
        center.repairBeforeRefresh = { [store] _ in
            guard let store else { return old.key }
            _ = try store.upsert(context: canonical, snapshot: nil, collections: [])
            try store.remove(key: old.key)
            return canonical.key
        }
        var refreshed = false
        center.onRefreshed = { _, _, _ in refreshed = true }

        let task = center.refresh(key: old.key)!
        await service.waitUntilStarted()
        try store.remove(key: canonical.key)
        center.cancelTracking(for: canonical.key)
        await service.resume()
        _ = await task.value

        XCTAssertNil(store.record(forKey: canonical.key))
        XCTAssertFalse(center.isRefreshing(old.key))
        XCTAssertFalse(refreshed)
    }

    func testCancelTrackingStopsLateEnforcementCallback() async throws {
        let key = store.all()[0].key
        let writ = paperWrit()
        var movement = successMV!
        movement.executionDocuments = [writ]
        let record = try XCTUnwrap(store.record(forKey: key))
        record.movement = movement
        let suspended = SuspendedFSSP(step: .notFound(EnforcementLookup(state: .notFound)))
        let center = RefreshCenter(
            store: store, client: SudrfClient(),
            fsspDiscover: { document in await suspended.discover(document) })
        var refreshed = false
        center.onEnforcementRefreshed = { _ in refreshed = true }

        let task = center.refreshEnforcement(key: key)!
        await suspended.waitUntilStarted()
        try store.remove(key: key)
        center.cancelTracking(for: key)
        await suspended.resume()
        await task.value

        XCTAssertNil(store.record(forKey: key))
        XCTAssertFalse(center.isRefreshingEnforcement(key))
        XCTAssertNil(center.enforcementError(forKey: key))
        XCTAssertFalse(refreshed)
    }

    func testCancelTrackingClearsCaptchaAndSourceErrors() async throws {
        let key = store.all()[0].key
        let writ = paperWrit()
        var movement = successMV!
        movement.executionDocuments = [writ]
        let record = try XCTUnwrap(store.record(forKey: key))
        record.movement = movement
        let treasury = ScriptedTreasury([.failure])
        let center = RefreshCenter(
            store: store, client: SudrfClient(),
            serviceBuilder: { _ in CaptchaMovement(url: self.formURL) },
            treasuryDiscover: { document, number, court in
                try await treasury.discover(document, caseNumber: number, court: court)
            },
            fsspDiscover: noFSSP)

        _ = await center.refreshEnforcement(key: key)?.value
        _ = await center.refresh(key: key)?.value
        XCTAssertNotNil(center.enforcementError(forKey: key))
        XCTAssertNotNil(center.lastErrors[key])
        XCTAssertNotNil(center.captchaPendingRequest(forKey: key))

        center.cancelTracking(for: key)

        XCTAssertNil(center.enforcementError(forKey: key))
        XCTAssertNil(center.lastErrors[key])
        XCTAssertNil(center.captchaPendingRequest(forKey: key))
        XCTAssertFalse(center.isRefreshing(key))
        XCTAssertFalse(center.isRefreshingEnforcement(key))
    }

    func testCancellationDuringAutoSolveDoesNotPersistCaptchaFailure() async throws {
        let key = store.all()[0].key
        let rec = try XCTUnwrap(store.record(forKey: key))
        let center = makeCenter { _, _, _, _ in
            AutoCaptchaSolver.SolveResult(token: nil, png: nil, cancelled: true)
        }
        var failed = false
        center.onRefreshFailed = { _, _ in failed = true }

        let execution = await center.refresh(key: key)?.value

        XCTAssertEqual(execution?.outcome, .cancelled)
        XCTAssertNil(rec.sourceRefreshAttempt)
        XCTAssertNil(center.lastErrors[key])
        XCTAssertFalse(failed)
    }

    func testCancellationDuringRepairPreflightStopsBeforeMovementFetch() async throws {
        let key = store.all()[0].key
        let movement = FixedMovement(successMV)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in movement })
        center.repairBeforeRefresh = { key in
            withUnsafeCurrentTask { $0?.cancel() }
            return key
        }

        let execution = await center.refresh(key: key)?.value
        let calls = await movement.calls

        XCTAssertEqual(execution?.outcome, .cancelled)
        XCTAssertEqual(calls, 0)
    }

    func testMoscowRefreshPersistsMosgorsudProvenance() async throws {
        var context = makeContext()
        context.searchDomain = MosGorSudEndpoint.host
        context.displayDomain = MosGorSudEndpoint.host
        context.caseNumber = "02-1234/2024"
        _ = try store.upsert(context: context, snapshot: nil, movement: nil, collections: [])
        let movement = makeSuccessMovement(court: context.searchCourt)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in FixedMovement(movement) })

        _ = await center.refresh(key: context.key)?.value

        let record = try XCTUnwrap(store.record(forKey: context.key))
        XCTAssertEqual(record.sourceRefreshAttempt?.provenance.sourceFamily, "mosgorsud")
        XCTAssertEqual(record.sourceRefreshAttempt?.provenance.host, MosGorSudEndpoint.host)
    }

    func testPartialRefreshAppliesUsablePayloadWithoutAdvancingLastSuccess() async throws {
        let ctx = makeContext()
        let key = store.all()[0].key
        let rec = try XCTUnwrap(store.record(forKey: key))
        let savedFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        rec.movement = successMV
        rec.snapshot = MovementDerivation.snapshot(from: successMV, context: ctx)
        rec.movementFetchedAt = savedFetchedAt

        var partial = successMV!
        partial.instances[0].judge = "Новый судья"
        partial.incompleteHigherCourtDomains = ["vs--komi.sudrf.ru"]
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in FixedMovement(partial) })

        let execution = await center.refresh(key: key)?.value

        guard case .partial = execution?.outcome else {
            return XCTFail("неполное движение нельзя выдавать за полный refresh")
        }
        XCTAssertEqual(rec.movement?.instances.first?.judge, "Новый судья")
        XCTAssertEqual(rec.movementFetchedAt, savedFetchedAt,
                       "partial не должен продлевать TTL полного успеха")
        XCTAssertEqual(rec.sourceRefreshAttempt?.kind, .partial)
        XCTAssertNotNil(center.lastErrors[key])
    }

    func testHonestZeroSubsourceDoesNotAdvanceLastSuccess() async throws {
        let ctx = makeContext()
        let key = store.all()[0].key
        let rec = try XCTUnwrap(store.record(forKey: key))
        let savedFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        rec.movement = successMV
        rec.snapshot = MovementDerivation.snapshot(from: successMV, context: ctx)
        rec.movementFetchedAt = savedFetchedAt

        var movement = successMV!
        movement.honestZeroDomains = ["vs--komi.sudrf.ru"]
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in FixedMovement(movement) })

        let execution = await center.refresh(key: key)?.value

        guard case .partial = execution?.outcome else {
            return XCTFail("honest-zero подисточника не является полным снимком движения")
        }
        XCTAssertEqual(rec.movementFetchedAt, savedFetchedAt)
        XCTAssertEqual(rec.sourceRefreshAttempt?.kind, .partial)
        XCTAssertEqual(rec.sourceRefreshAttempt?.provenance.affectedSources,
                       ["vs--komi.sudrf.ru"])
        XCTAssertNil(center.lastErrors[key])
    }

    func testPartialWarningCountsOnlyIncompleteSources() async throws {
        let key = store.all()[0].key
        var movement = successMV!
        movement.incompleteHigherCourtDomains = ["3kas.sudrf.ru"]
        movement.honestZeroDomains = ["vs--komi.sudrf.ru", "other.sudrf.ru"]
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in FixedMovement(movement) })

        let execution = await center.refresh(key: key)?.value

        let expected = "Не обновился источник 3kas.sudrf.ru; "
            + "сохранены последние успешные данные."
        XCTAssertEqual(execution?.outcome, .partial(expected))
        XCTAssertEqual(center.lastErrors[key], expected,
                       "honest-zero sources must not inflate the incomplete count")
    }

    func testTreasuryRefreshRunsAfterCourtFailureAndSavesResult() async throws {
        let ctx = makeContext()
        let key = store.all()[0].key
        let writ = paperWrit()
        var cached = successMV!
        cached.executionDocuments = [writ]
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.movement = cached
        rec.snapshot = MovementDerivation.snapshot(from: cached, context: ctx)
        rec.movementFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let event = EnforcementEvent(guid: "rss-1", date: Date(), text: "Документ принят",
                                     sourceOrder: 0)
        let result = enforcementRecord(document: writ, status: "Исполняется", events: [event])
        let treasury = ScriptedTreasury([.lookup(EnforcementLookup(state: .found, record: result))])
        let unavailable = UnavailableMovement()
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in unavailable },
                                   treasuryDiscover: { document, number, court in
                                       try await treasury.discover(document, caseNumber: number, court: court)
                                   },
                                   fsspDiscover: noFSSP)
        var refreshes = 0
        center.onEnforcementRefreshed = { _ in refreshes += 1 }

        let execution = await center.refresh(key: key)?.value

        guard case .failed = execution?.outcome else {
            return XCTFail("ошибка суда не должна маскироваться успехом Казначейства")
        }
        let checkedDocuments = await treasury.documents
        XCTAssertEqual(checkedDocuments, [writ.id])
        XCTAssertEqual(rec.movement, cached, "ошибка суда не должна стереть кэш")
        let treasuryRecord = try XCTUnwrap(rec.enforcementRecords.first {
            $0.source == .treasury
        })
        XCTAssertEqual(treasuryRecord.discoveryState, .found)
        XCTAssertEqual(treasuryRecord.events.map(\.id), [event.id])
        XCTAssertNotNil(center.lastErrors[key])
        XCTAssertEqual(refreshes, 1)
    }

    func testTreasuryChecksExactlyThreePaperWritsAndSkipsTwoElectronicIDs() async throws {
        let key = store.all()[0].key
        let paper = [
            paperWrit("paper-1", blank: "ФС № 1"),
            paperWrit("paper-2", blank: "ФС № 2"),
            paperWrit("paper-3", blank: "ФС № 3")
        ]
        let electronic = [
            CourtEnforcementDocument(id: "electronic-1", electronicID: "11RS#1"),
            CourtEnforcementDocument(id: "electronic-2", electronicID: "11RS#2")
        ]
        var movement = successMV!
        movement.executionDocuments = paper + electronic
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.movement = movement
        let treasury = ScriptedTreasury(Array(repeating: .lookup(
            EnforcementLookup(state: .notFound)), count: paper.count))
        let fssp = ScriptedFSSP(Array(repeating: .step(
            .notFound(EnforcementLookup(state: .notFound))), count: 5))
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   treasuryDiscover: { document, number, court in
                                       try await treasury.discover(
                                           document, caseNumber: number, court: court)
                                   },
                                   fsspDiscover: { document in
                                       try await fssp.discover(document)
                                   })

        _ = await center.refreshEnforcement(key: key)?.value

        let checkedDocuments = await treasury.documents
        let fsspDocuments = await fssp.documents
        XCTAssertEqual(Set(checkedDocuments), Set(paper.map(\.id)))
        XCTAssertEqual(fsspDocuments, (paper + electronic).map(\.id))
        XCTAssertEqual(rec.enforcementRecords.filter { $0.source == .treasury }.count, 3)
        XCTAssertEqual(rec.enforcementRecords.filter { $0.source == .bailiffs }.count, 5)
    }

    func testTreasurySkipsPaperWritDirectedToBailiffs() async throws {
        let key = store.all()[0].key
        let treasuryWrit = paperWrit("treasury", blank: "ФС № 1")
        let bailiffWrit = CourtEnforcementDocument(
            id: "bailiff", blankNumber: "ФС № 2", courtStatus: "Выдан",
            recipient: "Специализированный отдел судебных приставов")
        var movement = successMV!
        movement.executionDocuments = [treasuryWrit, bailiffWrit]
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.movement = movement
        let treasury = ScriptedTreasury([.lookup(EnforcementLookup(state: .notFound))])
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   treasuryDiscover: { document, number, court in
                                       try await treasury.discover(
                                           document, caseNumber: number, court: court)
                                   },
                                   fsspDiscover: noFSSP)

        _ = await center.refreshEnforcement(key: key)?.value

        let checkedDocuments = await treasury.documents
        XCTAssertEqual(checkedDocuments, [treasuryWrit.id])
        XCTAssertEqual(rec.enforcementRecords.filter { $0.source == .treasury }
            .map(\.courtDocumentID), [treasuryWrit.id])
    }

    func testPeriodicWalkChecksOnlyTreasuryWhenCourtCacheIsFresh() async throws {
        let key = store.all()[0].key
        let writ = paperWrit()
        var movement = successMV!
        movement.executionDocuments = [writ]
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.movement = movement
        rec.movementFetchedAt = Date()
        let service = FixedMovement(movement)
        let treasury = ScriptedTreasury([.lookup(EnforcementLookup(state: .notFound))])
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service },
                                   treasuryDiscover: { document, number, court in
                                       try await treasury.discover(
                                           document, caseNumber: number, court: court)
                                   },
                                   fsspDiscover: noFSSP)

        center.refreshAll(force: false)
        for _ in 0..<100 where rec.enforcementRecords.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        let checkedDocuments = await treasury.documents
        let courtCalls = await service.calls
        XCTAssertEqual(checkedDocuments, [writ.id])
        XCTAssertEqual(courtCalls, 0,
                       "свежую карточку суда не нужно запрашивать ради Казначейства")
        XCTAssertEqual(rec.enforcementRecords.first {
            $0.source == .treasury
        }?.discoveryState, .notFound)
    }

    func testForcedWalkDoesNotForceFreshEnforcementCheck() async throws {
        let key = store.all()[0].key
        let writ = paperWrit()
        var movement = successMV!
        movement.executionDocuments = [writ]
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.movement = movement
        rec.movementFetchedAt = .distantPast
        let checkedAt = Date()
        rec.enforcementRecords = [
            enforcementRecord(document: writ, attemptedAt: checkedAt),
            bailiffRecord(document: writ, state: .notFound, attemptedAt: checkedAt)
        ]

        let service = FixedMovement(movement)
        let treasury = ScriptedTreasury([])
        let fssp = ScriptedFSSP([])
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service },
                                   treasuryDiscover: { document, number, court in
                                       try await treasury.discover(
                                           document, caseNumber: number, court: court)
                                   },
                                   fsspDiscover: { document in
                                       try await fssp.discover(document)
                                   })

        center.refreshAll(force: true)
        for _ in 0..<100 {
            if await service.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 where center.isRefreshing(key) {
            try await Task.sleep(for: .milliseconds(10))
        }

        let courtCalls = await service.calls
        let treasuryCalls = await treasury.documents
        let fsspCalls = await fssp.documents
        XCTAssertEqual(courtCalls, 1, "forced walk must still refresh court movement")
        XCTAssertTrue(treasuryCalls.isEmpty,
                      "fresh enforcement must remain TTL-driven during forced walk")
        XCTAssertTrue(fsspCalls.isEmpty,
                      "fresh enforcement must remain TTL-driven during forced walk")
    }

    func testTreasuryErrorPreservesLastSuccessWithoutNewBadge() async throws {
        let key = store.all()[0].key
        let writ = paperWrit()
        var movement = successMV!
        movement.executionDocuments = [writ]
        let oldEvent = EnforcementEvent(guid: "rss-old", date: Date(), text: "Принят",
                                        sourceOrder: 0)
        let oldSuccess = Date(timeIntervalSince1970: 1_700_000_000)
        let old = enforcementRecord(document: writ, status: "Исполняется", events: [oldEvent],
                                    attemptedAt: oldSuccess)
        var oldFSSP = old
        oldFSSP.source = .bailiffs
        oldFSSP.discoveryState = .notFound
        oldFSSP.status = ""
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.movement = movement
        rec.enforcementRecords = [old, oldFSSP]
        let seenAt = Date(timeIntervalSince1970: 1_700_000_100)
        rec.seenAt = seenAt
        let treasury = ScriptedTreasury([.failure])
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   treasuryDiscover: { document, number, court in
                                       try await treasury.discover(document, caseNumber: number, court: court)
                                   },
                                   fsspDiscover: noFSSP)

        _ = await center.refreshEnforcement(key: key)?.value

        let saved = try XCTUnwrap(rec.enforcementRecords.first { $0.source == .treasury })
        XCTAssertEqual(saved.discoveryState, .found)
        XCTAssertEqual(saved.status, "Исполняется")
        XCTAssertEqual(saved.events, [oldEvent])
        XCTAssertEqual(saved.lastSuccessAt, oldSuccess)
        XCTAssertNotNil(saved.error)
        XCTAssertEqual(rec.seenAt, seenAt)
        XCTAssertNotNil(center.enforcementError(forKey: key))
    }

    func testTreasuryRechecksNotFoundAndTerminalWritsAfterSharedTTL() async throws {
        let key = store.all()[0].key
        let missing = paperWrit("court-writ-missing", blank: "ФС № 111")
        let terminal = paperWrit("court-writ-terminal", blank: "ФС № 222")
        var movement = successMV!
        movement.executionDocuments = [missing, terminal]
        let stale = Date.distantPast
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.movement = movement
        rec.enforcementRecords = [
            enforcementRecord(document: missing, state: .notFound, status: "", attemptedAt: stale),
            enforcementRecord(document: terminal, state: .found, status: "Исполнено", attemptedAt: stale)
        ]
        let treasury = ScriptedTreasury([
            .lookup(EnforcementLookup(state: .notFound)),
            .lookup(EnforcementLookup(state: .found,
                                      record: enforcementRecord(document: terminal,
                                                                 status: "Исполнено")))
        ])
        let service = FixedMovement(movement)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service },
                                   treasuryDiscover: { document, number, court in
                                       try await treasury.discover(document, caseNumber: number, court: court)
                                   },
                                   fsspDiscover: noFSSP)

        _ = await center.refresh(key: key)?.value

        let checkedDocuments = await treasury.documents
        XCTAssertEqual(Set(checkedDocuments), Set([missing.id, terminal.id]))
        XCTAssertEqual(Set(rec.enforcementRecords.map(\.discoveryState)), Set([.notFound, .found]))
    }

    func testInitialTreasuryDiscoveryMakesSeenCaseUnreadAndNotifiesRouter() async throws {
        let key = store.all()[0].key
        let writ = paperWrit()
        var movement = successMV!
        movement.executionDocuments = [writ]
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.movement = movement
        rec.seenAt = Date()
        let treasury = ScriptedTreasury([.lookup(EnforcementLookup(state: .notFound))])
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   treasuryDiscover: { document, number, court in
                                       try await treasury.discover(document, caseNumber: number, court: court)
                                   },
                                   fsspDiscover: noFSSP)
        var refreshes = 0
        center.onEnforcementRefreshed = { _ in refreshes += 1 }

        _ = await center.refreshEnforcement(key: key)?.value

        XCTAssertNil(rec.seenAt)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(rec.enforcementRecords.first {
            $0.source == .treasury
        }?.discoveryState, .notFound)
    }

    func testFSSPCaptchaPreservesLastBailiffResultAndSeenMarker() async throws {
        let key = store.all()[0].key
        let document = CourtEnforcementDocument(id: "electronic", electronicID: "11RS#captcha")
        var movement = successMV!
        movement.executionDocuments = [document]
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.movement = movement
        let oldDetails = BailiffEnforcementDetails(
            proceedingNumber: "587893/26/98078-ИП", debtor: "МКУ ДЕКАБРИСТ",
            department: "СОСП по г. Санкт-Петербургу")
        let old = bailiffRecord(document: document,
                               attemptedAt: Date(timeIntervalSince1970: 1_700_000_000),
                               details: oldDetails)
        rec.enforcementRecords = [old]
        let seenAt = Date(timeIntervalSince1970: 1_700_000_100)
        rec.seenAt = seenAt
        let challenge = FSSPCaptchaChallenge(
            courtDocumentID: document.id, codeID: "captcha-1", imagePNG: Data([1, 2, 3]),
            requestURL: URL(string: "https://is-go.fssp.gov.ru/ajax_search?code_id=captcha-1")!)
        let center = RefreshCenter(
            store: store, client: SudrfClient(),
            fsspDiscover: { _ in .captchaRequired(challenge) })

        _ = await center.refreshEnforcement(key: key)?.value

        let saved = try XCTUnwrap(rec.enforcementRecords.first { $0.source == .bailiffs })
        XCTAssertEqual(saved.discoveryState, .captchaRequired)
        XCTAssertEqual(saved.bailiffDetails, oldDetails)
        XCTAssertEqual(saved.lastSuccessAt, old.lastSuccessAt)
        XCTAssertEqual(rec.seenAt, seenAt,
                       "сама CAPTCHA не является новым изменением данных ФССП")
        XCTAssertNil(center.enforcementError(forKey: key))
    }

    func testFSSPTransportErrorPreservesLastBailiffResult() async throws {
        let key = store.all()[0].key
        let document = CourtEnforcementDocument(id: "electronic", electronicID: "11RS#error")
        var movement = successMV!
        movement.executionDocuments = [document]
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.movement = movement
        let oldDetails = BailiffEnforcementDetails(
            proceedingNumber: "123/26/98078-ИП", subjectAndOutstandingBalance: "10 000 руб.")
        let old = bailiffRecord(document: document,
                               attemptedAt: Date(timeIntervalSince1970: 1_700_000_000),
                               details: oldDetails)
        rec.enforcementRecords = [old]
        let center = RefreshCenter(
            store: store, client: SudrfClient(),
            fsspDiscover: { _ in throw URLError(.notConnectedToInternet) })

        _ = await center.refreshEnforcement(key: key)?.value

        let saved = try XCTUnwrap(rec.enforcementRecords.first { $0.source == .bailiffs })
        XCTAssertEqual(saved.discoveryState, .found)
        XCTAssertEqual(saved.bailiffDetails, oldDetails)
        XCTAssertNotNil(saved.error)
        XCTAssertNotNil(center.enforcementError(forKey: key))
    }

    func testBackgroundCaptchaCannotOverwriteConcurrentManualSuccess() async throws {
        let key = store.all()[0].key
        let document = CourtEnforcementDocument(id: "electronic", electronicID: "11RS#race")
        var movement = successMV!
        movement.executionDocuments = [document]
        let rec = try XCTUnwrap(store.record(forKey: key))
        rec.movement = movement
        let challenge = FSSPCaptchaChallenge(
            courtDocumentID: document.id, codeID: "stale", imagePNG: Data([1]),
            requestURL: URL(string: "https://is-go.fssp.gov.ru/ajax_search?code_id=stale")!)
        let suspended = SuspendedFSSP(step: .captchaRequired(challenge))
        let center = RefreshCenter(
            store: store, client: SudrfClient(),
            fsspDiscover: { document in await suspended.discover(document) })

        let background = try XCTUnwrap(center.refreshEnforcement(key: key))
        await suspended.waitUntilStarted()
        let details = BailiffEnforcementDetails(proceedingNumber: "1/26/98078-ИП")
        let manualRecord = bailiffRecord(document: document, attemptedAt: Date(), details: details)
        try center.applyFSSPSearchStep(
            key: key, document: document,
            step: .found(EnforcementLookup(state: .found, record: manualRecord)))
        await suspended.resume()
        await background.value

        let saved = try XCTUnwrap(rec.enforcementRecords.first { $0.source == .bailiffs })
        XCTAssertEqual(saved.discoveryState, .found)
        XCTAssertEqual(saved.bailiffDetails, details)
    }

    func testEnforcementCommitFailureReportsPersistenceErrorWithoutSuccessCallback() throws {
        let key = try XCTUnwrap(store.all().first?.key)
        let document = CourtEnforcementDocument(id: "electronic", electronicID: "11RS#save")
        let record = try XCTUnwrap(store.record(forKey: key))
        var movement = successMV!
        movement.executionDocuments = [document]
        record.movement = movement
        try store.save()
        let previous = record.enforcementRecords
        let update = bailiffRecord(
            document: document,
            details: BailiffEnforcementDetails(proceedingNumber: "1/26/98078-ИП"))
        let center = RefreshCenter(store: store, client: SudrfClient())
        var refreshed = false
        center.onEnforcementRefreshed = { _ in refreshed = true }
        store.failNextSaveForTesting = true

        XCTAssertThrowsError(try center.applyFSSPSearchStep(
            key: key, document: document,
            step: .found(EnforcementLookup(state: .found, record: update))
        )) { error in
            guard case .contextSave = error as? TrackedStoreCommitError else {
                return XCTFail("Expected context-save failure, got \(error)")
            }
        }

        XCTAssertEqual(store.record(forKey: key)?.enforcementRecords, previous)
        XCTAssertEqual(center.enforcementError(forKey: key),
                       "Не удалось сохранить обновление дела в локальной базе. Повторите попытку.")
        XCTAssertFalse(refreshed)
    }

    func testHigherCourtCaptchaStubDoesNotPersistCassationStage() async throws {
        let key = store.all()[0].key
        var movement = successMV!
        movement.instances.append(CaseInstance(
            level: .cassation, court: "Третий кассационный суд общей юрисдикции",
            caseNumber: "—", judge: nil, domain: "3kas.sudrf.ru",
            foundByUID: false, result: nil, sessions: [],
            captchaFormURL: URL(string: "https://3kas.sudrf.ru/modules.php?name=sud_delo")))
        let service = FixedMovement(movement)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })

        _ = await center.refresh(key: key)?.value

        let record = try XCTUnwrap(store.record(forKey: key))
        XCTAssertEqual(record.snapshot?.stageRaw, CaseStageKind.first.rawValue)
        XCTAssertEqual(record.snapshot?.steps, ["active", "todo", "todo", "todo"])
        XCTAssertFalse(record.movement?.instances.contains {
            $0.captchaFormURL != nil
        } ?? true)
    }
}
