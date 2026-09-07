import Combine
import Foundation
import SwiftUI

/// What the sidebar currently points at. The effect that owns the selection is
/// the one being rendered, so selecting a stage also activates its effect.
enum EffectSelection: Hashable {
    case effect(String)
    case stage(String)
}

/// Central coordinator: wires capture -> render engine -> preview/virtual
/// camera, and orchestrates stage compilation and persistence.
@MainActor
final class AppState: ObservableObject {

    let store: EffectStore
    let mediaLibrary: MediaLibrary
    let capture: CaptureManager
    let extensionManager: ExtensionManager
    let sink: VirtualCameraSink
    let engine: RenderEngine

    @Published private(set) var selection: EffectSelection?
    @Published var viewMode: ViewMode = .basic {
        didSet {
            guard viewMode != oldValue else { return }
            if viewMode == .basic, case .stage(let stageID) = selection {
                selection = store.effect(containing: stageID).map { .effect($0.id) }
            }
            store.config.viewMode = viewMode
            store.saveConfigSoon()
        }
    }
    @Published var historyDepth: Int {
        didSet {
            engine.setHistoryDepth(historyDepth)
            store.config.historyDepth = historyDepth
            store.saveConfigSoon()
        }
    }
    @Published var flipHorizontal: Bool {
        didSet {
            engine.setFlipHorizontal(flipHorizontal)
            store.config.flipHorizontal = flipHorizontal
            store.saveConfigSoon()
        }
    }

    private var compileTasks: [String: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// The single effect currently rendering: the selected one, or the one that
    /// owns the selected stage.
    var activeEffectID: String? {
        switch selection {
        case .effect(let id): return store.effect(id: id)?.id
        case .stage(let id): return store.effect(containing: id)?.id
        case nil: return nil
        }
    }

    var activeEffect: Effect? {
        activeEffectID.flatMap { store.effect(id: $0) }
    }

    var selectedStage: Stage? {
        guard case .stage(let id) = selection else { return nil }
        return store.stage(id: id)
    }

    init() {
        let engine = try! RenderEngine()
        self.engine = engine
        self.store = EffectStore()
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CameraEffects", isDirectory: true)
        self.mediaLibrary = MediaLibrary(appSupportRoot: appSupport)
        self.capture = CaptureManager()
        self.extensionManager = ExtensionManager()
        self.sink = VirtualCameraSink()
        self.historyDepth = 16
        self.flipHorizontal = true

        mediaLibrary.reloadGPUCache(device: engine.device)

        historyDepth = store.config.historyDepth
        flipHorizontal = store.config.flipHorizontal
        viewMode = store.config.viewMode
        // Property observers do not fire for assignments inside an initializer.
        engine.setHistoryDepth(historyDepth)
        engine.setFlipHorizontal(flipHorizontal)
        capture.selectedDeviceID = store.config.selectedDeviceID

        capture.frameHandler = { [engine] pixelBuffer, timestamp in
            engine.process(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }
        engine.outputHandler = { [sink] pixelBuffer, timestamp in
            sink.send(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }

        capture.$selectedDeviceID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] deviceID in
                guard let self else { return }
                self.store.config.selectedDeviceID = deviceID
                self.store.saveConfigSoon()
            }
            .store(in: &cancellables)

        store.externalChange
            .sink { [weak self] stage in
                self?.scheduleCompile(stage, debounce: false)
            }
            .store(in: &cancellables)

        // Streaming needs no user action: the sink follows the extension.
        extensionManager.$status
            .map { $0 == .installed }
            .removeDuplicates()
            .sink { [virtualCamera = sink] isInstalled in
                virtualCamera.enabled = isInstalled
            }
            .store(in: &cancellables)

        let restored = store.config.activeEffectID.flatMap { store.effect(id: $0) } ?? store.effects.first
        selection = restored.map { .effect($0.id) }
        capture.start()

        for stage in store.stages {
            scheduleCompile(stage, debounce: false)
        }
    }

    // MARK: Selection

    func select(_ newSelection: EffectSelection?) {
        guard selection != newSelection else { return }
        let previousEffectID = activeEffectID
        selection = newSelection
        guard activeEffectID != previousEffectID else { return }
        store.config.activeEffectID = activeEffectID
        store.saveConfigSoon()
        rebuildChain()
    }

    /// Falls back to the first effect when the selection points at something
    /// that no longer exists.
    private func validateSelection() {
        switch selection {
        case .effect(let id) where store.effect(id: id) != nil:
            return
        case .stage(let id) where store.stage(id: id) != nil && store.effect(containing: id) != nil:
            return
        default:
            selection = store.effects.first.map { .effect($0.id) }
            store.config.activeEffectID = activeEffectID
            store.saveConfigSoon()
        }
    }

    // MARK: Render chain

    /// Only the active effect renders, and it always starts from the current
    /// camera frame — nothing carries over between effects.
    func rebuildChain() {
        guard let cache = mediaLibrary.textureCache else { return }

        // Shadowing is scoped to one effect, and Editor Mode lists the stages
        // of every effect, so resolve the chain for all of them.
        var rendered = Set<String>()
        var activeChain: [(stage: Stage, compiled: CompiledStage)] = []
        for effect in store.effects {
            let chain = renderedStages(of: effect)
            rendered.formUnion(chain.map(\.stage.id))
            if effect.id == activeEffectID {
                activeChain = chain
            }
        }

        for stage in store.stages {
            let shadowed = stage.compiled != nil && !rendered.contains(stage.id)
            if stage.isShadowed != shadowed {
                stage.isShadowed = shadowed
            }
        }

        engine.setStages(activeChain.map { entry in
            RunningStage(
                compiled: entry.compiled,
                textureAssets: StageTextureAssets(bindings: entry.stage.textureBindings, cache: cache)
            )
        })
    }

    /// The compiled stages of `effect` that reach the output. A stage that
    /// never samples `uPrev` overwrites the whole frame, so everything before
    /// it in the same effect is invisible work; the chain starts at the last
    /// such stage.
    private func renderedStages(of effect: Effect) -> [(stage: Stage, compiled: CompiledStage)] {
        let runnable = effect.stageIDs.compactMap { stageID -> (stage: Stage, compiled: CompiledStage)? in
            guard let stage = store.stage(id: stageID), let compiled = stage.compiled else { return nil }
            return (stage, compiled)
        }
        let start = runnable.lastIndex { !$0.compiled.reflection.samplesPreviousOutput } ?? runnable.startIndex
        return Array(runnable[start...])
    }

    // MARK: Mutations — stages

    func addStage(toEffect effectID: String? = nil) {
        guard let target = effectID ?? activeEffectID ?? store.effects.first?.id,
              let stage = store.addStage(named: "New Stage", toEffect: target)
        else { return }
        select(.stage(stage.id))
        scheduleCompile(stage, debounce: false)
    }

    func duplicateStage(_ stage: Stage) {
        guard let copy = store.duplicateStage(stage) else { return }
        select(.stage(copy.id))
        scheduleCompile(copy, debounce: false)
    }

    func removeStage(_ stage: Stage) {
        compileTasks[stage.id]?.cancel()
        compileTasks[stage.id] = nil
        let owner = store.effect(containing: stage.id)
        store.removeStage(stage)
        if selection == .stage(stage.id) {
            selection = owner.map { .effect($0.id) }
        }
        validateSelection()
        rebuildChain()
    }

    func moveStage(_ stageID: String, toEffect targetEffectID: String, placement: StagePlacement) {
        store.moveStage(stageID, toEffect: targetEffectID, placement: placement)
        rebuildChain()
    }

    // MARK: Mutations — effects

    /// New effects start with one stage so there is something to edit.
    func addEffect() {
        let effect = store.addEffect()
        if let stage = store.addStage(named: "New Stage", toEffect: effect.id) {
            select(.stage(stage.id))
            scheduleCompile(stage, debounce: false)
        } else {
            select(.effect(effect.id))
        }
    }

    func renameEffect(_ effectID: String, to name: String) {
        store.renameEffect(id: effectID, to: name)
    }

    /// Effect order is presentation only — every effect is its own pipeline —
    /// so the render chain is unaffected.
    func moveEffect(_ effectID: String, before beforeEffectID: String?) {
        store.moveEffect(effectID, before: beforeEffectID)
    }

    func removeEffect(_ effect: Effect, deleteStages: Bool, moveStagesTo targetEffectID: String? = nil) {
        let removedStageIDs = Set(effect.stageIDs)
        store.removeEffect(id: effect.id, deleteStages: deleteStages, moveStagesTo: targetEffectID)

        if deleteStages {
            for stageID in removedStageIDs {
                compileTasks[stageID]?.cancel()
                compileTasks[stageID] = nil
            }
        }

        validateSelection()
        rebuildChain()
    }

    func parametersChanged(_ stage: Stage) {
        stage.applyParameters()
        store.persist(stage: stage)
    }

    // MARK: Media library

    func addMediaAsset(from url: URL) {
        do {
            _ = try mediaLibrary.addAsset(from: url)
            mediaLibrary.reloadGPUCache(device: engine.device)
            rebuildChain()
        } catch {
            NSLog("Failed to add media asset: \(error)")
        }
    }

    func removeMediaAsset(id: String) {
        for stage in store.stages {
            var changed = false
            for index in stage.textureBindings.indices where stage.textureBindings[index].mediaID == id {
                stage.textureBindings[index].mediaID = nil
                changed = true
            }
            if changed {
                store.persist(stage: stage)
            }
        }
        mediaLibrary.removeAsset(id: id)
        mediaLibrary.reloadGPUCache(device: engine.device)
        rebuildChain()
    }

    func assignMedia(_ mediaID: String?, toSampler samplerName: String, in stage: Stage) {
        guard let index = stage.textureBindings.firstIndex(where: { $0.name == samplerName }) else { return }
        stage.textureBindings[index].mediaID = mediaID
        store.persist(stage: stage)
        rebuildChain()
    }

    // MARK: Compilation

    func scheduleCompile(_ stage: Stage, debounce: Bool) {
        compileTasks[stage.id]?.cancel()
        compileTasks[stage.id] = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.compile(stage)
        }
    }

    private func compile(_ stage: Stage) async {
        let source = stage.source
        let device = engine.device
        let vertexFunction = engine.vertexFunction

        let result: Result<CompiledStage, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let output = try ShaderCompiler.compile(userSource: source)
                let compiled = try CompiledStage(device: device, vertexFunction: vertexFunction, output: output)
                return .success(compiled)
            } catch {
                return .failure(error)
            }
        }.value

        // Hop off the current SwiftUI turn. `Task { @MainActor in }` can run
        // inline while a view is still updating and then trip the publish warning.
        DispatchQueue.main.async { [weak self, weak stage] in
            guard let self, let stage else { return }
            guard stage.source == source else { return }

            switch result {
            case .success(let compiled):
                stage.compiled = compiled
                stage.syncParameters(with: compiled.reflection)
                stage.syncTextureBindings(with: compiled.reflection)
                stage.applyParameters()
                stage.diagnostics = compiled.warnings
                rebuildChain()
                store.stageContentsDidChange()
                store.persist(stage: stage)
            case .failure(let error):
                if let compileError = error as? ShaderCompileError {
                    stage.diagnostics = compileError.diagnostics
                } else {
                    stage.diagnostics = [ShaderDiagnostic(line: nil, message: error.localizedDescription)]
                }
            }
        }
    }
}
