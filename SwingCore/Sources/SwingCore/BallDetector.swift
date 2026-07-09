import Foundation
import CoreGraphics

// C2 — auto ball detection at address via CLASSICAL CV (bright near-circular blob),
// so it runs on macOS/Simulator (unlike neural Vision requests). Manual tap is the app fallback.

public enum BallDetector {

    /// Detect the ball on the address frame. `footRegion` (normalized top-left) narrows the search.
    /// Returns the ball center in normalized top-left coords + a confidence, or nil if not found.
    public static func detectAtAddress(image: CGImage, footRegion: CGRect? = nil) -> (point: CGPoint, confidence: Double)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let bpr = w * 4
        var data = [UInt8](repeating: 0, count: bpr * h)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var x0 = 0, y0 = 0, x1 = w, y1 = h
        if let fr = footRegion {
            let a = Int(fr.minX * Double(w)), b = Int(fr.maxX * Double(w))
            let c = Int(fr.minY * Double(h)), d = Int(fr.maxY * Double(h))
            if b > a, d > c { x0 = max(0, a); x1 = min(w, b); y0 = max(0, c); y1 = min(h, d) }
        }

        var sumX = 0.0, sumY = 0.0, count = 0
        var minPX = w, minPY = h, maxPX = 0, maxPY = 0
        for py in y0..<y1 {
            let row = py * bpr
            for px in x0..<x1 {
                let o = row + px * 4
                let luma = (0.299 * Double(data[o]) + 0.587 * Double(data[o+1]) + 0.114 * Double(data[o+2])) / 255.0
                if luma > 0.72 {
                    sumX += Double(px); sumY += Double(py); count += 1
                    if px < minPX { minPX = px }; if px > maxPX { maxPX = px }
                    if py < minPY { minPY = py }; if py > maxPY { maxPY = py }
                }
            }
        }
        guard count >= 8 else { return nil }
        let bw = Double(maxPX - minPX + 1), bh = Double(maxPY - minPY + 1)
        let circularity = min(bw, bh) / max(bw, bh)                 // 1 = square/round
        let fill = Double(count) / max(bw * bh, 1)                  // disc ≈ 0.78; a line ≈ low
        guard circularity > 0.5, fill > 0.4 else { return nil }
        // Buffer row 0 = top for this bitmap context → normalized top-left directly.
        let cx = (sumX / Double(count)) / Double(w)
        let cy = (sumY / Double(count)) / Double(h)
        let conf = min(1.0, circularity * fill + 0.3)
        return (CGPoint(x: cx, y: cy), conf)
    }
}
