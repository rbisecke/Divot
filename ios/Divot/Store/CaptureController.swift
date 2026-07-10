// Part of Divot (built + tested; see App/DivotApp.swift).
// P2.1 — in-app guided recorder. DEVICE-GATED: compiles on the Simulator but capture
// and live pose only run on a real iPhone (Simulator has no camera / body-pose model).
import Foundation
import CoreGraphics
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
    @Published var dtlMode = false   // false = face-on guide, true = down-the-line (side-on) guide
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    // P2.11 — live phase chip: updated at the same call site as the P2.9 trigger, from the
    // same MotionTrigger.LiveState, so recording state and phase never disagree.
    @Published var livePhase: SwingPhase = .address
    // P2.12 — live skeleton overlay: the exact joints dictionary captureOutput already builds
    // every sampled frame, just also published instead of only used locally.
    @Published var liveJoints: [SwingCore.Joint: JointPoint] = [:]
    // P2.12 — the active format's dimensions, oriented to match liveJoints' own coordinate
    // space (portrait — this app is portrait-locked, and AVCaptureVideoPreviewLayer rotates
    // the camera's native landscape-shaped buffer to match before applying videoGravity).
    // LiveSkeletonOverlay needs this to do real .resizeAspectFill crop math instead of a naive
    // x*width, y*height scale. .zero until the camera reports a format.
    @Published var liveVideoSize: CGSize = .zero

    /// Pure guide selector (testable): DTL uses the side-on check, otherwise the face-on check.
    static func framing(_ joints: [SwingCore.Joint: JointPoint], dtl: Bool) -> (ok: Bool, reason: String) {
        dtl ? FramingGuide.dtlInFrame(joints) : FramingGuide.inFrame(joints)
    }

    /// The camera to switch to from a given position (testable).
    static func nextPosition(_ p: AVCaptureDevice.Position) -> AVCaptureDevice.Position {
        p == .back ? .front : .back
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "capture.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var configured = false

    // P2.9 — motion auto-record state: a trailing lead-wrist speed buffer feeding the
    // causal MotionTrigger.step burst detector (replaces the old positional-span heuristic).
    private var recentSpeeds: [Double] = []
    private var lastWristPoint: JointPoint?
    private var liveState = MotionTrigger.LiveState()
    private var frameCounter = 0
    // P2.11 — live phase state machine, fed by the exact same speed sample as liveState above.
    private var phaseState = LivePhaseDetector.State()

    func requestAndConfigure() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if !granted { DispatchQueue.main.async { self.permissionDenied = true }; return }
            // P3.6 — mic access is best-effort: if it's denied, still configure and record
            // video-only rather than blocking the whole recorder on a permission that's only
            // needed for the experimental audio-contact signal.
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async { self.configure() }
            }
        }
    }

    private func configure() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        guard addCameraInput(position: cameraPosition) else {
            session.commitConfiguration(); return
        }
        addAudioInput()
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "capture.frames"))
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

            // P2.12 — publish the active format's dimensions, swapped to portrait: the raw
            // sensor format is landscape-shaped, but the preview (and this portrait-only app)
            // display it rotated, so the fill-crop math needs the displayed size, not the
            // sensor's raw width/height order.
            let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            let portraitSize = CGSize(width: CGFloat(min(dims.width, dims.height)),
                                      height: CGFloat(max(dims.width, dims.height)))
            DispatchQueue.main.async { self.liveVideoSize = portraitSize }
        }
        return true
    }

    /// P3.6 — add the default microphone so the recorded `.mov` carries an audio track for
    /// `AudioImpactDetector`'s contact-transient check. Best-effort: silently skipped if no
    /// mic is available or the input can't be added (video-only recording still works either
    /// way). Not swapped on camera flip like the video input — there's only ever one mic.
    private func addAudioInput() {
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
    }

    /// Flip between the back and front cameras (ignored mid-recording). Falls back to the current
    /// camera if the target isn't available.
    func switchCamera() {
        sessionQueue.async {
            guard self.configured, !self.movieOutput.isRecording else { return }
            let target = Self.nextPosition(self.cameraPosition)
            self.session.beginConfiguration()
            if let cur = self.currentInput { self.session.removeInput(cur); self.currentInput = nil }
            let position = self.addCameraInput(position: target) ? target
                : (self.addCameraInput(position: self.cameraPosition) ? self.cameraPosition : self.cameraPosition)
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.cameraPosition = position }
        }
    }

    private func maxFps(_ f: AVCaptureDevice.Format) -> Double {
        f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    func stop() { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }

    // MARK: live pose → framing guide + motion auto-record

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCounter += 1
        guard frameCounter % 3 == 0 else { return }   // throttle pose to ~every 3rd frame
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        let req = VNDetectHumanBodyPoseRequest()
        try? handler.perform([req])
        guard let obs = req.results?.first as? VNHumanBodyPoseObservation,
              let pts = try? obs.recognizedPoints(.all) else { return }
        var joints: [SwingCore.Joint: JointPoint] = [:]
        for (vn, j) in Self.jointMap {
            if let p = pts[vn], p.confidence >= 0.15 {
                joints[j] = JointPoint(x: Double(p.location.x), y: Double(p.location.y), c: Double(p.confidence))
            }
        }
        let guide = Self.framing(joints, dtl: dtlMode)
        DispatchQueue.main.async {
            self.framingOK = guide.ok
            self.framingReason = guide.reason
            self.liveJoints = joints   // P2.12 — same throttled cadence as pose sampling above
        }
        detectMotion(leadWrist: joints[.leftWrist], framingOK: guide.ok)
    }

    /// P2.9 — causal speed/burst trigger. Tracks frame-to-frame lead-wrist displacement
    /// magnitude in a trailing buffer and hands each new sample to `MotionTrigger.step`,
    /// which owns the actual start/stop decision; `beginRecording()`/`endRecording()` fire
    /// exactly on the state machine's false→true / true→false `recording` transitions.
    private func detectMotion(leadWrist: JointPoint?, framingOK: Bool) {
        guard let p = leadWrist else { return }
        let speed: Double
        if let last = lastWristPoint {
            let dx = p.x - last.x, dy = p.y - last.y
            speed = (dx * dx + dy * dy).squareRoot()
        } else {
            speed = 0
        }
        lastWristPoint = p

        recentSpeeds.append(speed); if recentSpeeds.count > 12 { recentSpeeds.removeFirst() }
        guard recentSpeeds.count >= 6 else { return }

        // Only allow a fresh recording to start while properly framed (matches the pre-P2.9
        // span heuristic's framingOK gate, dropped by accident in the rewire). Once recording,
        // framing no longer gates anything, so a brief framing loss mid-swing can't touch it.
        guard liveState.recording || framingOK else { return }

        let recentMean = recentSpeeds.reduce(0, +) / Double(recentSpeeds.count)

        let wasRecording = liveState.recording
        liveState = MotionTrigger.step(liveState, speed: speed, recentMean: recentMean)
        if !wasRecording, liveState.recording {
            beginRecording()
        } else if wasRecording, !liveState.recording {
            endRecording()
        }

        // P2.11 — same call site, same LiveState the trigger just produced (not a second
        // independent speed buffer), so "is recording" and "which phase" never disagree.
        phaseState = LivePhaseDetector.step(phaseState, speed: speed, wristY: p.y, trigger: liveState)
        let phase = phaseState.phase
        DispatchQueue.main.async { self.livePhase = phase }
    }

    private func beginRecording() {
        guard !movieOutput.isRecording else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString).mov")
        DispatchQueue.main.async { self.isRecording = true }
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func endRecording() {
        if movieOutput.isRecording { movieOutput.stopRecording() }
    }

    // P2.8 — no auto-trim: hand the raw recorded file straight to lastClipURL. analyzeSession
    // already segments multi-swing clips correctly (the same path a Photos multi-swing import
    // already exercises), so re-running pose estimation here just to keep the first detected
    // window was a redundant on-device Vision pass that silently discarded any extra swing
    // captured in the same take.
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.lastClipURL = outputFileURL
        }
    }

    private static let jointMap: [(VNHumanBodyPoseObservation.JointName, SwingCore.Joint)] = [
        (.nose, .nose), (.neck, .neck), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow), (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.rightHip, .rightHip), (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
    ]
}
