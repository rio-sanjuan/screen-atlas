import SwiftUI

/// A UI test bundle must name an app to test, even one that drives another. This
/// is that app, and it does nothing.
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup { Text("ScreenAtlas driver") }
    }
}
