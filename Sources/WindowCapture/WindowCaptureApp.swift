import SwiftUI

@main
struct WindowCaptureApp: App {
    @State private var model = AppModel()

    init() {
        DebugCommands.runIfRequested()
    }

    var body: some Scene {
        Window("Window Capture", id: "main") {
            MainView()
                .environment(model)
        }
        .defaultSize(width: 1040, height: 800)

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.session.isRunning ? "record.circle" : "camera.viewfinder")
        }
    }
}
