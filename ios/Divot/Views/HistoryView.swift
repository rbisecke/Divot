// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import SwiftData
import SwingCore

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedSession.date, order: .reverse) private var sessions: [SavedSession]
    @State private var hideFlaggedSessions = false

    private var visibleSessions: [SavedSession] {
        hideFlaggedSessions ? sessions.filter { !isFlagged($0) } : sessions
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleSessions) { saved in
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
                if visibleSessions.isEmpty {
                    let e = EmptyStateContent.forTab(.history)
                    ContentUnavailableView(e.title, systemImage: e.symbol, description: Text(e.message))
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // P3.5 — metadata only: never hard-filters analysis, just this list.
                        Toggle("Hide no-contact swings", isOn: $hideFlaggedSessions)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
    }

    // P3.5 — a session is flagged if any of its swings' best-effort contact signal came back
    // false. Soft-label only: doesn't affect analysis or the underlying data, just this list.
    private func isFlagged(_ saved: SavedSession) -> Bool {
        saved.session?.swings.contains { $0.contact?.likelyContact == false } ?? false
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
            if isFlagged(saved) { Text("No contact detected").font(.caption2).foregroundStyle(Color.textMuted) }
        }
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets {
            let saved = sessions[i]
            try? FileManager.default.removeItem(at: saved.videoURL)
            context.delete(saved)
        }
        try? context.save()
    }
}
