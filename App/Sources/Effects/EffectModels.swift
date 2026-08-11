import Foundation

/// A user-tweakable shader parameter, reflected from the shader's `Params`
/// uniform block and merged with persisted values from effect.json.
struct EffectParameter: Identifiable, Equatable {
    let name: String
    /// GLSL type name: float, int, bool, vec2, vec3, vec4.
    let type: String
    var values: [Double]
    var minimum: Double
    var maximum: Double

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
        case floatSlider
        case intSlider
        case toggle(componentCount: Int)
        case vec2Fields
        case color(supportsOpacity: Bool)
        case unsupported(String)
    }

    var editorKind: EditorKind {
        switch Self.normalizeReflectionType(type) {
        case "float":
            return .floatSlider
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
            return .vec2Fields
        case "vec3":
            return .color(supportsOpacity: false)
        case "vec4":
            return .color(supportsOpacity: true)
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
            return EffectParameter(name: name, type: normalized, values: Array(repeating: 0, count: count), minimum: 0, maximum: 1)
        case "int", "ivec2", "ivec3", "ivec4":
            return EffectParameter(name: name, type: normalized, values: Array(repeating: 0, count: count), minimum: 0, maximum: 10)
        case "vec3", "vec4":
            return EffectParameter(name: name, type: normalized, values: Array(repeating: 1, count: count), minimum: 0, maximum: 1)
        default:
            return EffectParameter(name: name, type: normalized, values: Array(repeating: 0.5, count: count), minimum: 0, maximum: 1)
        }
    }
}

/// On-disk manifest stored next to shader.frag in each effect folder.
struct EffectManifest: Codable {
    struct Param: Codable {
        var type: String?
        var value: [Double]
        var min: Double?
        var max: Double?
    }

    var name: String
    var enabled: Bool?
    var params: [String: Param]?
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
    @Published var diagnostics: [ShaderDiagnostic] = []

    /// Set after a successful compile; consumed by the render engine.
    var compiled: CompiledEffect?

    init(id: String, folderURL: URL, name: String, enabled: Bool, source: String, parameters: [EffectParameter]) {
        self.id = id
        self.folderURL = folderURL
        self.name = name
        self.enabled = enabled
        self.source = source
        self.parameters = parameters
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
            // Match persisted parameters by name; the type stored before the
            // first compile is provisional (inferred from component count),
            // so adopt the reflected type as long as the shape matches.
            if let existing = parameters.first(where: { $0.name == member.name }),
               existing.values.count == count {
                return EffectParameter(
                    name: existing.name,
                    type: type,
                    values: existing.values,
                    minimum: existing.minimum,
                    maximum: existing.maximum
                )
            }
            return EffectParameter.makeDefault(name: member.name, type: type)
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
        return EffectManifest(name: name, enabled: enabled, params: params)
    }
}
