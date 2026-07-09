// Generates a small SYNTHETIC portrait clip (placeholder_swing.mov) used by the DEBUG
// screenshot seed and the simulator overlay test. No real footage — a gradient with a
// moving dot, long enough (3.5s) to cover the replay pose's event times.
//
// Run:  swift make_placeholder_clip.swift
import AVFoundation
import CoreGraphics
import Foundation

let w = 480, h = 854, fps: Int32 = 30, seconds = 3.5
let frames = Int(Double(fps) * seconds)
let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("ios/DivotTests/Fixtures/placeholder_swing.mov")
try? FileManager.default.removeItem(at: out)

let writer = try! AVAssetWriter(outputURL: out, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: w, AVVideoHeightKey: h,
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
    kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let cs = CGColorSpaceCreateDeviceRGB()
for i in 0..<frames {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32ARGB, nil, &pb)
    guard let buf = pb else { continue }
    CVPixelBufferLockBaseAddress(buf, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    let t = Double(i) / Double(frames)
    ctx.setFillColor(CGColor(red: 0.05 + 0.1 * t, green: 0.07, blue: 0.10 + 0.15 * (1 - t), alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    // a dot that rises then falls, like a lead hand through a swing
    let x = Double(w) * (0.5 + 0.12 * cos(t * .pi))
    let y = Double(h) * (0.35 + 0.30 * sin(t * .pi))
    ctx.setFillColor(CGColor(red: 0.35, green: 0.78, blue: 0.72, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: x - 22, y: y - 22, width: 44, height: 44))
    CVPixelBufferUnlockBaseAddress(buf, [])
    while !input.isReadyForMoreMediaData { usleep(2000) }
    adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
print("wrote \(out.path) status=\(writer.status.rawValue) frames=\(frames)")
