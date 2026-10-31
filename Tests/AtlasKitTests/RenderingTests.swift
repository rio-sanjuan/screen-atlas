import CoreGraphics
import Foundation
import Testing

@testable import AtlasKit

private func node(_ id: String, root: Bool = false) -> AtlasGraph.Node {
    .init(id: id, title: id, isRoot: root, isBoundary: false, steps: [])
}

private func edge(_ from: String, _ to: String, label: String? = nil) -> AtlasGraph.Edge {
    .init(from: from, to: to, kind: .push, label: label)
}

private func graph(_ nodes: [AtlasGraph.Node], _ edges: [AtlasGraph.Edge]) -> AtlasGraph {
    .init(name: "Test", nodes: nodes, edges: edges, unresolved: [])
}

@Suite struct Layout {
    @Test func noTwoCardsOverlap() {
        let nodes = [node("r", root: true)] + (0..<9).map { node("n\($0)") }
        let edges = (0..<9).map { edge("r", "n\($0)") } + [edge("n0", "n5"), edge("n1", "n5"), edge("n5", "n8")]
        let layout = AtlasLayout(graph: graph(nodes, edges))
        let frames = Array(layout.frames.values)
        for (at, a) in frames.enumerated() {
            for b in frames[(at + 1)...] {
                #expect(!a.intersects(b))
            }
        }
    }

    @Test func everythingFitsInsideTheReportedSize() {
        let nodes = [node("r", root: true), node("a"), node("b")]
        let layout = AtlasLayout(graph: graph(nodes, [edge("r", "a"), edge("a", "b"), edge("b", "r")]))
        let bounds = CGRect(origin: .zero, size: layout.size)
        for frame in layout.frames.values { #expect(bounds.contains(frame)) }
    }

    @Test func aChildSitsBelowItsParent() {
        let layout = AtlasLayout(graph: graph([node("r", root: true), node("a")], [edge("r", "a")]))
        #expect(layout.frames["a"]!.minY > layout.frames["r"]!.maxY)
    }

    @Test func anArrowEndsOnTheTopOfItsTarget() {
        let layout = AtlasLayout(graph: graph([node("r", root: true), node("a")], [edge("r", "a")]))
        let end = layout.edges.first!.curves.last!.end
        #expect(end.y == layout.frames["a"]!.minY)
    }

    @Test func anEdgeClosingACycleRunsBackAndDoesNotBreakTheLayers() {
        let layout = AtlasLayout(graph: graph(
            [node("r", root: true), node("a")], [edge("r", "a"), edge("a", "r")]
        ))
        #expect(layout.edges.filter(\.isBack).count == 1)
        #expect(layout.frames["a"]!.minY > layout.frames["r"]!.maxY)
    }

    @Test func aLongEdgeStaysClearOfTheCardsItPasses() {
        // r → a → b, and r → b skipping a's row: its route must not run through a.
        let layout = AtlasLayout(graph: graph(
            [node("r", root: true), node("a"), node("b")], [edge("r", "a"), edge("a", "b"), edge("r", "b")]
        ))
        let long = layout.edges.first { $0.edge.from == "r" && $0.edge.to == "b" }!
        #expect(long.curves.count == 3)
        let passing = long.curves[1]
        let card = layout.frames["a"]!
        #expect(passing.start.x < card.minX || passing.start.x > card.maxX)
    }

    @Test func aGraphWithOneScreenLaysOut() {
        let layout = AtlasLayout(graph: graph([node("r", root: true)], []))
        #expect(layout.frames.count == 1)
        #expect(layout.edges.isEmpty)
    }
}

@Suite struct LinkOrigins {
    private let nodes = [node("r", root: true), node("a"), node("b")]
    private let edges = [edge("r", "a"), edge("r", "b")]

    private func phone(_ layout: AtlasLayout, _ id: String) -> CGRect {
        AtlasLayout.phone(in: layout.frames[id]!)
    }

    @Test func anArrowWithAKnownElementStartsOnThatElement() {
        let frame = LinkFrame(x: 0.1, y: 0.5, width: 0.3, height: 0.05)
        let layout = AtlasLayout(graph: graph(nodes, edges), links: ["r": ["a": frame]])
        let routed = layout.edges.first { $0.edge.to == "a" }!
        let phone = phone(layout, "r")
        #expect(phone.contains(routed.curves.first!.start))
        #expect(routed.origin == routed.curves.first!.start)
        #expect(abs(routed.spot!.midY - (phone.minY + 0.525 * phone.height)) < 0.01)
    }

    @Test func theDotSitsBesideTheElementNotOnIt() {
        let frame = LinkFrame(x: 0.2, y: 0.5, width: 0.2, height: 0.05)
        let layout = AtlasLayout(graph: graph(nodes, [edge("r", "a")]), links: ["r": ["a": frame]])
        let routed = layout.edges[0]
        #expect(routed.origin!.x < routed.spot!.minX)
        #expect(phone(layout, "r").contains(routed.origin!))
    }

    @Test func anArrowWithoutOneStartsBelowItsCard() {
        let layout = AtlasLayout(graph: graph(nodes, edges))
        let routed = layout.edges.first { $0.edge.to == "a" }!
        #expect(routed.origin == nil)
        #expect(routed.curves.first!.start.y == layout.frames["r"]!.maxY)
    }

    @Test func anArrowLeavesThePhoneBeforeHeadingDown() {
        let frame = LinkFrame(x: 0.6, y: 0.2, width: 0.2, height: 0.05)
        let layout = AtlasLayout(graph: graph(nodes, [edge("r", "a")]), links: ["r": ["a": frame]])
        let routed = layout.edges[0]
        let phone = phone(layout, "r")
        // Past the corner, the line runs down the gap with no more of the picture crossed.
        let channel = routed.curves[1].end.x
        #expect(channel > phone.maxX)
        #expect(routed.curves[2].start.x == channel && routed.curves[2].end.x == channel)
    }

    @Test func anElementHigherUpTakesTheOuterLaneSoLinesDoNotCross() {
        let high = LinkFrame(x: 0.6, y: 0.1, width: 0.2, height: 0.05)
        let low = LinkFrame(x: 0.6, y: 0.6, width: 0.2, height: 0.05)
        // A chain under the root keeps both targets beneath it, so neither is off to
        // one side, and both elements being right of centre sends both out on the right.
        let layout = AtlasLayout(
            graph: graph(nodes, [edge("r", "a"), edge("a", "b"), edge("r", "b")]),
            links: ["r": ["a": high, "b": low]]
        )
        let upper = layout.edges.first { $0.edge.to == "a" }!
        let lower = layout.edges.first { $0.edge.from == "r" && $0.edge.to == "b" }!
        let phone = phone(layout, "r")
        #expect(lower.curves[1].end.x > phone.maxX)
        #expect(upper.curves[1].end.x > lower.curves[1].end.x)
    }

    @Test func anElementBelowThePhonesEdgeStillStartsOnThePhone() {
        let frame = LinkFrame(x: 0.1, y: 0.995, width: 0.3, height: 0.05)
        let layout = AtlasLayout(graph: graph(nodes, [edge("r", "a")]), links: ["r": ["a": frame]])
        #expect(phone(layout, "r").contains(layout.edges[0].origin!))
    }

    @Test func aLinkFrameForAScreenNotConnectedIsIgnored() {
        let frame = LinkFrame(x: 0.1, y: 0.5, width: 0.3, height: 0.05)
        let layout = AtlasLayout(graph: graph(nodes, edges), links: ["r": ["gone": frame]])
        #expect(layout.edges.allSatisfy { $0.origin == nil })
    }
}

@Suite struct Page {
    @Test func aTitleCannotEndTheScriptItIsEmbeddedIn() throws {
        let text = try MapPage.embeddable(JSONEncoder().encode(["title": "</script><script>alert(1)</script>"]))
        #expect(!text.contains("</script>"))
        #expect(text.contains("\\u003c"))
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
        #expect(decoded["title"] == "</script><script>alert(1)</script>")
    }

    @Test func aNameInThePageTitleIsEscaped() {
        #expect(MapPage.escapeHTML("A<b>&") == "A&lt;b&gt;&amp;")
    }

    @Test func aPathIsWrittenAsOneSVGCurvePerSegment() {
        let curve = AtlasLayout.Curve(
            start: .zero, control1: CGPoint(x: 0, y: 5), control2: CGPoint(x: 10, y: 5), end: CGPoint(x: 10, y: 10)
        )
        #expect(MapPage.svgPath([curve]) == "M0.0 0.0C0.0 5.0 10.0 5.0 10.0 10.0")
    }

    @Test func theAppIsFoundAmongTheOtherTargetsInBuildSettings() throws {
        let settings = """
        Build settings for action build and target Kit:
            WRAPPER_EXTENSION = framework
            WRAPPER_NAME = Kit.framework
            PRODUCT_TYPE = com.apple.product-type.framework
            TARGET_BUILD_DIR = /build/Kit
            PRODUCT_BUNDLE_IDENTIFIER = dev.kit

        Build settings for action build and target App:
            WRAPPER_EXTENSION = app
            WRAPPER_NAME = My App.app
            PRODUCT_TYPE = com.apple.product-type.application
            TARGET_BUILD_DIR = /build/App
            PRODUCT_BUNDLE_IDENTIFIER = dev.app

        Build settings for action build and target AppTests:
            WRAPPER_EXTENSION = xctest
            WRAPPER_NAME = AppTests.xctest
            PRODUCT_TYPE = com.apple.product-type.bundle.unit-test
            TARGET_BUILD_DIR = /build/AppTests
            PRODUCT_BUNDLE_IDENTIFIER = dev.tests
        """
        let app = try Capturer.app(fromBuildSettings: settings, scheme: "App")
        #expect(app.bundleID == "dev.app")
        #expect(app.path.path == "/build/App/My App.app")
    }

    @Test func aSchemeWithoutAnAppIsAnError() {
        #expect(throws: AtlasError.self) {
            try Capturer.app(fromBuildSettings: "WRAPPER_EXTENSION = framework", scheme: "Kit")
        }
    }
}
