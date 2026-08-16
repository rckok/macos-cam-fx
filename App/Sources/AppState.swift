import Combine
import Foundation
import SwiftUI

/// Central coordinator: wires capture -> render engine -> preview/virtual
/// camera, and orchestrates effect compilation and persistence.
@MainActor
final class AppState: ObservableObject {

    let store: EffectStore
    let mediaLibrary: MediaLibrary
    let capture: CaptureManager
    let extensionManager: ExtensionManager
    let sink: VirtualCameraSink
    let engine: RenderEngine

    @Published var selectedEffectID: String?
    @Published var virtualCameraEnabled = false {
        didSet { sink.enabled = virtualCameraEnabled }
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

    var selectedEffect: Effect? {
        store.effects.first { $0.id == selectedEffectID }
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
            .sink { [weak self] effect in
                self?.scheduleCompile(effect, debounce: false)
            }
            .store(in: &cancellables)

        selectedEffectID = store.effects.first?.id
        capture.start()

        for effect in store.effects {
            scheduleCompile(effect, debounce: false)
        }
    }

    // MARK: Effect chain

    func rebuildChain() {
        guard let cache = mediaLibrary.textureCache else { return }
        let chain = store.groups
            .filter(\.enabled)
            .flatMap { group in
                group.effectIDs.compactMap { id -> RunningEffect? in
                    guard let effect = store.effect(id: id),
                          effect.enabled,
                          let compiled = effect.compiled
                    else { return nil }
                    return RunningEffect(
                        compiled: compiled,
                        textureAssets: EffectTextureAssets(bindings: effect.textureBindings, cache: cache)
                    )
                }
            }
        engine.setEffects(chain)
    }

    func addEffect(toGroup groupID: String? = nil) {
        let resolvedGroupID = groupID
            ?? store.group(containing: selectedEffectID ?? "")?.id
            ?? store.groups.first?.id
        guard let effect = store.addEffect(named: "New Effect", toGroup: resolvedGroupID) else { return }
        selectedEffectID = effect.id
        scheduleCompile(effect, debounce: false)
    }

    func addGroup() {
        _ = store.addGroup()
    }

    func removeEffect(_ effect: Effect) {
        compileTasks[effect.id]?.cancel()
        compileTasks[effect.id] = nil
        store.removeEffect(effect)
        if selectedEffectID == effect.id {
            selectedEffectID = store.effects.first?.id
        }
        rebuildChain()
    }

    func moveEffects(inGroup groupID: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        store.moveEffects(inGroup: groupID, fromOffsets: source, toOffset: destination)
        rebuildChain()
    }

    func moveEffect(_ effectID: String, toGroup targetGroupID: String, beforeEffectID: String? = nil) {
        store.moveEffect(effectID, toGroup: targetGroupID, beforeEffectID: beforeEffectID)
        rebuildChain()
    }

    func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        store.moveGroups(fromOffsets: source, toOffset: destination)
        rebuildChain()
    }

    func setGroupEnabled(_ groupID: String, enabled: Bool) {
        store.setGroupEnabled(id: groupID, enabled: enabled)
        rebuildChain()
    }

    func renameGroup(_ groupID: String, to name: String) {
        store.renameGroup(id: groupID, to: name)
    }

    func removeGroup(_ group: EffectGroup, deleteEffects: Bool, moveEffectsTo targetGroupID: String? = nil) {
        let removedEffectIDs = Set(group.effectIDs)
        store.removeGroup(id: group.id, deleteEffects: deleteEffects, moveEffectsTo: targetGroupID)

        if deleteEffects {
            for effectID in removedEffectIDs {
                compileTasks[effectID]?.cancel()
                compileTasks[effectID] = nil
            }
            if let selected = selectedEffectID, removedEffectIDs.contains(selected) {
                selectedEffectID = store.effects.first?.id
            }
        }

        rebuildChain()
    }

    func effectToggled(_ effect: Effect) {
        rebuildChain()
        store.persist(effect: effect)
    }

    func parametersChanged(_ effect: Effect) {
        effect.applyParameters()
        store.persist(effect: effect)
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
        for effect in store.effects {
            var changed = false
            for index in effect.textureBindings.indices where effect.textureBindings[index].mediaID == id {
                effect.textureBindings[index].mediaID = nil
                changed = true
            }
            if changed {
                store.persist(effect: effect)
            }
        }
        mediaLibrary.removeAsset(id: id)
        mediaLibrary.reloadGPUCache(device: engine.device)
        rebuildChain()
    }

    func assignMedia(_ mediaID: String?, toSampler samplerName: String, in effect: Effect) {
        guard let index = effect.textureBindings.firstIndex(where: { $0.name == samplerName }) else { return }
        effect.textureBindings[index].mediaID = mediaID
        store.persist(effect: effect)
        rebuildChain()
    }

    // MARK: Compilation

    func scheduleCompile(_ effect: Effect, debounce: Bool) {
        compileTasks[effect.id]?.cancel()
        compileTasks[effect.id] = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.compile(effect)
        }
    }

    private func compile(_ effect: Effect) async {
        let source = effect.source
        let device = engine.device
        let vertexFunction = engine.vertexFunction

        let result: Result<CompiledEffect, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let output = try ShaderCompiler.compile(userSource: source)
                let compiled = try CompiledEffect(device: device, vertexFunction: vertexFunction, output: output)
                return .success(compiled)
            } catch {
                return .failure(error)
            }
        }.value

        // Hop off the current SwiftUI turn. `Task { @MainActor in }` can run
        // inline while a view is still updating and then trip the publish warning.
        DispatchQueue.main.async { [weak self, weak effect] in
            guard let self, let effect else { return }
            guard effect.source == source else { return }

            switch result {
            case .success(let compiled):
                effect.compiled = compiled
                effect.syncParameters(with: compiled.reflection)
                effect.syncTextureBindings(with: compiled.reflection)
                effect.applyParameters()
                effect.diagnostics = []
                rebuildChain()
                store.persist(effect: effect)
            case .failure(let error):
                if let compileError = error as? ShaderCompileError {
                    effect.diagnostics = compileError.diagnostics
                } else {
                    effect.diagnostics = [ShaderDiagnostic(line: nil, message: error.localizedDescription)]
                }
            }
        }
    }
}
