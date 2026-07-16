// Part of Divot (built + tested; see App/DivotApp.swift).
import Foundation
import SwiftData
import SwingCore

/// A persisted analysis. The imported video is copied into the app's Documents
/// (never leaves the device); we store its filename plus the encoded SwingCore.Session.
@Model
final class SavedSession {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    // Stable club identity + a denormalized ClubSpec snapshot, so history survives the
    // club being renamed, re-lofted, or retired in the bag.
    var clubID: UUID = UUID()
    var clubCategoryRaw: String = ClubCategory.iron.rawValue
    var clubNumber: Int?
    var clubLoft: Double?
    var clubLabel: String?
    /// Legacy (pre-ClubSpec) fixed-enum raw value; non-nil only on rows awaiting migration.
    var clubRaw: String?
    var angleRaw: String = Angle.faceOn.rawValue
    var handRaw: String = Hand.right.rawValue
    var videoFilename: String = ""
    /// JSON-encoded SwingCore.Session (events, metrics, faults, comparison, stats).
    var analysisData: Data = Data()

    init(date: Date, club: ClubSpec, angle: Angle, hand: Hand, videoFilename: String, session: Session) {
        self.id = UUID()
        self.date = date
        self.clubID = club.id
        self.clubCategoryRaw = club.category.rawValue
        self.clubNumber = club.number
        self.clubLoft = club.loft
        self.clubLabel = club.label
        self.clubRaw = nil
        self.angleRaw = angle.rawValue
        self.handRaw = hand.rawValue
        self.videoFilename = videoFilename
        self.analysisData = (try? JSONEncoder().encode(session)) ?? Data()
    }

    /// The club as recorded on this session (from the snapshot, keyed by its stable id).
    var club: ClubSpec {
        ClubSpec(id: clubID,
                 category: ClubCategory(rawValue: clubCategoryRaw) ?? .iron,
                 number: clubNumber, loft: clubLoft, label: clubLabel)
    }
    var angle: Angle { Angle(rawValue: angleRaw) ?? .faceOn }
    var hand: Hand { Hand(rawValue: handRaw) ?? .right }
    var session: Session? { try? JSONDecoder().decode(Session.self, from: analysisData) }

    /// Absolute URL of the stored video in Documents (may be absent if the file was removed).
    var videoURL: URL {
        AppPaths.videosDir.appendingPathComponent(videoFilename)
    }

    /// Where this session's cached PoseSequence (if any) lives on disk — see PoseCache.swift
    /// (finding #13). The video file never changes in place once written, so no cache-key beyond
    /// the filename is needed.
    var poseCacheURL: URL {
        AppPaths.poseCacheDir.appendingPathComponent(videoFilename).appendingPathExtension("pose.json")
    }
}

enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    /// Swing video is sensitive body-pose data and CLAUDE.md/SECURITY.md both assert it "never
    /// leaves the phone" -- but files under Documents/ are backed up to iCloud by default, which
    /// is a real gap between that claim and actual behavior if the user has device backup
    /// enabled. Excluded from backup here, at the moment the directory is created (finding #12).
    /// Also sets a stronger file-protection class than the iOS default
    /// (.completeUntilFirstUserAuthentication), given this is framed as sensitive data.
    static var videosDir: URL {
        var d = documents.appendingPathComponent("videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? d.setResourceValues(rv)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: d.path)
        return d
    }
    /// Cached PoseSequence JSON, one per saved video — avoids re-running the single most
    /// expensive operation in the app (full frame decode + per-frame Vision) on every visit to a
    /// review screen (finding #13).
    static var poseCacheDir: URL {
        let d = documents.appendingPathComponent("poseCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
