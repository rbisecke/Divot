// Part of Divot (built + tested; see App/DivotApp.swift).
// P2.1 — in-app guided recorder. DEVICE-GATED: compiles on the Simulator but capture
// and live pose only run on a real iPhone (Simulator has no camera / body-pose model).
import Foundation
import AVFoundation
import Vision
import SwingCore

final class CaptureController: NSObject, ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {

    @Published var framingOK = false
    @Published var framingReason = "Point the camera at your setup"
    @Published var isRecording = false
    @Published var permissionDenied = false
    @Published var highFps = false
    @Published var lastClipURL: URL?
    /// UI-owned (set by the DTL/face-on Picker) — main is the source of truth; mirrored to
    /// `dtlModeSnapshot` for the capture.frames queue via `didSet` (finding #9).
    @Published var dtlMode = false { didSet { frameQueue.async { self.dtlModeSnapshot = self.dtlMode } } }
    /// Write-only-from-sessionQueue mirror of `currentPosition`, for UI display only — logic never
    /// reads this back (finding #9: cross-thread reads of capture state were a data race).
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    /// Set when switchCamera() fails to add both the target camera and the fallback (previous)
    /// camera — previously the preview just went black/frozen with no error surfaced, while
    /// `cameraPosition` kept reporting the old (no-longer-active) position (Medium finding).
    @Published var cameraUnavailable = false

    /// Pure guide selector (testable): DTL uses the side-on check, otherwise the face-on check.
    static func framing(_ joints: [SwingCore.Joint: JointPoint], dtl: Bool) -> (ok: Bool, reason: String) {
        dtl ? FramingGuide.dtlInFrame(joints) : FramingGuide.inFrame(joints)
    }

    /// The camera to switch to from a given position (testable).
    static func nextPosition(_ p: AVCaptureDevice.Position) -> AVCaptureDevice.Position {
        p == .back ? .front : .back
    }

    /// Derive the correct Vision request orientation from the capture connection's actual
    /// rotation angle and camera position (front camera delivers mirrored buffers), instead of
    /// assuming `.up` for every frame regardless of how the phone is actually held (finding #5).
    /// Pure/testable; uses the modern (iOS 17+) `videoRotationAngle`, not the deprecated
    /// `videoOrientation`.
    static func visionOrientation(rotationAngle: CGFloat, position: AVCaptureDevice.Position) -> CGImagePropertyOrientation {
        let mirrored = position == .front
        switch rotationAngle {
        case 90:  return mirrored ? .leftMirrored  : .right
        case 270: return mirrored ? .rightMirrored : .left
        case 0:   return mirrored ? .upMirrored    : .up
        default:  return mirrored ? .downMirrored  : .down   // 180
        }
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "capture.session")
    private let frameQueue = DispatchQueue(label: "capture.frames")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var configured = false

    // sessionQueue-confined source of truth for the active camera (finding #9); `cameraPosition`
    // above is a UI-facing mirror only.
    private var currentPosition: AVCaptureDevice.Position = .back
    // capture.frames-confined mirror of `dtlMode` (finding #9).
    private var dtlModeSnapshot = false

    // motion auto-record state — confined to capture.frames (only ever touched from captureOutput,
    // which always runs serially on that queue).
    private var trigger = LiveSwingTrigger()
    private var frameCounter = 0
    private var visionBusy = false
    // Set by stop() when a recording is torn down before it settled/finished naturally (finding #4);
    // consulted in the fileOutput delegate callback to discard the half-finalized clip.
    private var pendingTeardown = false

    func requestAndConfigure() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if !granted { DispatchQueue.main.async { self.permissionDenied = true }; return }
            self.sessionQueue.async { self.configure() }
        }
    }

    private func configure() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        guard addCameraInput(position: currentPosition) else {
            session.commitConfiguration(); return
        }
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()
        configured = true
        session.startRunning()
    }

    /// Add the wide-angle camera at `position` and pick its highest frame rate. Tracks the input
    /// so it can be swapped when switching cameras. Returns false if that camera is unavailable.
    @discardableResult
    private func addCameraInput(position: AVCaptureDevice.Position) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        currentInput = input

        // Prefer the highest frame rate the camera advertises (240 on the back camera if available;
        // the front camera is typically lower, which just disables the high-speed badge).
        if let best = device.formats.max(by: { fmt, other in maxFps(fmt) < maxFps(other) }) {
            let fps = maxFps(best)
            try? device.lockForConfiguration()
            device.activeFormat = best
            let dur = CMTimeMake(value: 1, timescale: Int32(max(30, fps)))
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.highFps = fps >= 120 }
        }
        return true
    }

    /// Flip between the back and front cameras (ignored mid-recording). Falls back to the current
    /// camera if the target isn't available.
    func switchCamera() {
        sessionQueue.async {
            guard self.configured, !self.movieOutput.isRecording else { return }
            let target = Self.nextPosition(self.currentPosition)
            self.session.beginConfiguration()
            if let cur = self.currentInput { self.session.removeInput(cur); self.currentInput = nil }
            let addedTarget = self.addCameraInput(position: target)
            let addedFallback = addedTarget ? true : self.addCameraInput(position: self.currentPosition)
            let position = addedTarget ? target : self.currentPosition
            self.session.commitConfiguration()
            self.currentPosition = position
            // Both the target camera and falling back to the previous one failed to add — the
            // preview would otherwise just go black/frozen with cameraPosition still silently
            // reporting the (no-longer-active) old value (Medium finding).
            let unavailable = !addedFallback
            DispatchQueue.main.async {
                self.cameraPosition = position
                self.cameraUnavailable = unavailable
            }
        }
    }

    private func maxFps(_ f: AVCaptureDevice.Format) -> Double {
        f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    /// Tear down the session. If a recording is in flight (e.g. the user backed out of a stuck
    /// auto-stop), finalize the movie file properly first instead of yanking the session out from
    /// under it (finding #4) — `fileOutput(_:didFinishRecordingTo:...)` completes the teardown and
    /// discards the half-finalized clip once `stopRecording()`'s completion callback fires.
    func stop() {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.pendingTeardown = true
                self.movieOutput.stopRecording()
            } else if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    // MARK: live pose → framing guide + motion auto-record

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCounter += 1
        // In-flight guard (Medium finding): a fresh VNImageRequestHandler/request/dictionary is
        // otherwise built every 3rd frame, up to ~80x/sec at 240fps -- safe without atomics since
        // captureOutput already runs synchronously to completion on capture.frames before the next
        // callback fires, but this keeps the pose work from ever backing up if that assumption
        // changes (e.g. a future async restructuring).
        guard frameCounter % 3 == 0, !visionBusy else { return }
        visionBusy = true; defer { visionBusy = false }
        let orientation = Self.visionOrientation(rotationAngle: connection.videoRotationAngle, position: currentPosition)
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: orientation, options: [:])
        let req = VNDetectHumanBodyPoseRequest()
        try? handler.perform([req])
        guard let obs = req.results?.first as? VNHumanBodyPoseObservation,
              let pts = try? obs.recognizedPoints(.all) else {
            // No body detected at all this sample (not just a low-confidence wrist) — still feed
            // the trigger a missing sample so a sustained total-tracking loss can still force a
            // stop via `maxMissingFrames`, same as a low-confidence wrist (finding #3).
            DispatchQueue.main.async { self.framingOK = false }
            detectMotion(leadWristY: nil, framingOK: false)
            return
        }
        var joints: [SwingCore.Joint: JointPoint] = [:]
        for (vn, j) in Self.jointMap {
            if let p = pts[vn], p.confidence >= 0.15 {
                joints[j] = JointPoint(x: Double(p.location.x), y: Double(p.location.y), c: Double(p.confidence))
            }
        }
        let guide = Self.framing(joints, dtl: dtlModeSnapshot)
        let leadY = joints[.leftWrist]?.y
        DispatchQueue.main.async { self.framingOK = guide.ok; self.framingReason = guide.reason }
        detectMotion(leadWristY: leadY, framingOK: guide.ok)
    }

    private func detectMotion(leadWristY: Double?, framingOK: Bool) {
        switch trigger.step(y: leadWristY, framingOK: framingOK) {
        case .start: beginRecording()
        case .stop: endRecording()
        case .none: break
        }
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString).mov")
        DispatchQueue.main.async { self.isRecording = true }
        // Funnel the actual AVFoundation mutation onto sessionQueue, the same queue every other
        // session/movieOutput mutation already runs on, so it can't race switchCamera/configure
        // (finding #8).
        sessionQueue.async {
            guard !self.movieOutput.isRecording else { return }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    private func endRecording() {
        sessionQueue.async { if self.movieOutput.isRecording { self.movieOutput.stopRecording() } }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.isRecording = false }
        if pendingTeardown {
            pendingTeardown = false
            try? FileManager.default.removeItem(at: outputFileURL)   // cancelled mid-swing; don't keep a half-finalized clip
            sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
            return
        }
        Task { await self.autoTrim(outputFileURL) }
    }

    /// Auto-trim the recorded clip to the detected swing window (Segmenter), then publish it.
    private func autoTrim(_ url: URL) async {
        guard let pose = try? PoseEstimator.pose(video: url),
              let win = Segmenter.swings(in: pose).first else {
            await MainActor.run { self.lastClipURL = url }; return
        }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            await MainActor.run { self.lastClipURL = url }; return
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("trim-\(UUID().uuidString).mov")
        export.timeRange = CMTimeRange(start: CMTime(seconds: win.start, preferredTimescale: 600),
                                       end: CMTime(seconds: win.end, preferredTimescale: 600))
        let final: URL
        do {
            try await export.export(to: out, as: .mov)
            final = out
            // Trim succeeded; drop the untrimmed original instead of leaking one full-resolution
            // recording into tmp/ on every successful auto-trim (finding #16).
            try? FileManager.default.removeItem(at: url)
        }
        catch { final = url }   // export failed; `url` is the fallback return value, must not delete it
        await MainActor.run { self.lastClipURL = final }
    }

    private static let jointMap: [(VNHumanBodyPoseObservation.JointName, SwingCore.Joint)] = [
        (.nose, .nose), (.neck, .neck), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow), (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.rightHip, .rightHip), (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
    ]
}
