import Combine
import Foundation

/// Loads and persists effects (one folder per effect: shader.frag +
/// effect.json) plus the global app configuration, and watches the effects
/// directory for external edits (hot reload).
@MainActor
final class EffectStore: ObservableObject {

    struct AppConfig: Codable {
        var order: [String] = []
        var selectedDeviceID: String?
        var historyDepth: Int = 16
        /// Mirror the incoming camera feed horizontally (default on, like FaceTime).
        var flipHorizontal: Bool = true

        enum CodingKeys: String, CodingKey {
            case order, selectedDeviceID, historyDepth, flipHorizontal
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
            selectedDeviceID = try container.decodeIfPresent(String.self, forKey: .selectedDeviceID)
            historyDepth = try container.decodeIfPresent(Int.self, forKey: .historyDepth) ?? 16
            flipHorizontal = try container.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? true
        }
    }

    @Published private(set) var effects: [Effect] = []
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

        var loaded: [Effect] = folders.compactMap(loadEffect(from:))

        // Respect saved chain order; unknown effects go to the end.
        let orderIndex = Dictionary(uniqueKeysWithValues: config.order.enumerated().map { ($1, $0) })
        loaded.sort {
            (orderIndex[$0.id] ?? Int.max, $0.name) < (orderIndex[$1.id] ?? Int.max, $1.name)
        }
        effects = loaded
    }

    private func loadEffect(from folder: URL) -> Effect? {
        let shaderURL = folder.appendingPathComponent(Self.shaderFileName)
        guard let source = try? String(contentsOf: shaderURL, encoding: .utf8) else { return nil }

        var name = folder.lastPathComponent
        var enabled = true
        var parameters: [EffectParameter] = []

        let manifestURL = folder.appendingPathComponent(Self.manifestFileName)
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(EffectManifest.self, from: data) {
            name = manifest.name
            enabled = manifest.enabled ?? true
            for (paramName, param) in manifest.params ?? [:] {
                // The concrete GLSL type is only known after compilation;
                // infer a provisional type from the component count.
                let type: String
                switch param.value.count {
                case 2: type = "vec2"
                case 3: type = "vec3"
                case 4: type = "vec4"
                default: type = "float"
                }
                parameters.append(EffectParameter(
                    name: paramName,
                    type: type,
                    values: param.value,
                    minimum: param.min ?? 0,
                    maximum: param.max ?? 1
                ))
            }
        }

        return Effect(
            id: folder.lastPathComponent,
            folderURL: folder,
            name: name,
            enabled: enabled,
            source: source,
            parameters: parameters
        )
    }

    // MARK: Mutations

    func addEffect(named requestedName: String) -> Effect? {
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
        persist(effect: effect)
        saveConfigSoon()
        return effect
    }

    func removeEffect(_ effect: Effect) {
        effects.removeAll { $0.id == effect.id }
        try? FileManager.default.removeItem(at: effect.folderURL)
        saveConfigSoon()
    }

    func moveEffects(fromOffsets source: IndexSet, toOffset destination: Int) {
        effects.move(fromOffsets: source, toOffset: destination)
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
    // New effect. Available inputs (see README for the full contract):
    //   vUV, uPrev, uFrames, uResolution, uTime, uFrameCount, uHeadIndex,
    //   ceHistory(uv, framesAgo)

    layout(std140, binding = 3) uniform Params {
        float amount;
    };

    void main() {
        vec4 color = texture(uPrev, vUV);
        outColor = mix(color, vec4(1.0 - color.rgb, color.a), amount);
    }
    """
}
