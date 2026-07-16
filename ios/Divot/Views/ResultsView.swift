// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import SwiftData
import SwingCore

struct ResultsView: View {
    let saved: SavedSession
    @Environment(\.modelContext) private var context
    @State private var selectedIndex: Int?
    @State private var stills: [FrameExtractor.Still] = []
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var shot: ShotData?
    @State private var showShotForm = false
    @State private var showCsvImport = false
    private let haptics = HapticsPlayer()

    private var session: Session? { saved.session }

    var body: some View {
        ScrollView {
            if let session, !session.swings.isEmpty {
                let swing = pickedSwing(session)
                VStack(alignment: .leading, spacing: 20) {
                    focusCard(session)
                    if session.swings.count > 1 { swingPicker(session) }
                    tempoCard(swing)
                    sequenceStrip()
                    NavigationLink {
                        SwingPlayerView(url: saved.videoURL, events: swing.events)
                    } label: {
                        Label("Play / slow-mo", systemImage: "play.rectangle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    matchCard(swing)
                    if let plane = swing.plane { overTheTopCard(plane) }
                    NavigationLink {
                        DTLPlaneView(saved: saved, swing: swing)
                    } label: {
                        Label("Plane & path (over-the-top)", systemImage: "scope").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    faultsSection(swing)
                    metricsSection(swing, session: session)
                    shotSection()
                    NavigationLink {
                        MotionView(saved: saved, swing: swing)
                    } label: {
                        Label("Motion: sequence & head travel", systemImage: "waveform.path.ecg")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    NavigationLink {
                        GhostCompareView(saved: saved, swing: swing)
                    } label: {
                        Label("Compare to the pro (ghost overlay)", systemImage: "figure.golf")
                    }
                    .buttonStyle(DivotPrimaryButtonStyle())
                }
                .padding()
            } else {
                ContentUnavailableView("No swing detected", systemImage: "questionmark.video",
                                       description: Text("Try a clip with your whole body in frame and good light."))
                    .padding(.top, 60)
            }
        }
        .background(Color.bg)
        .navigationTitle(saved.club.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectedIndex) { await loadStills() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { shareReport() } label: { Label("Share report", systemImage: "doc.text") }
                    Button { Task { await shareGif() } } label: { Label("Share sequence GIF", systemImage: "photo.stack") }
                } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .sheet(isPresented: $showShare) {
            if !shareItems.isEmpty { ActivityView(items: shareItems) }
        }
        .sheet(isPresented: $showShotForm, onDismiss: loadShot) {
            ShotDataForm(sessionID: saved.id)
        }
        .sheet(isPresented: $showCsvImport, onDismiss: loadShot) {
            if let session { CSVImportView(session: session, onImport: attachShots) }
        }
        .task { loadShot() }
    }

    private func loadShot() {
        let id = saved.id
        let desc = FetchDescriptor<ShotData>(predicate: #Predicate { $0.sessionID == id })
        shot = try? context.fetch(desc).first
    }

    private func attachShots(_ shots: [ShotData]) {
        // Replace any existing shots for this session, then insert the imported set.
        let id = saved.id
        let existing = (try? context.fetch(FetchDescriptor<ShotData>(predicate: #Predicate { $0.sessionID == id }))) ?? []
        existing.forEach { context.delete($0) }
        shots.forEach { context.insert($0) }
        try? context.save()
        loadShot()
    }

    @ViewBuilder private func shotSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Launch monitor").font(.headline)
                Spacer()
                Button("Import CSV") { showCsvImport = true }.font(.subheadline)
                Button(shot == nil ? "Add" : "Edit") { showShotForm = true }.font(.subheadline)
            }
            if let shot, !shot.displayRows.isEmpty {
                ForEach(shot.displayRows, id: \.0) { row in
                    HStack { Text(row.0).font(.subheadline); Spacer(); Text(row.1).monospacedDigit() }
                }
            } else {
                Text("Optional — attach your MLM2PRO numbers to this swing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func loadStills() async {
        guard let session, !session.swings.isEmpty else { return }
        stills = await FrameExtractor.stills(videoURL: saved.videoURL, events: pickedSwing(session).events)
    }

    private func shareReport() {
        guard let session, let url = ExportService.reportFile(session) else { return }
        shareItems = [url]; showShare = true
    }

    private func shareGif() async {
        guard let session else { return }
        if let url = await ExportService.sequenceGif(videoURL: saved.videoURL, events: pickedSwing(session).events) {
            shareItems = [url]; showShare = true
        }
    }

    private func tempoCard(_ swing: SwingAnalysis) -> some View {
        let back = max(0, swing.events.top.t - swing.events.address.t)
        let down = max(0, swing.events.impact.t - swing.events.top.t)
        let total = max(back + down, 0.0001)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tempo").font(.headline); Spacer()
                Text(TempoFormat.ratioText(swing.metrics.tempoRatio)).font(.title3).bold()
                Button { haptics.play(offsets: TempoHaptics.beats(for: swing)) } label: {
                    Image(systemName: "hand.tap").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .help("Feel the tempo")
                // .help() alone doesn't reliably surface as the VoiceOver label — the raw SF
                // Symbol name ("hand.tap") isn't human-readable, and the icon-only tap target was
                // also under the 44pt minimum (both surfaced once the a11y audit's navigation
                // reached this screen for finding #14).
                .accessibilityLabel("Feel the tempo")
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(Color.accentColor).frame(width: geo.size.width * back / total)
                    Rectangle().fill(Color.orange).frame(width: geo.size.width * down / total)
                }
            }
            .frame(height: 10).clipShape(Capsule())
            HStack {
                Text("backswing").font(.caption2).foregroundStyle(.secondary); Spacer()
                Text("downswing").font(.caption2).foregroundStyle(.secondary)
            }
            Text("aim ~3 : 1").font(.caption).foregroundStyle(.secondary)
        }
        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sequenceStrip() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Swing sequence").font(.headline)
            if stills.isEmpty {
                ProgressView().frame(maxWidth: .infinity).frame(height: 120)
            } else {
                HStack(spacing: 6) {
                    ForEach(stills) { still in
                        VStack(spacing: 3) {
                            Image(uiImage: still.image).resizable().aspectRatio(contentMode: .fit)
                                .frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(still.phase.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                        }
                        // The still image had no accessibility label at all (VoiceOver announced
                        // a bare "Image"). Combining with the phase caption below it gives the
                        // photo a real label ("Address", "Top", etc.) instead of adding a
                        // redundant one by hand.
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func pickedSwing(_ session: Session) -> SwingAnalysis {
        let idx = selectedIndex ?? session.stats?.bestSwing ?? session.swings[0].index
        return session.swings.first { $0.index == idx } ?? session.swings[0]
    }

    private func focusCard(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This session's focus", systemImage: "target").font(.headline)
            Text(session.stats?.focus ?? "keep grooving contact")
            if let best = session.stats?.bestSwing {
                Text("Best / most on-benchmark: Swing \(best)").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func swingPicker(_ session: Session) -> some View {
        Picker("Swing", selection: Binding(get: { pickedSwing(session).index }, set: { selectedIndex = $0 })) {
            ForEach(session.swings, id: \.index) { s in
                Text("Swing \(s.index)").tag(s.index)
            }
        }
        .pickerStyle(.segmented)
    }

    private func matchCard(_ swing: SwingAnalysis) -> some View {
        Group {
            if let c = swing.comparison {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Match to pro shape").font(.headline)
                        Spacer()
                        Text("\(Int(c.overall * 100))%").font(.title2).bold()
                            .foregroundStyle(matchColor(c.overall))
                    }
                    ForEach(Phase.allCases, id: \.self) { phase in
                        if let m = c.perPhaseMatch[phase] {
                            HStack {
                                Text(phase.rawValue.capitalized).frame(width: 90, alignment: .leading)
                                ProgressView(value: m).tint(matchColor(m))
                                Text("\(Int(m * 100))%").font(.caption).monospacedDigit()
                            }
                            // A bare ProgressView's own hit region is just its thin bar (well
                            // under the 44pt minimum). Combining the row into one accessibility
                            // element gives VoiceOver a single, correctly-sized element with a
                            // sensible combined label/value instead of three separate ones.
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func faultsSection(_ swing: SwingAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What to fix").font(.headline)
            if swing.faults.isEmpty {
                Label("On benchmark — nice strike. Keep grooving it.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(swing.faults, id: \.code) { f in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(severityColor(f.severity)).frame(width: 10, height: 10)
                            Text(f.label).bold()
                        }
                        Text(f.cue).font(.subheadline).foregroundStyle(.secondary)
                        if let drill = DrillCatalog.drill(for: f.drill) {
                            Label("Drill \(drill.code): \(drill.title)", systemImage: "play.circle")
                                .font(.caption).foregroundStyle(Color.textMuted)
                        } else {
                            Text("Drill \(f.drill)").font(.caption).foregroundStyle(Color.textMuted)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func metricsSection(_ swing: SwingAnalysis, session: Session) -> some View {
        let infos = FaultEvaluator.benchmarks(category: saved.club.category)
        let faultKeys = Set(swing.faults.map(\.metric))
        return VStack(alignment: .leading, spacing: 8) {
            Text("Measurements").font(.headline)
            ForEach(infos.filter { $0.angles == nil || $0.angles!.contains(saved.angle) }) { info in
                if let v = swing.metrics[info.key] {
                    HStack {
                        Text(info.label).font(.subheadline)
                        Spacer()
                        Text(format(v)).monospacedDigit()
                            .foregroundStyle(faultKeys.contains(info.key) ? .red : .primary)
                        Text("(aim \(info.higherIsBetter ? "≥" : "≤")\(format(info.good)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func overTheTopCard(_ plane: PlaneAnalysis) -> some View {
        HStack(spacing: 10) {
            Image(systemName: plane.overTheTop ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(PlaneFormat.color(plane))
            VStack(alignment: .leading, spacing: 2) {
                Text(PlaneFormat.title(plane)).bold()
                Text(PlaneFormat.detail(plane)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(PlaneFormat.color(plane).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func format(_ v: Double) -> String { String(format: "%.1f", v) }
    private func matchColor(_ v: Double) -> Color { v >= 0.7 ? .green : (v >= 0.5 ? .orange : .red) }
    private func severityColor(_ s: Double) -> Color { s >= 0.66 ? .red : (s >= 0.33 ? .orange : .yellow) }
}
