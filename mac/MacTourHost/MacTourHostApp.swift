import SwiftUI

// The UI-testing bundle needs a target app; the tour itself drives Apple's Photos app.
@main
struct MacTourHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Mac Photos tour host")
        }
    }
}
