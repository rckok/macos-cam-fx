import Foundation

/// How much of the effect tree the UI exposes.
enum ViewMode: String, Codable, CaseIterable, Identifiable {
    /// The camera with its floating controls: effects and their effect-level
    /// (`global`) controls.
    case basic
    /// The same, plus the editor panel under the camera: the active effect's
    /// stages, the GLSL editor, and the selected stage's controls.
    case editor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic: return "Basic"
        case .editor: return "Editor"
        }
    }
}

/// A user-tweakable shader parameter, reflected from a stage's `Params`
/// uniform block and merged with persisted values from stage.json.
struct StageParameter: Identifiable, Equatable {
    let name: String
    /// GLSL type name: float, int, bool, vec2, vec3, vec4.
    let type: String
    var values: [Double]
    var minimum: [Double]
    var maximum: [Double]
    /// vec3/vec4 use per-component sliders unless `@metadata(color=true)`.
    var isColor: Bool = false
    /// `@metadata(global)` also lists this control on the owning effect, so it
    /// stays reachable in Basic Mode where stages are hidden.
    var isGlobal: Bool = false

    var id: String { name }

    /// SPIR-V/std140 lowers GLSL `bool` to `uint`; normalize for UI and persistence.
    static func normalizeReflectionType(_ type: String) -> String {
        switch type {
        case "bool": return "uint"
        case "bvec2": return "uvec2"
        case "bvec3": return "uvec3"
        case "bvec4": return "uvec4"
        default: return type
        }
    }

    /// Scalar/vector `uint` params are edited as on/off switches (use for boolean flags).
    enum EditorKind: Equatable {
        case floatSliders(componentCount: Int)
        case intSlider
        case toggle(componentCount: Int)
        case color(supportsOpacity: Bool)
        case unsupported(String)
    }

    var editorKind: EditorKind {
        switch Self.normalizeReflectionType(type) {
        case "float":
            return .floatSliders(componentCount: 1)
        case "int":
            return .intSlider
        case "ivec2", "ivec3", "ivec4":
            return values.count == 1 ? .intSlider : .unsupported(type)
        case "uint":
            return .toggle(componentCount: 1)
        case "uvec2":
            return .toggle(componentCount: 2)
        case "uvec3":
            return .toggle(componentCount: 3)
        case "uvec4":
            return .toggle(componentCount: 4)
        case "vec2":
            return .floatSliders(componentCount: 2)
        case "vec3":
            return isColor ? .color(supportsOpacity: false) : .floatSliders(componentCount: 3)
        case "vec4":
            return isColor ? .color(supportsOpacity: true) : .floatSliders(componentCount: 4)
        default:
            return .unsupported(type)
        }
    }

    static func componentCount(for type: String) -> Int {
        switch normalizeReflectionType(type) {
        case "vec2", "ivec2", "uvec2", "bvec2": return 2
        case "vec3", "ivec3", "uvec3", "bvec3": return 3
        case "vec4", "ivec4", "uvec4", "bvec4": return 4
        default: return 1
        }
    }

    static func makeDefault(name: String, type: String) -> StageParameter {
        let normalized = normalizeReflectionType(type)
        let count = componentCount(for: normalized)
        switch normalized {
        case "bool", "bvec2", "bvec3", "bvec4", "uint", "uvec2", "uvec3", "uvec4":
            return StageParameter(
                name: name,
                type: normalized,
                values: Array(repeating: 0, count: count),
                minimum: Array(repeating: 0, count: count),
                maximum: Array(repeating: 1, count: count)
            )
        case "int", "ivec2", "ivec3", "ivec4":
            return StageParameter(
                name: name,
                type: normalized,
                values: Array(repeating: 0, count: count),
                minimum: Array(repeating: 0, count: count),
                maximum: Array(repeating: 10, count: count)
            )
        case "vec3", "vec4":
            return StageParameter(
                name: name,
                type: normalized,
                values: Array(repeating: 1, count: count),
                minimum: Array(repeating: 0, count: count),
                maximum: Array(repeating: 1, count: count)
            )
        default:
            return StageParameter(
                name: name,
                type: normalized,
                values: Array(repeating: 0.5, count: count),
                minimum: Array(repeating: 0, count: count),
                maximum: Array(repeating: 1, count: count)
            )
        }
    }

    /// Builds a parameter from reflection, optional shader `@metadata`, and
    /// any value already stored in the stage. Shader min/max/`color`/`global`
    /// win when present; the current value is kept and clamped into the range.
    static func resolved(
        name: String,
        type: String,
        existing: StageParameter?,
        minimum: [Double]?,
        maximum: [Double]?,
        defaultValue: [Double]?,
        isColor: Bool?,
        isGlobal: Bool?
    ) -> StageParameter {
        let normalized = normalizeReflectionType(type)
        let typeDefaults = makeDefault(name: name, type: normalized)
        let count = componentCount(for: normalized)

        var minima = aligned(minimum, count: count) ?? existing?.minimum ?? typeDefaults.minimum
        var maxima = aligned(maximum, count: count) ?? existing?.maximum ?? typeDefaults.maximum
        if minima.count != count { minima = typeDefaults.minimum }
        if maxima.count != count { maxima = typeDefaults.maximum }
        for index in 0..<count where minima[index] > maxima[index] {
            swap(&minima[index], &maxima[index])
        }

        var values: [Double]
        if let existing, existing.values.count == count {
            values = existing.values
        } else if let defaultValue, let alignedDefault = aligned(defaultValue, count: count) {
            values = alignedDefault
        } else {
            values = typeDefaults.values
        }
        values = zip(values, zip(minima, maxima)).map { value, bounds in
            min(max(value, bounds.0), bounds.1)
        }

        return StageParameter(
            name: name,
            type: normalized,
            values: values,
            minimum: minima,
            maximum: maxima,
            isColor: isColor ?? typeDefaults.isColor,
            isGlobal: isGlobal ?? false
        )
    }

    static func aligned(_ values: [Double]?, count: Int) -> [Double]? {
        guard let values, !values.isEmpty else { return nil }
        if values.count == 1 { return Array(repeating: values[0], count: count) }
        if values.count == count { return values }
        return nil
    }

    func sliderRange(at index: Int, step: Double = 0.0001) -> ClosedRange<Double> {
        let lo = minimum.indices.contains(index) ? minimum[index] : (minimum.first ?? 0)
        let hi = maximum.indices.contains(index) ? maximum[index] : (maximum.first ?? 1)
        return lo...max(hi, lo + step)
    }
}

/// A named pipeline of stages. Exactly one effect is active at a time — the
/// one that owns the current selection — so effects never chain into each
/// other: every effect starts from the current camera frame.
struct Effect: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var stageIDs: [String]

    init(id: String, name: String, stageIDs: [String] = []) {
        self.id = id
        self.name = name
        self.stageIDs = stageIDs
    }

    /// Built-in effects and stages ship inside the app bundle and carry this
    /// prefix; user stage IDs are folder names, which never contain ":".
    /// A built-in effect's ID is the prefix plus its bundle folder name, and
    /// its stages add "/" plus their subfolder name.
    static let builtInIDPrefix = "builtin:"

    /// Shipped with the app: viewable and usable, but its shader sources,
    /// names and stage layout cannot be edited. Duplicate it to customize.
    var isBuiltIn: Bool {
        id.hasPrefix(Self.builtInIDPrefix)
    }
}

/// Where a stage lands when it is dragged into an effect.
enum StagePlacement: Equatable {
    case start
    /// Immediately above the stage with this ID.
    case before(String)
    case end
}

/// Assigns a media-library asset to a `sampler2D` uniform in the stage shader.
struct StageTextureBinding: Identifiable, Equatable {
    /// GLSL sampler name, e.g. `uOverlay`.
    let name: String
    /// ID of the asset in the shared media library, if assigned.
    var mediaID: String?
    /// `@metadata(global)` also lists this picker on the owning effect, so it
    /// stays reachable in Basic Mode where stages are hidden.
    var isGlobal: Bool = false

    var id: String { name }
}

/// What a stage draws. Chosen when the stage is created and fixed after.
enum StageKind: String, Codable {
    /// One fullscreen fragment shader pass.
    case fragment
    /// Geometry drawn by a vertex and a fragment shader, optionally driven by
    /// a simulation pass whose state lives in 32-bit float textures.
    case geometry

    var title: String {
        switch self {
        case .fragment: return "Fragment Stage"
        case .geometry: return "Geometry Stage"
        }
    }

    /// The shader files a stage of this kind edits, in tab order.
    func files(simulation: Bool) -> [ShaderFile] {
        switch self {
        case .fragment: return [.fragment]
        case .geometry: return simulation ? [.simulation, .vertex, .fragment] : [.vertex, .fragment]
        }
    }
}

enum GeometryPrimitive: String, Codable, CaseIterable, Identifiable {
    case points
    case lines
    case lineStrip
    case triangles
    case triangleStrip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .points: return "Points"
        case .lines: return "Lines"
        case .lineStrip: return "Line Strip"
        case .triangles: return "Triangles"
        case .triangleStrip: return "Triangle Strip"
        }
    }
}

/// What a geometry stage's texture holds before it draws, each frame.
enum GeometryStartFrom: String, Codable, CaseIterable, Identifiable {
    /// Transparent black.
    case transparent
    /// The previous stage's output, the same image `uPrev` samples.
    case previousStage
    /// This stage's own output from the previous frame, so drawing accumulates.
    case ownLastFrame

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transparent: return "Transparent"
        case .previousStage: return "Previous Stage"
        case .ownLastFrame: return "Own Last Frame"
        }
    }
}

/// How a geometry stage's fragments combine with what is already there.
enum GeometryBlend: String, Codable, CaseIterable, Identifiable {
    case replace
    case alpha
    case additive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replace: return "Replace"
        case .alpha: return "Alpha"
        case .additive: return "Additive"
        }
    }
}

/// The stage-level controls of a geometry stage, saved in stage.json.
struct GeometrySettings: Codable, Equatable {
    static let countRange = 1...4_194_304
    static let verticesPerItemRange = 1...1_048_576
    static let stateSlotRange = 1...ShaderCompiler.maxStateSlots
    static let substepRange = 1...8

    var primitive: GeometryPrimitive = .points
    /// Items drawn, and simulated when the simulation pass is on.
    var count: Int = 10_000
    var verticesPerItem: Int = 1
    var startFrom: GeometryStartFrom = .transparent
    var blend: GeometryBlend = .alpha
    var simulation: Bool = false
    /// vec4 state values per item: `outState0` … `outState3`.
    var stateSlots: Int = 1
    /// Simulation steps per rendered frame.
    var substeps: Int = 1

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GeometrySettings()
        primitive = (try? container.decodeIfPresent(GeometryPrimitive.self, forKey: .primitive)) ?? defaults.primitive
        count = (try? container.decodeIfPresent(Int.self, forKey: .count)) ?? defaults.count
        verticesPerItem = (try? container.decodeIfPresent(Int.self, forKey: .verticesPerItem)) ?? defaults.verticesPerItem
        startFrom = (try? container.decodeIfPresent(GeometryStartFrom.self, forKey: .startFrom)) ?? defaults.startFrom
        blend = (try? container.decodeIfPresent(GeometryBlend.self, forKey: .blend)) ?? defaults.blend
        simulation = (try? container.decodeIfPresent(Bool.self, forKey: .simulation)) ?? defaults.simulation
        stateSlots = (try? container.decodeIfPresent(Int.self, forKey: .stateSlots)) ?? defaults.stateSlots
        substeps = (try? container.decodeIfPresent(Int.self, forKey: .substeps)) ?? defaults.substeps
        clamp()
    }

    mutating func clamp() {
        count = count.clamped(to: Self.countRange)
        verticesPerItem = verticesPerItem.clamped(to: Self.verticesPerItemRange)
        stateSlots = stateSlots.clamped(to: Self.stateSlotRange)
        substeps = substeps.clamped(to: Self.substepRange)
    }

    /// The settings a built-in stage's user may change, as differences from
    /// the bundled values. Only these are saved, so a later version of the
    /// bundle still takes effect for everything the user left alone.
    /// Simulation and state slots follow the bundled shaders and never differ.
    struct Changes: Codable, Equatable {
        var primitive: GeometryPrimitive?
        var count: Int?
        var verticesPerItem: Int?
        var startFrom: GeometryStartFrom?
        var blend: GeometryBlend?
        var substeps: Int?

        var isEmpty: Bool { self == Changes() }
    }

    func changes(from base: GeometrySettings) -> Changes {
        Changes(
            primitive: primitive == base.primitive ? nil : primitive,
            count: count == base.count ? nil : count,
            verticesPerItem: verticesPerItem == base.verticesPerItem ? nil : verticesPerItem,
            startFrom: startFrom == base.startFrom ? nil : startFrom,
            blend: blend == base.blend ? nil : blend,
            substeps: substeps == base.substeps ? nil : substeps
        )
    }

    func applying(_ changes: Changes) -> GeometrySettings {
        var result = self
        result.primitive = changes.primitive ?? primitive
        result.count = changes.count ?? count
        result.verticesPerItem = changes.verticesPerItem ?? verticesPerItem
        result.startFrom = changes.startFrom ?? startFrom
        result.blend = changes.blend ?? blend
        result.substeps = changes.substeps ?? substeps
        result.clamp()
        return result
    }

    /// Changing these needs a recompile; the rest apply on the next frame.
    func needsRecompile(comparedTo other: GeometrySettings) -> Bool {
        blend != other.blend || simulation != other.simulation || stateSlots != other.stateSlots
    }
}

/// On-disk manifest stored next to shader.frag in each stage folder.
struct StageManifest: Codable {
    struct Param: Codable {
        var type: String?
        var value: [Double]
        var min: [Double]?
        var max: [Double]?
        /// Mirrors `@metadata(global)`; kept so effect-level controls are
        /// available before the stage finishes its first compile.
        var global: Bool?

        enum CodingKeys: String, CodingKey {
            case type, value, min, max, global
        }

        init(type: String?, value: [Double], min: [Double]?, max: [Double]?, global: Bool?) {
            self.type = type
            self.value = value
            self.min = min
            self.max = max
            self.global = global
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            value = try container.decode([Double].self, forKey: .value)
            min = Self.decodeFlexibleDoubles(from: container, key: .min)
            max = Self.decodeFlexibleDoubles(from: container, key: .max)
            global = try container.decodeIfPresent(Bool.self, forKey: .global)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(type, forKey: .type)
            try container.encode(value, forKey: .value)
            try Self.encodeFlexibleDoubles(min, to: &container, key: .min)
            try Self.encodeFlexibleDoubles(max, to: &container, key: .max)
            if global == true {
                try container.encode(true, forKey: .global)
            }
        }

        private static func decodeFlexibleDoubles(
            from container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> [Double]? {
            if let values = try? container.decode([Double].self, forKey: key) { return values }
            if let value = try? container.decode(Double.self, forKey: key) { return [value] }
            return nil
        }

        private static func encodeFlexibleDoubles(
            _ values: [Double]?,
            to container: inout KeyedEncodingContainer<CodingKeys>,
            key: CodingKeys
        ) throws {
            guard let values else { return }
            if values.count == 1 {
                try container.encode(values[0], forKey: key)
            } else {
                try container.encode(values, forKey: key)
            }
        }
    }

    struct TextureBinding: Codable {
        var media: String?
        /// Mirrors `@metadata(global)`, as `Param.global` does.
        var global: Bool?
    }

    var name: String
    var params: [String: Param]?
    var textures: [String: TextureBinding]?
    /// Absent for fragment stages, including every stage written before
    /// geometry stages existed.
    var kind: StageKind?
    /// Every geometry setting, for user stages and the bundle's own files.
    var geometry: GeometrySettings?
    /// Built-in stage overrides only: what differs from the bundled settings.
    var geometryChanges: GeometrySettings.Changes?
}

/// One stage of an effect: a GLSL shader on disk plus runtime compile state.
final class Stage: Identifiable, ObservableObject {
    /// Folder name; doubles as the stable identifier. Built-in stages are
    /// identified by their effect folder and subfolder instead — see
    /// `Effect.builtInIDPrefix`.
    let id: String
    /// The stage folder: in Application Support for user stages, inside the
    /// effect's bundle folder for built-in ones.
    let folderURL: URL
    /// Shipped with the app. The shader and name are read-only; parameter and
    /// media choices still apply and are persisted in config.json.
    let isBuiltIn: Bool
    let kind: StageKind

    @Published var name: String
    /// The fragment shader: the whole stage for fragment stages.
    @Published var source: String
    /// Geometry stages only.
    @Published var vertexSource: String
    /// Geometry stages only; empty until the simulation pass is first enabled.
    @Published var simulationSource: String
    /// Geometry stages only.
    @Published var geometry: GeometrySettings
    /// The settings the stage was loaded with: for built-in stages, the
    /// bundle's, which saved changes are applied to and measured against.
    let bundledGeometry: GeometrySettings
    /// Bumped to restart the simulation from zeroed state.
    @Published var simulationResetCount = 0
    @Published var parameters: [StageParameter]
    @Published var textureBindings: [StageTextureBinding]
    /// From the last compile: errors, or warnings when it succeeded.
    @Published var diagnostics: [ShaderDiagnostic] = []
    /// From the owning effect's layout: `ceStageTexture("Name", ...)` calls
    /// whose name matches no stage (or several). Recomputed on every chain
    /// rebuild rather than on compile, so they follow renames and moves.
    @Published var layoutDiagnostics: [ShaderDiagnostic] = []
    /// Dropped from the effect's chain because a later stage of the same
    /// effect never samples `uPrev` and therefore discards this one's output.
    @Published var isShadowed = false

    /// Set after a successful compile; consumed by the render engine.
    var compiled: CompiledStage?

    /// Everything the editor and stage list should surface for this stage.
    var allDiagnostics: [ShaderDiagnostic] {
        diagnostics + layoutDiagnostics
    }

    /// Shown next to stages whose `isShadowed` flag is set.
    static let shadowedExplanation = """
    Not rendered: a later stage of this effect never samples uPrev, so it \
    replaces everything this stage would contribute. Reading this stage with \
    ceStageTexture() from any stage of the effect would keep it rendering.
    """

    /// Prelude-provided samplers that must not appear as media-library pickers.
    static let reservedTextureNames: Set<String> = [
        ShaderReflection.previousOutputSampler, "uFrames", ShaderReflection.stageTexturesSampler,
        ShaderReflection.stateSampler,
        VisionUniforms.personMatteSampler,
        VisionUniforms.faceMaskSampler,
        VisionUniforms.handMaskSampler,
    ]

    init(
        id: String,
        folderURL: URL,
        name: String,
        source: String,
        parameters: [StageParameter],
        textureBindings: [StageTextureBinding] = [],
        isBuiltIn: Bool = false,
        kind: StageKind = .fragment,
        vertexSource: String = "",
        simulationSource: String = "",
        geometry: GeometrySettings = GeometrySettings()
    ) {
        self.id = id
        self.folderURL = folderURL
        self.isBuiltIn = isBuiltIn
        self.kind = kind
        self.name = name
        self.source = source
        self.vertexSource = vertexSource
        self.simulationSource = simulationSource
        self.geometry = geometry
        self.bundledGeometry = geometry
        self.parameters = parameters
        self.textureBindings = textureBindings
    }

    /// The files edited in this stage's tabs, in order.
    var files: [ShaderFile] {
        kind.files(simulation: geometry.simulation)
    }

    func text(of file: ShaderFile) -> String {
        switch file {
        case .fragment: return source
        case .vertex: return vertexSource
        case .simulation: return simulationSource
        }
    }

    func setText(_ text: String, of file: ShaderFile) {
        switch file {
        case .fragment: source = text
        case .vertex: vertexSource = text
        case .simulation: simulationSource = text
        }
    }

    /// Everything a compile depends on. A compile whose input no longer
    /// matches the stage's by the time it finishes is discarded.
    var compileInput: StageCompileInput {
        StageCompileInput(
            kind: kind,
            fragmentSource: source,
            vertexSource: kind == .geometry ? vertexSource : "",
            simulationSource: kind == .geometry && geometry.simulation ? simulationSource : nil,
            stateSlots: geometry.stateSlots,
            blend: geometry.blend
        )
    }

    /// Controls listed on the owning effect as well as on this stage.
    var globalParameters: [StageParameter] {
        parameters.filter(\.isGlobal)
    }

    var globalTextureBindings: [StageTextureBinding] {
        textureBindings.filter(\.isGlobal)
    }

    var hasGlobalControls: Bool {
        parameters.contains(where: \.isGlobal) || textureBindings.contains(where: \.isGlobal)
    }

    /// Merges reflected `Params` members with existing parameter state,
    /// keeping persisted values and dropping stale entries.
    func syncParameters(with reflection: ShaderReflection) {
        guard let block = reflection.paramsBlock else {
            parameters = []
            return
        }
        parameters = block.members.map { member in
            let type = StageParameter.normalizeReflectionType(member.type)
            let count = StageParameter.componentCount(for: type)
            let existing = parameters.first(where: { $0.name == member.name && $0.values.count == count })
            return StageParameter.resolved(
                name: member.name,
                type: type,
                existing: existing,
                minimum: member.minimum,
                maximum: member.maximum,
                defaultValue: member.defaultValue,
                isColor: member.isColor,
                isGlobal: member.isGlobal
            )
        }
    }

    /// Merges reflected user `sampler2D` uniforms with persisted library assignments.
    func syncTextureBindings(with reflection: ShaderReflection) {
        let bindings = reflection.textures.filter {
            $0.dim == "2d" && !Self.reservedTextureNames.contains($0.name)
        }
        textureBindings = bindings.map { binding in
            var resolved = textureBindings.first { $0.name == binding.name }
                ?? StageTextureBinding(name: binding.name, mediaID: nil)
            resolved.isGlobal = binding.isGlobal ?? false
            return resolved
        }
    }

    /// Pushes all current parameter values into the compiled stage's buffer.
    func applyParameters() {
        guard let compiled else { return }
        for parameter in parameters {
            let type = StageParameter.normalizeReflectionType(parameter.type)
            compiled.writeParam(name: parameter.name, type: type, values: parameter.values)
        }
    }

    /// Overlays saved parameter values and media picks onto this stage,
    /// keeping the shader-defined ranges. Used for built-in stages, whose
    /// bundled stage.json is never rewritten.
    func applyManifestValues(_ manifest: StageManifest) {
        for (name, param) in manifest.params ?? [:] {
            guard let index = parameters.firstIndex(where: { $0.name == name }),
                  parameters[index].values.count == param.value.count
            else { continue }
            parameters[index].values = param.value
        }
        for (name, binding) in manifest.textures ?? [:] {
            if let index = textureBindings.firstIndex(where: { $0.name == name }) {
                textureBindings[index].mediaID = binding.media
            } else {
                textureBindings.append(StageTextureBinding(name: name, mediaID: binding.media))
            }
        }
        // A full `geometry` saved by an earlier build is ignored: it was
        // written after every compile, so it mostly repeats old bundle values.
        if kind == .geometry, let changes = manifest.geometryChanges {
            geometry = bundledGeometry.applying(changes)
        }
    }

    var manifest: StageManifest {
        var params: [String: StageManifest.Param] = [:]
        for parameter in parameters {
            params[parameter.name] = StageManifest.Param(
                type: parameter.type,
                value: parameter.values,
                min: parameter.minimum,
                max: parameter.maximum,
                global: parameter.isGlobal ? true : nil
            )
        }
        var textureManifest: [String: StageManifest.TextureBinding] = [:]
        for binding in textureBindings {
            textureManifest[binding.name] = StageManifest.TextureBinding(
                media: binding.mediaID,
                global: binding.isGlobal ? true : nil
            )
        }
        return StageManifest(
            name: name,
            params: params,
            textures: textureManifest.isEmpty ? nil : textureManifest,
            kind: kind == .geometry ? .geometry : nil,
            geometry: kind == .geometry && !isBuiltIn ? geometry : nil,
            geometryChanges: kind == .geometry && isBuiltIn ? nonEmpty(geometry.changes(from: bundledGeometry)) : nil
        )
    }
}

private func nonEmpty(_ changes: GeometrySettings.Changes) -> GeometrySettings.Changes? {
    changes.isEmpty ? nil : changes
}

/// The inputs of one stage compile; see `Stage.compileInput`.
struct StageCompileInput: Equatable {
    var kind: StageKind
    var fragmentSource: String
    var vertexSource: String
    /// Nil while the simulation pass is off.
    var simulationSource: String?
    var stateSlots: Int
    var blend: GeometryBlend
}
