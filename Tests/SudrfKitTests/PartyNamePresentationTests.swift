import XCTest
@testable import SudrfKit

final class PartyNamePresentationTests: XCTestCase {

    private struct Case {
        let input: String
        let level1: String
        let level2: String
    }

    private let cases: [Case] = [
        Case(input: "Иванова Елена Викторовна ⚔ Общество с ограниченной ответственностью «Северстрой»",
             level1: "Иванова Е. В. ⚔ ООО «Северстрой»",
             level2: "Иванова ⚔ «Северстрой»"),
        Case(input: "Лобанов Игорь Геннадьевич ⚔ Администрация муниципального образования городского округа «Сыктывкар»",
             level1: "Лобанов И. Г. ⚔ Администрация МО ГО «Сыктывкар»",
             level2: "Лобанов ⚔ адм. «Сыктывкар»"),
        Case(input: "Галкина Марина Викторовна и 2 других ⚔ Министерство юстиции Российской Федерации",
             level1: "Галкина М. В. +2 ⚔ Минюст России",
             level2: "Галкина +2 ⚔ Минюст"),
        Case(input: "Белова Ольга Сергеевна ⚔ Индивидуальный предприниматель Гусев Роман Ильич",
             level1: "Белова О. С. ⚔ ИП Гусев Р. И.",
             level2: "Белова ⚔ ИП Гусев"),
        Case(input: "Андреев Пётр Романович · лицо, привлекаемое к административной ответственности",
             level1: "Андреев П. Р.",
             level2: "Андреев")
    ]

    func testMockupPairs() {
        for c in cases {
            XCTAssertEqual(PartyNamePresentation.level1(c.input), c.level1, c.input)
            XCTAssertEqual(PartyNamePresentation.level2(c.input), c.level2, c.input)
        }
    }

    func testArrowSeparatorAcceptedAsAlternateSpelling() {
        let arrow = "Иванова Елена Викторовна → Общество с ограниченной ответственностью «Северстрой»"
        XCTAssertEqual(PartyNamePresentation.level1(arrow), "Иванова Е. В. ⚔ ООО «Северстрой»")
    }

    func testTwoNamesJoinedByAnd() {
        XCTAssertEqual(
            PartyNamePresentation.level1("Иванов Иван Иванович и Петров Петр Петрович"),
            "Иванов И. И. и Петров П. П."
        )
    }

    func testPersonAndOrganisationJoinedByAndAreBothAbbreviated() {
        XCTAssertEqual(
            PartyNamePresentation.level1(
                "Иванова Елена Викторовна и Общество с ограниченной ответственностью «Ромашка»"),
            "Иванова Е. В. и ООО «Ромашка»"
        )
    }

    func testQuotedNameContainingAndIsNotSplit() {
        XCTAssertEqual(
            PartyNamePresentation.level1("Общество с ограниченной ответственностью «Рога и копыта»"),
            "ООО «Рога и копыта»"
        )
    }

    func testBareAndInsideAnUnrecognisedNamePassesThrough() {
        let text = "Комитет имущественных и земельных отношений"
        XCTAssertEqual(PartyNamePresentation.level1(text), text)
    }

    func testSingleSide() {
        XCTAssertEqual(PartyNamePresentation.level1("Сидорова Анна Игоревна"), "Сидорова А. И.")
        XCTAssertEqual(PartyNamePresentation.level2("Сидорова Анна Игоревна"), "Сидорова")
    }

    func testUnrecognisedPassesThrough() {
        let text = "Общество с дополнительной ответственностью «Странное»" // не из закрытого списка форм
        XCTAssertEqual(PartyNamePresentation.level1(text), text)
    }

    func testUnpublishedPartiesPassThrough() {
        let text = "стороны не опубликованы"
        XCTAssertEqual(PartyNamePresentation.level1(text), text)
        XCTAssertEqual(PartyNamePresentation.level2(text), text)
    }

    func testMVDByRepublicRegionRule() {
        XCTAssertEqual(
            PartyNamePresentation.level1("Министерство внутренних дел по Республике Коми"),
            "МВД по РК"
        )
        XCTAssertEqual(
            PartyNamePresentation.level2("Министерство внутренних дел по Республике Коми"),
            "МВД"
        )
    }

    func testOSFRByRepublicRegionRule() {
        XCTAssertEqual(
            PartyNamePresentation.level1("Отделение Фонда пенсионного и социального страхования Российской Федерации по Республике Коми"),
            "ОСФР по РК"
        )
        XCTAssertEqual(
            PartyNamePresentation.level2("Отделение Фонда пенсионного и социального страхования Российской Федерации по Республике Коми"),
            "ОСФР"
        )
    }

    func testRosreestrByCity() {
        XCTAssertEqual(
            PartyNamePresentation.level1("Управление Федеральной службы государственной регистрации, кадастра и картографии по Москве"),
            "Управление Росреестра по Москве"
        )
        XCTAssertEqual(
            PartyNamePresentation.level2("Управление Федеральной службы государственной регистрации, кадастра и картографии по Москве"),
            "Росреестр"
        )
    }
}
