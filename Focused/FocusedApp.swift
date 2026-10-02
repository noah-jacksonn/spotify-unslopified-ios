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
    }
}
