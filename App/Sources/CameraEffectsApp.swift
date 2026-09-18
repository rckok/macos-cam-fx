import SwiftUI

@main
struct CameraEffectsApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 720, minHeight: 480)
        }
        // No title bar or toolbar: the camera runs to the top edge under the
        // traffic lights in both modes. The window's frame is remembered by
        // AppKit through the autosave name ContentView gives it.
        .windowStyle(.hiddenTitleBar)
    }
}
