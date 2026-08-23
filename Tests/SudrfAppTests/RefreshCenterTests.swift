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
        store.upsert(context: ctx, snapshot: nil, movement: nil, collections: [])
        // Чистый стор на нужный домен — иначе возможный хвост от
        // предыдущего тестового прогона даст ложный «успех без solve».
        await CaptchaTokenStore.shared.invalidate(domain: "syktsud--komi.sudrf.ru")

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
        store = nil
        scripted = nil
        try await super.tearDown()
    }

    private func makeCenter(
        autoSolve: @escaping (URL, SudrfClient, CaptchaSolver,
                              AutoCaptchaSolver.Settings)
            async -> AutoCaptchaSolver.SolveResult
    ) -> RefreshCenter {
        let solver = CaptchaSolver(provider: NeverUsedProvider())
        return RefreshCenter(
            store: store,
            client: SudrfClient(),
            captchaSolver: solver,
            captchaSettings: CaptchaSettings.shared,
            autoSolve: autoSolve,
            serviceBuilder: { [scripted] _ in scripted }
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
        center.onRefreshed = { key, _ in callbackKey = key }
        center.repairBeforeRefresh = { [store] key in
            XCTAssertEqual(key, old.key)
            store?.upsert(context: canonical, snapshot: nil, collections: [])
            store?.remove(key: old.key)
            return canonical.key
        }

        let execution = await center.refresh(key: old.key)?.value

        XCTAssertNil(store.record(forKey: old.key))
        XCTAssertNotNil(store.record(forKey: canonical.key)?.movement)
        XCTAssertEqual(callbackKey, canonical.key)
        XCTAssertEqual(execution?.effectiveKey, canonical.key)
        XCTAssertEqual(execution?.outcome, .refreshed)
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
            store?.upsert(context: canonical, snapshot: nil, collections: [])
            store?.remove(key: old.key)
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
            store?.upsert(context: canonical, snapshot: nil, collections: [])
            store?.remove(key: old.key)
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
        center.onRefreshed = { key, _ in refreshedKeys.append(key) }

        let key = store.all()[0].key
        _ = await center.refresh(key: key)?.value

        let calls = await scripted.calls
        XCTAssertEqual(calls.count, 2,
                       "после успешного solve должно быть 2 вызова movement (1 captcha + 1 retry)")
        let rec = store.record(forKey: key)
        XCTAssertNotNil(rec?.movementFetchedAt,
                        "movementFetchedAt должен быть выставлен после retry")
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

    func testIntentRefreshDistinguishesNotFoundAndNetworkFailure() async throws {
        let missingCenter = RefreshCenter(store: store, client: SudrfClient())
        let missingOutcome = await missingCenter.refreshForIntent(key: "missing")
        XCTAssertEqual(missingOutcome, .notFound)

        let unavailable = UnavailableMovement()
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in unavailable })
        let outcome = await center.refreshForIntent(key: store.all()[0].key)
        guard case .failed(let message) = outcome else {
            return XCTFail("ожидалась отдельная сетевая ошибка, получено \(outcome)")
        }
        XCTAssertFalse(message.isEmpty)
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
        XCTAssertNotNil(center.lastErrors[key])
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
        center.applyFSSPSearchStep(
            key: key, document: document,
            step: .found(EnforcementLookup(state: .found, record: manualRecord)))
        await suspended.resume()
        await background.value

        let saved = try XCTUnwrap(rec.enforcementRecords.first { $0.source == .bailiffs })
        XCTAssertEqual(saved.discoveryState, .found)
        XCTAssertEqual(saved.bailiffDetails, details)
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
        XCTAssertEqual(record.snapshot?.steps, ["active", "todo", "todo"])
        XCTAssertFalse(record.movement?.instances.contains {
            $0.captchaFormURL != nil
        } ?? true)
    }
}
