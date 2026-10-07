import AppKit
import SwiftData
import SwiftUI
import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class CalendarMonthViewTests: XCTestCase {
    private struct Fixture {
        let router: AppRouter
        let recordKey: String
        let caseNumber: String
        let movement: CaseMovement
        let september28: Date
        let october1: Date
        let october4: Date
        let march1: Date
    }

    func testNavigationButtonFramesStayFixedAcrossPeriodsAndOverlapCounts() async throws {
        let fixture = try makeFixture()
        let originalHearings = fixture.router.calendarHearings
        // One host per width: period and overlap changes must update the same tree.
        for width: CGFloat in [760, 1180, 1920] {
            fixture.router.calMode = .month
            fixture.router.calSelectedDate = nil
            let frames = NavigationFrames()
            let root = AnyView(CalendarScreen().environmentObject(fixture.router)
                .overlayPreferenceValue(CalendarNavigationBounds.self) { anchors in
                    GeometryReader { geometry in
                        let bounds = anchors.mapValues { geometry[$0] }
                        Color.clear.preference(key: NavigationFramePreference.self, value: bounds)
                    }
                }
                .onPreferenceChange(NavigationFramePreference.self) { bounds in
                    Task { @MainActor in frames.update(bounds) }
                }
                .frame(width: width, height: 760))
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 760),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            let hosted = (window: window, view: view)
            await renderNavigation(view, forceDisplay: true)
            defer { hosted.window.close() }
            let monthFrames = try frames.ordered()
            for month in 1...12 {
                fixture.router.calMonth = try XCTUnwrap(DateUtil.parse("01.\(month).2026"))
                for count in [0, 2, 12] {
                    let day = DateUtil.addDays(fixture.router.calMonth, 1)
                    fixture.router.calendarHearings = (0..<count).flatMap { offset in
                        originalHearings.prefix(2).map { event in
                            var event = event
                            event.date = DateUtil.addDays(day, offset)
                            return event
                        }
                    }
                    await renderNavigation(hosted.view)
                    assertFrames(try frames.ordered(), equal: monthFrames,
                                 context: "month=\(month), count=\(count), width=\(width)")
                }
            }
            let weekUpdate = frames.expectChangedBounds()
            fixture.router.calMode = .week
            await renderNavigation(hosted.view, forceDisplay: true)
            await fulfillment(of: [weekUpdate], timeout: 5)
            let weekFrames = try frames.ordered()
            for date in ["27.07.2026", "03.08.2026", "28.12.2026", "04.01.2027"] {
                fixture.router.calWeekStart = try XCTUnwrap(DateUtil.parse(date))
                await renderNavigation(hosted.view)
                assertFrames(try frames.ordered(), equal: weekFrames,
                             context: "week=\(date), width=\(width)")
            }
        }
    }

    private final class NavigationFrames {
        private var values: [String: CGRect] = [:]
        private var pendingChange: (previous: [String: CGRect], expectation: XCTestExpectation)?

        func expectChangedBounds() -> XCTestExpectation {
            let expectation = XCTestExpectation(description: "New mode's actual navigation bounds")
            pendingChange = (values, expectation)
            return expectation
        }

        func update(_ bounds: [String: CGRect]) {
            values = bounds
            if let pendingChange, !bounds.isEmpty, bounds != pendingChange.previous {
                self.pendingChange = nil
                pendingChange.expectation.fulfill()
            }
        }

        func ordered() throws -> [CGRect] {
            try ["previous", "current", "next"].map { name in
                let frame = try XCTUnwrap(values[name], "Missing actual button geometry: \(name)")
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                return frame
            }
        }
    }

    private func renderNavigation(_ view: NSView, forceDisplay: Bool = false) async {
        view.layoutSubtreeIfNeeded()
        if forceDisplay, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        // Preference delivery schedules a MainActor task. Yield through the main
        // queue after the forced render before reading its captured geometry.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private struct NavigationFramePreference: PreferenceKey {
        static var defaultValue: [String: CGRect] { [:] }
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private func assertFrames(_ actual: [CGRect], equal expected: [CGRect], context: String) {
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, context)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, context)
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, context)
            XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, context)
        }
    }

    func testNeighborDaysExposeFullYearAndRemainSelectableInBothMonths() throws {
        let fixture = try makeFixture()
        let hosted = host(fixture.router, size: CGSize(width: 1180, height: 720))
        defer { hosted.window.close() }
        try requireAccessibilityTree(in: hosted.view)

        for month in ["01.09.2026", "01.10.2026"] {
            let expectedMonth = DateUtil.startOfMonth(try XCTUnwrap(DateUtil.parse(month)))
            fixture.router.calMonth = expectedMonth
            fixture.router.calSelectedDate = nil
            settle(hosted.view)

            let day = try XCTUnwrap(accessibilityElement(
                in: hosted.view, identifier: dayIdentifier(fixture.september28)),
                "Missing September 28 cell for \(month)")
            XCTAssertTrue((accessibilityValue("accessibilityLabel", from: day) ?? "")
                .contains("28 сентября 2026 года"))
            XCTAssertTrue(press(day))
            XCTAssertEqual(fixture.router.calSelectedDate, fixture.september28)
            XCTAssertEqual(fixture.router.calMonth, expectedMonth)

            if month == "01.09.2026" {
                let initialLabel = accessibilityValue("accessibilityLabel", from: day) ?? ""
                XCTAssertTrue(initialLabel.contains("4 заседания"))
                fixture.router.calendarHearings.removeAll { $0.time == "14:00" }
                settle(hosted.view)
                let updatedDay = try XCTUnwrap(accessibilityElement(
                    in: hosted.view, identifier: dayIdentifier(fixture.september28)))
                let updatedLabel = accessibilityValue("accessibilityLabel", from: updatedDay) ?? ""
                XCTAssertTrue(updatedLabel.contains("3 заседания"))
                XCTAssertFalse(updatedLabel.contains("4 заседания"))

                for (date, expectedTime) in [(fixture.october1, "11:15"),
                                             (fixture.october4, "09:00")] {
                    let neighbor = try XCTUnwrap(accessibilityElement(
                        in: hosted.view, identifier: dayIdentifier(date)))
                    let label = accessibilityValue("accessibilityLabel", from: neighbor) ?? ""
                    XCTAssertTrue(label.contains(DateUtil.fullDate(date)))
                    XCTAssertTrue(label.contains(expectedTime))
                    XCTAssertTrue(press(neighbor))
                    XCTAssertEqual(fixture.router.calSelectedDate, date)
                    XCTAssertEqual(fixture.router.calMonth, expectedMonth)
                }
            }
        }

        fixture.router.calMonth = DateUtil.startOfMonth(DateUtil.addDays(fixture.march1, -1))
        fixture.router.calSelectedDate = nil
        settle(hosted.view)
        let sunday = try XCTUnwrap(accessibilityElement(
            in: hosted.view, identifier: dayIdentifier(fixture.march1)))
        let sundayLabel = accessibilityValue("accessibilityLabel", from: sunday) ?? ""
        XCTAssertTrue(sundayLabel.contains("1 марта 2026 года"))
        XCTAssertTrue(sundayLabel.contains("накладка"))
        XCTAssertTrue(sundayLabel.contains("в истории"))
    }

    func testTodayModeAndCachedCaseButtonsUseTheSyntheticRouter() throws {
        let fixture = try makeFixture()
        fixture.router.calMonth = DateUtil.startOfMonth(fixture.september28)
        fixture.router.calMode = .month
        fixture.router.calSelectedDate = nil
        let hosted = host(fixture.router, size: CGSize(width: 1280, height: 760))
        defer { hosted.window.close() }
        try requireAccessibilityTree(in: hosted.view)

        let day = try XCTUnwrap(accessibilityElement(
            in: hosted.view, identifier: dayIdentifier(fixture.september28)))
        XCTAssertTrue(press(day))
        XCTAssertEqual(fixture.router.calSelectedDate, fixture.september28)

        settle(hosted.view)
        let weekMode = try XCTUnwrap(accessibilityElement(in: hosted.view, label: "Неделя"))
        XCTAssertTrue(press(weekMode))
        XCTAssertEqual(fixture.router.calMode, .week)

        fixture.router.calWeekStart = DateUtil.addDays(DateUtil.startOfWeek(DateUtil.today), -7)
        settle(hosted.view)
        let thisWeek = try XCTUnwrap(accessibilityElement(in: hosted.view, label: "Эта неделя"))
        XCTAssertTrue(press(thisWeek))
        XCTAssertEqual(fixture.router.calWeekStart, DateUtil.startOfWeek(DateUtil.today))
        XCTAssertEqual(fixture.router.calSelectedDate, DateUtil.today)
        settle(hosted.view)

        let monthMode = try XCTUnwrap(accessibilityElement(in: hosted.view, label: "Месяц"))
        XCTAssertTrue(press(monthMode))
        XCTAssertEqual(fixture.router.calMode, .month)
        settle(hosted.view)

        fixture.router.calMonth = DateUtil.startOfMonth(fixture.september28)
        settle(hosted.view)
        let september28 = try XCTUnwrap(accessibilityElement(
            in: hosted.view, identifier: dayIdentifier(fixture.september28)))
        XCTAssertTrue(press(september28))
        settle(hosted.view)

        let openCase = try XCTUnwrap(accessibilityElement(in: hosted.view, label: "Открыть дело"))
        XCTAssertTrue(press(openCase))
        XCTAssertEqual(fixture.router.openedCase, fixture.caseNumber)
        XCTAssertEqual(fixture.router.liveMovement, fixture.movement)
        XCTAssertFalse(fixture.router.loadingMovement)
        XCTAssertFalse(fixture.router.refreshCenter.isRefreshing(fixture.recordKey))
    }

    func testMonthScreensRenderForVisualReview() throws {
        let fixture = try makeFixture()
        let outputDirectory = ProcessInfo.processInfo.environment["SUDRF_CALENDAR_VISUAL_OUTPUT"]

        for (monthString, monthName) in [("01.09.2026", "2026-09"), ("01.10.2026", "2026-10")] {
            fixture.router.calMonth = DateUtil.startOfMonth(try XCTUnwrap(DateUtil.parse(monthString)))
            fixture.router.calSelectedDate = nil
            for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                let png = try renderPNG(fixture.router, size: CGSize(width: 1280, height: 760),
                                        colorScheme: scheme)
                XCTAssertGreaterThan(png.count, 5_000)
                try save(png, name: "\(monthName)-\(suffix).png", to: outputDirectory)
            }
        }

        fixture.router.calMonth = DateUtil.startOfMonth(DateUtil.addDays(fixture.march1, -1))
        fixture.router.calSelectedDate = nil
        let narrow = try renderPNG(fixture.router, size: CGSize(width: 760, height: 660),
                                   colorScheme: .light)
        XCTAssertGreaterThan(narrow.count, 5_000)
        try save(narrow, name: "2026-02-narrow-march-01.png", to: outputDirectory)

        fixture.router.calMonth = DateUtil.startOfMonth(fixture.september28)
        fixture.router.calSelectedDate = fixture.september28
        let selectedDay = try renderPNG(fixture.router, size: CGSize(width: 1280, height: 760),
                                        colorScheme: .light)
        XCTAssertGreaterThan(selectedDay.count, 5_000)
        try save(selectedDay, name: "2026-09-selected-day.png", to: outputDirectory)

        fixture.router.calMonth = DateUtil.startOfMonth(DateUtil.addDays(fixture.march1, -1))
        fixture.router.calSelectedDate = fixture.march1
        let narrowSelectedDay = try renderPNG(fixture.router, size: CGSize(width: 1180, height: 720),
                                              colorScheme: .light)
        XCTAssertGreaterThan(narrowSelectedDay.count, 5_000)
        try save(narrowSelectedDay, name: "2026-02-march-01-panel.png", to: outputDirectory)
    }

    private func makeFixture() throws -> Fixture {
        let september28 = try XCTUnwrap(DateUtil.parse("28.09.2026"))
        let october1 = try XCTUnwrap(DateUtil.parse("01.10.2026"))
        let october4 = try XCTUnwrap(DateUtil.parse("04.10.2026"))
        let march1 = try XCTUnwrap(DateUtil.parse("01.03.2026"))
        let caseNumber = "2-351/2026"
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001",
            cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: caseNumber,
            caseID: "calendar-month-fixture",
            caseUID: "calendar-month-fixture")

        let movement = CaseMovement(
            uid: "11RS0001-01-2026-000351-13", caseNumber: caseNumber, inForce: false,
            instances: [
                CaseInstance(level: .first, court: "Сыктывкарский городской суд",
                             caseNumber: caseNumber, judge: "Иванов И. И.",
                             domain: "syktsud--komi.sudrf.ru", foundByUID: false,
                             result: nil, sessions: [
                                CaseSession(date: "28.09.2026", time: "10:00", room: "101",
                                            event: "Судебное заседание"),
                                CaseSession(date: "28.09.2026", time: "14:00", room: "101",
                                            event: "Судебное заседание")
                             ]),
                CaseInstance(level: .appeal, court: "Верховный суд Республики Коми",
                             caseNumber: "66а-351/2026", judge: "Петров П. П.",
                             domain: "vs--komi.sudrf.ru", foundByUID: true,
                             result: nil, sessions: [
                                CaseSession(date: "28.09.2026", time: "10:30", room: "2",
                                            event: "Судебное заседание")
                             ]),
                CaseInstance(level: .material, court: "Сыктывкарский городской суд",
                             caseNumber: "13-35/2026", judge: "Сидорова А. А.",
                             domain: "syktsud--komi.sudrf.ru", foundByUID: true,
                             result: nil, sessions: [
                                CaseSession(date: "28.09.2026", time: "12:05", room: "18",
                                            event: "Судебное заседание")
                             ])
            ], complaints: [:], acts: [])

        let deadlines = [
            StoredDeadline(kind: "appeal", what: "Активный срок", basis: "Синтетический срок",
                           calLabel: "апелляционный срок",
                           dateRef: september28.timeIntervalSinceReferenceDate,
                           statusRaw: DeadlineStatus.confirmed.rawValue,
                           occurrenceKey: "calendar-month|active",
                           lifecycleRaw: DeadlineLifecycle.active.rawValue),
            StoredDeadline(kind: "appeal", what: "Срок в истории", basis: "Синтетическая история",
                           calLabel: "исторический срок",
                           dateRef: september28.timeIntervalSinceReferenceDate,
                           statusRaw: DeadlineStatus.proposed.rawValue,
                           occurrenceKey: "calendar-month|september-history",
                           lifecycleRaw: DeadlineLifecycle.superseded.rawValue),
            StoredDeadline(kind: "appeal", what: "История на 1 марта", basis: "Синтетическая история",
                           calLabel: "исторический срок",
                           dateRef: march1.timeIntervalSinceReferenceDate,
                           statusRaw: DeadlineStatus.proposed.rawValue,
                           occurrenceKey: "calendar-month|march-history",
                           lifecycleRaw: DeadlineLifecycle.expiredUnconfirmed.rawValue)
        ]
        let snapshot = CaseSnapshot(
            uid: movement.uid, inForce: false, category: nil,
            partiesShort: "Иванов А. А. · Петров Б. Б.", leadCharges: nil,
            secondPartyLine: nil, stageRaw: CaseStageKind.first.rawValue,
            stageTag: "", statusText: "В производстве",
            statusChipRaw: Palette.Chip.blue.rawValue, lastEvent: "—", nextEvent: "—",
            nextChipRaw: Palette.Chip.gray.rawValue, steps: [], sessions: [], deadlines: deadlines,
            actsFingerprint: nil)

        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true,
                                     projectionSynchronizer: { _, _ in })
        let record = try store.upsert(context: context, snapshot: snapshot,
                                      movement: movement, collections: [])
        let router = try withIsolatedRouterDefaults {
            try AppRouter(modelContainer: container, modelContainerIsPrepared: true,
                          trackedStoreProjectionSynchronizer: { _, _ in })
        }
        router.calMonth = DateUtil.startOfMonth(september28)
        router.calWeekStart = DateUtil.startOfWeek(september28)
        router.calSelectedDate = nil
        router.calendarHearings = [
            hearing(recordKey: record.key, date: september28, time: "10:00",
                    caseNumber: caseNumber, court: "Сыктывкарский городской суд",
                    level: .first, instanceNumber: caseNumber),
            hearing(recordKey: record.key, date: september28, time: "10:30",
                    caseNumber: caseNumber, court: "Верховный суд Республики Коми",
                    level: .appeal, instanceNumber: "66а-351/2026"),
            hearing(recordKey: record.key, date: september28, time: "12:05",
                    caseNumber: caseNumber, court: "Сыктывкарский городской суд",
                    level: .material, instanceNumber: "13-35/2026"),
            hearing(recordKey: record.key, date: september28, time: "14:00",
                    caseNumber: caseNumber, court: "Сыктывкарский городской суд",
                    level: .first, instanceNumber: caseNumber),
            hearing(recordKey: record.key, date: october1, time: "11:15",
                    caseNumber: caseNumber, court: "Сыктывкарский городской суд",
                    level: .first, instanceNumber: caseNumber),
            hearing(recordKey: record.key, date: october4, time: "09:00",
                    caseNumber: caseNumber, court: "Верховный суд Республики Коми",
                    level: .appeal, instanceNumber: "66а-351/2026"),
            hearing(recordKey: record.key, date: march1, time: "09:00",
                    caseNumber: caseNumber, court: "Сыктывкарский городской суд",
                    level: .first, instanceNumber: caseNumber),
            hearing(recordKey: record.key, date: march1, time: "09:20",
                    caseNumber: caseNumber, court: "Верховный суд Республики Коми",
                    level: .appeal, instanceNumber: "66а-351/2026")
        ]
        return Fixture(router: router, recordKey: record.key, caseNumber: caseNumber,
                       movement: movement, september28: september28,
                       october1: october1, october4: october4, march1: march1)
    }

    private func hearing(recordKey: String, date: Date, time: String,
                         caseNumber: String, court: String,
                         level: CaseInstance.Level, instanceNumber: String) -> TrackedHearing {
        TrackedHearing(recordKey: recordKey, date: date, time: time,
                       caseNumber: caseNumber, parties: "Иванов А. А. · Петров Б. Б.",
                       court: court, room: "101", dateLabel: DateUtil.fullDate(date),
                       judge: "Иванов И. И.", identitySuffix: "fixture-\(time)",
                       instanceCaseNumber: instanceNumber, instanceLevel: level)
    }

    private func withIsolatedRouterDefaults<T>(_ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = original
        arguments["overviewReadFeedIDs.v1"] = [String]()
        arguments["notifiedFeedIDs.v1"] = [String]()
        arguments["captcha.maxAttempts"] = CaptchaSettings.defaultMaxAttempts
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        return try body()
    }

    private func host(_ router: AppRouter, size: CGSize)
        -> (window: NSWindow, view: NSHostingView<AnyView>) {
        let app = NSApplication.shared
        app.activate(ignoringOtherApps: true)
        let root = AnyView(CalendarScreen()
            .environmentObject(router)
            .frame(width: size.width, height: size.height))
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        settle(view)
        return (window, view)
    }

    private func requireAccessibilityTree(in view: NSHostingView<AnyView>) throws {
        let regularChildren = view.accessibilityChildren() ?? []
        let navigationChildren = view.accessibilityChildrenInNavigationOrder() ?? []
        guard !regularChildren.isEmpty || !navigationChildren.isEmpty else {
            throw XCTSkip("NSHostingView returned no in-process AX children in either order after window hosting; this process cannot traverse the SwiftUI controls.")
        }
    }

    private func settle(_ view: NSView) {
        view.window?.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
    }

    private func dayIdentifier(_ day: Date) -> String {
        "calendar-day-\(DateUtil.startOfDay(day).timeIntervalSince1970)"
    }

    private func accessibilityElement(in root: NSView,
                                      identifier: String? = nil,
                                      label: String? = nil) -> AnyObject? {
        var pending: [AnyObject] = [root]
        var visited = Set<ObjectIdentifier>()
        while let element = pending.popLast() {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            if (identifier == nil || accessibilityValue("accessibilityIdentifier", from: element) == identifier),
               (label == nil || accessibilityValue("accessibilityLabel", from: element) == label),
               identifier != nil || label != nil {
                return element
            }
            pending.append(contentsOf: accessibilityChildren(of: element))
        }
        return nil
    }

    private func accessibilityChildren(of element: AnyObject) -> [AnyObject] {
        let children: [Any]
        if let host = element as? NSHostingView<AnyView> {
            let regularChildren = host.accessibilityChildren() ?? []
            children = regularChildren.isEmpty
                ? (host.accessibilityChildrenInNavigationOrder() ?? [])
                : regularChildren
        } else if let accessibility = element as? NSAccessibilityProtocol {
            children = accessibility.accessibilityChildren() ?? []
        } else if let children = accessibilityObjectValue("accessibilityChildren", from: element) as? [Any] {
            return NSAccessibility.unignoredChildren(from: children) as [AnyObject]
        } else {
            return []
        }
        return NSAccessibility.unignoredChildren(from: children) as [AnyObject]
    }

    private func accessibilityValue(_ key: String, from element: AnyObject) -> String? {
        if let accessibility = element as? NSAccessibilityProtocol {
            return switch key {
            case "accessibilityIdentifier": accessibility.accessibilityIdentifier()
            case "accessibilityLabel": accessibility.accessibilityLabel()
            default: nil
            }
        }
        return accessibilityObjectValue(key, from: element) as? String
    }

    private func press(_ element: AnyObject) -> Bool {
        if let accessibility = element as? NSAccessibilityProtocol {
            return accessibility.accessibilityPerformPress()
        }
        guard let object = element as? NSObject else { return false }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias PressFunction = @convention(c) (AnyObject, Selector) -> Bool
        let press = unsafeBitCast(object.method(for: selector), to: PressFunction.self)
        return press(object, selector)
    }

    private func accessibilityObjectValue(_ name: String, from element: AnyObject) -> AnyObject? {
        guard let object = element as? NSObject else { return nil }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func renderPNG(_ router: AppRouter, size: CGSize,
                           colorScheme: ColorScheme) throws -> Data {
        let view = CalendarScreen()
            .environmentObject(router)
            .environment(\.colorScheme, colorScheme)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        return try XCTUnwrap(image.tiffRepresentation
            .flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
    }

    private func save(_ png: Data, name: String, to directory: String?) throws {
        guard let directory, !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try png.write(to: url.appendingPathComponent(name))
    }
}
