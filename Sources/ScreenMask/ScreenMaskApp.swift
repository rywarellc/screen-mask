import SwiftUI

@main
struct ScreenMaskApp: App {
    var body: some Scene {
        WindowGroup("Screen Mask") {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
