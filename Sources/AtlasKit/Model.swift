import Foundation

/// One thing to do on the way to a screen. A struct of optionals rather than an
/// enum so that a step reads as `{"tap": "Settings"}` in a config, and so the
/// driver, which cannot import this package, can decode the same JSON by itself.
public struct Step: Codable, Hashable, Sendable {
    public var tab: String?
    public var tap: String?
    public var tapContaining: String?
    /// Holds a finger on an element, for what's only in its context menu.
    public var longPress: String?
    public var longPressContaining: String?
    public var swipe: String?
    public var back: Bool?
    public var type: String?
    public var wait: Double?
    public var waitFor: String?

    public init(
        tab: String? = nil, tap: String? = nil, tapContaining: String? = nil,
        longPress: String? = nil, longPressContaining: String? = nil, swipe: String? = nil, back: Bool? = nil, type: String? = nil,
        wait: Double? = nil, waitFor: String? = nil
    ) {
        self.tab = tab
        self.tap = tap
        self.tapContaining = tapContaining
        self.longPress = longPress
        self.longPressContaining = longPressContaining
        self.swipe = swipe
        self.back = back
        self.type = type
        self.wait = wait
        self.waitFor = waitFor
    }

    public var summary: String {
        if let tab { return "Open the \(tab) tab" }
        if let tap { return "Tap \(tap)" }
        if let tapContaining { return "Tap the row containing \(tapContaining)" }
        if let longPress { return "Long-press \(longPress)" }
        if let longPressContaining { return "Long-press the element containing \(longPressContaining)" }
        if let swipe { return "Swipe \(swipe)" }
        if back != nil { return "Go back" }
        if let type { return "Type \(type)" }
        if let wait { return "Wait \(wait) s" }
        if let waitFor { return "Wait for \(waitFor)" }
        return "Do nothing"
    }
}

public enum EdgeKind: String, Codable, Hashable, Sendable {
    case push, sheet, cover, tab
}

/// What a project tells the tool. Everything specific to an app lives here, in a
/// file the tool is pointed at, so one build of the tool serves every project.
public struct Config: Codable, Sendable {
    public struct Screen: Codable, Sendable {
        public var title: String?
        /// The whole route to this screen, replacing what the scan worked out.
        public var steps: [Step]?
        /// Labels that must be on screen, or the capture counts as failed. This
        /// is what catches a stray dialog sitting over the screen you asked for.
        public var expect: [String]?
        /// A reason not to capture this screen. It stays on the map, marked.
        public var skip: String?
        /// Replaces the config's `launchArguments` for this screen and those routed
        /// through it. This is how an app's own staging hook can supply the data a
        /// screen needs, when a new user would have none.
        public var launchArguments: [String]?
    }

    public struct ExtraEdge: Codable, Sendable {
        public var from: String
        public var to: String
        public var label: String?
        public var kind: EdgeKind?
    }

    public var name: String
    /// The project's folder, relative to the config file.
    public var project: String
    public var workspace: String?
    public var xcodeproj: String?
    public var scheme: String?
    /// Folders to scan, relative to `project`.
    public var sources: [String]?
    /// Any scanned path containing one of these is ignored.
    public var excludePaths: [String]?
    /// The views the map starts from: a tab root, or the app's root view.
    public var roots: [String]
    /// Screens drawn on the map but not followed any further. This is how a map
    /// of one tab keeps from swallowing the rest of the app.
    public var stopAt: [String]?
    /// Views the scan should not treat as screens at all.
    public var exclude: [String]?
    public var device: String?
    public var appearance: String?
    public var launchArguments: [String]?
    public var launchEnvironment: [String: String]?
    /// How long one step may wait for its element, in seconds.
    public var timeout: Double?
    /// How long a screen gets to finish animating before its screenshot.
    public var settle: Double?
    public var screens: [String: Screen]?
    /// Connections the scan cannot see, such as a link whose value is computed.
    public var edges: [ExtraEdge]?

    public static func load(from url: URL) throws -> Config {
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch {
            throw AtlasError("couldn't read \(url.path): \(error)")
        }
    }
}

/// Where one config's files live on disk.
public struct Paths: Sendable {
    public let config: URL
    public let project: URL
    public let output: URL

    public init(configURL: URL, config: Config) {
        self.config = configURL.standardizedFileURL
        let folder = self.config.deletingLastPathComponent()
        project = URL(fileURLWithPath: config.project, relativeTo: folder).standardizedFileURL
        output = folder.appendingPathComponent("out")
    }

    public var graph: URL { output.appendingPathComponent("graph.json") }
    public var results: URL { output.appendingPathComponent("results.json") }
    public var screens: URL { output.appendingPathComponent("screens") }
    public var logs: URL { output.appendingPathComponent("logs") }
    public var chartPNG: URL { output.appendingPathComponent("chart.png") }
    public var chartPDF: URL { output.appendingPathComponent("chart.pdf") }
    public var map: URL { output.appendingPathComponent("map.html") }

    public var outputs: String {
        "\nchart  \(chartPNG.path)\n       \(chartPDF.path)\nmap    \(map.path)"
    }
}

public struct AtlasError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - The graph

public struct AtlasGraph: Codable, Sendable {
    public struct Node: Codable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var file: String?
        public var line: Int?
        public var group: String?
        public var isRoot: Bool
        public var isBoundary: Bool
        /// Nil when no route could be worked out; `routeNote` says why.
        public var steps: [Step]?
        public var routeNote: String?
        public var expect: [String]?
        public var skip: String?
        public var launchArguments: [String]?
    }

    public struct Edge: Codable, Hashable, Sendable {
        public var from: String
        public var to: String
        public var kind: EdgeKind
        public var label: String?
        /// The source that declared this connection, or nil if the config did.
        public var raw: String?
        public var file: String?
        public var line: Int?
    }

    /// A link the scan saw and could not follow, kept so the gap is visible.
    public struct Unresolved: Codable, Hashable, Sendable {
        public var screen: String
        public var raw: String
        public var file: String
        public var line: Int
    }

    public var name: String
    public var nodes: [Node]
    public var edges: [Edge]
    public var unresolved: [Unresolved]
}

// MARK: - Capture results

/// An element's place on a screenshot, as fractions of the screen.
public struct LinkFrame: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct CaptureResult: Codable, Sendable {
    /// Where the links to other screens sit on this one, by the screen they open.
    public var links: [String: LinkFrame]?
    public var id: String
    /// ok, failed or crashed.
    public var status: String
    public var note: String?
    public var file: String?
    public var visibleLabels: [String]?
    public var seconds: Double?
}

public struct CaptureRun: Codable, Sendable {
    public var device: String?
    public var runtime: String?
    public var commit: String?
    public var capturedAt: Date?
    public var results: [String: CaptureResult]

    public init(
        device: String? = nil, runtime: String? = nil, commit: String? = nil,
        capturedAt: Date? = nil, results: [String: CaptureResult] = [:]
    ) {
        self.device = device
        self.runtime = runtime
        self.commit = commit
        self.capturedAt = capturedAt
        self.results = results
    }

    /// Every link's place, by source screen and then by target.
    public var linkFrames: [String: [String: LinkFrame]] {
        results.compactMapValues(\.links)
    }
}

extension JSONEncoder {
    static var atlas: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var atlas: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Data {
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder.atlas.decode(type, from: self)
    }
}
