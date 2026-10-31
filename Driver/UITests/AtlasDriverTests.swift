import XCTest

// Decoded from the same JSON the tool writes. A separate copy of the shape,
// because this bundle is built by Xcode for a simulator and cannot import the
// tool's macOS package.
struct Plan: Decodable {
    struct Capture: Decodable {
        let id: String
        let file: String
        let steps: [Step]
        let expect: [String]?
        let links: [Link]
        let launchArguments: [String]?
    }

    /// An element on this screen that leads to another, to be found once it settles.
    struct Link: Decodable {
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

struct Step: Decodable {
    let tab: String?
    let tap: String?
    let tapContaining: String?
    let longPress: String?
    let longPressContaining: String?
    let swipe: String?
    let back: Bool?
    let type: String?
    let wait: Double?
    let waitFor: String?
}

struct Frame: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct Outcome: Encodable {
    var links: [String: Frame]?
    var id: String
    var status: String
    var note: String?
    var file: String?
    var visibleLabels: [String]?
    var seconds: Double?
}

struct StepFailure: Error {
    let message: String
}

final class AtlasDriverTests: XCTestCase {
    func testCaptureEveryScreen() throws {
        guard let path = ProcessInfo.processInfo.environment["ATLAS_PLAN"] else {
            XCTFail("ATLAS_PLAN is not set; run this through `screenatlas capture`.")
            return
        }
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var outcomes: [Outcome] = []
        for capture in plan.captures {
            outcomes.append(run(capture, plan: plan))
            // After every screen, so a driver that dies still leaves what it got.
            let data = try JSONEncoder().encode(outcomes)
            try data.write(to: URL(fileURLWithPath: plan.resultsFile))
        }
    }

    private func run(_ capture: Plan.Capture, plan: Plan) -> Outcome {
        let started = Date()
        let app = XCUIApplication(bundleIdentifier: plan.bundleID)
        app.launchArguments = capture.launchArguments ?? plan.launchArguments
        app.launchEnvironment = plan.launchEnvironment
        // A fresh launch per screen, so one screen's dialog or half-finished
        // state cannot decide what the next screen's screenshot shows.
        app.terminate()
        app.launch()
        defer { app.terminate() }

        var outcome = Outcome(id: capture.id, status: "ok")
        do {
            for step in capture.steps {
                try perform(step, in: app, timeout: plan.timeout)
                dismissSystemAlerts()
            }
            Thread.sleep(forTimeInterval: plan.settle)
            // A prompt can arrive a moment after its screen. If it's left up it ends
            // up in the picture, looking like part of the screen.
            if dismissSystemAlerts() { Thread.sleep(forTimeInterval: plan.settle) }
            for label in capture.expect ?? [] where !isShown(label, in: app, timeout: plan.timeout) {
                throw StepFailure(message: "Expected \"\(label)\" on screen, and it isn't there.")
            }
        } catch {
            outcome.status = "failed"
            outcome.note = (error as? StepFailure)?.message ?? "\(error)"
        }

        if app.state == .notRunning {
            outcome.status = "crashed"
            outcome.note = "The app stopped running on the way to this screen."
        }

        // A failed capture keeps its screenshot too: where it got stuck is the
        // fastest way to see what the steps need to be.
        let name = outcome.status == "ok" ? capture.file : "failed-\(capture.file)"
        let url = URL(fileURLWithPath: plan.screensDirectory).appendingPathComponent(name)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        outcome.file = name
        if outcome.status == "ok" { outcome.links = linkFrames(capture.links, in: app) }
        outcome.visibleLabels = visibleLabels(in: app)
        outcome.seconds = Date().timeIntervalSince(started)
        return outcome
    }

    // MARK: - Links

    /// Where each link sits on the screen just photographed, as fractions of it, so
    /// an arrow can start on the element itself. Only what's in the picture counts:
    /// a row further down the list has nothing on the screenshot to point at.
    private func linkFrames(_ links: [Plan.Link], in app: XCUIApplication) -> [String: Frame] {
        let bounds = app.frame
        guard bounds.width > 0, bounds.height > 0 else { return [:] }
        var frames: [String: Frame] = [:]
        for link in links where frames[link.to] == nil {
            let predicate = link.containing
                ? NSPredicate(format: "label CONTAINS %@", link.label)
                : NSPredicate(format: "label == %@ OR identifier == %@", link.label, link.label)
            let query = app.descendants(matching: .any).matching(predicate)
            var best: CGRect?
            for index in 0..<min(query.count, 8) {
                let element = query.element(boundBy: index)
                guard element.exists else { continue }
                let frame = element.frame
                guard !frame.isEmpty, bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
                // The smallest match: a label can also be carried by the container
                // around it, and the words are the thing to point at.
                if best == nil || frame.width * frame.height < best!.width * best!.height { best = frame }
            }
            if let best {
                frames[link.to] = Frame(
                    x: best.minX / bounds.width, y: best.minY / bounds.height,
                    width: best.width / bounds.width, height: best.height / bounds.height
                )
            }
        }
        return frames
    }

    // MARK: - Steps

    private func perform(_ step: Step, in app: XCUIApplication, timeout: Double) throws {
        if let tab = step.tab {
            try tapTab(tab, in: app, timeout: timeout)
        } else if let label = step.tap {
            try tap(label, containing: false, in: app, timeout: timeout)
        } else if let label = step.tapContaining {
            try tap(label, containing: true, in: app, timeout: timeout)
        } else if let label = step.longPress {
            try tap(label, containing: false, in: app, timeout: timeout, hold: 1.2)
        } else if let label = step.longPressContaining {
            try tap(label, containing: true, in: app, timeout: timeout, hold: 1.2)
        } else if let direction = step.swipe {
            switch direction {
            case "up": scroll(app, from: 0.7, to: 0.3)
            case "down": scroll(app, from: 0.3, to: 0.7)
            case "left": app.swipeLeft()
            case "right": app.swipeRight()
            default: throw StepFailure(message: "Unknown swipe direction \"\(direction)\".")
            }
        } else if step.back != nil {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.waitForExistence(timeout: timeout) else {
                throw StepFailure(message: "There is no back button on this screen.")
            }
            back.tap()
        } else if let text = step.type {
            app.typeText(text)
        } else if let seconds = step.wait {
            Thread.sleep(forTimeInterval: seconds)
        } else if let label = step.waitFor, !isShown(label, in: app, timeout: timeout) {
            throw StepFailure(message: "\"\(label)\" never appeared.")
        }
    }

    private func tapTab(_ label: String, in app: XCUIApplication, timeout: Double) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let button = app.tabBars.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                return
            }
            // A sidebar-adaptable tab view isn't always a tab bar to the accessibility tree.
            if let element = hittable(label, containing: false, in: app) {
                element.tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw StepFailure(message: "Couldn't find the \"\(label)\" tab.")
    }

    private func tap(
        _ label: String, containing: Bool, in app: XCUIApplication, timeout: Double, hold: TimeInterval? = nil
    ) throws {
        let started = Date()
        var swipes = 0
        var lastSwipe = started
        while Date().timeIntervalSince(started) < timeout {
            if let element = hittable(label, containing: containing, in: app) {
                if let hold { element.press(forDuration: hold) } else { element.tap() }
                return
            }
            // Give the screen time to load before deciding the row must be further
            // down, then scroll for it: lazy lists don't build what's off screen.
            let waited = Date().timeIntervalSince(started)
            if waited > 3, Date().timeIntervalSince(lastSwipe) > 1.2, swipes < 12 {
                scroll(app, from: 0.7, to: 0.3)
                swipes += 1
                lastSwipe = Date()
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw StepFailure(message: "Couldn't find \"\(label)\" to tap, after \(swipes) swipes.")
    }

    /// Scrolls by dragging down the screen's right margin. Not through the middle:
    /// a drag there lands on whatever is under it, and a chart or slider takes it
    /// as input, changing the app's state and never scrolling. The short hold at
    /// the end stops momentum, so a row can't fly past between two looks.
    private func scroll(_ app: XCUIApplication, from: CGFloat, to: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.975, dy: from))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.975, dy: to))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.1)
    }

    /// The frontmost element with this label. Last first, because a presented sheet
    /// comes after the screen under it, and that screen's controls can still be hit
    /// around a sheet that doesn't cover them: the first match taps the wrong one, and
    /// the capture would look like a success. Anything over the tab bar is skipped,
    /// since opening a tab is a `tab` step and a row named the same is what's meant here.
    private func hittable(_ label: String, containing: Bool, in app: XCUIApplication) -> XCUIElement? {
        let predicate = containing
            ? NSPredicate(format: "label CONTAINS %@", label)
            : NSPredicate(format: "label == %@ OR identifier == %@", label, label)
        let query = app.descendants(matching: .any).matching(predicate)
        let bar = app.tabBars.firstMatch
        let barFrame = bar.exists ? bar.frame : CGRect.null
        for index in stride(from: min(query.count, 24) - 1, through: 0, by: -1) {
            let element = query.element(boundBy: index)
            guard element.exists, element.isHittable else { continue }
            let frame = element.frame
            if barFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) { continue }
            return element
        }
        return nil
    }

    /// Answers a system prompt, such as a permission request. It belongs to SpringBoard,
    /// so it isn't in the app's own tree and no step could tap it. Allowing is right here:
    /// the simulator is this tool's own, and a denied permission often hides the screen.
    @discardableResult
    private func dismissSystemAlerts() -> Bool {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.exists else { return false }
        for title in ["Allow", "Allow While Using App", "Allow Once", "OK", "Continue"] {
            let button = alert.buttons[title]
            if button.exists {
                button.tap()
                return true
            }
        }
        let count = alert.buttons.count
        guard count > 0 else { return false }
        alert.buttons.element(boundBy: count - 1).tap()
        return true
    }

    private func isShown(_ label: String, in app: XCUIApplication, timeout: Double) -> Bool {
        let predicate = NSPredicate(format: "label == %@ OR identifier == %@", label, label)
        return app.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }

    /// What the accessibility tree says is on screen, so a failed step can be
    /// fixed from its report without opening a simulator.
    private func visibleLabels(in app: XCUIApplication) -> [String] {
        guard app.state != .notRunning, let root = try? app.snapshot() else { return [] }
        var labels: [String] = []
        var seen = Set<String>()
        func walk(_ element: XCUIElementSnapshot) {
            if labels.count >= 80 { return }
            if !element.label.isEmpty, seen.insert(element.label).inserted { labels.append(element.label) }
            element.children.forEach(walk)
        }
        walk(root)
        return labels
    }
}
