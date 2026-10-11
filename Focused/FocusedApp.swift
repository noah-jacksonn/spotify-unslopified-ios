import SwiftUI

@main
struct FocusedApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in
                    model.music?.handle(url: url)
                }
        }
        // The sleep timer's pause and token refreshes finishing while the
        // app is in the background.
        .backgroundTask(.urlSession(SleepTimer.sessionID)) {
            await model.sleepTimer.handleBackgroundEvents()
        }
    }
}
