import Foundation
import CoreGraphics

// C2 — auto ball detection at address via CLASSICAL CV (bright near-circular blob),
// so it runs on macOS/Simulator (unlike neural Vision requests). Manual tap is the app fallback.

public enum BallDetector {

    /// Detect the ball on the address frame. `footRegion` (normalized top-left) narrows the search.
    /// Returns the ball center in normalized top-left coords + a confidence, or nil if not found.
    public static func detectAtAddress(image: CGImage, footRegion: CGRect? = nil) -> (point: CGPoint, confidence: Double)? {
        let fullW = image.width, fullH = image.height
        guard fullW > 0, fullH > 0 else { return nil }

        // Crop to the search region up front when one is given, instead of always allocating and
        // drawing a full-resolution buffer only to then restrict the scan loop to a sub-rect
        // (Medium finding: ~33MB transient allocation on a 4K frame, on every load and re-anchor
        // tap, even though the only call site always had a real region to pass). Falls back to a
        // full-frame scan when no region is given or the crop fails.
        var img = image
        var originX = 0, originY = 0
        if let fr = footRegion {
            let px = max(0, Int((fr.minX * Double(fullW)).rounded(.down)))
            let pyTop = max(0, Int((fr.minY * Double(fullH)).rounded(.down)))
            let pw = min(fullW - px, Int((fr.width * Double(fullW)).rounded(.up)))
            let ph = min(fullH - pyTop, Int((fr.height * Double(fullH)).rounded(.up)))
            // CGImage.cropping(to:) takes its rect in the image's own coordinate space, which is
            // bottom-left-origin -- unlike the rest of this function (and footRegion itself),
            // which treats y as top-left to match the raw pixel buffer read below (row 0 = top).
            // Flip before cropping; use the top-left values again when mapping the result back.
            let pyBottom = fullH - pyTop - ph
            if pw > 0, ph > 0, let cropped = image.cropping(to: CGRect(x: px, y: pyBottom, width: pw, height: ph)) {
                img = cropped
                originX = px; originY = pyTop
            }
        }

        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        let bpr = w * 4
        var data = [UInt8](repeating: 0, count: bpr * h)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

        var sumX = 0.0, sumY = 0.0, count = 0
        var minPX = w, minPY = h, maxPX = 0, maxPY = 0
        for py in 0..<h {
            let row = py * bpr
            for px in 0..<w {
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
        // Buffer row 0 = top for this bitmap context; add the crop's origin back before
        // normalizing against the *full* image so the returned point stays full-frame-relative.
        let cx = (Double(originX) + sumX / Double(count)) / Double(fullW)
        let cy = (Double(originY) + sumY / Double(count)) / Double(fullH)
        let conf = min(1.0, circularity * fill + 0.3)
        return (CGPoint(x: cx, y: cy), conf)
    }
}
