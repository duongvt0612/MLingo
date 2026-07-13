import MLingoCore
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct MLingoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
