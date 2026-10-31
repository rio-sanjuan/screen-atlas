import Charts
import SwiftUI

struct TrailsTab: View {
    var body: some View {
        NavigationStack {
            TrailsHome()
                .trailsDestinations()
        }
    }
}

/// Value routes, listed in one table. The scan reads this `switch` to learn what each opens.
enum TrailsDestination: Hashable {
    case nearbyMap
    case gearList
}

extension View {
    func trailsDestinations() -> some View {
        navigationDestination(for: TrailsDestination.self) { destination in
            switch destination {
            case .nearbyMap: NearbyMapView()
            case .gearList: GearListView()
            }
        }
        .navigationDestination(for: Trail.self) { TrailDetailView(trail: $0) }
    }
}

struct TrailsHome: View {
    @State private var showingFilters = false

    var body: some View {
        List {
            Section("Near You") {
                ForEach(Sample.trails) { TrailRow(trail: $0) }
            }
            Section("Plan") {
                NavigationLink(value: TrailsDestination.gearList) {
                    Label("Gear List", systemImage: "backpack")
                }
            }
        }
        .navigationTitle("Trails")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // An icon has no words, so its accessibility label is what names the link.
                NavigationLink(value: TrailsDestination.nearbyMap) {
                    Image(systemName: "location.north.line")
                }
                .accessibilityLabel("Nearby Map")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Filters", systemImage: "line.3.horizontal.decrease") { showingFilters = true }
            }
        }
        .sheet(isPresented: $showingFilters) { FiltersSheet() }
    }
}

/// A component holding a link: the map credits it to whichever screen shows this row.
struct TrailRow: View {
    let trail: Trail

    var body: some View {
        NavigationLink(value: trail) {
            HStack(spacing: 12) {
                Image(systemName: trail.symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.green.gradient, in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(trail.name).font(.headline)
                    Text("\(trail.region) · \(trail.miles, specifier: "%.1f") mi · \(trail.difficulty)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct TrailDetailView: View {
    let trail: Trail
    @State private var hike: Trail?

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: trail.symbol)
                        .font(.system(size: 54))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 150)
                        .background(.green.gradient, in: .rect(cornerRadius: 14))
                    Text(trail.region).font(.subheadline).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("Distance", value: "\(String(format: "%.1f", trail.miles)) mi")
                LabeledContent("Climb", value: "\(trail.climbFeet) ft")
                LabeledContent("Difficulty", value: trail.difficulty)
            }
            Section {
                NavigationLink("Elevation Profile") { ElevationProfileView(trail: trail) }
                NavigationLink("Reviews") { ReviewsView() }
            }
            Section {
                Button("Start Hike") { start() }
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
        }
        .navigationTitle(trail.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $hike) { ActiveHikeView(trail: $0) }
    }

    private func start() {
        hike = trail
    }
}

struct ElevationProfileView: View {
    let trail: Trail

    var body: some View {
        List {
            Section("Feet Above Sea Level") {
                Chart(Array(trail.elevation.enumerated()), id: \.offset) { index, feet in
                    AreaMark(x: .value("Mile", index), yStart: .value("Base", 3000), yEnd: .value("Feet", feet))
                        .foregroundStyle(.green.opacity(0.25))
                    LineMark(x: .value("Mile", index), y: .value("Feet", feet))
                        .foregroundStyle(.green)
                }
                .chartXScale(domain: 0...(trail.elevation.count - 1))
                .frame(height: 220)
                .padding(.vertical, 8)
            }
            Section {
                LabeledContent("Highest", value: "\(trail.elevation.max() ?? 0) ft")
                LabeledContent("Lowest", value: "\(trail.elevation.min() ?? 0) ft")
                LabeledContent("Total climb", value: "\(trail.climbFeet) ft")
            }
        }
        .navigationTitle("Elevation Profile")
    }
}

struct ReviewsView: View {
    var body: some View {
        List(Sample.reviews) { review in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(review.author).font(.headline)
                    Spacer()
                    Text(String(repeating: "★", count: review.stars)).foregroundStyle(.orange)
                }
                Text(review.text).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("Reviews")
    }
}

struct ActiveHikeView: View {
    let trail: Trail
    @Environment(\.dismiss) private var dismiss
    @State private var addingNote = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Text("1:24:08").font(.system(size: 64, weight: .semibold, design: .rounded)).monospacedDigit()
                HStack(spacing: 32) {
                    stat("3.2", "miles")
                    stat("940", "ft climbed")
                    stat("2.3", "mph")
                }
                Spacer()
                Button("Add Note", systemImage: "note.text.badge.plus") { addingNote = true }
                    .buttonStyle(.bordered)
                Button("End Hike") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
            .navigationTitle(trail.name)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $addingNote) { AddNoteSheet() }
        }
    }

    private func stat(_ value: String, _ name: String) -> some View {
        VStack {
            Text(value).font(.title.weight(.semibold)).monospacedDigit()
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AddNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var note = "Trail junction at mile three is unmarked."

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") { TextField("What did you see?", text: $note, axis: .vertical) }
                Section { LabeledContent("Location", value: "Mile 3.2") }
            }
            .navigationTitle("Add Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct NearbyMapView: View {
    var body: some View {
        ZStack {
            Color.green.opacity(0.12).ignoresSafeArea()
            Canvas { context, size in
                // Contour lines, so the page reads as a map without needing MapKit.
                for ring in 1...7 {
                    let inset = CGFloat(ring) * 24
                    let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset * 1.5)
                    context.stroke(Path(ellipseIn: rect), with: .color(.green.opacity(0.35)), lineWidth: 1)
                }
            }
            .ignoresSafeArea()
            ForEach(Array(Sample.trails.enumerated()), id: \.element.id) { index, trail in
                Label(trail.name, systemImage: "mappin.circle.fill")
                    .font(.caption.weight(.medium))
                    .padding(8)
                    .background(.background, in: .capsule)
                    .offset(x: index.isMultiple(of: 2) ? -70 : 70, y: CGFloat(index) * 130 - 200)
            }
        }
        .navigationTitle("Nearby Map")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GearListView: View {
    @State private var packed: Set<String> = ["Water, 2 liters", "Headlamp"]

    var body: some View {
        List(Sample.gear, id: \.self) { item in
            Button {
                if packed.contains(item) { packed.remove(item) } else { packed.insert(item) }
            } label: {
                Label {
                    Text(item).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: packed.contains(item) ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        .navigationTitle("Gear List")
    }
}

struct FiltersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var difficulty = "Any"
    @State private var longest = 12.0
    @State private var dogs = true

    var body: some View {
        NavigationStack {
            Form {
                Picker("Difficulty", selection: $difficulty) {
                    ForEach(["Any", "Easy", "Moderate", "Hard"], id: \.self) { Text($0) }
                }
                Section("Longest Hike: \(Int(longest)) mi") { Slider(value: $longest, in: 1...20) }
                Toggle("Dogs Allowed", isOn: $dogs)
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

#Preview("Previews stay off the map") {
    NavigationStack { TrailsHome().trailsDestinations() }
}
