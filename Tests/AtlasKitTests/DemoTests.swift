import Foundation
import Testing

@testable import AtlasKit

/// The demo app, scanned for real: its source is the fixture, so a change to the scanner
/// that would redraw the map in the README shows up here first.
@Suite struct Demo {
    private func graph() throws -> AtlasGraph {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/Trailhead/atlas.json")
        let config = try Config.load(from: url)
        let paths = Paths(configURL: url, config: config)
        let scan = try SwiftUIScanner().scan(
            project: paths.project, folders: config.sources ?? ["."], excludePaths: config.excludePaths ?? []
        )
        return GraphBuilder(scan: scan, config: config).build()
    }

    private func edge(_ map: AtlasGraph, _ from: String, _ to: String) -> AtlasGraph.Edge? {
        map.edges.first { $0.from == from && $0.to == to }
    }

    @Test func everyScreenIsFoundAndHasARoute() throws {
        let map = try graph()
        #expect(map.nodes.count == 16)
        #expect(map.edges.count == 13)
        #expect(map.nodes.allSatisfy { $0.steps != nil })
        #expect(map.unresolved.isEmpty)
    }

    @Test func eachKindOfLinkIsReadAsWritten() throws {
        let map = try graph()
        // A sheet, named by the button that sets its state.
        #expect(edge(map, "TrailsTab", "FiltersSheet")?.kind == .sheet)
        #expect(edge(map, "TrailsTab", "FiltersSheet")?.label == "Filters")
        // An icon-only toolbar link, named by its accessibility label, through a route table.
        #expect(edge(map, "TrailsTab", "NearbyMapView")?.label == "Nearby Map")
        // A cover, reached through the method the button calls.
        #expect(edge(map, "TrailDetailView", "ActiveHikeView")?.kind == .cover)
        #expect(edge(map, "TrailDetailView", "ActiveHikeView")?.label == "Start Hike")
        // A link in a row component, credited to the tab showing the row.
        #expect(edge(map, "TrailsTab", "TrailDetailView")?.kind == .push)
        // A destination written inline.
        #expect(edge(map, "ProfileTab", "AboutView")?.label == "About Trailhead")
    }

    @Test func aRouteThroughAConfiguredScreenBuildsOnItsSteps() throws {
        let map = try graph()
        let note = map.nodes.first { $0.id == "AddNoteSheet" }
        #expect(note?.steps == [
            Step(tab: "Trails"), Step(tapContaining: "Eagle Ridge"), Step(tap: "Start Hike"), Step(tap: "Add Note"),
        ])
    }

    @Test func aPreviewAddsNothing() throws {
        let map = try graph()
        #expect(map.nodes.map(\.id).allSatisfy { !$0.lowercased().contains("preview") })
    }
}
