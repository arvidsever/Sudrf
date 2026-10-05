import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import SudrfApp

@MainActor
final class LocalCaseFilterAccessibilityTests: XCTestCase {
    func testGroupedFilterControlsAndMatchExplanation() throws {
        guard ProcessInfo.processInfo.environment["SUDRF_FILTER403_QA_OUTPUT"] != nil else {
            throw XCTSkip("Set SUDRF_FILTER403_QA_OUTPUT for isolated native accessibility QA")
        }
        _ = NSApplication.shared
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        _ = try LocalFilter403Fixture.seed(container, count: 2)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.myView = .stages
        router.query = "Ермаков"
        let expected = try XCTUnwrap(LocalCaseFilter.explanation(
            for: try XCTUnwrap(router.filteredCases().first), query: router.query))

        let root = AnyView(MyCasesView().environmentObject(router)
            .frame(width: 1320, height: 800))
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1320, height: 800),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(view)
        guard !(view.accessibilityChildren() ?? []).isEmpty
                || !(view.accessibilityChildrenInNavigationOrder() ?? []).isEmpty else {
            throw XCTSkip("NSHostingView returned no in-process AX children after window hosting")
        }

        let groupedNodes = accessibilityNodes(in: view)
        XCTAssertTrue(groupedNodes.contains { accessibilityHelp($0)?.contains(expected) == true },
            "No filtered card exposes its match explanation as AX help")
        let changeView = try XCTUnwrap(groupedNodes.first { accessibilityLabel($0) == "Изменить в списке" })
        XCTAssertTrue(press(changeView))
        settle(view)
        XCTAssertEqual(router.myView, .list)
        XCTAssertEqual(router.query, "Ермаков")

        let clear = try XCTUnwrap(accessibilityNodes(in: view).first {
            accessibilityLabel($0) == "Очистить фильтр"
        })
        XCTAssertTrue(press(clear))
        settle(view)
        XCTAssertTrue(router.query.isEmpty)
    }

    private func settle(_ view: NSView) {
        view.window?.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func accessibilityNodes(in root: NSView) -> [AnyObject] {
        var pending: [AnyObject] = [root]
        var visited = Set<ObjectIdentifier>()
        var result: [AnyObject] = []
        while let element = pending.popLast() {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            result.append(element)
            let children: [Any]
            if let host = element as? NSHostingView<AnyView> {
                let regular = host.accessibilityChildren() ?? []
                children = regular.isEmpty
                    ? (host.accessibilityChildrenInNavigationOrder() ?? []) : regular
            } else if let accessibility = element as? NSAccessibilityProtocol {
                children = accessibility.accessibilityChildren() ?? []
            } else {
                children = []
            }
            pending.append(contentsOf: NSAccessibility.unignoredChildren(from: children) as [AnyObject])
        }
        return result
    }

    private func accessibilityLabel(_ element: AnyObject) -> String? {
        (element as? NSAccessibilityProtocol)?.accessibilityLabel()
    }

    private func accessibilityHelp(_ element: AnyObject) -> String? {
        (element as? NSAccessibilityProtocol)?.accessibilityHelp()
    }

    private func press(_ element: AnyObject) -> Bool {
        (element as? NSAccessibilityProtocol)?.accessibilityPerformPress() ?? false
    }
}
