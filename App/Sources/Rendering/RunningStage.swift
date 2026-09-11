import Foundation
import Metal

/// A compiled stage plus its loaded file-based texture assets, ready for the
/// render engine's pass list.
struct RunningStage {
    let compiled: CompiledStage
    let textureAssets: StageTextureAssets
    /// Position in the owning effect (0-based, counting every stage of the
    /// effect, rendered or not). Selects the stage's slice in `uStageTextures`
    /// and is what `uStageIndex` reports to the shader.
    let index: Int
    /// Stage index for each of `compiled.stageReferences`, in slot order;
    /// -1 when the name did not match a stage of the effect.
    let stageRefs: [Int32]

    init(compiled: CompiledStage, textureAssets: StageTextureAssets, index: Int, stageRefs: [Int32]) {
        self.compiled = compiled
        self.textureAssets = textureAssets
        self.index = index
        self.stageRefs = stageRefs
    }
}
