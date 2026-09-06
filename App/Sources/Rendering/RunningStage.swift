import Foundation
import Metal

/// A compiled stage plus its loaded file-based texture assets, ready for the
/// render engine's pass list.
struct RunningStage {
    let compiled: CompiledStage
    let textureAssets: StageTextureAssets

    init(compiled: CompiledStage, textureAssets: StageTextureAssets) {
        self.compiled = compiled
        self.textureAssets = textureAssets
    }
}
