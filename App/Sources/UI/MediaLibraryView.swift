import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Browser for the shared media library — add and remove images/videos.
struct MediaLibraryView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Media Library")
                    .font(.headline)
                Spacer()
                Button {
                    pickAndAdd()
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if state.mediaLibrary.assets.isEmpty {
                ContentUnavailableView(
                    "No Media",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Add images or videos to use as shader textures in any effect.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.mediaLibrary.assets) { asset in
                        MediaAssetRow(asset: asset)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 360, height: 420)
    }

    private func pickAndAdd() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = MediaLibrary.imageContentTypes + MediaLibrary.videoContentTypes
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            state.addMediaAsset(from: url)
        }
    }
}

private struct MediaAssetRow: View {
    @EnvironmentObject private var state: AppState
    let asset: MediaAsset

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.displayName)
                    .lineLimit(1)
                Text(asset.kind == .video ? "Video" : "Image")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                state.removeMediaAsset(id: asset.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove from library")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if asset.kind == .image,
           let image = NSImage(contentsOf: state.mediaLibrary.fileURL(for: asset)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                Image(systemName: asset.kind == .video ? "film" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
