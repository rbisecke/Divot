// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import SwiftData
import SwingCore

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedSession.date, order: .reverse) private var sessions: [SavedSession]

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { saved in
                    NavigationLink {
                        ResultsView(saved: saved)
                    } label: {
                        row(saved)
                    }
                }
                .onDelete(perform: delete)
            }
            .listRowBackground(Color.surface)
            .divotScreenBackground()
            .overlay {
                if sessions.isEmpty {
                    let e = EmptyStateContent.forTab(.history)
                    ContentUnavailableView(e.title, systemImage: e.symbol, description: Text(e.message))
                }
            }
            .navigationTitle("History")
            .toolbar { EditButton() }
        }
    }

    private func row(_ saved: SavedSession) -> some View {
        let s = saved.session
        let best = s?.swings.first { $0.index == (s?.stats?.bestSwing ?? 1) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                PlaneSpark()
                Text(saved.club.displayName).bold()
                Text("· \(saved.angle.label)").foregroundStyle(.secondary)
                Spacer()
                if let m = best?.comparison?.overall {
                    Text("\(Int(m * 100))%").font(.metric(15)).foregroundStyle(Color.dataYou)
                }
            }
            Text(saved.date, format: .dateTime.month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            if let n = s?.swings.count { Text("\(n) swing\(n == 1 ? "" : "s")").font(.caption2).foregroundStyle(Color.textMuted) }
        }
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets {
            let saved = sessions[i]
            try? FileManager.default.removeItem(at: saved.videoURL)
            // Companion cleanup for finding #13's pose cache: don't leak a cached PoseSequence
            // for a session whose video no longer exists.
            try? FileManager.default.removeItem(at: saved.poseCacheURL)
            context.delete(saved)
        }
        try? context.save()
    }
}
