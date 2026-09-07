import Combine
import Foundation

/// Loads and persists stages (one folder per stage: shader.frag + stage.json)
/// plus the global app configuration, including the effects that group stages
/// into pipelines, and watches the stages directory for external edits.
@MainActor
final class EffectStore: ObservableObject {

    struct AppConfig: Codable {
        var effects: [Effect] = []
        /// Effect whose pipeline was rendering when the app last quit.
        var activeEffectID: String?
        var viewMode: ViewMode = .basic
        var selectedDeviceID: String?
        var historyDepth: Int = 16
        /// Mirror the incoming camera feed horizontally (default on, like FaceTime).
        var flipHorizontal: Bool = true

        enum CodingKeys: String, CodingKey {
            case effects, activeEffectID, viewMode, selectedDeviceID, historyDepth, flipHorizontal
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Required on purpose: a file without it was not written by this
            // app, and treating it as "no effects" would regroup every stage.
            effects = try container.decode([Effect].self, forKey: .effects)
            activeEffectID = try container.decodeIfPresent(String.self, forKey: .activeEffectID)
            viewMode = try container.decodeIfPresent(ViewMode.self, forKey: .viewMode) ?? .basic
            selectedDeviceID = try container.decodeIfPresent(String.self, forKey: .selectedDeviceID)
            historyDepth = try container.decodeIfPresent(Int.self, forKey: .historyDepth) ?? 16
            flipHorizontal = try container.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? true
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(effects, forKey: .effects)
            try container.encodeIfPresent(activeEffectID, forKey: .activeEffectID)
            try container.encode(viewMode, forKey: .viewMode)
            try container.encodeIfPresent(selectedDeviceID, forKey: .selectedDeviceID)
            try container.encode(historyDepth, forKey: .historyDepth)
            try container.encode(flipHorizontal, forKey: .flipHorizontal)
        }
    }

    @Published private(set) var stages: [Stage] = []
    @Published private(set) var effects: [Effect] = []
    @Published var config = AppConfig()

    /// Fired when a stage's shader changed on disk (external editor).
    let externalChange = PassthroughSubject<Stage, Never>()

    private let rootURL: URL
    private let stagesURL: URL
    private let configURL: URL
    private var directoryMonitor: DispatchSourceFileSystemObject?
    private var saveWorkItem: DispatchWorkItem?
    /// False until a config we could read is on disk. Only then may the store
    /// invent the built-in effects, which would otherwise regroup real stages.
    private var hasStoredConfig = false

    static let shaderFileName = "shader.frag"
    static let manifestFileName = "stage.json"
    private static let bundledResourceName = "BuiltInEffects"

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootURL = appSupport.appendingPathComponent("CameraEffects", isDirectory: true)
        stagesURL = rootURL.appendingPathComponent("Stages", isDirectory: true)
        configURL = rootURL.appendingPathComponent("config.json")

        try? FileManager.default.createDirectory(at: stagesURL, withIntermediateDirectories: true)
        seedBuiltInStagesIfNeeded()
        loadConfig()
        loadStages()
        // Make whatever we just resolved durable, so a launch that ends before
        // the first edit cannot leave the layout to be guessed again.
        saveConfig()
        startWatching()
    }

    // MARK: Loading

    private static var bundledRootURL: URL? {
        Bundle.main.url(forResource: bundledResourceName, withExtension: nil)
    }

    private func seedBuiltInStagesIfNeeded() {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: stagesURL.path)) ?? []
        guard existing.isEmpty, let bundled = Self.bundledRootURL else { return }

        let bundledStages = bundled.appendingPathComponent("Stages", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: bundledStages, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for folder in folders {
            let destination = stagesURL.appendingPathComponent(folder.lastPathComponent)
            try? FileManager.default.copyItem(at: folder, to: destination)
        }
    }

    /// Effects shipped with the app, described by `BuiltInEffects/effects.json`.
    private struct BuiltInLayout: Decodable {
        struct Entry: Decodable {
            var name: String
            var stages: [String]
        }

        var effects: [Entry]
    }

    private static func builtInEffects(stageIDs: [String]) -> [Effect] {
        let known = Set(stageIDs)
        var assigned = Set<String>()
        var effects: [Effect] = []

        if let root = bundledRootURL,
           let data = try? Data(contentsOf: root.appendingPathComponent("effects.json")),
           let layout = try? JSONDecoder().decode(BuiltInLayout.self, from: data) {
            for entry in layout.effects {
                let stages = entry.stages.filter { known.contains($0) && assigned.insert($0).inserted }
                guard !stages.isEmpty else { continue }
                effects.append(Effect(id: UUID().uuidString, name: entry.name, stageIDs: stages))
            }
        }

        for stageID in stageIDs where !assigned.contains(stageID) {
            effects.append(Effect(id: UUID().uuidString, name: stageID, stageIDs: [stageID]))
        }
        return effects
    }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL) else { return }
        do {
            config = try JSONDecoder().decode(AppConfig.self, from: data)
            hasStoredConfig = true
        } catch {
            // Saving would overwrite a config we could not understand, and with
            // it which stages belong to which effect. Keep it for recovery.
            let backupURL = rootURL.appendingPathComponent("config.unreadable.json")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: configURL, to: backupURL)
            NSLog("Could not read config.json (\(error)); kept a copy as \(backupURL.lastPathComponent)")
        }
    }

    private func loadStages() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: stagesURL, includingPropertiesForKeys: [.isDirectoryKey]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []

        let loaded: [Stage] = folders.compactMap(loadStage(from:))
        stages = loaded

        let stageIDs = loaded.map(\.id)
        effects = hasStoredConfig
            ? normalizeEffects(config.effects, stageIDs: stageIDs)
            : Self.builtInEffects(stageIDs: stageIDs)
        reorderStagesFromEffects()
    }

    /// Reconciles saved effects with the stages on disk: drops stage IDs that
    /// no longer exist and adopts stages nobody claims as their own effect.
    private func normalizeEffects(_ saved: [Effect], stageIDs: [String]) -> [Effect] {
        let known = Set(stageIDs)
        var assigned = Set<String>()
        var normalized = saved.map { effect -> Effect in
            var effect = effect
            effect.stageIDs = effect.stageIDs.filter { known.contains($0) && assigned.insert($0).inserted }
            return effect
        }
        for stageID in stageIDs where !assigned.contains(stageID) {
            normalized.append(Effect(id: UUID().uuidString, name: stageID, stageIDs: [stageID]))
        }
        return normalized
    }

    private func reorderStagesFromEffects() {
        let byID = Dictionary(stages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stages = effects.flatMap(\.stageIDs).compactMap { byID[$0] }
    }

    private func updateEffect(at index: Int, _ body: (inout Effect) -> Void) {
        var effect = effects[index]
        body(&effect)
        effects[index] = effect
    }

    func stage(id: String) -> Stage? {
        stages.first { $0.id == id }
    }

    /// Republishes without touching the arrays, for changes inside a stage
    /// (a recompile reshaping its parameters) that views read through here.
    func stageContentsDidChange() {
        objectWillChange.send()
    }

    func stages(in effect: Effect) -> [Stage] {
        effect.stageIDs.compactMap { stage(id: $0) }
    }

    func effect(id: String) -> Effect? {
        effects.first { $0.id == id }
    }

    func effect(containing stageID: String) -> Effect? {
        effects.first { $0.stageIDs.contains(stageID) }
    }

    /// Manifests written by hand may leave `type` out; guess it from the value.
    private func inferredType(for param: StageManifest.Param) -> String {
        switch param.value.count {
        case 2: return "vec2"
        case 3: return "vec3"
        case 4: return "vec4"
        default: return "float"
        }
    }

    private func loadStage(from folder: URL) -> Stage? {
        let shaderURL = folder.appendingPathComponent(Self.shaderFileName)
        guard let source = try? String(contentsOf: shaderURL, encoding: .utf8) else { return nil }

        var name = folder.lastPathComponent
        var parameters: [StageParameter] = []
        var textureBindings: [StageTextureBinding] = []

        let manifestURL = folder.appendingPathComponent(Self.manifestFileName)
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(StageManifest.self, from: data) {
            name = manifest.name
            for (paramName, param) in manifest.params ?? [:] {
                let type = StageParameter.normalizeReflectionType(
                    param.type ?? inferredType(for: param)
                )
                let defaults = StageParameter.makeDefault(name: paramName, type: type)
                let count = StageParameter.componentCount(for: type)
                parameters.append(StageParameter(
                    name: paramName,
                    type: type,
                    values: param.value,
                    minimum: StageParameter.aligned(param.min, count: count) ?? defaults.minimum,
                    maximum: StageParameter.aligned(param.max, count: count) ?? defaults.maximum,
                    isGlobal: param.global ?? false
                ))
            }
            for (samplerName, binding) in manifest.textures ?? [:] {
                textureBindings.append(StageTextureBinding(
                    name: samplerName,
                    mediaID: binding.media
                ))
            }
        }

        return Stage(
            id: folder.lastPathComponent,
            folderURL: folder,
            name: name,
            source: source,
            parameters: parameters,
            textureBindings: textureBindings
        )
    }

    // MARK: Mutations — stages

    func addStage(named requestedName: String, toEffect effectID: String) -> Stage? {
        guard let effectIndex = effects.firstIndex(where: { $0.id == effectID }) else { return nil }

        let folderName = uniqueFolderName(preferring: requestedName)
        let folder = stagesURL.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.newStageTemplate.write(
                to: folder.appendingPathComponent(Self.shaderFileName), atomically: true, encoding: .utf8
            )
        } catch {
            return nil
        }

        let stage = Stage(
            id: folderName,
            folderURL: folder,
            name: folderName,
            source: Self.newStageTemplate,
            parameters: []
        )
        stages.append(stage)
        updateEffect(at: effectIndex) { $0.stageIDs.append(stage.id) }

        reorderStagesFromEffects()
        persist(stage: stage)
        saveConfig()
        return stage
    }

    /// Copies a stage's folder (shader, manifest and any extra files) and
    /// places the copy directly after the original in the same effect.
    func duplicateStage(_ stage: Stage) -> Stage? {
        let folderName = uniqueFolderName(preferring: "\(stage.name) Copy")
        let folder = stagesURL.appendingPathComponent(folderName, isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: stage.folderURL.path) {
                try FileManager.default.copyItem(at: stage.folderURL, to: folder)
            } else {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        } catch {
            return nil
        }

        let copy = Stage(
            id: folderName,
            folderURL: folder,
            name: folderName,
            source: stage.source,
            parameters: stage.parameters,
            textureBindings: stage.textureBindings
        )
        stages.append(copy)

        if let effectIndex = effects.firstIndex(where: { $0.stageIDs.contains(stage.id) }) {
            updateEffect(at: effectIndex) { effect in
                if let index = effect.stageIDs.firstIndex(of: stage.id) {
                    effect.stageIDs.insert(copy.id, at: index + 1)
                } else {
                    effect.stageIDs.append(copy.id)
                }
            }
        } else {
            effects.append(Effect(id: UUID().uuidString, name: copy.name, stageIDs: [copy.id]))
        }

        reorderStagesFromEffects()
        persist(stage: copy)
        saveConfig()
        return copy
    }

    /// Folder name — which doubles as the stage ID — that is free on disk and
    /// unused by a loaded stage, suffixed with a counter when needed.
    private func uniqueFolderName(preferring requestedName: String) -> String {
        var base = requestedName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base.hasPrefix(".") {
            base = "New Stage"
        }

        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: stagesURL.appendingPathComponent(candidate).path)
            || stages.contains(where: { $0.id == candidate }) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    func removeStage(_ stage: Stage) {
        stages.removeAll { $0.id == stage.id }
        for index in effects.indices {
            updateEffect(at: index) { effect in
                effect.stageIDs.removeAll { $0 == stage.id }
            }
        }
        try? FileManager.default.removeItem(at: stage.folderURL)
        saveConfig()
    }

    /// Moves a stage to `placement` within `targetEffectID`, whether it comes
    /// from that same effect (a reorder) or another one.
    func moveStage(_ stageID: String, toEffect targetEffectID: String, placement: StagePlacement) {
        guard stage(id: stageID) != nil,
              let targetIndex = effects.firstIndex(where: { $0.id == targetEffectID })
        else { return }
        // Dropping a stage onto itself would otherwise send it to the end,
        // because the anchor is gone by the time the insertion point is found.
        if case .before(let anchorID) = placement, anchorID == stageID { return }

        for index in effects.indices {
            updateEffect(at: index) { $0.stageIDs.removeAll { $0 == stageID } }
        }
        updateEffect(at: targetIndex) { effect in
            let insertIndex: Int
            switch placement {
            case .start:
                insertIndex = effect.stageIDs.startIndex
            case .before(let anchorID):
                insertIndex = effect.stageIDs.firstIndex(of: anchorID) ?? effect.stageIDs.endIndex
            case .end:
                insertIndex = effect.stageIDs.endIndex
            }
            effect.stageIDs.insert(stageID, at: insertIndex)
        }
        reorderStagesFromEffects()
        saveConfig()
    }

    // MARK: Mutations — effects

    @discardableResult
    func addEffect(named requestedName: String = "New Effect") -> Effect {
        var name = requestedName
        var counter = 2
        while effects.contains(where: { $0.name == name }) {
            name = "\(requestedName) \(counter)"
            counter += 1
        }
        let effect = Effect(id: UUID().uuidString, name: name, stageIDs: [])
        effects.append(effect)
        saveConfig()
        return effect
    }

    func renameEffect(id: String, to name: String) {
        guard let index = effects.firstIndex(where: { $0.id == id }) else { return }
        updateEffect(at: index) { $0.name = name }
        saveConfig()
    }

    /// Moves an effect above `beforeEffectID`, or to the end when that is nil.
    func moveEffect(_ effectID: String, before beforeEffectID: String?) {
        guard beforeEffectID != effectID,
              let currentIndex = effects.firstIndex(where: { $0.id == effectID })
        else { return }

        let effect = effects.remove(at: currentIndex)
        if let beforeEffectID, let anchorIndex = effects.firstIndex(where: { $0.id == beforeEffectID }) {
            effects.insert(effect, at: anchorIndex)
        } else {
            effects.append(effect)
        }
        reorderStagesFromEffects()
        saveConfig()
    }

    func removeEffect(id: String, deleteStages: Bool, moveStagesTo targetEffectID: String?) {
        guard let index = effects.firstIndex(where: { $0.id == id }) else { return }
        let stageIDs = effects[index].stageIDs
        effects.remove(at: index)

        if deleteStages {
            for stageID in stageIDs {
                guard let stage = stage(id: stageID) else { continue }
                stages.removeAll { $0.id == stage.id }
                try? FileManager.default.removeItem(at: stage.folderURL)
            }
        } else if let targetEffectID,
                  let targetIndex = effects.firstIndex(where: { $0.id == targetEffectID }) {
            updateEffect(at: targetIndex) { $0.stageIDs.append(contentsOf: stageIDs) }
        } else {
            // Nowhere to put them: keep every stage reachable as its own effect.
            for stageID in stageIDs {
                let name = stage(id: stageID)?.name ?? stageID
                effects.append(Effect(id: UUID().uuidString, name: name, stageIDs: [stageID]))
            }
        }

        reorderStagesFromEffects()
        saveConfig()
    }

    // MARK: Persistence

    func persist(stage: Stage) {
        let shaderURL = stage.folderURL.appendingPathComponent(Self.shaderFileName)
        try? stage.source.write(to: shaderURL, atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(stage.manifest) {
            try? data.write(to: stage.folderURL.appendingPathComponent(Self.manifestFileName))
        }
    }

    /// Coalesces the settings that change while a control is being dragged.
    func saveConfigSoon() {
        config.effects = effects
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.writeConfig()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Writes immediately. Which stages belong to which effect is the one piece
    /// of state that lives only here, so it is never left on a pending timer.
    func saveConfig() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        config.effects = effects
        writeConfig()
    }

    private func writeConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        do {
            try data.write(to: configURL, options: .atomic)
            hasStoredConfig = true
        } catch {
            NSLog("Failed to write config.json: \(error)")
        }
    }

    // MARK: Hot reload

    private func startWatching() {
        let descriptor = open(stagesURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        monitor.setEventHandler { [weak self] in
            self?.reloadChangedShaders()
        }
        monitor.setCancelHandler { close(descriptor) }
        monitor.resume()
        directoryMonitor = monitor
    }

    private func reloadChangedShaders() {
        for stage in stages {
            let shaderURL = stage.folderURL.appendingPathComponent(Self.shaderFileName)
            guard let diskSource = try? String(contentsOf: shaderURL, encoding: .utf8),
                  diskSource != stage.source
            else { continue }
            stage.source = diskSource
            externalChange.send(stage)
        }
    }

    static let newStageTemplate = """
    // Built-in uniforms are listed in the inspector. See README for details.

    layout(std140, binding = 3) uniform Params {
        // @metadata(min=0.0 max=1.0 default=0.5 global)
        float amount;
    };

    void main() {
        vec4 color = texture(uPrev, vUV);
        outColor = mix(color, vec4(1.0 - color.rgb, color.a), amount);
    }
    """
}
