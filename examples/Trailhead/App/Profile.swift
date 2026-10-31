import SwiftUI

struct ProfileTab: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Hikes", value: "42")
                    LabeledContent("Miles", value: "287")
                    LabeledContent("Feet Climbed", value: "61,400")
                }
                Section("Settings") {
                    NavigationLink("Units") { UnitsView() }
                    NavigationLink("Notifications") { NotificationsView() }
                }
                Section {
                    NavigationLink("About Trailhead") { AboutView() }
                }
            }
            .navigationTitle("Profile")
        }
    }
}

struct UnitsView: View {
    @State private var units = "Miles and Feet"

    var body: some View {
        Form {
            Picker("Units", selection: $units) {
                ForEach(["Miles and Feet", "Kilometers and Meters"], id: \.self) { Text($0) }
            }
            .pickerStyle(.inline)
        }
        .navigationTitle("Units")
    }
}

struct NotificationsView: View {
    @State private var conditions = true
    @State private var friends = false
    @State private var weekly = true

    var body: some View {
        Form {
            Toggle("Trail Conditions", isOn: $conditions)
            Toggle("Friends' Hikes", isOn: $friends)
            Toggle("Weekly Summary", isOn: $weekly)
        }
        .navigationTitle("Notifications")
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "mountain.2.fill").font(.system(size: 60)).foregroundStyle(.green)
            Text("Trailhead").font(.title.bold())
            Text("A made-up hiking app, for showing what ScreenAtlas draws.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
