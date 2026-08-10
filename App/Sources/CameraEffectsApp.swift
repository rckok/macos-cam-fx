import SwiftUI

@main
struct CameraEffectsApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
    }
}
