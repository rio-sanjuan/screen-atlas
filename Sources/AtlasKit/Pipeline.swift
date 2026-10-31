import Foundation

/// The steps a command strings together, each readable from the last one's files.
public enum Pipeline {
    @discardableResult
    public static func scan(config: Config, paths: Paths) throws -> AtlasGraph {
        let result = try SwiftUIScanner().scan(
            project: paths.project,
            folders: config.sources ?? ["."],
            excludePaths: config.excludePaths ?? []
        )
        let graph = GraphBuilder(scan: result, config: config).build()
        try FileManager.default.createDirectory(at: paths.output, withIntermediateDirectories: true)
        try JSONEncoder.atlas.encode(graph).write(to: paths.graph)
        return graph
    }

    /// Draws the chart and the map from what the last scan and capture left behind.
    public static func render(graph: AtlasGraph, paths: Paths) throws {
        let run = try? Data(contentsOf: paths.results).decoded(as: CaptureRun.self)
        let layout = AtlasLayout(graph: graph, links: run?.linkFrames ?? [:])
        try Chart(graph: graph, run: run, layout: layout, paths: paths).write()
        try MapPage(graph: graph, run: run, layout: layout, paths: paths).write()
    }

    /// What each screen's capture came to, with what a failed one could see.
    public static func describe(_ run: CaptureRun, graph: AtlasGraph) -> String {
        var lines: [String] = [""]
        var captured = 0
        for node in graph.nodes {
            if let skip = node.skip {
                lines.append("  skipped  \(node.id): \(skip)")
            } else if let result = run.results[node.id] {
                if result.status == "ok" {
                    captured += 1
                    lines.append("  ok       \(node.id)")
                } else {
                    lines.append("  \(result.status)   \(node.id): \(result.note ?? "")")
                    if let labels = result.visibleLabels, !labels.isEmpty {
                        lines.append("           on screen: \(labels.prefix(30).joined(separator: " | "))")
                    }
                }
            } else {
                lines.append("  no route \(node.id)")
            }
        }
        lines.insert("\(captured) of \(graph.nodes.count) screens captured", at: 1)
        return lines.joined(separator: "\n")
    }

    /// A plain summary, written for reading in a terminal or by an agent filling
    /// in a config: what was found, and exactly which gaps need a person.
    public static func describe(_ graph: AtlasGraph) -> String {
        var lines: [String] = ["\(graph.name): \(graph.nodes.count) screens, \(graph.edges.count) connections", ""]
        for node in graph.nodes {
            let route: String
            if let steps = node.steps {
                route = steps.isEmpty ? "(launch screen)" : steps.map(\.summary).joined(separator: " → ")
            } else {
                route = "NO ROUTE: \(node.routeNote ?? "")"
            }
            let boundary = node.isBoundary ? " [stop]" : ""
            lines.append("  \(node.id)\(boundary)  \"\(node.title)\"")
            lines.append("      \(route)")
        }
        lines.append("")
        lines.append("Connections:")
        for edge in graph.edges {
            let label = edge.label.map { "\"\($0)\"" } ?? "(no label)"
            lines.append("  \(edge.from) → \(edge.to)  \(edge.kind.rawValue)  \(label)")
        }
        if !graph.unresolved.isEmpty {
            lines.append("")
            lines.append("Links the scan could not follow (add them under \"edges\" if they matter):")
            for gap in graph.unresolved {
                lines.append("  \(gap.screen): \(gap.raw)  (\(gap.file):\(gap.line))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
