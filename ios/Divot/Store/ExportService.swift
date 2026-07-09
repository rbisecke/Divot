// Part of Divot (built + tested; see App/DivotApp.swift).
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import SwingCore

/// P1.8 — on-device GIF writer (no cloud). Pure ImageIO.
enum GifExporter {
    @discardableResult
    static func write(_ images: [UIImage], frameDelay: Double, to url: URL) -> Bool {
        guard !images.isEmpty,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, images.count, nil)
        else { return false }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String:
            [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary as String:
            [kCGImagePropertyGIFDelayTime as String: frameDelay]] as CFDictionary
        for img in images { if let cg = img.cgImage { CGImageDestinationAddImage(dest, cg, frameProps) } }
        return CGImageDestinationFinalize(dest)
    }
}

/// P1.8 — build shareable artifacts on demand. Nothing is uploaded; files go to the temp dir
/// and are handed to the iOS share sheet only when the user taps Share.
enum ExportService {
    static func reportFile(_ session: Session) -> URL? {
        let md = ReportBuilder.markdown(session)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swing-report.md")
        do { try md.data(using: .utf8)?.write(to: url); return url } catch { return nil }
    }

    static func sequenceGif(videoURL: URL, events: SwingEvents) async -> URL? {
        let stills = await FrameExtractor.stills(videoURL: videoURL, events: events)
        guard !stills.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swing-sequence.gif")
        return GifExporter.write(stills.map { $0.image }, frameDelay: 0.7, to: url) ? url : nil
    }
}

/// Wraps the system share sheet for SwiftUI.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
