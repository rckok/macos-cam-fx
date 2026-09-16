import SwiftUI

/// Right-hand column: parameter controls for the selected effect or stage.
struct InspectorPanel<Content: View>: View {
    var title: String = "Inspector"
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // An inset rather than a row above the scroll view, so the controls
        // travel under the glass instead of stopping at a hard edge.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .glassChrome()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
