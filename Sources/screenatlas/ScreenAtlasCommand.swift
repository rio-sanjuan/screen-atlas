import ArgumentParser
import AtlasKit
import Foundation

@main
struct ScreenAtlasCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenatlas",
        abstract: "Map a SwiftUI app's screens: a chart and an interactive map, with screenshots.",
        subcommands: [Run.self, Scan.self, Capture.self, Render.self]
    )
}

struct ConfigOption: ParsableArguments {
    @Argument(help: "The project's atlas.json.")
    var config: String

    func load() throws -> (config: Config, paths: Paths) {
        let url = URL(fileURLWithPath: config)
        let loaded = try Config.load(from: url)
        return (loaded, Paths(configURL: url, config: loaded))
    }
}

struct CaptureOptions: ParsableArguments {
    @Flag(help: "Reuse the app already built by the last run.")
    var noBuild = false

    @Flag(help: "Leave the simulator running afterwards.")
    var keepBooted = false

    @Option(help: "Capture only these screens (comma separated), keeping the rest from the last run.")
    var only: String?

    var options: Capturer.Options {
        var options = Capturer.Options()
        options.build = !noBuild
        options.keepBooted = keepBooted
        options.only = only?.split(separator: ",").map(String.init) ?? []
        return options
    }
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read the source and print the screens it found.")

    @OptionGroup var options: ConfigOption

    func run() throws {
        let (config, paths) = try options.load()
        let graph = try Pipeline.scan(config: config, paths: paths)
        print(Pipeline.describe(graph))
    }
}

struct Capture: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan, then take a screenshot of each screen.")

    @OptionGroup var options: ConfigOption
    @OptionGroup var capture: CaptureOptions

    func run() throws {
        let (config, paths) = try options.load()
        let graph = try Pipeline.scan(config: config, paths: paths)
        let run = try Capturer(config: config, paths: paths, options: capture.options) { print($0) }.run(graph: graph)
        print(Pipeline.describe(run, graph: graph))
    }
}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan again and redraw the chart and map from the last capture."
    )

    @OptionGroup var options: ConfigOption

    func run() throws {
        let (config, paths) = try options.load()
        let graph = try Pipeline.scan(config: config, paths: paths)
        try Pipeline.render(graph: graph, paths: paths)
        print(paths.outputs)
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan, capture and draw: the whole thing.")

    @OptionGroup var options: ConfigOption
    @OptionGroup var capture: CaptureOptions

    func run() throws {
        let (config, paths) = try options.load()
        let graph = try Pipeline.scan(config: config, paths: paths)
        let run = try Capturer(config: config, paths: paths, options: capture.options) { print($0) }.run(graph: graph)
        print(Pipeline.describe(run, graph: graph))
        try Pipeline.render(graph: graph, paths: paths)
        print(paths.outputs)
    }
}
