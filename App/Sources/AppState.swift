import Combine
import Foundation
import SwiftUI

/// Central coordinator: wires capture -> render engine -> preview/virtual
/// camera, and orchestrates effect compilation and persistence.
@MainActor
final class AppState: ObservableObject {

    let store: EffectStore
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

    private var compileTasks: [String: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()

    var selectedEffect: Effect? {
        store.effects.first { $0.id == selectedEffectID }
    }

    init() {
        // Metal is available on all supported hardware; fail hard if not.
        let engine = try! RenderEngine()
        self.engine = engine
        self.store = EffectStore()
        self.capture = CaptureManager()
        self.extensionManager = ExtensionManager()
        self.sink = VirtualCameraSink()
        self.historyDepth = 16

        historyDepth = store.config.historyDepth
        capture.selectedDeviceID = store.config.selectedDeviceID

        // Frame path: capture queue -> engine; Metal completion -> sink.
        capture.frameHandler = { [engine] pixelBuffer, timestamp in
            engine.process(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }
        engine.outputHandler = { [sink] pixelBuffer, timestamp in
            sink.send(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }

        // Persist source selection.
        capture.$selectedDeviceID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] deviceID in
                guard let self else { return }
                self.store.config.selectedDeviceID = deviceID
                self.store.saveConfigSoon()
            }
            .store(in: &cancellables)

        // Hot reload from external editors.
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

    /// Pushes the current enabled+compiled chain into the render engine.
    func rebuildChain() {
        let chain = store.effects
            .filter(\.enabled)
            .compactMap(\.compiled)
        engine.setEffects(chain)
    }

    func addEffect() {
        guard let effect = store.addEffect(named: "New Effect") else { return }
        selectedEffectID = effect.id
        scheduleCompile(effect, debounce: false)
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

    func moveEffects(fromOffsets source: IndexSet, toOffset destination: Int) {
        store.moveEffects(fromOffsets: source, toOffset: destination)
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

    // MARK: Compilation

    /// Recompiles an effect, optionally debounced (used while typing).
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

        guard !Task.isCancelled, effect.source == source else { return }

        switch result {
        case .success(let compiled):
            effect.compiled = compiled
            effect.syncParameters(with: compiled.reflection)
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
            // Keep the last working pipeline running; only the editor shows errors.
        }
    }
}
