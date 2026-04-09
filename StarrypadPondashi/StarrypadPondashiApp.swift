import SwiftUI

@main
struct StarrypadPondashiApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(viewModel.midi)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
