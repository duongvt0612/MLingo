import MLingoCore
import SwiftUI

@main
struct MLingoApp: App {
    @State private var viewModel = MLingoViewModel.live()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView(viewModel: viewModel)
                .frame(width: 520, height: 560)
        }
    }
}
