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
        // No title bar of its own: in Basic Mode the camera runs to the top
        // edge under the traffic lights; in Editor Mode the toolbar is the
        // title bar.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}
