// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            ImportView()
                .tabItem { Label("Analyze", systemImage: "figure.golf") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
            CompareView()
                .tabItem { Label("Compare", systemImage: "rectangle.split.2x1") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.brand)
        .preferredColorScheme(.dark)   // Divot is dark-first
        .task {
            SampleData.seedIfRequested(modelContext)
            do {
                try BagStore.seedDefaultBagIfEmpty(modelContext)
                try BagStore.migrateLegacySessions(modelContext)
            } catch {
                // A transient SwiftData failure here means seeding/migration just doesn't happen
                // for this launch (finding #17) rather than risking duplicate rows by assuming
                // "empty" — the next launch retries.
                print("BagStore seed/migrate failed: \(error)")
            }
        }
    }
}
