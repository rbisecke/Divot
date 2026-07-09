import XCTest
@testable import SwingCore

final class ModelsTests: XCTestCase {
    func testClubCategoryMapping() {
        XCTAssertEqual(ClubSpec(category: .driver).category, .driver)
        XCTAssertEqual(ClubSpec(category: .wood, number: 3).category, .wood)
        XCTAssertEqual(ClubSpec(category: .iron, number: 7).category, .iron)
        XCTAssertEqual(ClubSpec(category: .wedge, loft: 46).category, .wedge)
        XCTAssertEqual(ClubSpec(category: .wedge, loft: 56).category, .wedge)
    }

    func testMetricsSubscript() {
        var m = SwingMetrics()
        m.headSwayIn = 3.9
        m.tempoRatio = 3.0
        XCTAssertEqual(m["head_sway_in"], 3.9)
        XCTAssertEqual(m["tempo_ratio"], 3.0)
        XCTAssertNil(m["weight_lead_pct_est"])
        XCTAssertNil(m["nonsense"])
    }

    func testCodableRoundTrip() throws {
        var m = SwingMetrics(); m.headRiseCm = -6.4; m.leadArmBendDeg = 24.6
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(SwingMetrics.self, from: data)
        XCTAssertEqual(back.headRiseCm, -6.4)
        XCTAssertEqual(back.leadArmBendDeg, 24.6)
    }
}
