import XCTest
@testable import SudrfKit

/// `PackagedResource` — единственный вход к ресурсам модуля. Прямой
/// `Bundle.module` использовать нельзя: в собранном .app он не находит бандл
/// (тот лежит в `Contents/Resources`, а аксессор смотрит в корень) и не
/// возвращает nil, а роняет процесс через `fatalError`. Именно так приложение
/// падало при обновлении дела до v0.42.27.
///
/// Здесь проверяется ветка разработки и тестов — `Bundle.module`. Ветку
/// собранного приложения (`Contents/Resources/SudrfKit_SudrfKit.bundle`)
/// юнит-тестом не достать: `Bundle.main` тестового процесса — это раннер.
/// Её обеспечивает `Scripts/make-app.sh`, который копирует бандлы внутрь .app.
final class PackagedResourceTests: XCTestCase {

    func testFindsJSONResource() throws {
        let url = try XCTUnwrap(PackagedResource.url("VNKODCourts", withExtension: "json"),
                                "справочник VNKOD-судов не найден в ресурсах")
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0)
    }

    func testFindsCertificateResource() throws {
        let url = try XCTUnwrap(PackagedResource.url("RussianTrustedRootCA", withExtension: "cer"),
                                "корневой сертификат не найден в ресурсах")
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
    }

    func testLoadsCompleteLegalDeadlineRegistry() throws {
        let registry = try LegalDeadlineRegistry.load()
        XCTAssertEqual(registry.coreRules.count, 66)
        XCTAssertEqual(Set(registry.coreRules.map(\.ruleID)).count, 66)
        XCTAssertEqual(registry.sources.count, 4)
        XCTAssertEqual(registry.sources.map(\.revision), [2, 1, 1, 1])
        XCTAssertEqual(registry.rule(id: "GPK-APPEAL-GENERAL")?.duration.kind, .months)
        XCTAssertEqual(registry.rule(id: "KOAP-APPEAL-RETURN-DETERMINATION-ONE-SUTKI")?.duration.kind,
                       .calendarSutki)
    }

    func testMissingResourceReturnsNilInsteadOfTrapping() {
        XCTAssertNil(PackagedResource.url("ЗаведомоНетТакогоФайла", withExtension: "json"))
    }

    /// Реальная защита от регресса: справочник должен не просто читаться, а
    /// разбираться — иначе `SearchPatternDirectory` молча отдаст пустой индекс
    /// и все VNKOD-суды поедут по primary-паттерну.
    func testDirectoryIndexIsNotEmpty() {
        XCTAssertEqual(SearchPatternDirectory.pattern(forDomain: "zavolgskiy.uln.sudrf.ru"), .vnkod)
    }
}
