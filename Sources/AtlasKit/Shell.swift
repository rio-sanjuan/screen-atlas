import Foundation

enum Shell {
    struct Output {
        var status: Int32
        var text: String
    }

    /// Runs a command to the end and returns what it printed.
    ///
    /// Output goes through a file rather than a pipe: xcodebuild can print more
    /// than a pipe's buffer holds, and a process blocked writing to a full pipe
    /// never exits, so waiting for it would hang.
    @discardableResult
    static func run(
        _ arguments: [String], in directory: URL? = nil, environment: [String: String] = [:], log: URL? = nil
    ) throws -> Output {
        let manager = FileManager.default
        let file = log ?? manager.temporaryDirectory.appendingPathComponent("screenatlas-\(UUID().uuidString).log")
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        manager.createFile(atPath: file.path, contents: nil)
        defer { if log == nil { try? manager.removeItem(at: file) } }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        try process.run()
        process.waitUntilExit()

        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return Output(status: process.terminationStatus, text: text)
    }

    /// As `run`, and a non-zero exit is an error carrying the end of the output.
    @discardableResult
    static func require(
        _ arguments: [String], in directory: URL? = nil, environment: [String: String] = [:], log: URL? = nil,
        doing action: String
    ) throws -> String {
        let output = try run(arguments, in: directory, environment: environment, log: log)
        guard output.status == 0 else {
            let errors = output.text.split(separator: "\n").filter { $0.contains("error:") }
            let detail = errors.isEmpty ? output.text.split(separator: "\n").suffix(15) : errors.suffix(15)
            let where_ = log.map { "\nFull log: \($0.path)" } ?? ""
            throw AtlasError("\(action) failed:\n\(detail.joined(separator: "\n"))\(where_)")
        }
        return output.text
    }
}
