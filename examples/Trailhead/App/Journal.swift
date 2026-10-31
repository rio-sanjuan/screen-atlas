import SwiftUI

struct JournalTab: View {
    @State private var writing = false

    var body: some View {
        NavigationStack {
            List(Sample.entries) { JournalRow(entry: $0) }
                .navigationTitle("Journal")
                .navigationDestination(for: JournalEntry.self) { EntryDetailView(entry: $0) }
                .toolbar {
                    Button("New Entry", systemImage: "square.and.pencil") { writing = true }
                }
                .sheet(isPresented: $writing) { NewEntrySheet() }
        }
    }
}

struct JournalRow: View {
    let entry: JournalEntry

    var body: some View {
        NavigationLink(value: entry) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.headline)
                Text("\(entry.date) · \(entry.trail)").font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct EntryDetailView: View {
    let entry: JournalEntry

    var body: some View {
        List {
            Section {
                LabeledContent("Date", value: entry.date)
                LabeledContent("Trail", value: entry.trail)
            }
            Section("Notes") { Text(entry.text) }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NewEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                Section("Notes") { TextField("How was it?", text: $text, axis: .vertical).lineLimit(5...) }
            }
            .navigationTitle("New Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Save") { dismiss() } }
        }
    }
}
