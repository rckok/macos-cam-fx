import Foundation
import Metal

/// Maps a stage's sampler bindings to textures from the shared media library.
final class StageTextureAssets {
    private let bindings: [StageTextureBinding]
    private let cache: MediaTextureCache

    init(bindings: [StageTextureBinding], cache: MediaTextureCache) {
        self.bindings = bindings
        self.cache = cache
    }

    func texture(named samplerName: String) -> MTLTexture? {
        guard let mediaID = bindings.first(where: { $0.name == samplerName })?.mediaID else {
            return nil
        }
        return cache.texture(forMediaID: mediaID)
    }

    func advanceVideoFrames() {
        cache.advanceVideoFrames()
    }
}
