import Foundation

/// A user-tweakable shader parameter, reflected from the shader's `Params`
/// uniform block and merged with persisted values from effect.json.
struct EffectParameter: Identifiable, Equatable {
    let name: String
    /// GLSL type name: float, int, bool, vec2, vec3, vec4.
    let type: String
    var values: [Double]
    var minimum: [Double]
    var maximum: [Double]
    /// vec3/vec4 use per-component sliders unless `@metadata(color=true)`.
    var isColor: Bool = false

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

    static func makeDefault(name: String, type: String) -> EffectParameter {
        let normalized = normalizeReflectionType(type)
        let count = componentCount(for: normalized)
        switch normalized {
        case "bool", "bvec2", "bvec3", "bvec4", "uint", "uvec2", "uvec3", "uvec4":
            return EffectParameter(
                name: name,
                type: normalized,
                values: Array(repeating: 0, count: count),
                minimum: Array(repeating: 0, count: count),
                maximum: Array(repeating: 1, count: count)
            )
        case "int", "ivec2", "ivec3", "ivec4":
            return EffectParameter(
                name: name,
                type: normalized,
                values: Array(repeating: 0, count: count),
                minimum: Array(repeating: 0, count: count),
                maximum: Array(repeating: 10, count: count)
            )
        case "vec3", "vec4":
            return EffectParameter(
                name: name,
                type: normalized,
                values: Array(repeating: 1, count: count),
                minimum: Array(repeating: 0, count: count),
                maximum: Array(repeating: 1, count: count)
            )
        default:
            return EffectParameter(
                name: name,
                type: normalized,
                values: Array(repeating: 0.5, count: count),
                minimum: Array(repeating: 0, count: count),
                maximum: Array(repeating: 1, count: count)
            )
        }
    }

    /// Builds a parameter from reflection, optional shader `@metadata`, and
    /// any value already stored in the effect. Shader min/max/`color` win when
    /// present; the current value is kept and clamped into the resulting range.
    static func resolved(
        name: String,
        type: String,
        existing: EffectParameter?,
        minimum: [Double]?,
        maximum: [Double]?,
        defaultValue: [Double]?,
        isColor: Bool?
    ) -> EffectParameter {
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

        return EffectParameter(
            name: name,
            type: normalized,
            values: values,
            minimum: minima,
            maximum: maxima,
            isColor: isColor ?? typeDefaults.isColor
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

/// A named pipeline group that can be enabled/disabled as a whole.
struct EffectGroup: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var enabled: Bool
    var effectIDs: [String]

    init(id: String, name: String, enabled: Bool = true, effectIDs: [String] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.effectIDs = effectIDs
    }
}

/// Assigns a media-library asset to a `sampler2D` uniform in the effect shader.
struct EffectTextureBinding: Identifiable, Equatable {
    /// GLSL sampler name, e.g. `uOverlay`.
    let name: String
    /// ID of the asset in the shared media library, if assigned.
    var mediaID: String?

    var id: String { name }
}

/// On-disk manifest stored next to shader.frag in each effect folder.
struct EffectManifest: Codable {
    struct Param: Codable {
        var type: String?
        var value: [Double]
        var min: [Double]?
        var max: [Double]?

        enum CodingKeys: String, CodingKey {
            case type, value, min, max
        }

        init(type: String?, value: [Double], min: [Double]?, max: [Double]?) {
            self.type = type
            self.value = value
            self.min = min
            self.max = max
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            value = try container.decode([Double].self, forKey: .value)
            min = Self.decodeFlexibleDoubles(from: container, key: .min)
            max = Self.decodeFlexibleDoubles(from: container, key: .max)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(type, forKey: .type)
            try container.encode(value, forKey: .value)
            try Self.encodeFlexibleDoubles(min, to: &container, key: .min)
            try Self.encodeFlexibleDoubles(max, to: &container, key: .max)
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
    }

    var name: String
    var enabled: Bool?
    var params: [String: Param]?
    var textures: [String: TextureBinding]?
}

/// One effect: a GLSL shader on disk plus runtime compile state.
final class Effect: Identifiable, ObservableObject {
    /// Folder name; doubles as the stable identifier.
    let id: String
    let folderURL: URL

    @Published var name: String
    @Published var enabled: Bool
    @Published var source: String
    @Published var parameters: [EffectParameter]
    @Published var textureBindings: [EffectTextureBinding]
    @Published var diagnostics: [ShaderDiagnostic] = []
    /// Enabled, but dropped from the render chain because a later enabled
    /// effect never samples `uPrev` and therefore discards this one's output.
    @Published var isShadowed = false

    /// Set after a successful compile; consumed by the render engine.
    var compiled: CompiledEffect?

    /// Shown next to effects whose `isShadowed` flag is set.
    static let shadowedExplanation = """
    Not rendered: a later enabled effect never samples uPrev, so it replaces \
    everything this effect would contribute.
    """

    /// Prelude-provided samplers that must not appear as media-library pickers.
    static let reservedTextureNames: Set<String> = [
        "uPrev", "uFrames",
        VisionUniforms.personMatteSampler,
        VisionUniforms.faceMaskSampler,
        VisionUniforms.handMaskSampler,
    ]

    init(
        id: String,
        folderURL: URL,
        name: String,
        enabled: Bool,
        source: String,
        parameters: [EffectParameter],
        textureBindings: [EffectTextureBinding] = []
    ) {
        self.id = id
        self.folderURL = folderURL
        self.name = name
        self.enabled = enabled
        self.source = source
        self.parameters = parameters
        self.textureBindings = textureBindings
    }

    /// Merges reflected `Params` members with existing parameter state,
    /// keeping persisted values and dropping stale entries.
    func syncParameters(with reflection: ShaderReflection) {
        guard let block = reflection.paramsBlock else {
            parameters = []
            return
        }
        parameters = block.members.map { member in
            let type = EffectParameter.normalizeReflectionType(member.type)
            let count = EffectParameter.componentCount(for: type)
            let existing = parameters.first(where: { $0.name == member.name && $0.values.count == count })
            return EffectParameter.resolved(
                name: member.name,
                type: type,
                existing: existing,
                minimum: member.minimum,
                maximum: member.maximum,
                defaultValue: member.defaultValue,
                isColor: member.isColor
            )
        }
    }

    /// Merges reflected user `sampler2D` uniforms with persisted library assignments.
    func syncTextureBindings(with reflection: ShaderReflection) {
        let bindings = reflection.textures.filter {
            $0.dim == "2d" && !Self.reservedTextureNames.contains($0.name)
        }
        textureBindings = bindings.map { binding in
            if let existing = textureBindings.first(where: { $0.name == binding.name }) {
                return existing
            }
            return EffectTextureBinding(name: binding.name, mediaID: nil)
        }
    }

    /// Pushes all current parameter values into the compiled effect's buffer.
    func applyParameters() {
        guard let compiled else { return }
        for parameter in parameters {
            let type = EffectParameter.normalizeReflectionType(parameter.type)
            compiled.writeParam(name: parameter.name, type: type, values: parameter.values)
        }
    }

    var manifest: EffectManifest {
        var params: [String: EffectManifest.Param] = [:]
        for parameter in parameters {
            params[parameter.name] = EffectManifest.Param(
                type: parameter.type,
                value: parameter.values,
                min: parameter.minimum,
                max: parameter.maximum
            )
        }
        var textureManifest: [String: EffectManifest.TextureBinding] = [:]
        for binding in textureBindings {
            textureManifest[binding.name] = EffectManifest.TextureBinding(media: binding.mediaID)
        }
        return EffectManifest(
            name: name,
            enabled: enabled,
            params: params,
            textures: textureManifest.isEmpty ? nil : textureManifest
        )
    }
}
