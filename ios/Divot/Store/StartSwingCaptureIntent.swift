// D6 — App Intent so the Action button (or Shortcuts/Siri) can start a swing capture.
// Actual button trigger is device-only; this compiles + registers the shortcut on the Simulator.
import AppIntents
import Foundation

/// Observed by the UI to open the capture flow when the intent runs.
@MainActor final class CaptureLauncher: ObservableObject {
    static let shared = CaptureLauncher()
    @Published var startCaptureRequested = false
    func requestCapture() { startCaptureRequested = true }
    func consume() { startCaptureRequested = false }
}

struct StartSwingCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Swing Capture"
    static var description = IntentDescription("Open Divot and start recording a swing.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureLauncher.shared.requestCapture()
        return .result()
    }
}

struct DivotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSwingCaptureIntent(),
            phrases: ["Start a swing capture in \(.applicationName)"],
            shortTitle: "Start Capture",
            systemImageName: "record.circle"
        )
    }
}
