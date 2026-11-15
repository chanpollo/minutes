import XCTest
@testable import Minutes

final class ChangelogTests: XCTestCase {
    func testHeadingWithBuildAndDate() {
        XCTAssertEqual(
            Changelog.parse("## 0.6.1 (10) — 2026-10-30"),
            [.init(version: "0.6.1", build: 10, date: "2026-10-30")]
        )
    }

    func testHeadingWithBuildWordAndHyphen() {
        XCTAssertEqual(
            Changelog.parse("## 0.6.1 (build 10) - 2026-10-30"),
            [.init(version: "0.6.1", build: 10, date: "2026-10-30")]
        )
    }

    func testHeadingWithBuildNoDate() {
        XCTAssertEqual(Changelog.parse("## 0.6.1 (10)"), [.init(version: "0.6.1", build: 10, date: nil)])
    }

    func testHeadingWithDateNoBuild() {
        XCTAssertEqual(
            Changelog.parse("## 0.6.1 – 2026-10-30"),
            [.init(version: "0.6.1", build: nil, date: "2026-10-30")]
        )
    }

    func testHeadingVersionOnly() {
        XCTAssertEqual(Changelog.parse("## 0.6.1"), [.init(version: "0.6.1", build: nil, date: nil)])
    }

    func testReleasesKeepFileOrderNewestFirst() {
        let text = """
        ## 0.6.9 (18) — 2026-11-14
        - Ninth.

        ## 0.6.8 (17) — 2026-11-13
        - Eighth, one.
        * Eighth, two.

        ## 0.6.7 (16) — 2026-11-12
        - Seventh.
        """
        let releases = Changelog.parse(text)
        XCTAssertEqual(releases.map(\.version), ["0.6.9", "0.6.8", "0.6.7"])
        XCTAssertEqual(releases.map(\.build), [18, 17, 16])
        XCTAssertEqual(releases[1].items, ["Eighth, one.", "Eighth, two."])
    }

    func testLineUnderBulletContinuesIt() {
        let text = """
        ## 0.6.1 (10) — 2026-10-30
        - First line
          wraps here
        and here.
        - Second.
        """
        XCTAssertEqual(Changelog.parse(text)[0].items, ["First line wraps here and here.", "Second."])
    }

    func testLineBeforeAnyBulletIsDropped() {
        XCTAssertEqual(Changelog.parse("## 0.6.1\nLoose text.\n- Item.")[0].items, ["Item."])
    }

    func testTextBeforeFirstHeadingIgnored() {
        let text = """
        # Changelog

        Newest first.
        - Not a release item.

        ## 0.6.1 (10) — 2026-10-30
        - Item.
        """
        XCTAssertEqual(Changelog.parse(text), [.init(version: "0.6.1", build: 10, date: "2026-10-30", items: ["Item."])])
    }

    func testNoHeadingGivesNothing() {
        XCTAssertEqual(Changelog.parse("# Changelog\n- Item."), [])
        XCTAssertEqual(Changelog.parse(""), [])
    }

    func testDateText() {
        XCTAssertEqual(Changelog.dateText("2026-10-30"), "30 Oct 2026")
        XCTAssertEqual(Changelog.dateText("2026-01-05"), "5 Jan 2026")
    }

    func testDateTextKeepsOtherForms() {
        XCTAssertEqual(Changelog.dateText("Oct 2026"), "Oct 2026")
        XCTAssertEqual(Changelog.dateText("30/10/2026"), "30/10/2026")
        XCTAssertEqual(Changelog.dateText(""), "")
    }

    func testReleaseDateText() {
        XCTAssertEqual(Changelog.Release(version: "0.6.1", date: "2026-10-30").dateText, "30 Oct 2026")
        XCTAssertEqual(Changelog.Release(version: "0.6.1", date: "soon").dateText, "soon")
        XCTAssertNil(Changelog.Release(version: "0.6.1").dateText)
    }
}
