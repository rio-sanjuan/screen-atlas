import Foundation
import Testing

@testable import AtlasKit

private func graph(
    _ source: String, roots: [String] = ["Root"], stopAt: [String]? = nil, screens: [String: Config.Screen]? = nil
) -> AtlasGraph {
    let result = SwiftUIScanner().scan(sources: [("App/Fixture.swift", source)])
    let config = Config(
        name: "Fixture", project: ".", workspace: nil, xcodeproj: nil, scheme: nil, sources: ["App"],
        excludePaths: nil, roots: roots, stopAt: stopAt, exclude: nil, device: nil, appearance: nil,
        launchArguments: nil, launchEnvironment: nil, timeout: nil, settle: nil, screens: screens, edges: nil
    )
    return GraphBuilder(scan: result, config: config).build()
}

private func edge(_ graph: AtlasGraph, _ from: String, _ to: String) -> AtlasGraph.Edge? {
    graph.edges.first { $0.from == from && $0.to == to }
}

@Suite struct Scanning {
    @Test func aValueLinkOpensWhatTheRouteTableSwitchSays() {
        let map = graph("""
        enum Route: Hashable { case one, two }
        struct One: View { var body: some View { Text("1") } }
        struct Two: View { var body: some View { Text("2") } }
        struct Root: View {
            var body: some View {
                NavigationLink(value: Route.one) { Label("First", systemImage: "a") }
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .one: One()
                        case .two: Two()
                        }
                    }
            }
        }
        """)
        #expect(edge(map, "Root", "One")?.label == "First")
        #expect(edge(map, "Root", "One")?.kind == .push)
        // `.two` has a table entry, but nothing on this screen links to it.
        #expect(edge(map, "Root", "Two") == nil)
    }

    @Test func aLinkInAComponentBelongsToTheScreenThatComposesIt() {
        let map = graph("""
        struct Target: View { var body: some View { Text("t") } }
        struct Row: View { var body: some View { NavigationLink("Open") { Target() } } }
        struct Section2: View { var body: some View { Row() } }
        struct Root: View { var body: some View { Section2() } }
        """)
        #expect(edge(map, "Root", "Target")?.label == "Open")
        #expect(map.nodes.map(\.id).contains("Row") == false)
    }

    @Test func aDestinationIsAnotherScreenNotPartOfThisOne() {
        let map = graph("""
        struct Far: View { var body: some View { Text("f") } }
        struct Near: View { var body: some View { NavigationLink("Far") { Far() } } }
        struct Root: View { var body: some View { NavigationLink("Near") { Near() } } }
        """)
        #expect(edge(map, "Root", "Near") != nil)
        #expect(edge(map, "Near", "Far") != nil)
        // If `Near` counted as composed by `Root`, its link would appear here too.
        #expect(edge(map, "Root", "Far") == nil)
    }

    @Test func aRouteTableInAViewExtensionHasNoLeadingDotAndStillCounts() {
        let map = graph("""
        struct Thing: Hashable {}
        struct ThingPage: View { var body: some View { Text("t") } }
        extension View {
            func thingRoutes() -> some View {
                navigationDestination(for: Thing.self) { _ in ThingPage() }
            }
        }
        struct Root: View {
            var body: some View {
                NavigationLink(value: Thing()) { Text("Thing") }.thingRoutes()
            }
        }
        """)
        #expect(edge(map, "Root", "ThingPage")?.label == "Thing")
    }

    @Test func aSheetTakesItsLabelFromTheButtonThatSetsItsState() {
        let map = graph("""
        struct Pop: View { var body: some View { Text("p") } }
        struct Root: View {
            @State private var showing = false
            var body: some View {
                Button("Show it") { showing = true }
                    .sheet(isPresented: $showing) { Pop() }
            }
        }
        """)
        #expect(edge(map, "Root", "Pop")?.label == "Show it")
        #expect(edge(map, "Root", "Pop")?.kind == .sheet)
    }

    @Test func aButtonReachesItsStateThroughTheMethodsItCalls() {
        let map = graph("""
        struct Session: View { var body: some View { Text("s") } }
        struct Root: View {
            @State private var session: Int?
            var body: some View {
                Button("Start") { start() }
                    .fullScreenCover(item: $session) { _ in Session() }
            }
            private func start() { prepare() }
            private func prepare() { session = 1 }
        }
        """)
        #expect(edge(map, "Root", "Session")?.label == "Start")
        #expect(edge(map, "Root", "Session")?.kind == .cover)
    }

    @Test func aHelperWrappingAPresentationPresentsLikeOne() {
        let map = graph("""
        struct Session: View { var body: some View { Text("s") } }
        extension View {
            func coverOnPhone(isPresented: Binding<Bool>, content: @escaping () -> some View) -> some View {
                fullScreenCover(isPresented: isPresented, content: content)
            }
        }
        struct Root: View {
            @State private var on = false
            var body: some View {
                Button("Go") { on = true }
                    .coverOnPhone(isPresented: $on) { Session() }
            }
        }
        """)
        #expect(edge(map, "Root", "Session")?.kind == .cover)
        #expect(edge(map, "Root", "Session")?.label == "Go")
        // The helper's own `content` is not a destination to report as a gap.
        #expect(map.unresolved.isEmpty)
    }

    @Test func anAccessibilityLabelNamesAnIconOnlyLink() {
        let map = graph("""
        struct Target: View { var body: some View { Text("t") } }
        struct Root: View {
            var body: some View {
                NavigationLink { Target() } label: { Image(systemName: "map") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open map")
            }
        }
        """)
        #expect(edge(map, "Root", "Target")?.label == "Open map")
    }

    @Test func aPropertysDeclaredTypeResolvesItsRoute() {
        let map = graph("""
        struct Album: Hashable {}
        struct AlbumPage: View { var body: some View { Text("d") } }
        struct Row: View {
            let album: Album
            var body: some View { NavigationLink(value: album) { Text("Open album") } }
        }
        struct Root: View {
            var body: some View {
                Row(album: Album())
                    .navigationDestination(for: Album.self) { AlbumPage(album: $0) }
            }
        }
        """)
        #expect(edge(map, "Root", "AlbumPage")?.label == "Open album")
    }

    @Test func aComputedValueIsReportedNotGuessed() {
        let map = graph("""
        struct Root: View {
            let row: Row2
            var body: some View { NavigationLink(value: row.destination.key) { Text("Mystery") } }
        }
        """)
        #expect(map.edges.isEmpty)
        #expect(map.unresolved.map(\.raw) == ["NavigationLink(value: row.destination.key)"])
    }

    @Test func previewsAreNotPartOfTheApp() {
        let map = graph("""
        struct OnlyPreviewed: View { var body: some View { Text("p") } }
        struct Root: View { var body: some View { Text("r") } }
        #Preview { NavigationLink("x") { OnlyPreviewed() } }
        """)
        #expect(map.edges.isEmpty)
        #expect(map.nodes.map(\.id) == ["Root"])
    }

    @Test func aTabsLabelBecomesTheFirstStepToItsRoot() {
        let map = graph("""
        struct HomeTab: View { var body: some View { Text("s") } }
        struct App1: View {
            var body: some View { TabView { Tab("Home", systemImage: "a", value: 1) { HomeTab() } } }
        }
        """, roots: ["HomeTab"])
        #expect(map.nodes.first?.steps == [Step(tab: "Home")])
    }

    @Test func aLoneRootWithNoTabIsWhereTheAppLaunches() {
        let map = graph("struct Root: View { var body: some View { Text(\"r\") } }")
        #expect(map.nodes.first?.steps == [])
    }

    @Test func oneOfSeveralRootsWithNoTabHasNoRouteRatherThanTheLaunchScreen() {
        let map = graph("""
        struct First: View { var body: some View { Text("f") } }
        struct Second: View { var body: some View { Text("s") } }
        struct App1: View {
            var body: some View { TabView { Tab("First", systemImage: "a", value: 1) { First() } } }
        }
        """, roots: ["First", "Second"])
        #expect(map.nodes.first { $0.id == "First" }?.steps == [Step(tab: "First")])
        let second = map.nodes.first { $0.id == "Second" }
        #expect(second?.steps == nil)
        #expect(second?.routeNote?.contains("several roots") == true)
    }

    @Test func aTabsNameDropsTheWordTab() {
        let map = graph("struct PracticeTab: View { var body: some View { Text(\"p\") } }", roots: ["PracticeTab"])
        #expect(map.nodes.first?.title == "Practice")
    }

    @Test func aScreensRouteTapsTheLabelsOnTheWay() {
        let map = graph("""
        struct C: View { var body: some View { Text("c") } }
        struct B: View { var body: some View { NavigationLink("To C") { C() } } }
        struct Root: View { var body: some View { NavigationLink("To B") { B() } } }
        """)
        let c = map.nodes.first { $0.id == "C" }
        #expect(c?.steps == [Step(tap: "To B"), Step(tap: "To C")])
    }

    @Test func aScreenBehindAnUnlabelledLinkHasNoRouteAndSaysSo() {
        let map = graph("""
        struct Pic: View { var body: some View { Text("c") } }
        struct Root: View { var body: some View { NavigationLink { Pic() } label: { Image(systemName: "a") } } }
        """)
        let pic = map.nodes.first { $0.id == "Pic" }
        #expect(pic?.steps == nil)
        #expect(pic?.routeNote?.contains("no label") == true)
    }

    @Test func stepsInTheConfigAreBuiltOnByTheScreensBeyond() {
        let map = graph("""
        struct C: View { var body: some View { Text("c") } }
        struct Pic: View { var body: some View { NavigationLink("To C") { C() } } }
        struct Root: View { var body: some View { NavigationLink { Pic() } label: { Image(systemName: "a") } } }
        """, screens: ["Pic": .init(steps: [Step(tap: "The icon")])])
        let c = map.nodes.first { $0.id == "C" }
        #expect(c?.steps == [Step(tap: "The icon"), Step(tap: "To C")])
    }

    @Test func aScreensLaunchArgumentsCarryToTheScreensRoutedThroughIt() {
        let map = graph("""
        struct C: View { var body: some View { Text("c") } }
        struct Pic: View { var body: some View { NavigationLink("To C") { C() } } }
        struct Other: View { var body: some View { Text("o") } }
        struct Root: View {
            var body: some View {
                NavigationLink { Pic() } label: { Image(systemName: "a") }
                NavigationLink("To Other") { Other() }
            }
        }
        """, screens: ["Pic": .init(steps: [Step(tap: "The icon")], launchArguments: ["-seed", "yes"])])
        #expect(map.nodes.first { $0.id == "Pic" }?.launchArguments == ["-seed", "yes"])
        #expect(map.nodes.first { $0.id == "C" }?.launchArguments == ["-seed", "yes"])
        #expect(map.nodes.first { $0.id == "Other" }?.launchArguments == nil)
    }

    @Test func aStopScreenIsDrawnButNotFollowed() {
        let map = graph("""
        struct C: View { var body: some View { Text("c") } }
        struct B: View { var body: some View { NavigationLink("To C") { C() } } }
        struct Root: View { var body: some View { NavigationLink("To B") { B() } } }
        """, stopAt: ["B"])
        #expect(map.nodes.map(\.id) == ["Root", "B"])
        #expect(map.nodes.last?.isBoundary == true)
    }

    @Test func aCycleOfScreensEnds() {
        let map = graph("""
        struct B: View { var body: some View { NavigationLink("Back") { Root() } } }
        struct Root: View { var body: some View { NavigationLink("On") { B() } } }
        """)
        #expect(map.nodes.count == 2)
        #expect(map.edges.count == 2)
    }

    @Test func aScreensTitleIsItsOwnOrThatOfTheOneViewItWraps() {
        let map = graph("""
        struct Home: View { var body: some View { Text("h").navigationTitle("Welcome") } }
        struct Root: View { var body: some View { NavigationStack { Home() } } }
        """)
        #expect(map.nodes.first?.title == "Welcome")
    }

    @Test func aNameWithNoTitleIsMadeReadable() {
        let map = graph("""
        struct AccountSettingsEditorView: View { var body: some View { Text("h") } }
        struct Root: View { var body: some View { NavigationLink("K") { AccountSettingsEditorView() } } }
        """)
        #expect(map.nodes.last?.title == "Account Settings Editor")
    }
}
