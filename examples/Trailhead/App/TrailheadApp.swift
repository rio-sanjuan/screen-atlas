import SwiftUI

@main
struct TrailheadApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Trails", systemImage: "map") { TrailsTab() }
                Tab("Journal", systemImage: "book.closed") { JournalTab() }
                Tab("Profile", systemImage: "person.crop.circle") { ProfileTab() }
            }
            .tint(.green)
        }
    }
}
