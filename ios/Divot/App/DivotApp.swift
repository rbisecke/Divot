// Divot — on-device SwiftUI app over the validated SwingCore engine.
// Builds against the iOS SDK and is tested via ios/project.yml (XcodeGen).
// See ios/Divot/SETUP.md for build, run, and validation.

import SwiftUI
import SwiftData
import TipKit

@main
struct DivotApp: App {
    init() {
        Theme.configureAppearance()
        // Tips are real-user discovery UI; skip them in seeded UI-test / screenshot runs so
        // transient popovers don't clutter the accessibility audit or the tour.
        if !ProcessInfo.processInfo.arguments.contains("-seedSampleData") {
            try? Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationDefault)])
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [SavedSession.self, ShotData.self, BagClub.self, MLM2ProOverride.self])
    }
}
