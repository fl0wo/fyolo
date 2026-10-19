import XCTest
import FyoloShared
@testable import fyolo

/// What a ⌘-click does with an answer: jump to the one place that matters, or list.
final class ReferenceNavigationTests: XCTestCase {
    private func hit(_ path: String, _ line: Int, _ kind: String?) -> Fyolod.SearchHit {
        Fyolod.SearchHit(
            path: path, line: line, text: "", spans: [0 ..< 1], isWindowed: false,
            before: [], after: [], textOffset: 0, kind: kind)
    }

    private func result(
        kind: String, atDefinition: Bool, definitions: [Fyolod.SearchHit],
        hits: [Fyolod.SearchHit]
    ) -> Fyolod.ReferencesResult {
        Fyolod.ReferencesResult(
            symbol: .init(
                name: "name", kind: kind, definitions: definitions,
                atDefinition: atDefinition, note: nil),
            hits: hits, limitHit: false)
    }

    private func decide(_ result: Fyolod.ReferencesResult) -> ReferenceNavigation.Decision {
        ReferenceNavigation.decide(result, clickedPath: "app/page.tsx")
    }

    func testAUsageJumpsToItsOneDefinition() {
        let answer = result(
            kind: "export", atDefinition: false,
            definitions: [hit("components/nav.tsx", 2, "definition")],
            hits: [hit("app/page.tsx", 9, "usage"), hit("app/other.tsx", 4, "usage")])
        XCTAssertEqual(decide(answer), .jump(.init(path: "components/nav.tsx", line: 2)))
    }

    func testTheDefinitionUsedInOneOtherFileJumpsThere() {
        let answer = result(
            kind: "export", atDefinition: true, definitions: [hit("app/page.tsx", 3, "definition")],
            hits: [hit("lib/use.ts", 7, "usage"), hit("lib/use.ts", 12, "usage"),
                   hit("lib/use.ts", 1, "import")])
        XCTAssertEqual(decide(answer), .jump(.init(path: "lib/use.ts", line: 7)))
    }

    func testTheDefinitionUsedOnlyHereOrNowhereOrWidelyLists() {
        let here = result(
            kind: "local", atDefinition: true, definitions: [hit("app/page.tsx", 3, "definition")],
            hits: [hit("app/page.tsx", 5, "usage")])
        XCTAssertEqual(decide(here), .list)
        let nowhere = result(
            kind: "export", atDefinition: true, definitions: [hit("app/page.tsx", 3, "definition")],
            hits: [hit("app/terms/page.tsx", 3, "unrelated")])
        XCTAssertEqual(decide(nowhere), .list)
        let widely = result(
            kind: "export", atDefinition: true, definitions: [hit("app/page.tsx", 3, "definition")],
            hits: [hit("a.ts", 1, "usage"), hit("b.ts", 1, "usage")])
        XCTAssertEqual(decide(widely), .list)
        let hereAndThere = result(
            kind: "export", atDefinition: true, definitions: [hit("app/page.tsx", 3, "definition")],
            hits: [hit("app/page.tsx", 8, "usage"), hit("b.ts", 1, "usage")])
        XCTAssertEqual(decide(hereAndThere), .list)
    }

    func testAModuleOpensAndUnresolvedNamesAndPackagesList() {
        let module = result(
            kind: "module", atDefinition: false,
            definitions: [hit("components/nav.tsx", 1, "definition")], hits: [])
        XCTAssertEqual(decide(module), .jump(.init(path: "components/nav.tsx", line: 1)))
        let name = result(
            kind: "name", atDefinition: false, definitions: [],
            hits: [hit("A.swift", 1, "definition")])
        XCTAssertEqual(decide(name), .list)
        let package = result(
            kind: "package", atDefinition: false, definitions: [],
            hits: [hit("app/page.tsx", 4, "usage")])
        XCTAssertEqual(decide(package), .list)
    }
}
