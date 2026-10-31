import Foundation
import SwiftParser
import SwiftSyntax

/// Reads SwiftUI source and writes down how views reach each other.
///
/// This is syntax, not types: it has no compiler behind it, so it sees what is
/// written and guesses nothing it can check. A link whose value is computed
/// comes out unresolved rather than wrong, and the graph says so, because a gap
/// someone can fill is better than an arrow nobody can trust.
public struct SwiftUIScanner {
    public struct TypeFacts: Sendable {
        public var name: String
        public var file: String
        public var line: Int
        public var isView: Bool
        public var isModifier: Bool
        public var properties: [String: String]
    }

    /// One way out of a view, before route values have been looked up.
    public struct RawEdge: Sendable {
        public enum Target: Hashable, Sendable {
            case views([String])
            case route(type: String, member: String?)
            case implicitMember(String)
            case unknown
        }

        public var owner: String
        public var kind: EdgeKind
        public var target: Target
        public var label: String?
        /// The state a presentation hangs on, for finding the button that sets it.
        public var flag: String?
        public var raw: String
        public var file: String
        public var line: Int
    }

    public struct ButtonFacts: Sendable {
        public var label: String
        public var assigned: Set<String>
        public var called: Set<String>
    }

    public struct MethodFacts: Sendable {
        public var assigned: Set<String> = []
        public var called: Set<String> = []
    }

    public struct Result: Sendable {
        public var types: [String: TypeFacts] = [:]
        public var extensionFunctions: Set<String> = []
        public var compositions: [String: Set<String>] = [:]
        public var edges: [RawEdge] = []
        /// Route type → case name (nil for "any value") → the views it opens.
        public var routeTables: [String: [String?: Set<String>]] = [:]
        public var tabs: [String: String] = [:]
        public var titles: [String: String] = [:]
        public var buttons: [String: [ButtonFacts]] = [:]
        public var methods: [String: [String: MethodFacts]] = [:]
    }

    public init() {}

    /// Scans source strings, keyed by the path to report for each.
    public func scan(sources: [(path: String, text: String)]) -> Result {
        let parsed = sources.map { (path: $0.path, tree: Parser.parse(source: $0.text)) }

        let collector = TypeCollector()
        for file in parsed {
            collector.file = file.path
            collector.converter = SourceLocationConverter(fileName: file.path, tree: file.tree)
            collector.walk(file.tree)
        }

        var result = Result()
        result.types = collector.types
        result.extensionFunctions = collector.extensionFunctions

        let views = Set(collector.types.values.filter(\.isView).map(\.name))
        let modifiers = Set(collector.types.values.filter(\.isModifier).map(\.name))
        let aliases = collector.presentationAliases
        for file in parsed {
            let walker = BodyWalker(
                file: file.path,
                converter: SourceLocationConverter(fileName: file.path, tree: file.tree),
                views: views, modifiers: modifiers, aliases: aliases,
                extensionFunctions: collector.extensionFunctions, types: collector.types
            )
            walker.walk(file.tree)
            walker.merge(into: &result)
        }
        return result
    }

    /// Scans every Swift file under the given folders.
    public func scan(project: URL, folders: [String], excludePaths: [String]) throws -> Result {
        var sources: [(path: String, text: String)] = []
        let manager = FileManager.default
        for folder in folders {
            let root = project.appendingPathComponent(folder)
            guard let walk = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw AtlasError("couldn't read \(root.path)")
            }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let relative = url.standardizedFileURL.path
                    .replacingOccurrences(of: project.standardizedFileURL.path + "/", with: "")
                // `.build` holds checked-out dependencies, which are not this app's screens.
                let excluded = excludePaths + [".build/", "/Tests/", ".claude/"]
                if excluded.contains(where: { relative.contains($0) }) { continue }
                sources.append((relative, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        // Sorted because a directory's order differs between machines, and the
        // first label found for an edge should not.
        return scan(sources: sources.sorted { $0.path < $1.path })
    }
}

// MARK: - First pass: what types exist

private final class TypeCollector: SyntaxVisitor {
    var file = ""
    var converter: SourceLocationConverter!
    var types: [String: SwiftUIScanner.TypeFacts] = [:]
    var extensionFunctions: Set<String> = []
    /// `extension View` helpers that wrap a presentation, such as a sheet on one
    /// platform and a cover on another. Their callers are presentations too.
    var presentationAliases: [String: EdgeKind] = [:]

    init() { super.init(viewMode: .sourceAccurate) }

    private func record(
        _ name: String, inherited: InheritanceClauseSyntax?, members: MemberBlockSyntax, at node: some SyntaxProtocol
    ) {
        let inherits = inherited?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        if inherits.contains("PreviewProvider") { return }
        var properties: [String: String] = [:]
        for member in members.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                guard let id = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let type = binding.typeAnnotation?.type else { continue }
                properties[id] = cleanType(type.trimmedDescription)
            }
        }
        var facts = types[name] ?? .init(
            name: name, file: file, line: node.startLocation(converter: converter).line,
            isView: false, isModifier: false, properties: [:]
        )
        facts.isView = facts.isView || inherits.contains("View")
        facts.isModifier = facts.isModifier || inherits.contains("ViewModifier")
        facts.properties.merge(properties) { first, _ in first }
        types[name] = facts
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, inherited: node.inheritanceClause, members: node.memberBlock, at: node)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, inherited: node.inheritanceClause, members: node.memberBlock, at: node)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, inherited: node.inheritanceClause, members: node.memberBlock, at: node)
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        node.macroName.text == "Preview" ? .skipChildren : .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.extendedType.trimmedDescription == "View" else {
            if let inherited = node.inheritanceClause {
                record(
                    node.extendedType.trimmedDescription, inherited: inherited,
                    members: node.memberBlock, at: node
                )
            }
            return .visitChildren
        }
        for member in node.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            extensionFunctions.insert(function.name.text)
            if let kind = PresentationFinder.first(in: Syntax(function)) {
                presentationAliases[function.name.text] = kind
            }
        }
        return .visitChildren
    }
}

/// The first presentation in a helper's body. First, because a helper that is a
/// cover on iOS and a sheet elsewhere writes the iOS branch first, and the
/// simulator is where these screens get captured.
private final class PresentationFinder: SyntaxVisitor {
    var kind: EdgeKind?

    init() { super.init(viewMode: .sourceAccurate) }

    static func first(in node: Syntax) -> EdgeKind? {
        let finder = PresentationFinder()
        finder.walk(node)
        return finder.kind
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if kind == nil, let name = calledName(node), let found = standardPresentations[name] {
            kind = found
        }
        return .visitChildren
    }
}

private let standardPresentations: [String: EdgeKind] = [
    "sheet": .sheet, "popover": .sheet, "inspector": .sheet, "fullScreenCover": .cover,
]

// MARK: - Second pass: how they connect

private final class BodyWalker: SyntaxVisitor {
    private let file: String
    private let converter: SourceLocationConverter
    private let views: Set<String>
    private let modifiers: Set<String>
    private let aliases: [String: EdgeKind]
    private let extensionFunctions: Set<String>
    private let types: [String: SwiftUIScanner.TypeFacts]

    private var owners: [String] = []
    private var inViewExtension = false
    private var localTypes: [String: String] = [:]

    /// Closures and expressions that are another screen, not part of this one.
    /// Inside them a view is a destination, so it must not count as composition.
    private var destinations: Set<SyntaxIdentifier> = []
    private var destinationDepth = 0
    private var labelOverrides: [SyntaxIdentifier: String] = [:]
    private var handledAppends: Set<SyntaxIdentifier> = []

    private var compositions: [String: Set<String>] = [:]
    private var edges: [SwiftUIScanner.RawEdge] = []
    private var routeTables: [String: [String?: Set<String>]] = [:]
    private var tabs: [String: String] = [:]
    private var titles: [String: String] = [:]
    private var buttons: [String: [SwiftUIScanner.ButtonFacts]] = [:]
    private var methods: [String: [String: SwiftUIScanner.MethodFacts]] = [:]

    init(
        file: String, converter: SourceLocationConverter, views: Set<String>, modifiers: Set<String>,
        aliases: [String: EdgeKind], extensionFunctions: Set<String>, types: [String: SwiftUIScanner.TypeFacts]
    ) {
        self.file = file
        self.converter = converter
        self.views = views
        self.modifiers = modifiers
        self.aliases = aliases
        self.extensionFunctions = extensionFunctions
        self.types = types
        super.init(viewMode: .sourceAccurate)
    }

    func merge(into result: inout SwiftUIScanner.Result) {
        result.compositions.merge(compositions) { $0.union($1) }
        result.edges.append(contentsOf: edges)
        for (type, table) in routeTables {
            result.routeTables[type, default: [:]].merge(table) { $0.union($1) }
        }
        result.tabs.merge(tabs) { first, _ in first }
        result.titles.merge(titles) { first, _ in first }
        result.buttons.merge(buttons) { $0 + $1 }
        for (owner, table) in methods {
            result.methods[owner, default: [:]].merge(table) { first, _ in first }
        }
    }

    private var owner: String? { owners.last }

    private func line(of node: some SyntaxProtocol) -> Int {
        node.startLocation(converter: converter).line
    }

    // MARK: Scopes

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.inheritanceClause?.inheritedTypes.contains(where: { $0.type.trimmedDescription == "PreviewProvider" }) == true {
            return .skipChildren
        }
        owners.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) {
        if owners.last == node.name.text { owners.removeLast() }
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        owners.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { owners.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        owners.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { owners.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.trimmedDescription
        if name == "View" {
            inViewExtension = true
        } else {
            owners.append(name)
        }
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) {
        if inViewExtension {
            inViewExtension = false
        } else {
            owners.removeLast()
        }
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        node.macroName.text == "Preview" ? .skipChildren : .visitChildren
    }
    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        node.macroName.text == "Preview" ? .skipChildren : .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        // A helper on `View` has no type to belong to, so it stands in for one:
        // whoever calls `.helper()` composes whatever the helper's body holds.
        if inViewExtension, owners.isEmpty {
            owners.append("ext:\(node.name.text)")
        }
        for parameter in node.signature.parameterClause.parameters {
            let name = (parameter.secondName ?? parameter.firstName).text
            localTypes[name] = cleanType(parameter.type.trimmedDescription)
        }
        if let owner, let body = node.body {
            let facts = ActionFacts.read(Syntax(body))
            methods[owner, default: [:]][node.name.text] = .init(assigned: facts.assigned, called: facts.called)
        }
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        if inViewExtension, owners.last == "ext:\(node.name.text)" {
            owners.removeLast()
        }
        localTypes.removeAll()
    }

    // MARK: Destinations

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        if destinations.contains(node.id) { destinationDepth += 1 }
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) {
        if destinations.contains(node.id) { destinationDepth -= 1 }
    }

    override func visitPost(_ node: FunctionCallExprSyntax) {
        if destinations.contains(node.id) { destinationDepth -= 1 }
    }

    // MARK: Calls

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if destinations.contains(node.id) { destinationDepth += 1 }
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            // Inside a `View` extension or a modifier, `navigationDestination(for:)`
            // has no leading dot. It is still that modifier, not a function of ours.
            if name.first?.isLowercase == true {
                handleMemberCall(name, base: nil, node)
            } else {
                handleTypeCall(name, node)
            }
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            handleMemberCall(member.declName.baseName.text, base: member.base, node)
        }
        return .visitChildren
    }

    private func handleTypeCall(_ name: String, _ node: FunctionCallExprSyntax) {
        switch name {
        case "NavigationLink": handleNavigationLink(node)
        case "Button": handleButton(node)
        case "Tab": handleTab(node)
        default: break
        }
        if let owner, destinationDepth == 0, views.contains(name) || modifiers.contains(name) {
            compositions[owner, default: []].insert(name)
        }
    }

    private func handleMemberCall(_ name: String, base: ExprSyntax?, _ node: FunctionCallExprSyntax) {
        switch name {
        case "navigationTitle":
            if let owner, titles[owner] == nil, let title = firstLiteral(node) { titles[owner] = title }
        case "accessibilityLabel":
            // Called on the link's chain, and visited before the link inside it,
            // so the label is waiting by the time the link is read.
            if let base, let text = firstLiteral(node), let root = chainRoot(base) { labelOverrides[root.id] = text }
        case "navigationDestination":
            handleNavigationDestination(node)
        case "tabItem":
            handleTabItem(node, base: base)
        case "append":
            handleAppend(node, base: base)
        default:
            if let kind = standardPresentations[name] ?? aliases[name] {
                handlePresentation(node, kind: kind, name: name)
            } else if let owner, destinationDepth == 0, extensionFunctions.contains(name) {
                compositions[owner, default: []].insert("ext:\(name)")
            }
        }
    }

    private func handleNavigationLink(_ node: FunctionCallExprSyntax) {
        guard let owner else { return }
        let literal = firstLiteral(node)
        let value = argument("value", of: node)
        let destinationArgument = argument("destination", of: node)
        let labelClosure = node.additionalTrailingClosures.first { $0.label.text == "label" }?.closure

        var label = labelOverrides[node.id] ?? literal
        var target: SwiftUIScanner.RawEdge.Target?

        if let value {
            target = routeTarget(value)
            if label == nil, let closure = node.trailingClosure { label = LabelFinder.first(in: Syntax(closure)) }
        } else if let destinationArgument {
            markDestination(Syntax(destinationArgument))
            target = .views(ViewFinder.views(in: Syntax(destinationArgument), known: views))
            if label == nil, let closure = node.trailingClosure { label = LabelFinder.first(in: Syntax(closure)) }
        } else if let closure = node.trailingClosure {
            // `NavigationLink { Destination() } label: { … }`, or `NavigationLink("Title") { Destination() }`.
            markDestination(Syntax(closure))
            target = .views(ViewFinder.views(in: Syntax(closure), known: views))
            if label == nil, let labelClosure { label = LabelFinder.first(in: Syntax(labelClosure)) }
        }

        if let target {
            addEdge(owner: owner, kind: .push, target: target, label: label, flag: nil, node: node)
        }
    }

    private func handleButton(_ node: FunctionCallExprSyntax) {
        guard let owner else { return }
        var action: Syntax?
        var labelSource: Syntax?
        if let argument = argument("action", of: node) {
            action = Syntax(argument)
            labelSource = node.trailingClosure.map(Syntax.init)
        } else {
            action = node.trailingClosure.map(Syntax.init)
            labelSource = node.additionalTrailingClosures.first { $0.label.text == "label" }.map { Syntax($0.closure) }
        }
        let label = labelOverrides[node.id] ?? firstLiteral(node) ?? labelSource.flatMap { LabelFinder.first(in: $0) }
        guard let label, let action else { return }

        let facts = ActionFacts.read(action)
        buttons[owner, default: []].append(.init(label: label, assigned: facts.assigned, called: facts.called))

        // A push from code takes the button's label, since it has none of its own.
        for append in facts.pathAppends {
            handledAppends.insert(append.id)
            if let value = append.arguments.first?.expression {
                addEdge(owner: owner, kind: .push, target: routeTarget(value), label: label, flag: nil, node: append)
            }
        }
    }

    private func handleAppend(_ node: FunctionCallExprSyntax, base: ExprSyntax?) {
        guard let owner, !handledAppends.contains(node.id), isPath(base),
              let value = node.arguments.first?.expression else { return }
        addEdge(owner: owner, kind: .push, target: routeTarget(value), label: nil, flag: nil, node: node)
    }

    private func handleTab(_ node: FunctionCallExprSyntax) {
        guard let closure = node.trailingClosure else { return }
        let isSearch = argument("role", of: node)?.trimmedDescription == ".search"
        guard let label = firstLiteral(node) ?? (isSearch ? "Search" : nil) else { return }
        for view in ViewFinder.views(in: Syntax(closure), known: views) where tabs[view] == nil {
            tabs[view] = label
        }
    }

    private func handleTabItem(_ node: FunctionCallExprSyntax, base: ExprSyntax?) {
        guard let base, let closure = node.trailingClosure,
              let label = LabelFinder.first(in: Syntax(closure)) else { return }
        for view in ViewFinder.views(in: Syntax(base), known: views) where tabs[view] == nil {
            tabs[view] = label
        }
    }

    private func handleNavigationDestination(_ node: FunctionCallExprSyntax) {
        guard let closure = node.trailingClosure else { return }
        markDestination(Syntax(closure))
        if let forType = argument("for", of: node) {
            let type = cleanType(forType.trimmedDescription.replacingOccurrences(of: ".self", with: ""))
            for (member, opened) in routeEntries(closure) {
                routeTables[type, default: [:]][member, default: []].formUnion(opened)
            }
            return
        }
        // `navigationDestination(item:)` and `(isPresented:)` open from state, as a sheet does.
        guard let owner else { return }
        let state = argument("item", of: node) ?? argument("isPresented", of: node)
        addEdge(
            owner: owner, kind: .push, target: .views(ViewFinder.views(in: Syntax(closure), known: views)),
            label: nil, flag: state.flatMap(flagName), node: node
        )
    }

    private func handlePresentation(_ node: FunctionCallExprSyntax, kind: EdgeKind, name: String) {
        guard let owner else { return }
        let content = node.trailingClosure.map(Syntax.init)
            ?? argument("content", of: node).map(Syntax.init)
        guard let content else { return }
        markDestination(content)
        let state = argument("isPresented", of: node) ?? argument("item", of: node)
        addEdge(
            owner: owner, kind: kind, target: .views(ViewFinder.views(in: content, known: views)),
            label: nil, flag: state.flatMap(flagName), node: node
        )
    }

    // MARK: Helpers

    private func markDestination(_ node: Syntax) {
        destinations.insert(node.id)
    }

    private func addEdge(
        owner: String, kind: EdgeKind, target: SwiftUIScanner.RawEdge.Target, label: String?, flag: String?,
        node: FunctionCallExprSyntax
    ) {
        // A presentation of inline content, such as a popover of plain text, has
        // no view to draw. It is not a screen and not a gap in the map either.
        if case .views(let opened) = target, opened.isEmpty, kind != .push { return }
        // The call alone: a modifier's own text begins with everything it was chained onto.
        let call = "\(calledName(node) ?? "")(\(node.arguments.trimmedDescription))"
        let text = String(call.prefix(90)).split(separator: "\n").first.map(String.init) ?? call
        edges.append(.init(
            owner: owner, kind: kind, target: target, label: label, flag: flag,
            raw: text, file: file, line: line(of: node)
        ))
    }

    private func argument(_ name: String, of node: FunctionCallExprSyntax) -> ExprSyntax? {
        node.arguments.first { $0.label?.text == name }?.expression
    }

    private func firstLiteral(_ node: FunctionCallExprSyntax) -> String? {
        guard let first = node.arguments.first, first.label == nil else { return nil }
        return literal(first.expression)
    }

    /// The call a chain of modifiers started from.
    private func chainRoot(_ expression: ExprSyntax) -> FunctionCallExprSyntax? {
        var current: ExprSyntax? = expression
        while let call = current?.as(FunctionCallExprSyntax.self) {
            guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return call }
            current = member.base
        }
        return nil
    }

    private func isPath(_ base: ExprSyntax?) -> Bool {
        base?.trimmedDescription.lowercased().hasSuffix("path") ?? false
    }

    /// What pushing this value opens, read from how it is written.
    private func routeTarget(_ expression: ExprSyntax) -> SwiftUIScanner.RawEdge.Target {
        if let member = expression.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            guard let base = member.base else { return .implicitMember(name) }
            let baseText = base.trimmedDescription
            if baseText.first?.isUppercase == true {
                return .route(type: cleanType(baseText), member: name)
            }
            return typedProperty(name, on: baseText)
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self),
               reference.baseName.text.first?.isUppercase == true {
                return .route(type: reference.baseName.text, member: nil)
            }
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                if member.base == nil { return .implicitMember(member.declName.baseName.text) }
                let baseText = member.base?.trimmedDescription ?? ""
                if baseText.first?.isUppercase == true {
                    return .route(type: cleanType(baseText), member: member.declName.baseName.text)
                }
            }
            return .unknown
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return typedProperty(reference.baseName.text, on: nil)
        }
        return .unknown
    }

    /// A value held in a variable: its declared type, when one is written down.
    private func typedProperty(_ name: String, on base: String?) -> SwiftUIScanner.RawEdge.Target {
        if base == nil || base == "self" {
            if let type = localTypes[name] ?? owner.flatMap({ types[$0]?.properties[name] }) {
                return .route(type: type, member: nil)
            }
        }
        // `ForEach(albums) { album in NavigationLink(value: album) }`: a closure's
        // parameter has no written type. Its name is the only evidence, and the
        // graph builder accepts it only if it names a route type exactly.
        return .route(type: "?\(name)", member: nil)
    }

    private func routeEntries(_ closure: ClosureExprSyntax) -> [(String?, Set<String>)] {
        guard let switchExpr = SwitchFinder.first(in: Syntax(closure)) else {
            return [(nil, Set(ViewFinder.views(in: Syntax(closure), known: views)))]
        }
        var entries: [(String?, Set<String>)] = []
        for element in switchExpr.cases {
            guard let switchCase = element.as(SwitchCaseSyntax.self) else { continue }
            let opened = Set(ViewFinder.views(in: Syntax(switchCase.statements), known: views))
            switch switchCase.label {
            case .case(let label):
                for item in label.caseItems {
                    entries.append((caseName(item.pattern.trimmedDescription), opened))
                }
            case .default:
                entries.append((nil, opened))
            }
        }
        return entries
    }
}

// MARK: - Small readers

private func calledName(_ node: FunctionCallExprSyntax) -> String? {
    if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
    return node.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
}

private func literal(_ expression: ExprSyntax) -> String? {
    guard let string = expression.as(StringLiteralExprSyntax.self), string.segments.count == 1,
          case .stringSegment(let segment)? = string.segments.first else { return nil }
    return segment.content.text
}

/// `.chapter(let value)` and `let .chapter(value)` are both the case `chapter`.
private func caseName(_ pattern: String) -> String? {
    let stripped = pattern.replacingOccurrences(of: "let ", with: "").replacingOccurrences(of: "var ", with: "")
    guard let dot = stripped.firstIndex(of: ".") else { return nil }
    let name = stripped[stripped.index(after: dot)...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
    return name.isEmpty ? nil : String(name)
}

/// The bare name of a type: `Binding<Album>?` and `Library.Album` are both `Album`,
/// since that is what a route table for it is registered under.
func cleanType(_ text: String) -> String {
    var type = text.trimmingCharacters(in: .whitespaces)
    while type.hasSuffix("?") || type.hasSuffix("!") { type.removeLast() }
    for wrapper in ["Binding<", "Optional<"] where type.hasPrefix(wrapper) && type.hasSuffix(">") {
        type = String(type.dropFirst(wrapper.count).dropLast())
    }
    while type.hasSuffix("?") { type.removeLast() }
    return type.split(separator: ".").last.map(String.init) ?? type
}

/// The state a binding hangs on. `$flag` is that state, and in
/// `Binding(get: { session != nil }, …)` the first thing named after `get` is.
private func flagName(_ expression: ExprSyntax) -> String? {
    IdentifierFinder.first(in: Syntax(expression)).map { $0.hasPrefix("$") ? String($0.dropFirst()) : $0 }
}

private final class IdentifierFinder: SyntaxVisitor {
    var found: String?

    init() { super.init(viewMode: .sourceAccurate) }

    static func first(in node: Syntax) -> String? {
        let finder = IdentifierFinder()
        finder.walk(node)
        return finder.found
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if found == nil, !["Binding", "self", "nil"].contains(name) { found = name }
        return .visitChildren
    }
}

/// The project views a piece of source creates, stopping at each: a view inside
/// another view's closure belongs to that view, not to whoever wrote the outer one.
private final class ViewFinder: SyntaxVisitor {
    private let known: Set<String>
    private var found: [String] = []

    private init(known: Set<String>) {
        self.known = known
        super.init(viewMode: .sourceAccurate)
    }

    static func views(in node: Syntax, known: Set<String>) -> [String] {
        let finder = ViewFinder(known: known)
        finder.walk(node)
        return finder.found
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self),
           known.contains(reference.baseName.text) {
            if !found.contains(reference.baseName.text) { found.append(reference.baseName.text) }
            return .skipChildren
        }
        return .visitChildren
    }
}

/// The text a label closure would show.
private final class LabelFinder: SyntaxVisitor {
    private var found: String?

    private init() { super.init(viewMode: .sourceAccurate) }

    static func first(in node: Syntax) -> String? {
        let finder = LabelFinder()
        finder.walk(node)
        return finder.found
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if found == nil, let name = calledName(node), ["Label", "Text", "LabeledContent"].contains(name),
           let first = node.arguments.first, first.label == nil, let text = literal(first.expression) {
            found = text
            return .skipChildren
        }
        return found == nil ? .visitChildren : .skipChildren
    }
}

private final class SwitchFinder: SyntaxVisitor {
    private var found: SwitchExprSyntax?

    private init() { super.init(viewMode: .sourceAccurate) }

    static func first(in node: Syntax) -> SwitchExprSyntax? {
        let finder = SwitchFinder()
        finder.walk(node)
        return finder.found
    }

    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        if found == nil { found = node }
        return .skipChildren
    }
}

/// What a button's action or a method's body does to state, which is how a
/// presentation hanging on that state gets connected to the button.
private final class ActionFacts: SyntaxVisitor {
    var assigned: Set<String> = []
    var called: Set<String> = []
    var pathAppends: [FunctionCallExprSyntax] = []

    private init() { super.init(viewMode: .sourceAccurate) }

    static func read(_ node: Syntax) -> ActionFacts {
        let facts = ActionFacts()
        facts.walk(node)
        return facts
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        if elements.count >= 3, elements[1].is(AssignmentExprSyntax.self) {
            let target = elements[0].trimmedDescription.replacingOccurrences(of: "self.", with: "")
            assigned.insert(target)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            called.insert(reference.baseName.text)
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let base = member.base?.trimmedDescription ?? ""
            if member.declName.baseName.text == "toggle" {
                assigned.insert(base.replacingOccurrences(of: "self.", with: ""))
            } else if member.declName.baseName.text == "append", base.lowercased().hasSuffix("path") {
                pathAppends.append(node)
            } else if base == "self" {
                called.insert(member.declName.baseName.text)
            }
        }
        return .visitChildren
    }
}
