// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import SwingCore

/// Pick a swing video, choose club/angle, and run the on-device analysis.
struct ImportView: View {
    @Environment(\.modelContext) private var context
    @Query private var bagClubs: [BagClub]
    @StateObject private var store = AnalysisStore()
    @StateObject private var launcher = CaptureLauncher.shared   // D6 — Action-button intent

    @AppStorage(SettingsKey.hand) private var handRaw = Hand.right.rawValue
    @AppStorage(SettingsKey.club) private var clubRaw = ""
    @AppStorage(SettingsKey.angle) private var angleRaw = Angle.faceOn.rawValue

    @State private var pickedItem: PhotosPickerItem?
    @State private var pickedURL: URL?
    @State private var showFileImporter = false
    @State private var showCapture = false
    @State private var navSession: SavedSession?
    @State private var detectedNote: String?

    private var hand: Hand { Hand(rawValue: handRaw) ?? .right }
    private var activeBag: [ClubSpec] { Bag.sorted(bagClubs.filter { !$0.retired }.map(\.spec)) }
    /// The club chosen for this swing, resolved from the remembered id against the current bag.
    private var selectedClub: ClubSpec? {
        UUID(uuidString: clubRaw).flatMap { id in activeBag.first { $0.id == id } }
            ?? BagStore.resolveClub(setting: clubRaw, in: activeBag)
    }
    private var angle: Binding<SwingCore.Angle> { Binding(get: { SwingCore.Angle(rawValue: angleRaw) ?? .faceOn }, set: { angleRaw = $0.rawValue }) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Swing video") {
                    PhotosPicker(selection: $pickedItem, matching: .videos) {
                        Label(pickedURL == nil ? "Choose from Photos" : "Change video", systemImage: "photo.on.rectangle")
                    }
                    Button { showFileImporter = true } label: {
                        Label("Choose from Files", systemImage: "folder")
                    }
                    Button { showCapture = true } label: {
                        Label("Record a swing", systemImage: "camera")
                    }
                    if pickedURL != nil {
                        Label("Video ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }

                Section("This swing") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Club").font(.subheadline).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 54))], spacing: 8) {
                            ForEach(activeBag) { c in
                                let on = selectedClub?.id == c.id
                                Button { clubRaw = c.id.uuidString } label: {
                                    Text(c.displayName).font(.caption.bold())
                                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                                        .background(on ? Color.brand : Color.surface,
                                                    in: RoundedRectangle(cornerRadius: 8))
                                        .foregroundStyle(on ? Color.onAccent : Color.textPrimary)
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(Color.hairline, lineWidth: on ? 0 : 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Picker("Camera angle", selection: angle) {
                        ForEach(SwingCore.Angle.all, id: \.self) { Text($0.label).tag($0) }
                    }
                    if let note = detectedNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Handedness", value: hand.label)
                }

                Section {
                    Button {
                        Task { await run() }
                    } label: {
                        HStack(spacing: 8) {
                            if store.busy { ProgressView().tint(Color.onAccent) }
                            Text("Analyze swing")
                        }
                    }
                    .buttonStyle(DivotPrimaryButtonStyle())
                    .disabled(pickedURL == nil || store.busy)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if store.busy {
                    Text("\(store.phase) on-device — pose + measurements.").font(.footnote).foregroundStyle(.secondary)
                }
                if let msg = store.error {
                    Text(msg).foregroundStyle(.red).font(.footnote)
                }
            }
            .listRowBackground(Color.surface)
            .divotScreenBackground()
            .navigationTitle("Analyze")
            .onAppear(perform: normalizeClubSelection)
            .onChange(of: bagClubs.count) { _, _ in normalizeClubSelection() }
            .onChange(of: pickedItem) { _, item in Task { await loadPicked(item) } }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie, .video]) { result in
                if case .success(let url) = result { pickedURL = url; Task { await detectAngle(url) } }
            }
            .navigationDestination(item: $navSession) { saved in
                ResultsView(saved: saved)
            }
            .fullScreenCover(isPresented: $showCapture) {
                CaptureView { url in pickedURL = url; Task { await detectAngle(url) } }
            }
            // D3 — success haptic when analysis finishes (busy true → false)
            .sensoryFeedback(.success, trigger: store.busy) { old, new in old && !new }
            // D6 — Action-button App Intent opens the capture flow
            .onChange(of: launcher.startCaptureRequested) { _, req in
                if req { showCapture = true; launcher.consume() }
            }
        }
    }

    /// Preselect the last-used club (persisted in `clubRaw`), or a sensible fallback, once the
    /// bag loads — so the grid opens on the club you most likely want.
    private func normalizeClubSelection() {
        let specs = activeBag
        guard !specs.isEmpty else { return }
        if UUID(uuidString: clubRaw).flatMap({ id in specs.first { $0.id == id } }) == nil,
           let resolved = BagStore.resolveClub(setting: clubRaw, in: specs) {
            clubRaw = resolved.id.uuidString
        }
    }

    private func loadPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        // Copy the transferable movie to a temp URL we can read.
        if let movie = try? await item.loadTransferable(type: MovieFile.self) {
            pickedURL = movie.url
            await detectAngle(movie.url)
        }
    }

    /// P1.6 — pre-select the camera angle from the setup pose. Vision returns nothing on the
    /// Simulator, so this no-ops there and only takes effect on device.
    private func detectAngle(_ url: URL) async {
        detectedNote = nil
        let detection = await Task.detached { () -> (angle: SwingCore.Angle, confidence: Double)? in
            guard let pose = try? PoseEstimator.pose(video: url), !pose.frames.isEmpty else { return nil }
            let events = EventDetector.detect(pose)
            return AngleDetector.detect(pose, events: events)
        }.value
        guard let detection, let applied = AngleSelection.apply(detection: detection) else { return }
        angleRaw = applied.angle.rawValue
        detectedNote = applied.note
    }

    private func run() async {
        guard let url = pickedURL, let club = selectedClub else { return }
        guard let (session, filename) = await store.analyze(
            pickedURL: url, club: club, angle: angle.wrappedValue, hand: hand) else { return }
        save(session, club: club, filename: filename)
    }

    private func save(_ session: Session, club: ClubSpec, filename: String) {
        let saved = SavedSession(date: Date(), club: club, angle: angle.wrappedValue,
                                 hand: hand, videoFilename: filename, session: session)
        context.insert(saved)
        try? context.save()
        pickedURL = nil
        pickedItem = nil
        navSession = saved
    }
}

/// Bridges a PhotosPicker video selection to a readable file URL in the temp dir.
struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}
