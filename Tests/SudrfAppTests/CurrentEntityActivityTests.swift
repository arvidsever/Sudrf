import XCTest
@testable import SudrfApp

final class CurrentEntityActivityTests: XCTestCase {
    @MainActor
    func testCaseActivityUsesAppEntityWithoutCustomWebpageURL() {
        let activity = CurrentEntityActivityFactory.caseActivity(
            caseNumber: "2-1755/2026", identifier: "court.example#case")

        XCTAssertEqual(activity.activityType, "ru.sudrf.case")
        XCTAssertEqual(activity.title, "Дело № 2-1755/2026")
        XCTAssertNil(activity.webpageURL)
        XCTAssertNotNil(activity.appEntityIdentifier)
        XCTAssertNotNil(activity.persistentIdentifier)
        XCTAssertTrue(activity.isEligibleForSearch)
    }

    @MainActor
    func testCourtActActivityUsesAppEntityWithoutCustomWebpageURL() {
        let activity = CurrentEntityActivityFactory.courtActActivity(
            title: "Решение", caseNumber: "2-1755/2026",
            identifier: "court.example#act-1")

        XCTAssertEqual(activity.activityType, "ru.sudrf.court-act")
        XCTAssertEqual(activity.title, "Решение по делу № 2-1755/2026")
        XCTAssertNil(activity.webpageURL)
        XCTAssertNotNil(activity.appEntityIdentifier)
        XCTAssertNotNil(activity.persistentIdentifier)
        XCTAssertTrue(activity.isEligibleForSearch)
    }
}
