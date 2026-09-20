import AppKit
import SwiftUI

/// The background gallery, unfolded from the camera menu onto glass: a grid
/// of the images that can go behind the person, the one in use marked, with
/// a button to add more and a delete control on each.
struct BackgroundGalleryPane: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var library: BackgroundLibrary

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Background")
                    .font(.headline)
                Spacer()
                Button {
                    pickAndAdd()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add images")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // Hugs its content while it fits, and scrolls once it does not.
            ViewThatFits(in: .vertical) {
                gallery
                ScrollView {
                    gallery
                }
            }
        }
    }

    @ViewBuilder
    private var gallery: some View {
        if library.images.isEmpty {
            Text("Add an image to put behind you. Everything outside the person is replaced by it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(library.images) { image in
                    BackgroundCell(
                        thumbnail: library.thumbnail(for: image.id),
                        name: image.name,
                        isSelected: state.backgroundImageID == image.id,
                        onSelect: { state.backgroundImageID = image.id },
                        onDelete: { state.removeBackground(id: image.id) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
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

/// One gallery image at the camera's 16:9. Clicking picks it; the pick is
/// marked with a tick and an accent border; hovering reveals its delete
/// button, which the context menu also offers.
private struct BackgroundCell: View {
    let thumbnail: NSImage?
    let name: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

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
        .help(name)
        // A sibling of the select button, not part of its label, so each
        // click lands on exactly one of them.
        .overlay(alignment: .topTrailing) {
            if isHovered {
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
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let thumbnail {
            Color.clear
                .overlay(
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                )
        } else {
            ZStack {
                Color.primary.opacity(0.1)
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
