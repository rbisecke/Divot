// Divot design tokens — the single source of truth for color, type, and metrics.
// Colors resolve from the asset catalog (Any/Dark appearances); never hardcode hex in views.
import SwiftUI
import UIKit

extension Color {
    static let bg            = Color("BG")
    static let surface       = Color("Surface")
    static let textPrimary   = Color("TextPrimary")
    static let textMuted     = Color("TextMuted")
    static let hairline      = Color("Hairline")
    static let dataYou       = Color("DataYou")
    static let dataReference = Color("DataReference")
    static let warn          = Color("WarnAmber")
    /// The brand accent (also the AccentColor asset used app-wide by `.tint`).
    static let brand         = Color("AccentColor")
    /// Text/icons placed ON a teal fill. Teal is a light accent, so this is near-black in
    /// BOTH appearances (white-on-teal fails contrast). Use for selected chips + prominent buttons.
    static let onAccent      = Color(red: 0.039, green: 0.051, blue: 0.067)
}

/// Prominent CTA: teal fill with dark (onAccent) label — high contrast, unlike white-on-teal.
/// Disabled state dims to a surface fill + muted label (still passes contrast).
struct DivotPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? Color.onAccent : Color.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background((isEnabled ? Color.brand : Color.surface).opacity(configuration.isPressed ? 0.82 : 1),
                        in: RoundedRectangle(cornerRadius: DivotUI.corner))
            .overlay(RoundedRectangle(cornerRadius: DivotUI.corner)
                .strokeBorder(Color.hairline, lineWidth: isEnabled ? 0 : 1))
    }
}

enum Theme {
    /// Global control appearance: segmented selection uses teal + dark text (was gray + white).
    static func configureAppearance() {
        let teal = UIColor(named: "AccentColor") ?? .systemTeal
        let onAccent = UIColor(red: 0.039, green: 0.051, blue: 0.067, alpha: 1)
        let seg = UISegmentedControl.appearance()
        seg.selectedSegmentTintColor = teal
        seg.setTitleTextAttributes([.foregroundColor: onAccent,
                                    .font: UIFont.systemFont(ofSize: 14, weight: .semibold)], for: .selected)
        seg.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .normal)
    }
}

extension Font {
    /// Wordmark + hero numbers — SF Pro Rounded.
    static func wordmark(_ size: CGFloat = 34, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    /// Metrics — monospaced digits so numbers don't jitter frame to frame.
    static func metric(_ size: CGFloat = 17, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
}

/// Layout constants for a consistent card/surface system.
enum DivotUI {
    static let corner: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let spacing: CGFloat = 12
    static let hairlineWidth: CGFloat = 1
}

extension View {
    /// Standard Divot card: surface fill, hairline border, consistent radius.
    func divotCard() -> some View {
        self.padding(DivotUI.cardPadding)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: DivotUI.corner))
            .overlay(RoundedRectangle(cornerRadius: DivotUI.corner).strokeBorder(Color.hairline, lineWidth: DivotUI.hairlineWidth))
    }
}

/// The "Divot" wordmark.
struct Wordmark: View {
    var size: CGFloat = 34
    var body: some View {
        Text("Divot").font(.wordmark(size)).foregroundStyle(Color.textPrimary)
    }
}
