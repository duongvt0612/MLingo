import SwiftUI

struct MLingoCommands: Commands {
    let viewModel: MLingoViewModel

    var body: some Commands {
        CommandMenu("Translation") {
            Button("Start Translation") {
                viewModel.start()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!viewModel.commandAvailability.canStartTranslation)

            Button("Stop") {
                viewModel.stopCurrentActivity()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!viewModel.commandAvailability.canStop)

            Divider()

            Button(
                viewModel.overlayPresentationState.isVisible
                    ? "Hide Overlay"
                    : "Show Overlay"
            ) {
                viewModel.toggleOverlayVisibility()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!viewModel.commandAvailability.canToggleOverlay)
        }
    }
}
