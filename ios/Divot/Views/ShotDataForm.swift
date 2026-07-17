// Part of Divot (built + tested; see App/DivotApp.swift).
// P2.7 — optional MLM2PRO manual entry. Fully optional; the app works without it.
import SwiftUI
import SwiftData
import SwingCore

struct ShotDataForm: View {
    let sessionID: UUID
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var ballSpeed = ""
    @State private var clubSpeed = ""
    @State private var carry = ""
    @State private var spin = ""
    @State private var launch = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Launch monitor (optional)") {
                    field("Ball speed (mph)", $ballSpeed)
                    field("Club speed (mph)", $clubSpeed)
                    field("Carry (yd)", $carry)
                    field("Spin (rpm)", $spin)
                    field("Launch (°)", $launch)
                }
                Text("Leave any field blank — nothing here is required.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Add shot data")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack { Text(label); Spacer()
            TextField("", text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                // The empty "" placeholder above also doubles as the accessibility label by
                // default, so VoiceOver announced every field as "text field, blank" with no way
                // to tell them apart (finding #14). Pass the real label through explicitly.
                .accessibilityLabel(label)
        }
    }

    private func save() {
        let shot = ShotData(sessionID: sessionID,
                            ballSpeedMph: Double(ballSpeed), clubSpeedMph: Double(clubSpeed),
                            carryYds: Double(carry), spinRpm: Double(spin), launchDeg: Double(launch))
        context.insert(shot)
        try? context.save()
        dismiss()
    }
}
