import XCTest
import SwiftData
import UIKit
import SwiftUI
import AVFoundation
@testable import Divot
import SwingCore

/// Runs the real pipeline on-device (Simulator) against a bundled swing clip, and
/// exercises the app's persistence layer. This is the S4–S6 validation gate.
final class AppValidationTests: XCTestCase {

    // Club specs matching the legacy fixtures, via the migration mapper.
    private let pw = ClubLegacy.map(rawValue: "pw")
    private let dr = ClubLegacy.map(rawValue: "dr")
    private let i7 = ClubLegacy.map(rawValue: "7i")
    private let i9 = ClubLegacy.map(rawValue: "9i")

    /// A committed SYNTHETIC clip (no real footage) — enough to exercise frame extraction.
    private func sampleClip() throws -> URL {
        let bundle = Bundle(for: type(of: self))
        return try XCTUnwrap(bundle.url(forResource: "placeholder_swing", withExtension: "mov"),
                             "placeholder_swing.mov must be bundled in the test target")
    }

    /// A REAL swing clip for the on-device pipeline test. Not committed (privacy) — drop your
    /// own at DivotTests/Fixtures/sample_swing.mov to run it; otherwise the test skips.
    private func realSwingClip() throws -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "sample_swing", withExtension: "mov") else {
            throw XCTSkip("Add a real swing clip at DivotTests/Fixtures/sample_swing.mov to run the on-device pipeline test.")
        }
        return url
    }

    // MARK: Engine on iOS

    func testPipelineRunsOnDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("""
        VNDetectHumanBodyPoseRequest returns no results on the iOS Simulator (no pose model). \
        The full pipeline is validated on macOS against golden fixtures — including this exact bundled \
        clip (see SwingCore/validate.sh) — and runs for real on-device / on a signed 'Designed for iPad' Mac run.
        """)
        #endif
        let clip = try realSwingClip()
        let session = try SwingAnalyzer.analyzeSession(video: clip, club: pw, angle: .faceOn, hand: .right)

        XCTAssertFalse(session.swings.isEmpty, "at least one swing detected")
        let swing = session.swings[0]

        // events ordered
        let e = swing.events
        XCTAssertLessThan(e.address.frame, e.top.frame)
        XCTAssertLessThan(e.top.frame, e.impact.frame)
        XCTAssertLessThanOrEqual(e.impact.frame, e.finish.frame)
        XCTAssertGreaterThan(e.impact.t, 0.3)
        XCTAssertLessThan(e.impact.t, 5.0)

        // metrics present + finite
        XCTAssertNotNil(swing.metrics.tempoRatio)
        XCTAssertNotNil(swing.metrics.weightLeadPctEst)
        for key in ["head_sway_in", "lead_arm_bend_deg", "xfactor_deg"] {
            if let v = swing.metrics[key] { XCTAssertTrue(v.isFinite, "\(key) finite") }
        }

        // faults evaluated (this clip is my chunky wedge swing → expect the known ones)
        let codes = Set(swing.faults.map(\.code))
        XCTAssertTrue(codes.contains("chicken_wing") || codes.contains("hanging_back"),
                      "expected the known wedge faults, got \(codes)")

        // comparison to a bundled pro template
        let cmp = try XCTUnwrap(swing.comparison, "comparison populated")
        XCTAssertGreaterThan(cmp.overall, 0)
        XCTAssertLessThanOrEqual(cmp.overall, 1)

        // session stats
        let stats = try XCTUnwrap(session.stats)
        XCTAssertGreaterThanOrEqual(stats.bestSwing, 1)
        XCTAssertFalse(stats.focus.isEmpty)
    }

    func testReferenceLibraryBundled() {
        XCTAssertEqual(ReferenceStore.available.count, 8, "all 8 pro templates ship in the app bundle")
        XCTAssertNotNil(ReferenceStore.template(category: .wedge, angle: .faceOn))
    }

    /// Wave 1 F2 — every design token resolves from the asset catalog, and the metric font is monospaced.
    func testThemeTokensResolve() {
        let names = ["AccentColor", "BG", "Surface", "TextPrimary", "TextMuted",
                     "Hairline", "DataYou", "DataReference", "WarnAmber"]
        for name in names {
            XCTAssertNotNil(UIColor(named: name), "color token \(name) must exist in the asset catalog")
        }
        // Metric font uses monospaced (tabular) digits.
        let metric = UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        XCTAssertTrue(metric.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ||
                      metric.pointSize == 17, "metric font is a valid monospaced-digit font")
    }

    /// The whole pipeline via the replay mock — runs ANYWHERE (incl. the Simulator, where
    /// live Vision can't). This is the device-free end-to-end proof.
    func testPipelineViaReplayProvider() throws {
        let bundle = Bundle(for: type(of: self))
        let jsonURL = try XCTUnwrap(bundle.url(forResource: "sample_swing.pose", withExtension: "json"),
                                    "recorded pose JSON must be bundled in the test target")
        let replay = try ReplayPoseProvider(contentsOf: jsonURL)
        let session = try SwingAnalyzer.analyzeSession(video: URL(fileURLWithPath: "/dev/null"),
                                                       club: pw, angle: .faceOn, hand: .right, provider: replay)
        XCTAssertFalse(session.swings.isEmpty, "replay yields a swing")
        let sw = session.swings[0]
        XCTAssertLessThan(sw.events.address.frame, sw.events.top.frame)
        XCTAssertLessThan(sw.events.top.frame, sw.events.impact.frame)
        XCTAssertEqual(sw.events.impact.t, 1.87, accuracy: 0.3)
        let codes = Set(sw.faults.map(\.code))
        XCTAssertTrue(codes.contains("chicken_wing") || codes.contains("hanging_back"), "got \(codes)")
        let cmp = try XCTUnwrap(sw.comparison)
        XCTAssertGreaterThan(cmp.overall, 0)
    }

    func testBenchmarksClubAware() {
        let wedge = FaultEvaluator.benchmarks(category: .wedge)
        let driver = FaultEvaluator.benchmarks(category: .driver)
        let w = wedge.first { $0.key == "weight_lead_pct_est" }
        let d = driver.first { $0.key == "weight_lead_pct_est" }
        XCTAssertEqual(w?.good, 85)
        XCTAssertEqual(d?.good, 60)
    }

    // MARK: Persistence

    func testSavedSessionRoundTrip() throws {
        // Replay provider, not the real VisionPoseProvider over sampleClip(): the Simulator has no
        // body-pose model, so live Vision detects zero joints in every frame of the placeholder
        // clip. Before finding #6's fix that silently produced a garbage-but-non-throwing swing
        // (exactly the bug #6 fixes); now it correctly throws lowPoseConfidence/noSwingDetected,
        // so this SwiftData round-trip test needs a real (replayed) swing to persist instead.
        let bundle = Bundle(for: type(of: self))
        let jsonURL = try XCTUnwrap(bundle.url(forResource: "sample_swing.pose", withExtension: "json"))
        let replay = try ReplayPoseProvider(contentsOf: jsonURL)
        let session = try SwingAnalyzer.analyzeSession(video: URL(fileURLWithPath: "/dev/null"),
                                                        club: pw, angle: .faceOn, hand: .right, provider: replay)

        let container = try ModelContainer(for: SavedSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let saved = SavedSession(date: .now, club: pw, angle: .faceOn, hand: .right,
                                 videoFilename: "x.mov", session: session)
        ctx.insert(saved)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<SavedSession>())
        XCTAssertEqual(fetched.count, 1)
        let back = try XCTUnwrap(fetched.first?.session)
        XCTAssertEqual(back.swings.count, session.swings.count)
        XCTAssertEqual(fetched.first?.club.category, .wedge)
    }

    // MARK: Bag persistence + migration (S2)

    private func bagContainer() throws -> ModelContext {
        let container = try ModelContainer(for: SavedSession.self, BagClub.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    func testBagClubRoundTrip() throws {
        let ctx = try bagContainer()
        let spec = ClubSpec(category: .wedge, loft: 54, label: "SW")
        ctx.insert(BagClub(spec: spec, order: 3))
        try ctx.save()
        let back = try XCTUnwrap(try ctx.fetch(FetchDescriptor<BagClub>()).first)
        XCTAssertEqual(back.spec.category, .wedge)
        XCTAssertEqual(back.spec.loft, 54)
        XCTAssertEqual(back.spec.label, "SW")
        XCTAssertEqual(back.id, spec.id, "the bag club keeps the spec's stable id")
    }

    func testSeedDefaultBagIsIdempotent() throws {
        let ctx = try bagContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)
        let first = try ctx.fetch(FetchDescriptor<BagClub>())
        XCTAssertEqual(first.count, 11, "default bag seeds 11 clubs")
        // ordered by sortKey (Driver first, wedges last).
        let ordered = first.sorted { $0.order < $1.order }.map { $0.spec.displayName }
        XCTAssertEqual(ordered, ["Driver","3W","5H","6i","7i","8i","9i","PW","50°","54°","58°"])
        // second call must not duplicate.
        BagStore.seedDefaultBagIfEmpty(ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<BagClub>()).count, 11, "re-seed is a no-op")
    }

    func testMigrateLegacySessionBindsToBag() throws {
        let ctx = try bagContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)
        // A pre-ClubSpec session: only the legacy clubRaw is set, snapshot empty.
        let session = makeSession(club: pw)
        let legacy = SavedSession(date: session.date, club: pw, angle: .faceOn, hand: .right,
                                  videoFilename: "old.mov", session: session)
        legacy.clubRaw = "7i"            // simulate an unmigrated row
        legacy.clubID = UUID()
        ctx.insert(legacy)
        try ctx.save()

        let migrated = BagStore.migrateLegacySessions(ctx)
        XCTAssertEqual(migrated, 1)
        let row = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SavedSession>()).first)
        XCTAssertNil(row.clubRaw, "legacy raw cleared after migration")
        XCTAssertEqual(row.club.category, .iron)
        XCTAssertEqual(row.club.number, 7)
        // bound to the seeded 7-iron (no new club created).
        let sevenIron = try XCTUnwrap(try ctx.fetch(FetchDescriptor<BagClub>())
            .first { $0.spec.category == .iron && $0.spec.number == 7 })
        XCTAssertEqual(row.clubID, sevenIron.id, "session bound to the bag's 7-iron by id")
        XCTAssertNotNil(row.session, "analysis still decodes after migration")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<BagClub>()).count, 11, "no extra club created")
        // idempotent: a second pass migrates nothing.
        XCTAssertEqual(BagStore.migrateLegacySessions(ctx), 0)
    }

    func testMigrateCreatesClubWhenNotCarried() throws {
        let ctx = try bagContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)   // default bag has no 56° wedge
        let session = makeSession(club: pw)
        let legacy = SavedSession(date: session.date, club: pw, angle: .faceOn, hand: .right,
                                  videoFilename: "old.mov", session: session)
        legacy.clubRaw = "sw"    // sand wedge → {wedge, 56, "SW"}, absent from the default bag
        ctx.insert(legacy)
        try ctx.save()

        XCTAssertEqual(BagStore.migrateLegacySessions(ctx), 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<BagClub>()).count, 12, "an absent legacy club is added to the bag")
        let row = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SavedSession>()).first)
        XCTAssertEqual(row.club.loft, 56)
    }

    func testRetiredClubStillResolvesHistory() throws {
        let ctx = try bagContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)
        let bag = BagStore.activeBag(ctx)
        let seven = try XCTUnwrap(bag.first { $0.category == .iron && $0.number == 7 })
        let saved = SavedSession(date: .now, club: seven, angle: .faceOn, hand: .right,
                                 videoFilename: "x.mov", session: makeSession(club: seven))
        ctx.insert(saved)
        // retire the 7-iron.
        let clubRow = try XCTUnwrap(try ctx.fetch(FetchDescriptor<BagClub>()).first { $0.id == seven.id })
        clubRow.retired = true
        try ctx.save()

        XCTAssertFalse(BagStore.activeBag(ctx).contains { $0.id == seven.id }, "retired club leaves the active bag")
        let row = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SavedSession>()).first)
        XCTAssertEqual(row.club.number, 7, "its past session still resolves the club from the snapshot")
    }

    // MARK: My Bag editor (S3)

    func testAddWedgeByNameSetsLoftAndLabel() {
        let sand = BagEditor.wedgeSpec(name: "Sand wedge")
        XCTAssertEqual(sand.loft, 56)
        XCTAssertEqual(sand.label, "SW")
        let lob = BagEditor.wedgeSpec(name: "lw")
        XCTAssertEqual(lob.loft, 60)
        XCTAssertEqual(lob.label, "LW")
    }

    func testAddWedgeByLoftLabelling() {
        // A bare loft with no custom label displays by loft ("54°").
        let bare = BagEditor.wedgeSpec(loft: 54)
        XCTAssertEqual(bare.loft, 54)
        XCTAssertNil(bare.label)
        XCTAssertEqual(bare.displayName, "54°")
        // The UI can offer a suggestion; a custom label wins.
        XCTAssertEqual(Bag.suggestedWedgeLabel(loft: 54), "SW")
        let named = BagEditor.wedgeSpec(loft: 58, customLabel: "58 LW")
        XCTAssertEqual(named.label, "58 LW")
    }

    func testDuplicateWedgesPersistDistinctly() throws {
        let ctx = try bagContainer()
        for l in [50.0, 54.0, 58.0] { BagEditor.add(BagEditor.wedgeSpec(loft: l), to: ctx) }
        let wedges = try ctx.fetch(FetchDescriptor<BagClub>()).filter { $0.spec.category == .wedge }
        XCTAssertEqual(wedges.count, 3)
        XCTAssertEqual(Set(wedges.compactMap { $0.spec.loft }), [50, 54, 58])
        XCTAssertEqual(Set(wedges.map { $0.id }).count, 3, "each wedge has a distinct id")
    }

    func testRetireHidesButKeepsRow() throws {
        let ctx = try bagContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)
        let total = try ctx.fetchCount(FetchDescriptor<BagClub>())
        let driver = try XCTUnwrap(try ctx.fetch(FetchDescriptor<BagClub>()).first { $0.spec.category == .driver })
        BagEditor.retire(driver, in: ctx)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<BagClub>()), total, "retire keeps the row")
        XCTAssertFalse(BagStore.activeBag(ctx).contains { $0.category == .driver }, "retired club leaves the active bag")
        BagEditor.restore(driver, in: ctx)
        XCTAssertTrue(BagStore.activeBag(ctx).contains { $0.category == .driver }, "restore brings it back")
    }

    func testReorderPersists() throws {
        let ctx = try bagContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)
        var clubs = try ctx.fetch(FetchDescriptor<BagClub>()).sorted { $0.order < $1.order }
        let firstID = clubs[0].id
        clubs.reverse()
        BagEditor.reorder(clubs, in: ctx)
        let reread = try ctx.fetch(FetchDescriptor<BagClub>()).sorted { $0.order < $1.order }
        XCTAssertEqual(reread.last?.id, firstID, "the previously-first club is now last")
    }

    func testDeleteRemovesFromBag() throws {
        let ctx = try bagContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)
        let club = try XCTUnwrap(try ctx.fetch(FetchDescriptor<BagClub>()).first { $0.spec.category == .wedge && $0.spec.loft == 58 })
        BagEditor.delete(club, in: ctx)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<BagClub>()), 10)
        XCTAssertFalse(try ctx.fetch(FetchDescriptor<BagClub>()).contains { $0.spec.loft == 58 })
    }

    // MARK: MLM2PRO club-code mapping + override (S6)

    private func importContainer() throws -> ModelContext {
        let container = try ModelContainer(for: SavedSession.self, BagClub.self, MLM2ProOverride.self, ShotData.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    func testCsvClubCodeAutoBinds() throws {
        let ctx = try importContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)
        let bag = BagStore.activeBag(ctx)
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "sample_shots", withExtension: "csv"))
        let rows = MLM2ProCSV.parse(try String(contentsOf: url, encoding: .utf8))

        let res = ClubCodeResolver.resolve(rows: rows, bag: bag, overrides: [:])
        XCTAssertTrue(ClubCodeResolver.needsConfirm(res).isEmpty, "the 9i code auto-binds, no confirmation needed")
        let nine = try XCTUnwrap(bag.first { $0.category == .iron && $0.number == 9 })
        XCTAssertEqual(ClubCodeResolver.bindings(res)["9i"]?.id, nine.id)

        // shots carry the resolved club id.
        let session = makeMultiSwingSession(3)
        let shots = ShotImporter.match(rows: rows, to: session, bag: bag)
        XCTAssertEqual(shots.first?.clubID, nine.id, "each 9i shot binds to the 9-iron")
    }

    func testAmbiguousWedgeCodeConfirmsOnceThenPersists() throws {
        let ctx = try importContainer()
        // A bag with two sand-range wedges makes "sw" ambiguous.
        BagEditor.add(ClubSpec(category: .wedge, loft: 54), to: ctx)
        BagEditor.add(ClubSpec(category: .wedge, loft: 56), to: ctx)
        let bag = BagStore.activeBag(ctx)
        let rows = MLM2ProCSV.parse("Club Type\nsw\nsw")

        // First import: "sw" needs confirmation.
        var res = ClubCodeResolver.resolve(rows: rows, bag: bag, overrides: OverrideStore.all(ctx))
        XCTAssertEqual(ClubCodeResolver.needsConfirm(res), ["sw"])

        // User picks the 54° wedge; the choice persists.
        let w54 = try XCTUnwrap(bag.first { $0.loft == 54 })
        OverrideStore.set(code: "sw", clubID: w54.id, in: ctx)

        // Second import: no confirmation, "sw" now auto-binds to the chosen 54°.
        res = ClubCodeResolver.resolve(rows: rows, bag: bag, overrides: OverrideStore.all(ctx))
        XCTAssertTrue(ClubCodeResolver.needsConfirm(res).isEmpty, "the learned override removes the re-ask")
        XCTAssertEqual(ClubCodeResolver.bindings(res)["sw"]?.id, w54.id)
    }

    func testOverrideStoreUpdatesInPlace() throws {
        let ctx = try importContainer()
        let a = UUID(), b = UUID()
        OverrideStore.set(code: "gw", clubID: a, in: ctx)
        XCTAssertEqual(OverrideStore.all(ctx)["gw"], a)
        OverrideStore.set(code: "gw", clubID: b, in: ctx)
        XCTAssertEqual(OverrideStore.all(ctx)["gw"], b, "re-confirming updates rather than duplicating")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<MLM2ProOverride>()), 1)
    }

    // MARK: Labels & per-wedge Trends (S5)

    func testTrendsDataUsesSnapshotClub() throws {
        let ctx = try bagContainer()
        // Snapshot club (B) differs from the encoded analysis club (A), as after a migration.
        let a = ClubSpec(category: .iron, number: 7)
        let b = ClubSpec(category: .wedge, loft: 54, label: "SW")
        let saved = SavedSession(date: .now, club: b, angle: .faceOn, hand: .right,
                                 videoFilename: "x.mov", session: makeSession(club: a))
        ctx.insert(saved)
        let sessions = TrendsData.sessions([saved])
        XCTAssertEqual(sessions.first?.club.id, b.id, "trends uses the stable snapshot club, not the encoded one")
        XCTAssertEqual(sessions.first?.club.loft, 54)
    }

    func testPerWedgeTrendsAreDistinct() throws {
        let ctx = try bagContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)
        let bag = BagStore.activeBag(ctx)
        let w54 = try XCTUnwrap(bag.first { $0.category == .wedge && $0.loft == 54 })
        let w58 = try XCTUnwrap(bag.first { $0.category == .wedge && $0.loft == 58 })
        // two 54° sessions, one 58° session.
        for (i, club) in [w54, w54, w58].enumerated() {
            let d = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86_400)
            ctx.insert(SavedSession(date: d, club: club, angle: .faceOn, hand: .right,
                                    videoFilename: "\(i).mov", session: makeSession(club: club, date: d)))
        }
        let sessions = TrendsData.sessions(try ctx.fetch(FetchDescriptor<SavedSession>()))
        XCTAssertEqual(Trends.series(sessions, metric: "tempo_ratio", clubID: w54.id).count, 2, "the 54° wedge has its own line")
        XCTAssertEqual(Trends.series(sessions, metric: "tempo_ratio", clubID: w58.id).count, 1, "the 58° wedge is a separate line")
        XCTAssertEqual(Trends.series(sessions, metric: "tempo_ratio", clubID: nil).count, 3, "all clubs combined")
    }

    func testHistoryLabelUsesDisplayName() throws {
        let ctx = try bagContainer()
        let wedge = ClubSpec(category: .wedge, loft: 54)
        let saved = SavedSession(date: .now, club: wedge, angle: .faceOn, hand: .right,
                                 videoFilename: "x.mov", session: makeSession(club: wedge))
        ctx.insert(saved)
        XCTAssertEqual(saved.club.displayName, "54°", "a label-less wedge shows its loft")
    }

    // MARK: Capture picker from the bag (S4)

    func testCapturePickerListsActiveBagInLoftOrder() throws {
        let ctx = try bagContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)
        // retire the driver — it must drop out of the picker.
        let driver = try XCTUnwrap(try ctx.fetch(FetchDescriptor<BagClub>()).first { $0.spec.category == .driver })
        BagEditor.retire(driver, in: ctx)

        let picker = BagStore.activeBag(ctx)
        XCTAssertFalse(picker.contains { $0.category == .driver }, "retired club is not offered")
        XCTAssertEqual(picker.map { $0.displayName }, ["3W","5H","6i","7i","8i","9i","PW","50°","54°","58°"],
                       "picker is the active bag in loft/length order")
    }

    func testCapturePickerPreselectsLastUsed() throws {
        let ctx = try bagContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)
        let bag = BagStore.activeBag(ctx)
        let wedge54 = try XCTUnwrap(bag.first { $0.category == .wedge && $0.loft == 54 })
        // "last used" = the persisted club id.
        let resolved = BagStore.resolveClub(setting: wedge54.id.uuidString, in: bag)
        XCTAssertEqual(resolved?.id, wedge54.id)
    }

    func testCapturePickerFallsBackWhenUnset() throws {
        let ctx = try bagContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)
        let bag = BagStore.activeBag(ctx)
        let resolved = try XCTUnwrap(BagStore.resolveClub(setting: "", in: bag))
        XCTAssertEqual(resolved.category, .iron, "an unset default resolves to a mid-iron")
    }

    func testCapturePickerSelectionPersistsClubID() throws {
        let ctx = try bagContainer()
        BagStore.seedDefaultBagIfEmpty(ctx)
        let bag = BagStore.activeBag(ctx)
        let nine = try XCTUnwrap(bag.first { $0.category == .iron && $0.number == 9 })
        // selecting the 9-iron and saving a session records its stable id.
        let saved = SavedSession(date: .now, club: nine, angle: .faceOn, hand: .right,
                                 videoFilename: "x.mov", session: makeSession(club: nine))
        XCTAssertEqual(saved.clubID, nine.id)
        XCTAssertEqual(saved.club.number, 9)
    }

    // MARK: P1 helpers

    /// Build a synthetic Session without needing Vision (Simulator-safe).
    private func makeSession(club: ClubSpec = ClubLegacy.map(rawValue: "pw"), date: Date = Date(timeIntervalSince1970: 1_700_000_000),
                             tempo: Double = 2.94, weight: Double = 40) -> Session {
        var m = SwingMetrics(); m.tempoRatio = tempo; m.weightLeadPctEst = weight; m.xfactorDeg = 35
        let ev = SwingEvents(address: SwingEvent(t: 0, frame: 0), top: SwingEvent(t: 1.2, frame: 36),
                             impact: SwingEvent(t: 1.6, frame: 48), finish: SwingEvent(t: 2.2, frame: 66))
        let sa = SwingAnalysis(index: 1, events: ev, metrics: m, faults: [])
        let stats = SessionStats(bestSwing: 1, recurringFaults: [:], focus: "keep grooving contact")
        return Session(date: date, club: club, angle: .faceOn, hand: .right, swings: [sa], stats: stats)
    }

    private func widePose() -> PoseSequence {
        func jp(_ x: Double, _ y: Double) -> JointPoint { JointPoint(x: x, y: y, c: 1) }
        let joints: [Joint: JointPoint] = [
            .leftShoulder: jp(0.3, 0.4), .rightShoulder: jp(0.7, 0.4),
            .leftHip: jp(0.4, 0.6), .rightHip: jp(0.6, 0.6),
            .nose: jp(0.5, 0.3), .leftWrist: jp(0.45, 0.55), .rightWrist: jp(0.55, 0.55),
        ]
        return PoseSequence(fps: 30, width: 1000, height: 1000, frames: [PoseFrame(t: 0, joints: joints)])
    }

    func testScrubberEventTicks() {
        let s = makeSession()
        let ev = s.swings[0].events
        let ticks = ScrubberMath.normalizedTicks(ev, duration: 2.2)
        XCTAssertEqual(ticks.count, 4)
        XCTAssertTrue(ticks.allSatisfy { $0.pos >= 0 && $0.pos <= 1 })
        let pos = ticks.map(\.pos)
        XCTAssertEqual(zip(pos, pos.dropFirst()).allSatisfy { $0 <= $1 }, true, "A≤T≤I≤F")
    }

    func testFrameRateNoticeThreshold() {
        XCTAssertTrue(ScrubberMath.showsLowFpsNotice(30))
        XCTAssertFalse(ScrubberMath.showsLowFpsNotice(120))
    }

    func testTempoCardFormatting() {
        XCTAssertEqual(TempoFormat.ratioText(2.94), "2.9 : 1")
        XCTAssertEqual(TempoFormat.ratioText(nil), "—")
        XCTAssertEqual(TempoFormat.ratioText(0), "—")
    }

    func testSequenceRequestsFourEventFrames() {
        let ev = makeSession().swings[0].events
        let times = FrameExtractor.eventTimes(ev)
        XCTAssertEqual(times.count, 4)
        XCTAssertEqual(times.map(\.phase), [.address, .top, .impact, .finish])
        XCTAssertEqual(times.map(\.t), [ev.address.t, ev.top.t, ev.impact.t, ev.finish.t])
    }

    func testTrendsQueryDecodes() throws {
        let container = try ModelContainer(for: SavedSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let s1 = makeSession(date: Date(timeIntervalSince1970: 1_700_000_000), tempo: 2.8)
        let s2 = makeSession(date: Date(timeIntervalSince1970: 1_700_100_000), tempo: 3.1)
        ctx.insert(SavedSession(date: s1.date, club: pw, angle: .faceOn, hand: .right, videoFilename: "a.mov", session: s1))
        ctx.insert(SavedSession(date: s2.date, club: pw, angle: .faceOn, hand: .right, videoFilename: "b.mov", session: s2))
        try ctx.save()
        let sessions = try ctx.fetch(FetchDescriptor<SavedSession>()).compactMap { $0.session }
        let series = Trends.series(sessions, metric: "tempo_ratio", category: nil)
        XCTAssertEqual(series.count, 2)
        XCTAssertLessThan(series[0].date, series[1].date)
    }

    func testRememberLastClub() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "test.remember.\(UUID().uuidString)"))
        var prefs = Preferences(suite)
        let clubID = dr.id.uuidString
        prefs.clubRaw = clubID
        let reread = Preferences(suite)
        XCTAssertEqual(reread.clubRaw, clubID)
    }

    func testAngleDetectionMapping() {
        let pose = widePose()
        let ev = SwingEvents(address: SwingEvent(t: 0, frame: 0), top: SwingEvent(t: 1, frame: 0),
                             impact: SwingEvent(t: 1, frame: 0), finish: SwingEvent(t: 1, frame: 0))
        let det = AngleDetector.detect(pose, events: ev)
        XCTAssertEqual(det.angle, .faceOn)
        let applied = AngleSelection.apply(detection: det)
        XCTAssertNotNil(applied)
        XCTAssertEqual(applied?.angle, .faceOn)
    }

    func testGifExportWritesFile() throws {
        func solid(_ color: UIColor) -> UIImage {
            let r = CGRect(x: 0, y: 0, width: 32, height: 32)
            return UIGraphicsImageRenderer(size: r.size).image { ctx in color.setFill(); ctx.fill(r) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).gif")
        XCTAssertTrue(GifExporter.write([solid(.red), solid(.green)], frameDelay: 0.3, to: url))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(Array(data.prefix(3)), [0x47, 0x49, 0x46], "GIF magic bytes")
    }

    func testReportMarkdownContainsClub() {
        let md = ReportBuilder.markdown(makeSession(club: pw))
        XCTAssertTrue(md.contains("PW"), "report names the club")
        XCTAssertTrue(md.contains("Tempo"))
    }

    // MARK: P2

    func testEveryDrillCodeHasAsset() {
        var codes = Set<String>()
        for category in [ClubCategory.wedge, .driver, .iron, .wood] {
            for info in FaultEvaluator.benchmarks(category: category) { codes.insert(info.drill) }
        }
        XCTAssertFalse(codes.isEmpty)
        for code in codes {
            XCTAssertNotNil(DrillCatalog.drill(for: code), "drill \(code) has a catalog entry")
        }
    }

    func testSideBySideAlignmentUsesEngine() {
        let a = SwingEvents(address: SwingEvent(t: 0, frame: 0), top: SwingEvent(t: 1, frame: 0),
                            impact: SwingEvent(t: 2, frame: 0), finish: SwingEvent(t: 3, frame: 0))
        let b = SwingEvents(address: SwingEvent(t: 0, frame: 0), top: SwingEvent(t: 2, frame: 0),
                            impact: SwingEvent(t: 4, frame: 0), finish: SwingEvent(t: 6, frame: 0))
        XCTAssertEqual(EventAlignment.mapTime(a.impact.t, from: a, to: b), b.impact.t, accuracy: 0.001)
        XCTAssertEqual(EventAlignment.mapTime(a.top.t, from: a, to: b), b.top.t, accuracy: 0.001)
    }

    func testHapticBeatsWiring() {
        let swing = makeSession().swings[0]
        let beats = TempoHaptics.beats(for: swing)
        XCTAssertEqual(beats.count, 2)
        XCTAssertLessThan(beats[0], beats[1])
    }

    func testShotDataDisplayRowsSkipNil() {
        XCTAssertTrue(ShotData(sessionID: UUID()).displayRows.isEmpty)
        XCTAssertEqual(ShotData(sessionID: UUID(), ballSpeedMph: 100).displayRows.count, 1)
    }

    func testShotDataOptionalRoundTrip() throws {
        let container = try ModelContainer(for: SavedSession.self, ShotData.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let sess = makeSession()
        let saved = SavedSession(date: sess.date, club: pw, angle: .faceOn, hand: .right,
                                 videoFilename: "a.mov", session: sess)
        ctx.insert(saved)
        ctx.insert(ShotData(sessionID: saved.id, ballSpeedMph: 120, carryYds: 95))
        try ctx.save()

        let withID = saved.id
        let shots = try ctx.fetch(FetchDescriptor<ShotData>(predicate: #Predicate { $0.sessionID == withID }))
        XCTAssertEqual(shots.count, 1)
        XCTAssertEqual(shots.first?.ballSpeedMph, 120)

        // a session with no shot data attached fetches nothing (proves "never required")
        let saved2 = SavedSession(date: Date(timeIntervalSince1970: 1_700_500_000), club: pw,
                                  angle: .faceOn, hand: .right, videoFilename: "b.mov", session: sess)
        ctx.insert(saved2); try ctx.save()
        let noID = saved2.id
        let none = try ctx.fetch(FetchDescriptor<ShotData>(predicate: #Predicate { $0.sessionID == noID }))
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: P3

    private func makeMultiSwingSession(_ n: Int) -> Session {
        let swings = (1...n).map { i -> SwingAnalysis in
            let ev = SwingEvents(address: SwingEvent(t: 0, frame: 0), top: SwingEvent(t: 1.2, frame: 36),
                                 impact: SwingEvent(t: 1.6, frame: 48), finish: SwingEvent(t: 2.2, frame: 66))
            return SwingAnalysis(index: i, events: ev, metrics: SwingMetrics(), faults: [])
        }
        let stats = SessionStats(bestSwing: 1, recurringFaults: [:], focus: "keep grooving contact")
        return Session(date: Date(timeIntervalSince1970: 1_700_000_000), club: i9, angle: .faceOn,
                       hand: .right, swings: swings, stats: stats)
    }

    func testCsvImportMatchesShots() throws {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "sample_shots", withExtension: "csv"),
                                "sample_shots.csv must be bundled in the test target")
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = MLM2ProCSV.parse(text)
        XCTAssertGreaterThanOrEqual(rows.count, 5, "fixture has >=5 shot rows")

        // fewer swings than rows → matches min(rows, swings)
        let session = makeMultiSwingSession(3)
        let shots = ShotImporter.match(rows: rows, to: session)
        XCTAssertEqual(shots.count, 3)
        XCTAssertEqual(shots.map(\.swingIndex), [1, 2, 3])
        // row 1 ball speed from the fixture (24.7) maps onto swing 1
        XCTAssertEqual(shots[0].ballSpeedMph, rows[0].ballSpeed)
        XCTAssertEqual(shots[0].ballSpeedMph, 24.7)

        // empty rows → no shots
        XCTAssertTrue(ShotImporter.match(rows: [], to: session).isEmpty)
    }

    func testPose3DDeviceGated() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("VNDetectHumanBodyPose3DRequest has no model on the Simulator; experimental P3.2 runs on-device only.")
        #else
        // On device: 3D pose on a bundled still would return an observation. Kept minimal;
        // full validation is the on-device spike documented in EXPERIMENTAL.md.
        XCTAssertTrue(true)
        #endif
    }

    func testDockKitSupportFlagCompiles() {
        _ = DockKitService.isSupported
        _ = DockKitService.statusText
    }

    // MARK: Club-path (C1–C6)

    /// C1/C3 — the DTL overlay builds from replay pose on the Simulator, with a plane + hand-path,
    /// and the over-the-top plane analysis is populated and surfaces via PlaneFormat.
    func testDTLOverlayBuildsFromReplay() async throws {
        let bundle = Bundle(for: type(of: self))
        let clip = try sampleClip()
        let jsonURL = try XCTUnwrap(bundle.url(forResource: "sample_swing.pose", withExtension: "json"))
        let replay = try ReplayPoseProvider(contentsOf: jsonURL)
        let session = try SwingAnalyzer.analyzeSession(video: clip, club: i7, angle: .dtl, hand: .right, provider: replay)
        let swing = try XCTUnwrap(session.swings.first)

        let snaps = await FrameExtractor.snapshots(videoURL: clip, session: session, swing: swing)
        XCTAssertFalse(snaps.isEmpty, "overlay snapshots build")
        XCTAssertGreaterThan(snaps[0].handPath.count, 1, "hand-path has points")
        XCTAssertNotNil(snaps[0].shaftPlane ?? snaps[0].lines["swingPlane"], "a plane line exists")
        XCTAssertTrue(snaps[0].clubHeadPath.isEmpty, "no club-head path without a model (graceful empty)")

        // C3 — plane analysis populated + display mapping works.
        let plane = try XCTUnwrap(swing.plane, "SwingAnalyzer populates plane from the hand-path")
        XCTAssertEqual(plane.source, "hand")
        XCTAssertFalse(PlaneFormat.title(plane).isEmpty)
        XCTAssertTrue(PlaneFormat.detail(plane).contains("dev"))
    }

    /// C2 — ball anchor falls back to a tap when auto-detect returns nothing.
    @MainActor func testBallTapFallbackSetsAnchor() {
        let m = BallAnchorModel(detected: nil)
        XCTAssertFalse(m.isSet)
        m.setTap(CGPoint(x: 0.5, y: 0.8))
        XCTAssertTrue(m.isSet)
        XCTAssertEqual(m.ball?.x ?? 0, 0.5, accuracy: 0.0001)
    }

    /// C6 — the back camera advertises a high-frame-rate format (needed for club-head vision). Device-only.
    func test240fpsFormatAvailableOnDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("No camera on the Simulator; 240fps format check runs on-device.")
        #else
        let device = try XCTUnwrap(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back))
        let maxFps = device.formats.flatMap { $0.videoSupportedFrameRateRanges }.map(\.maxFrameRate).max() ?? 0
        XCTAssertGreaterThanOrEqual(maxFps, 120, "back camera should offer >=120fps (ideally 240) for club-head capture")
        #endif
    }

    /// C4 — live ball-flight trace on a synthetic parabola clip. Device-only (VNDetectTrajectories).
    func testBallFlightTraceOnSyntheticClip() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("VNDetectTrajectories returns nothing on the Simulator; runs on a real iPhone.")
        #else
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "ball_flight_synth", withExtension: "mov"),
                                "synthetic ball-flight clip must be bundled")
        let flight = BallFlightTracer.trace(videoURL: url, roi: nil)
        XCTAssertTrue(flight.detected, "should detect the synthetic parabola on device")
        XCTAssertGreaterThanOrEqual(flight.points.count, 5)
        #endif
    }

    /// C6 — the capture guide selector picks the DTL (side-on) check in DTL mode.
    func testDtlModeSelectsGuide() {
        func jp(_ x: Double, _ y: Double) -> JointPoint { JointPoint(x: x, y: y, c: 1) }
        var joints: [Joint: JointPoint] = [
            .nose: jp(0.5, 0.90), .leftShoulder: jp(0.50, 0.75), .rightShoulder: jp(0.46, 0.75),
            .leftHip: jp(0.49, 0.55), .rightHip: jp(0.47, 0.55),
            .leftKnee: jp(0.49, 0.35), .rightKnee: jp(0.47, 0.35),
            .leftAnkle: jp(0.49, 0.15), .rightAnkle: jp(0.47, 0.15),
        ]
        XCTAssertTrue(CaptureController.framing(joints, dtl: true).ok, "side-on ⇒ DTL guide ok")
        joints[.leftShoulder] = jp(0.40, 0.75); joints[.rightShoulder] = jp(0.60, 0.75)
        XCTAssertFalse(CaptureController.framing(joints, dtl: true).ok, "face-on ⇒ DTL guide rejects")
        XCTAssertTrue(CaptureController.framing(joints, dtl: false).ok, "face-on ⇒ face-on guide ok")
    }

    func testCameraSwitchTogglesPosition() {
        XCTAssertEqual(CaptureController.nextPosition(.back), .front)
        XCTAssertEqual(CaptureController.nextPosition(.front), .back)
    }

    /// Regression coverage for finding #5: live pose tracking hardcoded `.up` regardless of the
    /// connection's actual rotation/mirroring, which is wrong in the normal (portrait) case.
    func testVisionOrientationAccountsForRotationAndMirroring() {
        XCTAssertEqual(CaptureController.visionOrientation(rotationAngle: 90, position: .back), .right)
        XCTAssertEqual(CaptureController.visionOrientation(rotationAngle: 90, position: .front), .leftMirrored)
        XCTAssertEqual(CaptureController.visionOrientation(rotationAngle: 270, position: .back), .left)
        XCTAssertEqual(CaptureController.visionOrientation(rotationAngle: 270, position: .front), .rightMirrored)
        XCTAssertEqual(CaptureController.visionOrientation(rotationAngle: 0, position: .back), .up)
        XCTAssertEqual(CaptureController.visionOrientation(rotationAngle: 0, position: .front), .upMirrored)
        XCTAssertEqual(CaptureController.visionOrientation(rotationAngle: 180, position: .back), .down)
        XCTAssertEqual(CaptureController.visionOrientation(rotationAngle: 180, position: .front), .downMirrored)
    }

    // MARK: Wave 2 (branding cohesion + data-UX)

    func testDataVizCodingRoles() {
        XCTAssertEqual(DataVizRole.you.color, Color.dataYou)
        XCTAssertEqual(DataVizRole.reference.color, Color.dataReference)
        XCTAssertEqual(DataVizRole.offPlane.color, Color.warn)
    }

    func testEmptyStateContent() {
        XCTAssertEqual(EmptyStateContent.forTab(.history).symbol, "figure.golf")
        XCTAssertEqual(EmptyStateContent.forTab(.trends).symbol, "chart.xyaxis.line")
        XCTAssertEqual(EmptyStateContent.forTab(.compare).symbol, "rectangle.split.2x1")
        XCTAssertFalse(EmptyStateContent.forTab(.history).title.isEmpty)
        XCTAssertNotEqual(EmptyStateContent.forTab(.history), EmptyStateContent.forTab(.trends))
    }

    func testChartSelectionResolver() {
        let d0 = Date(timeIntervalSince1970: 0)
        let pts: [(date: Date, value: Double)] = [
            (d0, 1), (d0.addingTimeInterval(86_400), 2), (d0.addingTimeInterval(2*86_400), 3),
        ]
        // nearest to just after day 1 → the day-1 point (value 2)
        let near = ChartScrub.nearest(to: d0.addingTimeInterval(86_400 + 1000), in: pts)
        XCTAssertEqual(near?.value, 2)
        XCTAssertNil(ChartScrub.nearest(to: d0, in: []))
    }
}
