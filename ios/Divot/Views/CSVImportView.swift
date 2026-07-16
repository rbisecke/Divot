// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import SwingCore

/// P3.1 — import an MLM2PRO shot-export CSV and attach shots to this session's swings.
/// Each row's "Club Type" is resolved to a bag club; ambiguous/unknown codes are confirmed
/// once and remembered. Everything stays on device; nothing is uploaded.
struct CSVImportView: View {
    let session: Session
    var onImport: ([ShotData]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var bagClubs: [BagClub]

    @State private var showImporter = false
    @State private var rows: [ShotRow] = []
    @State private var matched: [ShotData] = []
    @State private var error: String?
    @State private var pending: PendingCode?

    private struct PendingCode: Identifiable { let id = UUID(); let code: String }
    private var activeBag: [ClubSpec] { Bag.sorted(bagClubs.filter { !$0.retired }.map(\.spec)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Choose MLM2PRO CSV", systemImage: "doc.badge.plus")
                    }
                    Text("Export shots from the Rapsodo app, then pick the CSV here. Shots map to your swings in order.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                if !matched.isEmpty {
                    Section("Matched \(matched.count) shot(s) to \(session.swings.count) swing(s)") {
                        ForEach(Array(matched.enumerated()), id: \.offset) { i, shot in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Swing \(shot.swingIndex ?? i + 1)").font(.subheadline).bold()
                                Text(shot.displayRows.map { "\($0.0) \($0.1)" }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        Button("Attach \(matched.count) shot(s)") {
                            onImport(matched)
                            dismiss()
                        }
                        .disabled(matched.isEmpty)
                    }
                }
            }
            .navigationTitle("Import launch data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                handle(result)
            }
            .sheet(item: $pending) { p in
                ConfirmClubSheet(code: p.code, bag: activeBag) { club in
                    do { try OverrideStore.set(code: p.code, clubID: club.id, in: context) }
                    catch { self.error = "Couldn't save: \(error.localizedDescription)" }
                    pending = nil
                    resolveAndProceed()
                }
            }
        }
    }

    private func handle(_ result: Result<URL, Error>) {
        error = nil
        switch result {
        case .failure(let e): error = e.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                error = "Couldn't read the CSV file."; return
            }
            rows = MLM2ProCSV.parse(text)
            resolveAndProceed()
        }
    }

    /// Resolve club codes against the bag + learned overrides. Any ambiguous/unknown code is
    /// confirmed one at a time (persisting the choice); once all resolve, attach the shots.
    private func resolveAndProceed() {
        let overrides = OverrideStore.all(context)
        let res = ClubCodeResolver.resolve(rows: rows, bag: activeBag, overrides: overrides)
        if let next = ClubCodeResolver.needsConfirm(res).first {
            pending = PendingCode(code: next)
            return
        }
        let m = ShotImporter.match(rows: rows, to: session, bag: activeBag, overrides: overrides)
        if m.isEmpty {
            error = rows.isEmpty ? "No shots found in that CSV." : "No swings to match against."
        }
        matched = m
    }
}

/// One-time "Which club is <code>?" picker for an ambiguous/unknown MLM2PRO code.
private struct ConfirmClubSheet: View {
    let code: String
    let bag: [ClubSpec]
    var onPick: (ClubSpec) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(bag) { club in
                Button { onPick(club); dismiss() } label: {
                    HStack {
                        Text(club.displayName)
                        Spacer()
                        Text(club.category.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Which club is \(code)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
