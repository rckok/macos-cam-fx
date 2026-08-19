import Combine
import Foundation

/// Loads and persists effects (one folder per effect: shader.frag +
/// effect.json) plus the global app configuration, and watches the effects
/// directory for external edits (hot reload).
@MainActor
final class EffectStore: ObservableObject {

    struct AppConfig: Codable {
        var order: [String] = []
        var groups: [EffectGroup] = []
        var selectedDeviceID: String?
        var historyDepth: Int = 16
        /// Mirror the incoming camera feed horizontally (default on, like FaceTime).
        var flipHorizontal: Bool = true

        enum CodingKeys: String, CodingKey {
            case order, groups, selectedDeviceID, historyDepth, flipHorizontal
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
            groups = try container.decodeIfPresent([EffectGroup].self, forKey: .groups) ?? []
            selectedDeviceID = try container.decodeIfPresent(String.self, forKey: .selectedDeviceID)
            historyDepth = try container.decodeIfPresent(Int.self, forKey: .historyDepth) ?? 16
            flipHorizontal = try container.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? true
        }
    }

    static let generalGroupID = "general"

    @Published private(set) var effects: [Effect] = []
    @Published private(set) var groups: [EffectGroup] = []
    @Published var config = AppConfig()

    /// Fired when an effect's shader changed on disk (external editor).
    let externalChange = PassthroughSubject<Effect, Never>()

    private let rootURL: URL
    private let effectsURL: URL
    private let configURL: URL
    private var directoryMonitor: DispatchSourceFileSystemObject?
    private var saveWorkItem: DispatchWorkItem?

    static let shaderFileName = "shader.frag"
    static let manifestFileName = "effect.json"

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootURL = appSupport.appendingPathComponent("CameraEffects", isDirectory: true)
        effectsURL = rootURL.appendingPathComponent("Effects", isDirectory: true)
        configURL = rootURL.appendingPathComponent("config.json")

        try? FileManager.default.createDirectory(at: effectsURL, withIntermediateDirectories: true)
        seedBuiltInEffectsIfNeeded()
        loadConfig()
        loadEffects()
        startWatching()
    }

    // MARK: Loading

    private func seedBuiltInEffectsIfNeeded() {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: effectsURL.path)) ?? []
        guard existing.isEmpty,
              let bundled = Bundle.main.url(forResource: "BuiltInEffects", withExtension: nil)
        else { return }

        let folders = (try? FileManager.default.contentsOfDirectory(
            at: bundled, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for folder in folders {
            let destination = effectsURL.appendingPathComponent(folder.lastPathComponent)
            try? FileManager.default.copyItem(at: folder, to: destination)
        }
    }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let loaded = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return }
        config = loaded
    }

    private func loadEffects() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: effectsURL, includingPropertiesForKeys: [.isDirectoryKey]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []

        let loaded: [Effect] = folders.compactMap(loadEffect(from:))
        effects = loaded

        if config.groups.isEmpty {
            groups = Self.migrateGroups(from: config.order, effectIDs: loaded.map(\.id))
        } else {
            groups = normalizeGroups(config.groups, effectIDs: loaded.map(\.id))
        }
        reorderEffectsFromGroups()
    }

    private static func migrateGroups(from order: [String], effectIDs: [String]) -> [EffectGroup] {
        let orderedIDs: [String]
        if order.isEmpty {
            orderedIDs = effectIDs
        } else {
            let known = Set(order)
            orderedIDs = order + effectIDs.filter { !known.contains($0) }
        }
        return [EffectGroup(id: generalGroupID, name: "General", enabled: true, effectIDs: orderedIDs)]
    }

    /// Reconciles saved groups with effects on disk (drops missing IDs, appends orphans).
    private func normalizeGroups(_ saved: [EffectGroup], effectIDs: [String]) -> [EffectGroup] {
        let validIDs = Set(effectIDs)
        var assigned = Set<String>()
        var normalized = saved.map { group -> EffectGroup in
            var group = group
            group.effectIDs = group.effectIDs.filter { validIDs.contains($0) }
            assigned.formUnion(group.effectIDs)
            return group
        }

        let orphans = effectIDs.filter { !assigned.contains($0) }
        if !orphans.isEmpty {
            if let generalIndex = normalized.firstIndex(where: { $0.id == Self.generalGroupID }) {
                normalized[generalIndex].effectIDs.append(contentsOf: orphans)
            } else if let firstIndex = normalized.indices.first {
                normalized[firstIndex].effectIDs.append(contentsOf: orphans)
            } else {
                normalized.append(EffectGroup(id: Self.generalGroupID, name: "General", effectIDs: orphans))
            }
        }

        if normalized.isEmpty {
            normalized = [EffectGroup(id: Self.generalGroupID, name: "General", effectIDs: effectIDs)]
        }
        return normalized
    }

    private func reorderEffectsFromGroups() {
        let byID = Dictionary(uniqueKeysWithValues: effects.map { ($0.id, $0) })
        effects = groups.flatMap(\.effectIDs).compactMap { byID[$0] }
    }

    private func updateGroup(at index: Int, _ body: (inout EffectGroup) -> Void) {
        var group = groups[index]
        body(&group)
        groups[index] = group
    }

    func effect(id: String) -> Effect? {
        effects.first { $0.id == id }
    }

    func effects(in group: EffectGroup) -> [Effect] {
        group.effectIDs.compactMap { effect(id: $0) }
    }

    func group(containing effectID: String) -> EffectGroup? {
        groups.first { $0.effectIDs.contains(effectID) }
    }

    private func inferredLegacyType(for param: EffectManifest.Param) -> String {
        switch param.value.count {
        case 2: return "vec2"
        case 3: return "vec3"
        case 4: return "vec4"
        default: return "float"
        }
    }

    private func loadEffect(from folder: URL) -> Effect? {
        let shaderURL = folder.appendingPathComponent(Self.shaderFileName)
        guard let source = try? String(contentsOf: shaderURL, encoding: .utf8) else { return nil }

        var name = folder.lastPathComponent
        var enabled = true
        var parameters: [EffectParameter] = []
        var textureBindings: [EffectTextureBinding] = []

        let manifestURL = folder.appendingPathComponent(Self.manifestFileName)
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(EffectManifest.self, from: data) {
            name = manifest.name
            enabled = manifest.enabled ?? true
            for (paramName, param) in manifest.params ?? [:] {
                let type = EffectParameter.normalizeReflectionType(
                    param.type ?? inferredLegacyType(for: param)
                )
                let defaults = EffectParameter.makeDefault(name: paramName, type: type)
                let count = EffectParameter.componentCount(for: type)
                parameters.append(EffectParameter(
                    name: paramName,
                    type: type,
                    values: param.value,
                    minimum: EffectParameter.aligned(param.min, count: count) ?? defaults.minimum,
                    maximum: EffectParameter.aligned(param.max, count: count) ?? defaults.maximum
                ))
            }
            for (samplerName, binding) in manifest.textures ?? [:] {
                textureBindings.append(EffectTextureBinding(
                    name: samplerName,
                    mediaID: binding.media
                ))
            }
        }

        return Effect(
            id: folder.lastPathComponent,
            folderURL: folder,
            name: name,
            enabled: enabled,
            source: source,
            parameters: parameters,
            textureBindings: textureBindings
        )
    }

    // MARK: Mutations — effects

    func addEffect(named requestedName: String, toGroup groupID: String? = nil) -> Effect? {
        let baseName = requestedName.isEmpty ? "New Effect" : requestedName
        var folderName = baseName.replacingOccurrences(of: "/", with: "-")
        var counter = 2
        while FileManager.default.fileExists(atPath: effectsURL.appendingPathComponent(folderName).path) {
            folderName = "\(baseName) \(counter)"
            counter += 1
        }

        let folder = effectsURL.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.newEffectTemplate.write(
                to: folder.appendingPathComponent(Self.shaderFileName), atomically: true, encoding: .utf8
            )
        } catch {
            return nil
        }

        let effect = Effect(
            id: folderName,
            folderURL: folder,
            name: baseName,
            enabled: true,
            source: Self.newEffectTemplate,
            parameters: []
        )
        effects.append(effect)

        let targetGroupID = groupID ?? groups.first?.id ?? Self.generalGroupID
        if let index = groups.firstIndex(where: { $0.id == targetGroupID }) {
            updateGroup(at: index) { $0.effectIDs.append(effect.id) }
        } else if let index = groups.indices.first {
            updateGroup(at: index) { $0.effectIDs.append(effect.id) }
        } else {
            groups = [EffectGroup(id: Self.generalGroupID, name: "General", effectIDs: [effect.id])]
        }

        reorderEffectsFromGroups()
        persist(effect: effect)
        saveConfigSoon()
        return effect
    }

    func removeEffect(_ effect: Effect) {
        effects.removeAll { $0.id == effect.id }
        for index in groups.indices {
            updateGroup(at: index) { group in
                group.effectIDs.removeAll { $0 == effect.id }
            }
        }
        try? FileManager.default.removeItem(at: effect.folderURL)
        saveConfigSoon()
    }

    func moveEffects(inGroup groupID: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        updateGroup(at: index) { $0.effectIDs.move(fromOffsets: source, toOffset: destination) }
        reorderEffectsFromGroups()
        saveConfigSoon()
    }

    /// Moves an effect into `targetGroupID`, optionally inserting before `beforeEffectID`.
    /// When `beforeEffectID` is nil, appends to the end of the target group.
    func moveEffect(_ effectID: String, toGroup targetGroupID: String, beforeEffectID: String? = nil) {
        for index in groups.indices {
            updateGroup(at: index) { $0.effectIDs.removeAll { $0 == effectID } }
        }
        guard let targetIndex = groups.firstIndex(where: { $0.id == targetGroupID }) else { return }
        updateGroup(at: targetIndex) { group in
            if let beforeEffectID, let insertIndex = group.effectIDs.firstIndex(of: beforeEffectID) {
                group.effectIDs.insert(effectID, at: insertIndex)
            } else {
                group.effectIDs.append(effectID)
            }
        }
        reorderEffectsFromGroups()
        saveConfigSoon()
    }

    // MARK: Mutations — groups

    @discardableResult
    func addGroup(named requestedName: String = "New Group") -> EffectGroup {
        var name = requestedName
        var counter = 2
        while groups.contains(where: { $0.name == name }) {
            name = "\(requestedName) \(counter)"
            counter += 1
        }
        let group = EffectGroup(id: UUID().uuidString, name: name, enabled: true, effectIDs: [])
        groups.append(group)
        saveConfigSoon()
        return group
    }

    func renameGroup(id: String, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        updateGroup(at: index) { $0.name = name }
        saveConfigSoon()
    }

    func setGroupEnabled(id: String, enabled: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        updateGroup(at: index) { $0.enabled = enabled }
        saveConfigSoon()
    }

    func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        groups.move(fromOffsets: source, toOffset: destination)
        reorderEffectsFromGroups()
        saveConfigSoon()
    }

    func removeGroup(id: String, deleteEffects: Bool, moveEffectsTo targetGroupID: String?) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let effectIDs = groups[index].effectIDs
        groups.remove(at: index)

        if deleteEffects {
            for effectID in effectIDs {
                guard let effect = effect(id: effectID) else { continue }
                effects.removeAll { $0.id == effect.id }
                try? FileManager.default.removeItem(at: effect.folderURL)
            }
        } else if let targetGroupID,
                  let targetIndex = groups.firstIndex(where: { $0.id == targetGroupID }) {
            updateGroup(at: targetIndex) { $0.effectIDs.append(contentsOf: effectIDs) }
        }

        if groups.isEmpty {
            let remainingIDs = deleteEffects ? [] : effectIDs
            groups = [EffectGroup(id: Self.generalGroupID, name: "General", effectIDs: remainingIDs)]
        }

        reorderEffectsFromGroups()
        saveConfigSoon()
    }

    // MARK: Persistence

    func persist(effect: Effect) {
        let shaderURL = effect.folderURL.appendingPathComponent(Self.shaderFileName)
        try? effect.source.write(to: shaderURL, atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(effect.manifest) {
            try? data.write(to: effect.folderURL.appendingPathComponent(Self.manifestFileName))
        }
    }

    func saveConfigSoon() {
        config.order = effects.map(\.id)
        config.groups = groups
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(self.config) {
                try? data.write(to: self.configURL)
            }
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    // MARK: Hot reload

    private func startWatching() {
        let descriptor = open(effectsURL.path, O_EVTONLY)
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
        for effect in effects {
            let shaderURL = effect.folderURL.appendingPathComponent(Self.shaderFileName)
            guard let diskSource = try? String(contentsOf: shaderURL, encoding: .utf8),
                  diskSource != effect.source
            else { continue }
            effect.source = diskSource
            externalChange.send(effect)
        }
    }

    static let newEffectTemplate = """
    // Built-in uniforms are listed in the inspector. See README for details.

    layout(std140, binding = 3) uniform Params {
        // @metadata(min=0.0 max=1.0 default=0.5)
        float amount;
    };

    void main() {
        vec4 color = texture(uPrev, vUV);
        outColor = mix(color, vec4(1.0 - color.rgb, color.a), amount);
    }
    """
}
