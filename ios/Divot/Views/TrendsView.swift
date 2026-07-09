// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import SwiftData
import Charts
import TipKit
import SwingCore

/// P1.5 — per-metric trends over sessions (best swing per session), club-filterable.
struct TrendsView: View {
    @Query(sort: \SavedSession.date, order: .forward) private var saved: [SavedSession]
    @Query private var bagClubs: [BagClub]

    private let metrics: [(key: String, label: String)] = [
        ("tempo_ratio", "Tempo"), ("weight_lead_pct_est", "Weight on lead"),
        ("xfactor_deg", "X-Factor"), ("lead_arm_bend_deg", "Lead-arm bend"),
        ("head_sway_in", "Head sway"), ("head_rise_cm", "Head rise"),
        ("over_the_top", "Over-the-top"),
    ]
    @State private var metricKey = "tempo_ratio"
    @State private var clubFilter: UUID?
    @State private var selDate: Date?

    private struct CP: Identifiable { let id = UUID(); let date: Date; let value: Double }

    private var sessions: [Session] { TrendsData.sessions(saved) }
    // Only clubs that actually have sessions, in bag order, so wedges (50/54/58) list separately.
    private var clubsWithHistory: [ClubSpec] {
        let ids = Set(sessions.map { $0.club.id })
        return Bag.sorted(bagClubs.map(\.spec).filter { ids.contains($0.id) })
    }

    private var points: [CP] {
        if metricKey == "over_the_top" {
            return sessions.compactMap { s -> CP? in
                if let cf = clubFilter, s.club.id != cf { return nil }
                let best = s.swings.first { $0.index == (s.stats?.bestSwing ?? 1) } ?? s.swings.first
                guard let v = best?.plane?.maxAbovePlane else { return nil }
                return CP(date: s.date, value: v)
            }.sorted { $0.date < $1.date }
        }
        return Trends.series(sessions, metric: metricKey, clubID: clubFilter).map { CP(date: $0.date, value: $0.value) }
    }

    private var trend: [CP] {
        let win = 3
        guard !points.isEmpty else { return [] }
        return points.indices.map { i in
            let slice = points[max(0, i - win + 1)...i]
            return CP(date: points[i].date, value: slice.map(\.value).reduce(0, +) / Double(slice.count))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if points.isEmpty {
                    let e = EmptyStateContent.forTab(.trends)
                    ContentUnavailableView(e.title, systemImage: e.symbol, description: Text(e.message))
                } else {
                    Form {
                        Section {
                            Picker("Metric", selection: $metricKey) {
                                ForEach(metrics, id: \.key) { Text($0.label).tag($0.key) }
                            }
                            Picker("Club", selection: $clubFilter) {
                                Text("All clubs").tag(UUID?.none)
                                ForEach(clubsWithHistory) { Text($0.displayName).tag(UUID?.some($0.id)) }
                            }
                        }
                        Section(metrics.first { $0.key == metricKey }?.label ?? "Metric") {
                            chart.frame(height: 240)
                        }
                    }
                    .listRowBackground(Color.surface)
                    .divotScreenBackground()
                }
            }
            .navigationTitle("Trends")
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { p in
                PointMark(x: .value("Date", p.date), y: .value("Value", p.value))
                    .foregroundStyle(DataVizRole.reference.color)
            }
            ForEach(trend) { p in
                LineMark(x: .value("Date", p.date), y: .value("Trend", p.value))
                    .foregroundStyle(DataVizRole.you.color)
                    .interpolationMethod(.catmullRom)
            }
            if let selDate, let np = ChartScrub.nearest(to: selDate, in: points.map { ($0.date, $0.value) }) {
                RuleMark(x: .value("Date", np.date))
                    .foregroundStyle(Color.hairline)
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        Text(String(format: "%.1f", np.value))
                            .font(.metric(13)).foregroundStyle(Color.textPrimary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.hairline))
                    }
            }
        }
        .chartXSelection(value: $selDate)
        .popoverTip(ChartScrubTip())   // D4 — discover chart scrubbing
    }
}
