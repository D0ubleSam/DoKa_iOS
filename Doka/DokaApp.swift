import SwiftUI

@main
struct DokaApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || ProcessInfo.processInfo.environment["DOKA_TESTING"] == "1" {
                // Hosted contract tests must not start cameras, networking or Keychain reads.
                EmptyView()
            } else {
                CameraScreen().preferredColorScheme(.dark)
            }
        }
    }
}
