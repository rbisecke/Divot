// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import SwiftData
import SwingCore

struct SettingsView: View {
    @Query private var bagClubs: [BagClub]
    @AppStorage(SettingsKey.hand) private var handRaw = Hand.right.rawValue
    @AppStorage(SettingsKey.club) private var clubRaw = ""
    @AppStorage(SettingsKey.angle) private var angleRaw = Angle.faceOn.rawValue
    @AppStorage(SettingsKey.experimental) private var experimental = false

    private var activeBag: [ClubSpec] { Bag.sorted(bagClubs.filter { !$0.retired }.map(\.spec)) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Handedness") {
                    Picker("I play", selection: $handRaw) {
                        ForEach(Hand.all, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Your clubs") {
                    NavigationLink {
                        MyBagView()
                    } label: {
                        LabeledContent("My Bag", value: "\(activeBag.count) club\(activeBag.count == 1 ? "" : "s")")
                    }
                    .accessibilityIdentifier("myBagLink")
                }
                Section("Defaults for a new analysis") {
                    Picker("Club", selection: $clubRaw) {
                        ForEach(activeBag) { Text($0.displayName).tag($0.id.uuidString) }
                    }
                    Picker("Camera angle", selection: $angleRaw) {
                        ForEach(SwingCore.Angle.all, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                }
                Section {
                    Toggle("Experimental features", isOn: $experimental)
                    if experimental {
                        NavigationLink { ExperimentalView() } label: { Text("Experimental (device-only)") }
                    }
                } header: { Text("Experimental") } footer: {
                    Text("3D avatar, ball tracking, DockKit — wired but require a real device to validate.")
                }
                Section {
                    Text("All processing happens on this device. Videos never leave your phone.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Privacy") }
            }
            .listRowBackground(Color.surface)
            .divotScreenBackground()
            .navigationTitle("Settings")
            .onAppear(perform: normalizeClubSetting)
            .onChange(of: bagClubs.count) { _, _ in normalizeClubSetting() }
        }
    }

    /// Resolve an empty / legacy default-club setting to a real bag-club id once the bag loads.
    private func normalizeClubSetting() {
        let specs = activeBag
        guard !specs.isEmpty else { return }
        if UUID(uuidString: clubRaw).flatMap({ id in specs.first { $0.id == id } }) == nil,
           let resolved = BagStore.resolveClub(setting: clubRaw, in: specs) {
            clubRaw = resolved.id.uuidString
        }
    }
}
