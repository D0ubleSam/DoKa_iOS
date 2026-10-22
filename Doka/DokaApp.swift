import SwiftUI

@main
struct DokaApp: App {
    var body: some Scene {
        WindowGroup { CameraScreen().preferredColorScheme(.dark) }
    }
}
