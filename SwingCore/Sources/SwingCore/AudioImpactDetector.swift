import Foundation
import AVFoundation
import CoreMedia

// P3.6 — best-effort audio-transient detector: reads a recorded clip's audio track and
// finds its sharpest short-window energy spike within a given time window. Classical
// signal processing (short-window RMS envelope), no ML — unlike BallFlightTracer's
// Vision-based trajectory detection, the peak-picking math here can run on macOS/Simulator
// too; only the capture step (recording audio at all) is device-gated (no mic on the
// Simulator).

public enum AudioImpactDetector {

    /// Strongest transient's timestamp within `window`, or nil if the clip has no audio
    /// track, it can't be read, or no clear peak stands out from the local noise floor.
    public static func peakTransient(videoURL: URL, window: ClosedRange<Double>,
                                     riseFactor: Double = 2.5) -> Double? {
        guard let envelope = rmsEnvelope(videoURL: videoURL) else { return nil }
        return strongestPeak(envelope: envelope, window: window, riseFactor: riseFactor)
    }

    // MARK: - Pure peak-picking (validated headlessly by SwingCoreCheck)

    /// Given a short-window RMS energy envelope (`(t, energy)` pairs, one per ~5ms window),
    /// find the highest-energy sample inside `window` and return its timestamp, but only if
    /// it clears `riseFactor * mean` — mirrors `MotionTrigger.swingWindow`'s peak/mean burst
    /// test, applied to audio energy instead of wrist speed. The mean is computed from the
    /// same in-window samples as the peak search (a *local* noise floor, matching
    /// `MotionTrigger.step`'s `recentMean`, which is always a trailing local buffer, never a
    /// whole-clip average) — otherwise loud or quiet audio well outside `window` (walk-up
    /// chatter, dead air before/after the swing, now that P2.8 no longer trims the recorded
    /// clip) would skew the rise-factor bar for a transient that has nothing to do with it. A
    /// silent or evenly-loud window (nothing rises meaningfully above the local mean) returns
    /// nil.
    public static func strongestPeak(envelope: [(t: Double, energy: Double)],
                                     window: ClosedRange<Double>, riseFactor: Double = 2.5) -> Double? {
        guard !envelope.isEmpty else { return nil }
        let inWindow = envelope.filter { window.contains($0.t) }
        guard let best = inWindow.max(by: { $0.energy < $1.energy }) else { return nil }

        let mean = inWindow.reduce(0.0) { $0 + $1.energy } / Double(inWindow.count)
        guard mean > 1e-9 else { return nil }   // silence-only floor
        guard best.energy > mean * riseFactor else { return nil }
        return best.t
    }

    // MARK: - Device-gated audio reading

    /// Reads the clip's audio track via `AVAssetReader` (same reading pattern
    /// `BallFlightTracer` uses for video) and buckets samples into a ~5ms RMS envelope,
    /// timestamped from each buffer's own presentation time. Returns nil if there's no audio
    /// track or it can't be opened (e.g. an older clip recorded before P3.6 added the mic).
    static func rmsEnvelope(videoURL: URL, windowSeconds: Double = 0.005) -> [(t: Double, energy: Double)]? {
        let asset = AVURLAsset(url: videoURL)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.startReading()

        var result: [(t: Double, energy: Double)] = []
        var sampleRate = 44_100.0
        var channelCount = 1

        while reader.status == .reading, let sb = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sb) }
            if let fmt = CMSampleBufferGetFormatDescription(sb),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                sampleRate = asbd.mSampleRate
                channelCount = max(1, Int(asbd.mChannelsPerFrame))
            }
            let bufferStart = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
            guard bufferStart.isFinite, let blockBuffer = CMSampleBufferGetDataBuffer(sb) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
                  let dataPointer = dataPointer else { continue }

            let framesPerWindow = max(1, Int(sampleRate * windowSeconds))
            let samplesPerWindow = framesPerWindow * channelCount
            let int16Count = length / MemoryLayout<Int16>.size

            dataPointer.withMemoryRebound(to: Int16.self, capacity: int16Count) { samples in
                var i = 0
                var windowIdx = 0
                while i < int16Count {
                    let end = min(i + samplesPerWindow, int16Count)
                    var sumSquares = 0.0
                    for k in i..<end {
                        let v = Double(samples[k]) / 32_768.0
                        sumSquares += v * v
                    }
                    let n = end - i
                    let rms = n > 0 ? (sumSquares / Double(n)).squareRoot() : 0
                    result.append((t: bufferStart + Double(windowIdx) * windowSeconds, energy: rms))
                    i = end
                    windowIdx += 1
                }
            }
        }
        return result.isEmpty ? nil : result
    }
}
