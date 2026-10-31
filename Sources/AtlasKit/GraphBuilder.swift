import Foundation

/// Turns scanned facts into a map of screens.
///
/// The scan only knows which *view* holds a link, and most links live in small
/// components: a row, a section. A screen is what someone looks at, so each link
/// is rolled up to every screen that composes the component holding it.
public struct GraphBuilder {
    private let scan: SwiftUIScanner.Result
    private let config: Config

    public init(scan: SwiftUIScanner.Result, config: Config) {
        self.scan = scan
        self.config = config
    }

    public func build() -> AtlasGraph {
        let excluded = Set(config.exclude ?? [])
        let boundaries = Set(config.stopAt ?? [])
        var order: [String] = []
        var seen = Set<String>()
        var edges: [AtlasGraph.Edge] = []
        var unresolved: [AtlasGraph.Unresolved] = []
        var queue = config.roots

        while !queue.isEmpty {
            let screen = queue.removeFirst()
            guard seen.insert(screen).inserted else { continue }
            order.append(screen)
            if boundaries.contains(screen) { continue }

            for raw in rawEdges(of: screen) {
                let targets = resolve(raw.target)
                if targets.isEmpty {
                    unresolved.append(.init(screen: screen, raw: raw.raw, file: raw.file, line: raw.line))
                    continue
                }
                for target in targets where target != screen && !excluded.contains(target) {
                    edges.append(.init(
                        from: screen, to: target, kind: raw.kind,
                        label: raw.label ?? flagLabel(raw, in: composed(from: screen)),
                        raw: raw.raw, file: raw.file, line: raw.line
                    ))
                    queue.append(target)
                }
            }
        }

        for extra in config.edges ?? [] {
            for id in [extra.from, extra.to] where seen.insert(id).inserted { order.append(id) }
            edges.append(.init(from: extra.from, to: extra.to, kind: extra.kind ?? .push, label: extra.label))
        }

        let merged = mergeEdges(edges)
        let (routes, launches) = routes(through: merged)
        let overrides = config.screens ?? [:]
        let nodes = order.map { id -> AtlasGraph.Node in
            let facts = scan.types[id]
            let override = overrides[id]
            let route = routes[id]
            return AtlasGraph.Node(
                id: id,
                title: override?.title ?? title(of: id),
                file: facts?.file,
                line: facts?.line,
                group: facts.map { group(ofFile: $0.file) },
                isRoot: config.roots.contains(id),
                isBoundary: boundaries.contains(id),
                steps: route,
                routeNote: route == nil ? routeNote(for: id, edges: merged) : nil,
                expect: override?.expect,
                skip: override?.skip,
                launchArguments: launches[id]
            )
        }
        return AtlasGraph(name: config.name, nodes: nodes, edges: merged, unresolved: unique(unresolved))
    }

    // MARK: - Composition

    /// A screen and every component in it, however deep.
    private func composed(from screen: String) -> [String] {
        var order: [String] = []
        var seen = Set<String>()
        var stack = [screen]
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            order.append(next)
            stack.append(contentsOf: (scan.compositions[next] ?? []).sorted().reversed())
        }
        return order
    }

    private func rawEdges(of screen: String) -> [SwiftUIScanner.RawEdge] {
        let members = Set(composed(from: screen))
        return scan.edges.filter { members.contains($0.owner) }
    }

    // MARK: - Route values

    private func resolve(_ target: SwiftUIScanner.RawEdge.Target) -> [String] {
        switch target {
        case .views(let views):
            return views
        case .route(let type, let member):
            return views(forRoute: type, member: member)
        case .implicitMember(let member):
            // `.speedTyping` with no type written: fine if only one table has that case.
            let tables = scan.routeTables.filter { $0.value.keys.contains(member) }
            return tables.count == 1 ? views(forRoute: tables.first!.key, member: member) : []
        case .unknown:
            return []
        }
    }

    private func views(forRoute type: String, member: String?) -> [String] {
        // A `?name` is a closure parameter: no written type, only a name. Accept
        // it if the name is a route type's, and report it as a gap otherwise.
        var typeName = type
        if type.hasPrefix("?") {
            let name = type.dropFirst().lowercased()
            guard let match = scan.routeTables.keys.first(where: { $0.lowercased() == name }) else { return [] }
            typeName = match
        }
        guard let table = scan.routeTables[typeName] else { return [] }
        var opened = table[nil] ?? []
        if let member {
            opened.formUnion(table[member] ?? [])
        } else {
            for views in table.values { opened.formUnion(views) }
        }
        return opened.sorted()
    }

    // MARK: - Labels

    /// The button that shows a presentation, found through the state between them.
    private func flagLabel(_ raw: SwiftUIScanner.RawEdge, in members: [String]) -> String? {
        guard let flag = raw.flag else { return nil }
        for owner in members {
            for button in scan.buttons[owner] ?? [] where sets(flag, button: button, owner: owner) {
                return button.label
            }
        }
        return nil
    }

    private func sets(_ flag: String, button: SwiftUIScanner.ButtonFacts, owner: String) -> Bool {
        if button.assigned.contains(flag) { return true }
        // Through the methods the action calls: `Button("Start") { start() }`.
        var seen = Set<String>()
        var stack = Array(button.called)
        while let name = stack.popLast() {
            guard seen.insert(name).inserted, let method = scan.methods[owner]?[name] else { continue }
            if method.assigned.contains(flag) { return true }
            stack.append(contentsOf: method.called)
        }
        return false
    }

    /// A screen often has several links to one place. One arrow says that, and
    /// the arrow keeps the first link that has words on it.
    private func mergeEdges(_ edges: [AtlasGraph.Edge]) -> [AtlasGraph.Edge] {
        var order: [String] = []
        var merged: [String: AtlasGraph.Edge] = [:]
        for edge in edges {
            let key = "\(edge.from)\u{0}\(edge.to)"
            if let existing = merged[key] {
                if existing.label == nil, edge.label != nil {
                    merged[key]?.label = edge.label
                    merged[key]?.kind = edge.kind
                    merged[key]?.raw = edge.raw
                    merged[key]?.file = edge.file
                    merged[key]?.line = edge.line
                }
            } else {
                merged[key] = edge
                order.append(key)
            }
        }
        return order.compactMap { merged[$0] }
    }

    // MARK: - Routes

    /// The steps to each screen: the config's if it wrote them, otherwise the
    /// labels on the way there, tapped in turn. Breadth first, so the route is
    /// the shortest one that has words on every link.
    private func routes(through edges: [AtlasGraph.Edge]) -> (routes: [String: [Step]], launches: [String: [String]]) {
        var routes: [String: [Step]] = [:]
        var launches: [String: [String]] = [:]
        let overrides = config.screens ?? [:]
        for (id, screen) in overrides {
            if let steps = screen.steps { routes[id] = steps }
            if let arguments = screen.launchArguments { launches[id] = arguments }
        }
        for root in config.roots where routes[root] == nil {
            if let tab = scan.tabs[root] {
                routes[root] = [Step(tab: tab)]
            } else if config.roots.count == 1 {
                routes[root] = []
            }
            // With several roots and no tab to open, launching would show whichever
            // screen the app starts on, and that picture would go under this name.
        }
        var changed = true
        while changed {
            changed = false
            for edge in edges where routes[edge.to] == nil {
                guard let base = routes[edge.from], let label = edge.label else { continue }
                routes[edge.to] = base + [Step(tap: label)]
                // The way there has to start from the same state, or its taps find nothing.
                if launches[edge.to] == nil, let inherited = launches[edge.from] { launches[edge.to] = inherited }
                changed = true
            }
        }
        return (routes, launches)
    }

    private func routeNote(for id: String, edges: [AtlasGraph.Edge]) -> String {
        let incoming = edges.filter { $0.to == id }
        if let edge = incoming.first(where: { $0.label == nil }) {
            return "The link from \(edge.from) has no label in the source, so add steps for \(id) to the config."
        }
        if config.roots.contains(id) {
            return "\(id) is one of several roots and no Tab opens it, so add steps for it to the config."
        }
        return "No route from a root reaches \(id); add steps for it to the config."
    }

    // MARK: - Names

    private func title(of id: String) -> String {
        // Its own title, or that of the one view it wraps, as a tab wraps its home.
        // No deeper: a screen is not named after a note section somewhere inside it.
        var current = id
        var seen = Set<String>()
        while seen.insert(current).inserted {
            if let title = scan.titles[current] { return title }
            let views = (scan.compositions[current] ?? []).filter { scan.types[$0]?.isView == true }
            guard views.count == 1, let only = views.first else { break }
            current = only
        }
        var name = id
        for suffix in ["View", "Screen", "Page", "Tab"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
        }
        return name.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
    }

    private func group(ofFile file: String) -> String {
        var parts = file.split(separator: "/").map(String.init).dropLast()
        for source in config.sources ?? [] {
            let prefix = source.split(separator: "/").map(String.init)
            if Array(parts.prefix(prefix.count)) == prefix { parts = parts.dropFirst(prefix.count) }
        }
        return parts.joined(separator: "/")
    }

    private func unique(_ items: [AtlasGraph.Unresolved]) -> [AtlasGraph.Unresolved] {
        var seen = Set<AtlasGraph.Unresolved>()
        return items.filter { seen.insert($0).inserted }
    }
}
