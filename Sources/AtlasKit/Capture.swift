import Foundation

/// Builds the app, walks to each screen in a simulator, and takes its picture.
public struct Capturer {
    public struct Options: Sendable {
        public var build = true
        public var keepBooted = false
        /// Capture only these screens, keeping the last run's results for the rest.
        public var only: [String] = []
        public init() {}
    }

    private let config: Config
    private let paths: Paths
    private let options: Options
    private let log: @Sendable (String) -> Void

    public init(config: Config, paths: Paths, options: Options, log: @escaping @Sendable (String) -> Void) {
        self.config = config
        self.paths = paths
        self.options = options
        self.log = log
    }

    /// Where the driver project sits, found from this file: the tool always runs
    /// out of its own checkout, and the driver is built from source in it.
    private static let driverFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Driver")

    private var cache: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ScreenAtlas")
            .appendingPathComponent(slug(config.name))
    }

    public func run(graph: AtlasGraph) throws -> CaptureRun {
        let simulator = try Simulator.prepare(
            name: "ScreenAtlas · \(config.name)",
            deviceType: config.device ?? "iPhone 17 Pro",
            appearance: config.appearance ?? "light",
            log: log
        )
        defer {
            if !options.keepBooted { simulator.shutdown() }
        }

        let app = try builtApp(for: simulator)
        try simulator.install(app, fresh: options.only.isEmpty)
        log("installed  \(app.bundleID)")

        let manager = FileManager.default
        try manager.createDirectory(at: paths.screens, withIntermediateDirectories: true)
        let capturable = graph.nodes.filter { node in
            node.skip == nil && node.steps != nil && (options.only.isEmpty || options.only.contains(node.id))
        }
        if options.only.isEmpty {
            // Nothing from a previous run may pass for this one.
            for name in (try? manager.contentsOfDirectory(atPath: paths.screens.path)) ?? [] {
                try? manager.removeItem(at: paths.screens.appendingPathComponent(name))
            }
        } else {
            for node in capturable {
                for name in ["\(slug(node.id)).png", "failed-\(slug(node.id)).png"] {
                    try? manager.removeItem(at: paths.screens.appendingPathComponent(name))
                }
            }
        }

        let produced = try drive(capturable, graph: graph, app: app, simulator: simulator)

        var results: [String: CaptureResult] = options.only.isEmpty ? [:] : (load()?.results ?? [:])
        for node in capturable where produced[node.id] == nil {
            results[node.id] = CaptureResult(
                id: node.id, status: "failed",
                note: "The driver stopped before reaching this screen; see out/logs/driver.log."
            )
        }
        results.merge(produced) { _, new in new }

        let run = CaptureRun(
            device: simulator.deviceType, runtime: simulator.runtime,
            commit: commit(), capturedAt: Date(), results: results
        )
        try JSONEncoder.atlas.encode(run).write(to: paths.results)
        return run
    }

    public func load() -> CaptureRun? {
        guard let data = try? Data(contentsOf: paths.results) else { return nil }
        return try? JSONDecoder.atlas.decode(CaptureRun.self, from: data)
    }

    // MARK: - The app

    struct BuiltApp {
        let path: URL
        let bundleID: String
    }

    private func builtApp(for simulator: Simulator) throws -> BuiltApp {
        // An XcodeGen project is usually gitignored, so a fresh clone has none yet.
        let spec = paths.project.appendingPathComponent("project.yml")
        if firstFile(ending: ".xcodeproj") == nil, FileManager.default.fileExists(atPath: spec.path) {
            log("generating the project from project.yml")
            try Shell.require(["xcodegen", "generate", "--quiet"], in: paths.project, doing: "Generating the project")
        }

        var arguments = ["xcodebuild"]
        if let workspace = config.workspace ?? firstFile(ending: ".xcworkspace") {
            arguments += ["-workspace", workspace]
        } else if let project = config.xcodeproj ?? firstFile(ending: ".xcodeproj") {
            arguments += ["-project", project]
        } else {
            throw AtlasError("No .xcworkspace or .xcodeproj in \(paths.project.path); name one in the config.")
        }
        guard let scheme = config.scheme else { throw AtlasError("The config needs a \"scheme\" to build.") }
        // Its own build folder: another session or Xcode building the same project
        // in the shared one would fail one of the two on a locked database.
        arguments += [
            "-scheme", scheme, "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,id=\(simulator.udid)",
            "-derivedDataPath", cache.appendingPathComponent("app").path,
        ]

        if options.build {
            log("building   \(scheme) (the first build of a project is the slow one)")
            let built = currentCommit()
            try Shell.require(
                arguments + ["build", "-quiet"], in: paths.project,
                log: paths.logs.appendingPathComponent("app-build.log"), doing: "Building \(scheme)"
            )
            try? built?.write(to: builtCommitFile, atomically: true, encoding: .utf8)
        }
        let settings = try Shell.require(
            arguments + ["-showBuildSettings"], in: paths.project, doing: "Reading build settings"
        )
        return try Self.app(fromBuildSettings: settings, scheme: scheme)
    }

    /// The application in a scheme's settings, which may also list test bundles
    /// and frameworks. From the settings rather than a glob of the build folder,
    /// which can hold stale copies of other configurations.
    static func app(fromBuildSettings text: String, scheme: String) throws -> BuiltApp {
        var found: [String: String] = [:]
        func finished() -> BuiltApp? {
            guard found["WRAPPER_EXTENSION"] == "app", found["PRODUCT_TYPE"] == "com.apple.product-type.application",
                  let directory = found["TARGET_BUILD_DIR"], let name = found["WRAPPER_NAME"],
                  let bundleID = found["PRODUCT_BUNDLE_IDENTIFIER"] else { return nil }
            return BuiltApp(path: URL(fileURLWithPath: directory).appendingPathComponent(name), bundleID: bundleID)
        }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Build settings for action") {
                if let app = finished() { return app }
                found = [:]
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            found[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        if let app = finished() { return app }
        throw AtlasError("The scheme \(scheme) doesn't build an application.")
    }

    private func firstFile(ending suffix: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.project.path)) ?? []
        return names.sorted().first { $0.hasSuffix(suffix) }
    }

    private var builtCommitFile: URL { cache.appendingPathComponent("built-commit.txt") }

    /// What the app on the simulator was built from, which is what the screenshots
    /// show. Under `--no-build` that may no longer be what's checked out.
    private func commit() -> String? {
        if !options.build, let built = try? String(contentsOf: builtCommitFile, encoding: .utf8) { return built }
        return currentCommit()
    }

    private func currentCommit() -> String? {
        guard let head = try? Shell.run(["git", "-C", paths.project.path, "rev-parse", "--short", "HEAD"]),
              head.status == 0 else { return nil }
        let short = head.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try? Shell.run(["git", "-C", paths.project.path, "status", "--porcelain"])
        let dirty = status?.text.isEmpty == false
        return dirty ? "\(short)+uncommitted" : short
    }

    // MARK: - The driver

    private struct Plan: Encodable {
        struct Capture: Encodable {
            let id: String
            let file: String
            let steps: [Step]
            let expect: [String]?
            let links: [Link]
            let launchArguments: [String]?
        }

        struct Link: Encodable {
            let to: String
            let label: String
            let containing: Bool
        }

        let bundleID: String
        let launchArguments: [String]
        let launchEnvironment: [String: String]
        let screensDirectory: String
        let resultsFile: String
        let timeout: Double
        let settle: Double
        let captures: [Capture]
    }

    /// What to look for on a screen to find its links: the label on the link, or,
    /// where the source gave it none, the last tap of the route written for the
    /// screen it opens. A link it can't find just starts from the phone's edge.
    private func links(from node: AtlasGraph.Node, graph: AtlasGraph) -> [Plan.Link] {
        graph.edges.filter { $0.from == node.id }.compactMap { edge in
            if let label = edge.label {
                return Plan.Link(to: edge.to, label: label, containing: false)
            }
            let target = graph.nodes.first { $0.id == edge.to }
            guard let last = target?.steps?.last else { return nil }
            if let tap = last.tap { return Plan.Link(to: edge.to, label: tap, containing: false) }
            if let tap = last.tapContaining { return Plan.Link(to: edge.to, label: tap, containing: true) }
            return nil
        }
    }

    private func drive(
        _ nodes: [AtlasGraph.Node], graph: AtlasGraph, app: BuiltApp, simulator: Simulator
    ) throws -> [String: CaptureResult] {
        guard !nodes.isEmpty else { return [:] }
        let manager = FileManager.default
        let workFolder = paths.output.appendingPathComponent("work")
        try manager.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let planFile = workFolder.appendingPathComponent("plan.json")
        let resultsFile = workFolder.appendingPathComponent("driver-results.json")
        try? manager.removeItem(at: resultsFile)

        let plan = Plan(
            bundleID: app.bundleID,
            launchArguments: config.launchArguments ?? [],
            launchEnvironment: config.launchEnvironment ?? [:],
            screensDirectory: paths.screens.path,
            resultsFile: resultsFile.path,
            timeout: config.timeout ?? 20,
            settle: config.settle ?? 1,
            captures: nodes.map { node in
                .init(
                    id: node.id, file: "\(slug(node.id)).png", steps: node.steps ?? [], expect: node.expect,
                    links: links(from: node, graph: graph),
                    launchArguments: node.launchArguments
                )
            }
        )
        try JSONEncoder.atlas.encode(plan).write(to: planFile)

        let driver = Self.driverFolder
        if !manager.fileExists(atPath: driver.appendingPathComponent("AtlasDriver.xcodeproj").path) {
            log("generating the driver project")
            try Shell.require(["xcodegen", "generate", "--quiet"], in: driver, doing: "Generating the driver project")
        }

        log("driving    \(nodes.count) screens")
        // `TEST_RUNNER_` is how xcodebuild passes a variable to the test process.
        // No parallel testing: it would clone the simulator instead of using ours.
        let output = try Shell.run(
            [
                "xcodebuild", "test",
                "-project", "AtlasDriver.xcodeproj", "-scheme", "AtlasDriver",
                "-destination", "platform=iOS Simulator,id=\(simulator.udid)",
                "-derivedDataPath", cache.appendingPathComponent("driver").path,
                "-parallel-testing-enabled", "NO",
                "-test-timeouts-enabled", "NO",
                "-quiet",
            ],
            in: driver,
            environment: ["TEST_RUNNER_ATLAS_PLAN": planFile.path],
            log: paths.logs.appendingPathComponent("driver.log")
        )

        guard let data = try? Data(contentsOf: resultsFile) else {
            let errors = output.text.split(separator: "\n").filter { $0.contains("error:") }.suffix(15)
            throw AtlasError(
                "The driver produced no results (exit \(output.status)):\n"
                    + errors.joined(separator: "\n")
                    + "\nFull log: \(paths.logs.appendingPathComponent("driver.log").path)"
            )
        }
        let outcomes = try JSONDecoder().decode([CaptureResult].self, from: data)
        return Dictionary(outcomes.map { ($0.id, $0) }) { first, _ in first }
    }
}

// MARK: - The simulator

/// One simulator per config, created for this tool and found by its exact name.
/// Never whatever happens to be booted: other work may be running in those, and
/// this one gets its app wiped and its status bar rewritten.
struct Simulator {
    let udid: String
    let deviceType: String
    let runtime: String

    static func prepare(
        name: String, deviceType: String, appearance: String, log: (String) -> Void
    ) throws -> Simulator {
        let list = try simctlJSON(["list", "-j"])
        guard let runtimes = list["runtimes"] as? [[String: Any]],
              let types = list["devicetypes"] as? [[String: Any]],
              let devices = list["devices"] as? [String: [[String: Any]]] else {
            throw AtlasError("Couldn't read the simulator list.")
        }
        // The newest iOS, because that is what a phone runs and what shows the
        // newest system chrome.
        let available = runtimes.filter {
            ($0["isAvailable"] as? Bool) == true && ($0["platform"] as? String) == "iOS"
        }
        guard let runtime = available.max(by: { version($0) < version($1) }),
              let runtimeID = runtime["identifier"] as? String else {
            throw AtlasError("No iOS simulator runtime is installed.")
        }
        guard let typeID = types.first(where: { ($0["name"] as? String) == deviceType })?["identifier"] as? String else {
            throw AtlasError("No simulator device type is called \(deviceType).")
        }

        var udid: String?
        var state: String?
        for (owner, entries) in devices {
            for entry in entries where (entry["name"] as? String) == name {
                if owner == runtimeID {
                    udid = entry["udid"] as? String
                    state = entry["state"] as? String
                } else if let old = entry["udid"] as? String {
                    // Left on an older iOS: it is this tool's own, so replace it.
                    try? Shell.run(["xcrun", "simctl", "shutdown", old])
                    try? Shell.run(["xcrun", "simctl", "delete", old])
                }
            }
        }
        if udid == nil {
            let created = try Shell.require(
                ["xcrun", "simctl", "create", name, typeID, runtimeID], doing: "Creating the simulator"
            )
            udid = created.trimmingCharacters(in: .whitespacesAndNewlines)
            log("created    \(name)")
        }
        guard let udid else { throw AtlasError("Couldn't create a simulator.") }
        if state != "Booted" {
            try Shell.require(["xcrun", "simctl", "boot", udid], doing: "Booting the simulator")
            try Shell.require(["xcrun", "simctl", "bootstatus", udid, "-b"], doing: "Waiting for the simulator")
            log("booted     \(name)")
        }

        // Same clock and bars every run, so the only differences between two
        // charts are differences in the app.
        try Shell.require(
            [
                "xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi",
                "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
                "--batteryState", "charged", "--batteryLevel", "100",
            ],
            doing: "Setting the status bar"
        )
        try Shell.require(["xcrun", "simctl", "ui", udid, "appearance", appearance], doing: "Setting the appearance")
        return Simulator(udid: udid, deviceType: deviceType, runtime: (runtime["name"] as? String) ?? runtimeID)
    }

    /// A fresh install makes every full run start as a new user, whatever the
    /// last run tapped. A partial run keeps the data the full run saw.
    func install(_ app: Capturer.BuiltApp, fresh: Bool) throws {
        if fresh { try? Shell.run(["xcrun", "simctl", "uninstall", udid, app.bundleID]) }
        try Shell.require(["xcrun", "simctl", "install", udid, app.path.path], doing: "Installing the app")
        // So a permission prompt can't sit over a screen. Not every service can be
        // granted on every runtime, and a prompt left over is reported by `expect`.
        try? Shell.run(["xcrun", "simctl", "privacy", udid, "grant", "all", app.bundleID])
    }

    func shutdown() {
        try? Shell.run(["xcrun", "simctl", "shutdown", udid])
    }

    private static func simctlJSON(_ arguments: [String]) throws -> [String: Any] {
        let text = try Shell.require(["xcrun", "simctl"] + arguments, doing: "Listing simulators")
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw AtlasError("Couldn't read the simulator list.")
        }
        return object
    }

    private static func version(_ runtime: [String: Any]) -> [Int] {
        ((runtime["version"] as? String) ?? "0").split(separator: ".").map { Int($0) ?? 0 }
    }
}

private func < (left: [Int], right: [Int]) -> Bool {
    left.lexicographicallyPrecedes(right)
}

/// A name safe for a file or folder.
func slug(_ text: String) -> String {
    let parts = text.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) || !$0.isASCII }
    return parts.map { String(String.UnicodeScalarView($0)) }.joined(separator: "-")
}
