import CoreGraphics
import Foundation

/// Where everything goes. The chart and the map both draw from one of these, so
/// the picture in a document and the one you can pan around are the same picture.
public struct AtlasLayout: Sendable {
    public struct Curve: Sendable {
        public var start: CGPoint
        public var control1: CGPoint
        public var control2: CGPoint
        public var end: CGPoint

        func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(
                x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                y: a * start.y + b * control1.y + c * control2.y + d * end.y
            )
        }
    }

    public struct RoutedEdge: Sendable {
        public var edge: AtlasGraph.Edge
        public var curves: [Curve]
        public var labelCenter: CGPoint
        /// The element this arrow starts on, when it was found on the screenshot.
        public var spot: CGRect?
        public var origin: CGPoint?
        /// Runs against the flow, back up to a screen above.
        public var isBack: Bool
    }

    public var frames: [String: CGRect]
    public var edges: [RoutedEdge]
    public var size: CGSize

    public static let cardWidth: CGFloat = 196
    /// The title under a phone.
    static let captionHeight: CGFloat = 40
    static let screenAspect: CGFloat = 2622.0 / 1206.0
    public static var cardHeight: CGFloat { captionHeight + cardWidth * screenAspect }
    static let layerGap: CGFloat = 132
    static let cardGap: CGFloat = 44
    static let margin: CGFloat = 56

    /// The phone inside a card: the top of it, with the title underneath.
    public static func phone(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - captionHeight)
    }

    public init(graph: AtlasGraph, links: [String: [String: LinkFrame]] = [:]) {
        var builder = LayeredLayout(graph: graph, links: links)
        let result = builder.run()
        frames = result.frames
        edges = result.edges
        size = result.size
    }
}

/// A Sugiyama layout, top down: a phone screen is tall and narrow, so a screen
/// with many ways out spreads into a row that still fits on a page, where a
/// left-to-right chart would turn it into a very tall column.
private struct LayeredLayout {
    private let graph: AtlasGraph
    private let links: [String: [String: LinkFrame]]
    private var outgoing: [String: [String]] = [:]
    private var incoming: [String: [String]] = [:]
    private var backEdges = Set<String>()
    private var layers: [[Vertex]] = []
    private var layerOf: [String: Int] = [:]
    /// Each edge's chain of vertices, including the dummies across skipped layers.
    private var chains: [String: [String]] = [:]

    private struct Vertex {
        let id: String
        let isDummy: Bool
        var x: CGFloat = 0
        var width: CGFloat { isDummy ? 20 : AtlasLayout.cardWidth }
    }

    init(graph: AtlasGraph, links: [String: [String: LinkFrame]]) {
        self.graph = graph
        self.links = links
    }

    /// How an arrow leaves the element it starts on: out through the side of the
    /// phone, then down the gap beside it, clear of the screenshot.
    private struct Exit {
        let spot: CGRect
        let start: CGPoint
        let isRight: Bool
        let channel: CGFloat
    }

    /// Lines leaving one side run down the gap together. The one from highest on the
    /// screen takes the outermost lane, since it has to pass the others' rows on the
    /// way down, and inner lanes for those lower down means none of them cross.
    private func exits(from: CGRect, source: String, edges: [AtlasGraph.Edge]) -> [String: Exit] {
        let phone = AtlasLayout.phone(in: from)
        var sides: [Bool: [(edge: AtlasGraph.Edge, spot: CGRect)]] = [:]
        for edge in edges {
            guard let link = links[source]?[edge.to] else { continue }
            let spot = CGRect(
                x: phone.minX + link.x * phone.width, y: phone.minY + link.y * phone.height,
                width: link.width * phone.width, height: link.height * phone.height
            )
            // Out of the nearer side, wherever the target is. Heading straight for a
            // target on the far side would draw a line through the screen's own text;
            // the arrow can cross over beneath the phone, where there's nothing to hide.
            let isRight = spot.midX >= phone.midX
            sides[isRight, default: []].append((edge, spot))
        }
        var result: [String: Exit] = [:]
        for (isRight, entries) in sides {
            let ordered = entries.sorted { $0.spot.midY > $1.spot.midY }
            for (lane, entry) in ordered.enumerated() {
                let offset = 10 + 7 * CGFloat(min(lane, 5))
                let y = min(entry.spot.midY, phone.maxY - 6)
                // Just outside the element, so the dot sits beside its words and not on
                // their first letter, and never past the edge of the phone.
                let x = isRight
                    ? min(entry.spot.maxX + 6, phone.maxX - 4)
                    : max(entry.spot.minX - 6, phone.minX + 4)
                result[entry.edge.to] = Exit(
                    spot: entry.spot,
                    start: CGPoint(x: x, y: y),
                    isRight: isRight,
                    channel: isRight ? phone.maxX + offset : phone.minX - offset
                )
            }
        }
        return result
    }

    private func straight(_ a: CGPoint, _ b: CGPoint) -> AtlasLayout.Curve {
        .init(start: a, control1: a, control2: b, end: b)
    }

    /// Out of the phone, round the corner, and down the gap to just under the card.
    private func runOut(_ exit: Exit, below: CGFloat) -> [AtlasLayout.Curve] {
        let radius: CGFloat = 7
        let direction: CGFloat = exit.isRight ? 1 : -1
        let beforeCorner = CGPoint(x: exit.channel - direction * radius, y: exit.start.y)
        let afterCorner = CGPoint(x: exit.channel, y: exit.start.y + radius)
        let corner = AtlasLayout.Curve(
            start: beforeCorner,
            control1: CGPoint(x: exit.channel - direction * radius * 0.45, y: exit.start.y),
            control2: CGPoint(x: exit.channel, y: exit.start.y + radius * 0.55),
            end: afterCorner
        )
        return [straight(exit.start, beforeCorner), corner, straight(afterCorner, CGPoint(x: exit.channel, y: below))]
    }

    private func key(_ edge: AtlasGraph.Edge) -> String { "\(edge.from)\u{0}\(edge.to)" }

    mutating func run() -> (frames: [String: CGRect], edges: [AtlasLayout.RoutedEdge], size: CGSize) {
        findBackEdges()
        assignLayers()
        buildLayers()
        reduceCrossings()
        placeHorizontally()
        return route()
    }

    /// Navigation has cycles, since screens link back to each other. A layered
    /// layout needs none, so edges closing a cycle are set aside and drawn apart.
    private mutating func findBackEdges() {
        let ids = graph.nodes.map(\.id)
        for edge in graph.edges where edge.from != edge.to {
            outgoing[edge.from, default: []].append(edge.to)
        }
        var state: [String: Int] = [:]
        func visit(_ id: String, _ layout: inout LayeredLayout) {
            state[id] = 1
            for next in layout.outgoing[id] ?? [] {
                switch state[next] {
                case 1: layout.backEdges.insert("\(id)\u{0}\(next)")
                case nil: visit(next, &layout)
                default: break
                }
            }
            state[id] = 2
        }
        // Roots first, so "back" means back towards where the app starts.
        for id in graph.nodes.filter(\.isRoot).map(\.id) + ids where state[id] == nil {
            visit(id, &self)
        }
    }

    private mutating func assignLayers() {
        var forward: [String: [String]] = [:]
        var waiting: [String: Int] = [:]
        for node in graph.nodes { waiting[node.id] = 0 }
        for edge in graph.edges where edge.from != edge.to && !backEdges.contains(key(edge)) {
            forward[edge.from, default: []].append(edge.to)
            waiting[edge.to, default: 0] += 1
        }
        var ready = graph.nodes.map(\.id).filter { waiting[$0] == 0 }
        for id in ready { layerOf[id] = 0 }
        while !ready.isEmpty {
            let id = ready.removeFirst()
            for next in forward[id] ?? [] {
                layerOf[next] = max(layerOf[next] ?? 0, (layerOf[id] ?? 0) + 1)
                waiting[next]! -= 1
                if waiting[next] == 0 { ready.append(next) }
            }
        }
    }

    private mutating func buildLayers() {
        let count = (layerOf.values.max() ?? 0) + 1
        layers = Array(repeating: [], count: count)
        for node in graph.nodes {
            layers[layerOf[node.id] ?? 0].append(Vertex(id: node.id, isDummy: false))
        }
        for edge in graph.edges where edge.from != edge.to && !backEdges.contains(key(edge)) {
            let from = layerOf[edge.from] ?? 0, to = layerOf[edge.to] ?? 0
            var chain = [edge.from]
            if to > from + 1 {
                for layer in (from + 1)..<to {
                    let id = "dummy\u{0}\(key(edge))\u{0}\(layer)"
                    layers[layer].append(Vertex(id: id, isDummy: true))
                    layerOf[id] = layer
                    chain.append(id)
                }
            }
            chain.append(edge.to)
            chains[key(edge)] = chain
            for (a, b) in zip(chain, chain.dropFirst()) {
                outgoing[a, default: []].append(b)
                incoming[b, default: []].append(a)
            }
        }
    }

    /// The barycenter heuristic: put each vertex near the average of its
    /// neighbours in the next layer, sweeping down and back up a few times.
    private mutating func reduceCrossings() {
        for sweep in 0..<8 {
            let down = sweep.isMultiple(of: 2)
            let order = down ? Array(1..<max(layers.count, 1)) : Array((0..<max(layers.count - 1, 0)).reversed())
            for index in order {
                let reference = down ? layers[index - 1] : layers[index + 1]
                var position: [String: Int] = [:]
                for (at, vertex) in reference.enumerated() { position[vertex.id] = at }
                let scored = layers[index].enumerated().map { at, vertex -> (Vertex, Double, Int) in
                    let neighbours = (down ? incoming[vertex.id] : outgoing[vertex.id]) ?? []
                    let known = neighbours.compactMap { position[$0] }
                    let score = known.isEmpty ? Double(at) : Double(known.reduce(0, +)) / Double(known.count)
                    return (vertex, score, at)
                }
                layers[index] = scored.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
            }
        }
    }

    /// Lets each vertex drift towards its neighbours, then pushes apart whatever
    /// that made overlap, keeping the order the crossing pass chose.
    private mutating func placeHorizontally() {
        for index in layers.indices {
            var x: CGFloat = 0
            for at in layers[index].indices {
                layers[index][at].x = x + layers[index][at].width / 2
                x += layers[index][at].width + AtlasLayout.cardGap
            }
            let width = x - AtlasLayout.cardGap
            for at in layers[index].indices { layers[index][at].x -= width / 2 }
        }
        for pass in 0..<24 {
            let down = pass.isMultiple(of: 2)
            let order = down ? Array(layers.indices) : Array(layers.indices.reversed())
            var positions: [String: CGFloat] = [:]
            for layer in layers { for vertex in layer { positions[vertex.id] = vertex.x } }
            for index in order {
                for at in layers[index].indices {
                    let id = layers[index][at].id
                    let neighbours = (down ? incoming[id] : outgoing[id]) ?? []
                    let known = neighbours.compactMap { positions[$0] }
                    guard !known.isEmpty else { continue }
                    layers[index][at].x = known.reduce(0, +) / CGFloat(known.count)
                }
                separate(layer: index)
                for vertex in layers[index] { positions[vertex.id] = vertex.x }
            }
        }
    }

    private mutating func separate(layer index: Int) {
        let gap = AtlasLayout.cardGap
        let count = layers[index].count
        guard count > 1 else { return }
        let wanted = layers[index].map(\.x)
        // Push right, then left, and take the middle, so neither end of a row is
        // the one that gets displaced.
        var right = wanted
        for at in 1..<count {
            let least = right[at - 1] + (layers[index][at - 1].width + layers[index][at].width) / 2 + gap
            right[at] = max(right[at], least)
        }
        var left = wanted
        for at in stride(from: count - 2, through: 0, by: -1) {
            let most = left[at + 1] - (layers[index][at + 1].width + layers[index][at].width) / 2 - gap
            left[at] = min(left[at], most)
        }
        for at in 0..<count { layers[index][at].x = (right[at] + left[at]) / 2 }
        for at in 1..<count {
            let least = layers[index][at - 1].x + (layers[index][at - 1].width + layers[index][at].width) / 2 + gap
            layers[index][at].x = max(layers[index][at].x, least)
        }
    }

    private func route() -> (frames: [String: CGRect], edges: [AtlasLayout.RoutedEdge], size: CGSize) {
        let cardWidth = AtlasLayout.cardWidth, cardHeight = AtlasLayout.cardHeight
        let margin = AtlasLayout.margin
        let vertices = layers.flatMap { $0 }
        let minX = (vertices.map { $0.x - $0.width / 2 }.min() ?? 0) - margin
        let maxX = (vertices.map { $0.x + $0.width / 2 }.max() ?? 0) + margin

        func y(_ layer: Int) -> CGFloat { margin + CGFloat(layer) * (cardHeight + AtlasLayout.layerGap) }
        var frames: [String: CGRect] = [:]
        var centers: [String: CGPoint] = [:]
        for (index, layer) in layers.enumerated() {
            for vertex in layer {
                let x = vertex.x - minX
                centers[vertex.id] = CGPoint(x: x, y: y(index) + cardHeight / 2)
                if !vertex.isDummy {
                    frames[vertex.id] = CGRect(x: x - cardWidth / 2, y: y(index), width: cardWidth, height: cardHeight)
                }
            }
        }

        // Where several arrows arrive at one card they spread out along its top,
        // in the order of where they came from, so they and their labels separate.
        var arrivals: [String: [(source: CGFloat, edge: String)]] = [:]
        for edge in graph.edges where chains[key(edge)] != nil {
            let chain = chains[key(edge)]!
            let before = chain[chain.count - 2]
            arrivals[edge.to, default: []].append((centers[before]?.x ?? 0, key(edge)))
        }
        var arrivalX: [String: CGFloat] = [:]
        var arrivalIndex: [String: Int] = [:]
        for (target, entries) in arrivals {
            let sorted = entries.sorted { $0.source < $1.source }
            let spacing = min(44, cardWidth * 0.7 / CGFloat(max(sorted.count - 1, 1)))
            let span = spacing * CGFloat(sorted.count - 1)
            for (at, entry) in sorted.enumerated() {
                arrivalX[entry.edge] = (centers[target]?.x ?? 0) - span / 2 + spacing * CGFloat(at)
                arrivalIndex[entry.edge] = at
            }
        }

        var routed: [AtlasLayout.RoutedEdge] = []
        var allExits: [String: [String: Exit]] = [:]
        for node in graph.nodes {
            guard let from = frames[node.id] else { continue }
            let leaving = graph.edges.filter { $0.from == node.id && chains[key($0)] != nil }
            allExits[node.id] = exits(from: from, source: node.id, edges: leaving)
        }
        var backOffset: CGFloat = 0
        var extraWidth: CGFloat = 0
        for edge in graph.edges where edge.from != edge.to {
            guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
            if let chain = chains[key(edge)] {
                let exit = allExits[edge.from]?[edge.to]
                let below = from.maxY + 4
                var points: [CGPoint] = [exit.map { CGPoint(x: $0.channel, y: below) } ?? CGPoint(x: from.midX, y: from.maxY)]
                for id in chain.dropFirst().dropLast() {
                    let center = centers[id]!
                    // A long edge passes a layer's row along a straight run, clear of the cards.
                    points.append(CGPoint(x: center.x, y: center.y - cardHeight / 2))
                    points.append(CGPoint(x: center.x, y: center.y + cardHeight / 2))
                }
                points.append(CGPoint(x: arrivalX[key(edge)] ?? to.midX, y: to.minY))
                var curves = zip(points, points.dropFirst()).map { a, b -> AtlasLayout.Curve in
                    let bend = (b.y - a.y) * 0.5
                    return .init(
                        start: a, control1: CGPoint(x: a.x, y: a.y + bend),
                        control2: CGPoint(x: b.x, y: b.y - bend), end: b
                    )
                }
                if let exit { curves = runOut(exit, below: below) + curves }
                // Near the arrowhead, where a fan of arrows is furthest apart.
                let last = curves.last!
                var label = last.point(at: 0.72)
                // Arrows that share a target stagger, so their labels stay legible.
                if (arrivalIndex[key(edge)] ?? 0) % 2 == 1 { label.y -= 24 }
                routed.append(.init(
                    edge: edge, curves: curves, labelCenter: label, spot: exit?.spot, origin: exit?.start, isBack: false
                ))
            } else {
                // Back up the chart, around the outside of both cards.
                backOffset += 18
                let side = max(from.maxX, to.maxX) + 26 + backOffset
                extraWidth = max(extraWidth, side + 40 - (maxX - minX))
                let start = CGPoint(x: from.maxX, y: from.midY)
                let end = CGPoint(x: to.maxX, y: to.midY)
                let curve = AtlasLayout.Curve(
                    start: start, control1: CGPoint(x: side, y: start.y),
                    control2: CGPoint(x: side, y: end.y), end: end
                )
                routed.append(.init(
                    edge: edge, curves: [curve], labelCenter: curve.point(at: 0.5), spot: nil, origin: nil, isBack: true
                ))
            }
        }

        let height = y(layers.count - 1) + cardHeight + margin
        return (frames, routed, CGSize(width: (maxX - minX) + extraWidth, height: height))
    }
}
