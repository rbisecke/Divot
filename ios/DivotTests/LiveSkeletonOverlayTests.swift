import XCTest
import UIKit
import SwiftUI
@testable import Divot
import SwingCore

/// P2.12 — coverage for `LiveSkeletonOverlay.mapPoint`, the pure fill-crop transform that
/// replaces a naive `x * width, y * height` scale. This is the single most important thing to
/// get right in this unit (there's no device available to verify alignment visually), so these
/// cases are chosen to pin down the actual `.resizeAspectFill` crop math rather than just
/// exercise the function.
final class LiveSkeletonOverlayTests: XCTestCase {

    private let accuracy: CGFloat = 0.01

    // MARK: matching aspect ratios (identity-ish scale, no crop)

    func testMapPointMatchingAspectRatioIsIdentityScale() {
        let videoSize = CGSize(width: 400, height: 800)
        let viewSize = CGSize(width: 400, height: 800)

        let center = LiveSkeletonOverlay.mapPoint(CGPoint(x: 0.5, y: 0.5), videoSize: videoSize, viewSize: viewSize)
        XCTAssertEqual(center.x, 200, accuracy: accuracy)
        XCTAssertEqual(center.y, 400, accuracy: accuracy)

        // Vision's bottom-left origin: (0, 0) is the bottom-left of the frame, which is the
        // view's bottom-left in top-left screen coordinates (x unchanged, y flipped to max).
        let bottomLeft = LiveSkeletonOverlay.mapPoint(CGPoint(x: 0, y: 0), videoSize: videoSize, viewSize: viewSize)
        XCTAssertEqual(bottomLeft.x, 0, accuracy: accuracy)
        XCTAssertEqual(bottomLeft.y, 800, accuracy: accuracy)

        // (0, 1) is Vision's top-left, which is the view's top-left (y = 0).
        let topLeft = LiveSkeletonOverlay.mapPoint(CGPoint(x: 0, y: 1), videoSize: videoSize, viewSize: viewSize)
        XCTAssertEqual(topLeft.x, 0, accuracy: accuracy)
        XCTAssertEqual(topLeft.y, 0, accuracy: accuracy)
    }

    // MARK: video wider (relatively) than the view — the portrait-video-in-portrait-view case
    // this app actually hits: a camera sensor's native aspect ratio (e.g. 1080x1920, 0.5625) is
    // usually less extreme than an iPhone screen's (e.g. 390x844, ~0.462), so the video is
    // "wider" than the view for a given height — .resizeAspectFill matches heights and crops
    // the left/right edges.

    func testMapPointWiderVideoCropsLeftAndRight() {
        let videoSize = CGSize(width: 1080, height: 1920)
        let viewSize = CGSize(width: 390, height: 844)

        // Center must always land at the view's center — that's what "centered crop" means.
        let center = LiveSkeletonOverlay.mapPoint(CGPoint(x: 0.5, y: 0.5), videoSize: videoSize, viewSize: viewSize)
        XCTAssertEqual(center.x, viewSize.width / 2, accuracy: 1)
        XCTAssertEqual(center.y, viewSize.height / 2, accuracy: 1)

        // The full vertical extent of the video must exactly cover the view's height (matched
        // axis, no vertical crop): top and bottom edges land exactly on the view's bounds.
        let top = LiveSkeletonOverlay.mapPoint(CGPoint(x: 0.5, y: 1), videoSize: videoSize, viewSize: viewSize)
        let bottom = LiveSkeletonOverlay.mapPoint(CGPoint(x: 0.5, y: 0), videoSize: videoSize, viewSize: viewSize)
        XCTAssertEqual(top.y, 0, accuracy: 1)
        XCTAssertEqual(bottom.y, viewSize.height, accuracy: 1)

        // The video's left/right edges fall outside the view's bounds on both sides (cropped),
        // symmetrically around the center.
        let left = LiveSkeletonOverlay.mapPoint(CGPoint(x: 0, y: 0.5), videoSize: videoSize, viewSize: viewSize)
        let right = LiveSkeletonOverlay.mapPoint(CGPoint(x: 1, y: 0.5), videoSize: videoSize, viewSize: viewSize)
        XCTAssertLessThan(left.x, 0, "left edge of a relatively-wider video must be cropped off-view")
        XCTAssertGreaterThan(right.x, viewSize.width, "right edge of a relatively-wider video must be cropped off-view")
        XCTAssertEqual(0 - left.x, right.x - viewSize.width, accuracy: 1, "crop must be symmetric")
    }

    // MARK: video taller (relatively) than the view — e.g. a narrow high-speed format in a
    // shorter view — matches widths and crops the top/bottom edges instead.

    func testMapPointTallerVideoCropsTopAndBottom() {
        let videoSize = CGSize(width: 1080, height: 2400)
        let viewSize = CGSize(width: 390, height: 700)

        let center = LiveSkeletonOverlay.mapPoint(CGPoint(x: 0.5, y: 0.5), videoSize: videoSize, viewSize: viewSize)
        XCTAssertEqual(center.x, viewSize.width / 2, accuracy: 1)
        XCTAssertEqual(center.y, viewSize.height / 2, accuracy: 1)

        // Matched axis this time is width: left/right edges land exactly on the view's bounds.
        let left = LiveSkeletonOverlay.mapPoint(CGPoint(x: 0, y: 0.5), videoSize: videoSize, viewSize: viewSize)
        let right = LiveSkeletonOverlay.mapPoint(CGPoint(x: 1, y: 0.5), videoSize: videoSize, viewSize: viewSize)
        XCTAssertEqual(left.x, 0, accuracy: 1)
        XCTAssertEqual(right.x, viewSize.width, accuracy: 1)

        // Top/bottom are cropped off, symmetrically.
        let top = LiveSkeletonOverlay.mapPoint(CGPoint(x: 0.5, y: 1), videoSize: videoSize, viewSize: viewSize)
        let bottom = LiveSkeletonOverlay.mapPoint(CGPoint(x: 0.5, y: 0), videoSize: videoSize, viewSize: viewSize)
        XCTAssertLessThan(top.y, 0, "top edge of a relatively-taller video must be cropped off-view")
        XCTAssertGreaterThan(bottom.y, viewSize.height, "bottom edge of a relatively-taller video must be cropped off-view")
        XCTAssertEqual(0 - top.y, bottom.y - viewSize.height, accuracy: 1, "crop must be symmetric")
    }

    // MARK: degenerate input

    func testMapPointZeroVideoSizeReturnsZeroRatherThanDividingByZero() {
        let p = LiveSkeletonOverlay.mapPoint(CGPoint(x: 0.5, y: 0.5), videoSize: .zero, viewSize: CGSize(width: 400, height: 800))
        XCTAssertEqual(p, .zero)
    }

    // MARK: view instantiation with partial/missing joints doesn't crash

    func testOverlayRendersWithoutCrashingOnPartialJoints() {
        let joints: [Joint: JointPoint] = [
            .leftShoulder: JointPoint(x: 0.4, y: 0.6, c: 0.9),
            .rightWrist: JointPoint(x: 0.7, y: 0.3, c: 0.9),
            // Deliberately missing the rest of Skeleton.edges' joints/dots.
        ]
        let view = LiveSkeletonOverlay(joints: joints, videoSize: CGSize(width: 1080, height: 1920))
        let host = UIHostingController(rootView: view.frame(width: 390, height: 844))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        XCTAssertNotNil(host.view)
    }

    func testOverlayRendersWithoutCrashingOnEmptyJointsAndUnknownVideoSize() {
        let view = LiveSkeletonOverlay(joints: [:], videoSize: .zero)
        let host = UIHostingController(rootView: view.frame(width: 390, height: 844))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        XCTAssertNotNil(host.view)
    }
}
