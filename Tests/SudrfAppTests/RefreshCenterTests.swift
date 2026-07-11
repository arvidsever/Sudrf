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
        await center.refresh(key: key)?.value

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
        await center.refresh(key: key)?.value

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
        await center.refresh(key: key)?.value

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
}
