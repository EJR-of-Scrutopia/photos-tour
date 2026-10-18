import SwiftUI

// The UI-testing bundle needs a target app; the tour itself drives Apple's Photos app.
@main
struct TourHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Photos tour host")
        }
    }
}
