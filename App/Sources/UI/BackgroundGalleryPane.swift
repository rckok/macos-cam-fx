import AppKit
import SwiftUI

/// The background gallery, unfolded from the camera menu onto glass: how
/// carefully the person is cut out, then a grid of the images that can go
/// behind them — led by a None tile that leaves the camera as it is, and
/// ending in a tile that adds more — with a delete control on each image.
struct BackgroundGalleryPane: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var library: BackgroundLibrary
    /// Opened from a menu item, the pane has no button of its own on the bar
    /// to toggle it away, so it carries a close button.
    let onClose: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Background")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // Hugs its content while it fits, and scrolls once it does not.
            ViewThatFits(in: .vertical) {
                content
                ScrollView {
                    content
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            qualityControl
            gallery
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    /// One switch for the person matte everywhere it is used, not only under
    /// the background: an effect sampling `uPersonMatte` gets the same cut.
    private var qualityControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("High-accuracy matte", isOn: Binding(
                get: { state.personMatteQuality == .accurate },
                set: { state.personMatteQuality = $0 ? .accurate : .balanced }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            Text("Cleaner edges around hair and shoulders, at a higher cost per frame. Applies to the background and to every effect that uses the person matte.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gallery: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            BackgroundTile(
                content: .none,
                isSelected: state.backgroundImageID == nil,
                onSelect: { state.backgroundImageID = nil },
                onDelete: nil
            )
            ForEach(library.images) { image in
                BackgroundTile(
                    content: .image(library.thumbnail(for: image.id), name: image.name),
                    isSelected: state.backgroundImageID == image.id,
                    onSelect: { state.backgroundImageID = image.id },
                    onDelete: { state.removeBackground(id: image.id) }
                )
            }
            AddBackgroundTile(action: pickAndAdd)
        }
    }

    private func pickAndAdd() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = MediaLibrary.imageContentTypes
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                state.addBackground(from: url)
            }
        }
    }
}

/// The gallery's last tile, which adds images from disk. Same shape as the
/// others, so the grid reads as one set.
private struct AddBackgroundTile: View {
    let action: () -> Void

    @State private var isHovered = false

    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.primary.opacity(isHovered ? 0.16 : 0.08)
                VStack(spacing: 2) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                    Text("Add")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    Color.white.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Add images")
    }
}

/// One gallery tile at the camera's 16:9. Clicking picks it; the pick is
/// marked with a tick and an accent border. Image tiles reveal a delete
/// button on hover, which their context menu also offers; the None tile has
/// nothing to delete.
private struct BackgroundTile: View {
    enum Content {
        case none
        case image(NSImage?, name: String)
    }

    let content: Content
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    @State private var isHovered = false

    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        Button(action: onSelect) {
            picture
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(
                        isSelected ? Color.accentColor : Color.white.opacity(0.15),
                        lineWidth: isSelected ? 2 : 1
                    )
                )
                .overlay(alignment: .bottomLeading) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(5)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(helpText)
        // A sibling of the select button, not part of its label, so each
        // click lands on exactly one of them.
        .overlay(alignment: .topTrailing) {
            if isHovered, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Delete image")
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            if let onDelete {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }

    private var helpText: String {
        switch content {
        case .none: return "No background — the camera as it is"
        case .image(_, let name): return name
        }
    }

    @ViewBuilder
    private var picture: some View {
        switch content {
        case .none:
            ZStack {
                Color.primary.opacity(0.1)
                VStack(spacing: 2) {
                    Image(systemName: "nosign")
                        .foregroundStyle(.secondary)
                    Text("None")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .image(let thumbnail?, _):
            Color.clear
                .overlay(
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                )
        case .image(nil, _):
            ZStack {
                Color.primary.opacity(0.1)
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
