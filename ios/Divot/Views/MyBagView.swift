// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import SwiftData
import SwingCore

/// Settings → My Bag: edit the clubs you carry. Active clubs (reorder, retire, delete) plus
/// a retired section (restore). Wedges are keyed by loft; add by name or by loft.
struct MyBagView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BagClub.order) private var clubs: [BagClub]
    @State private var showAdd = false

    private var active: [BagClub] { clubs.filter { !$0.retired } }
    private var retired: [BagClub] { clubs.filter { $0.retired } }

    var body: some View {
        Form {
            Section("In the bag") {
                ForEach(active) { club in row(club) }
                    .onMove(perform: move)
            }

            if !retired.isEmpty {
                Section("Retired") {
                    ForEach(retired) { club in
                        HStack {
                            Text(club.spec.displayName).foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore") { BagEditor.restore(club, in: context) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .listRowBackground(Color.surface)
        .divotScreenBackground()
        .navigationTitle("My Bag")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarLeading) {
                Button { showAdd = true } label: { Label("Add club", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { AddClubSheet() }
    }

    private func row(_ club: BagClub) -> some View {
        HStack {
            Text(club.spec.displayName).bold()
            Text("· \(club.spec.category.label)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { BagEditor.delete(club, in: context) } label: {
                Label("Delete", systemImage: "trash")
            }
            Button { BagEditor.retire(club, in: context) } label: {
                Label("Retire", systemImage: "archivebox")
            }.tint(.orange)
        }
    }

    private func move(_ offsets: IndexSet, _ to: Int) {
        var ordered = active
        ordered.move(fromOffsets: offsets, toOffset: to)
        BagEditor.reorder(ordered, in: context)
    }
}

/// Add a club: pick a category, then a number (woods/hybrids/irons) or, for wedges, a loft
/// with a name quick-pick and an optional letter label.
struct AddClubSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var category: ClubCategory = .iron
    @State private var number = 7
    @State private var loft = 54.0
    @State private var label = ""

    private var isWedge: Bool { category == .wedge }
    private var isDriver: Bool { category == .driver }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Category", selection: $category) {
                        ForEach(ClubCategory.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .onChange(of: category) { _, _ in syncLabelSuggestion() }
                }

                if !isDriver && !isWedge {
                    Section("Number") {
                        Stepper("\(numberNoun) \(number)", value: $number, in: 1...12)
                    }
                }

                if isWedge {
                    Section("Loft") {
                        HStack {
                            Text("\(Int(loft.rounded()))°").monospacedDigit()
                            Slider(value: $loft, in: 44...64, step: 1) { _ in syncLabelSuggestion() }
                                .onChange(of: loft) { _, _ in syncLabelSuggestion() }
                        }
                        HStack(spacing: 8) {
                            ForEach(["PW", "GW", "SW", "LW"], id: \.self) { name in
                                Button(name) {
                                    loft = Bag.wedgePrefillLoft(name: name)
                                    label = Bag.suggestedWedgeLabel(loft: loft)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                Section("Label (optional)") {
                    TextField(labelPlaceholder, text: $label)
                        .textInputAutocapitalization(.characters)
                }
            }
            .navigationTitle("Add club")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: add) }
            }
            .onAppear(perform: syncLabelSuggestion)
        }
    }

    private var numberNoun: String {
        switch category {
        case .wood: return "Wood"
        case .hybrid: return "Hybrid"
        case .drivingIron: return "Driving iron"
        default: return "Iron"
        }
    }
    private var labelPlaceholder: String { isWedge ? Bag.suggestedWedgeLabel(loft: loft) : category.label }

    /// Keep the wedge label field showing the suggested letter until the user overrides it.
    private func syncLabelSuggestion() {
        if isWedge, label.isEmpty { label = Bag.suggestedWedgeLabel(loft: loft) }
    }

    private func add() {
        let spec: ClubSpec
        if isWedge {
            spec = BagEditor.wedgeSpec(loft: loft, customLabel: label)
        } else {
            spec = BagEditor.numberedSpec(category: category, number: number, customLabel: label)
        }
        BagEditor.add(spec, to: context)
        dismiss()
    }
}
