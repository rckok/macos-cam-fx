import Foundation
import Metal

/// A compiled effect plus its loaded file-based texture assets, ready for the
/// render engine's effect chain.
struct RunningEffect {
    let compiled: CompiledEffect
    let textureAssets: EffectTextureAssets

    init(compiled: CompiledEffect, textureAssets: EffectTextureAssets) {
        self.compiled = compiled
        self.textureAssets = textureAssets
    }
}
