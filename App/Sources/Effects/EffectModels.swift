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

    static func componentCount(for type: String) -> Int {
        switch type {
        case "vec2", "ivec2": return 2
        case "vec3", "ivec3": return 3
        case "vec4", "ivec4": return 4
        default: return 1
        }
    }

    static func makeDefault(name: String, type: String) -> EffectParameter {
        let count = componentCount(for: type)
        switch type {
        case "bool":
            return EffectParameter(name: name, type: type, values: [0], minimum: 0, maximum: 1)
        case "int":
            return EffectParameter(name: name, type: type, values: [0], minimum: 0, maximum: 10)
        case "vec3", "vec4":
            return EffectParameter(name: name, type: type, values: Array(repeating: 1, count: count), minimum: 0, maximum: 1)
        default:
            return EffectParameter(name: name, type: type, values: Array(repeating: 0.5, count: count), minimum: 0, maximum: 1)
        }
    }
}

/// On-disk manifest stored next to shader.frag in each effect folder.
struct EffectManifest: Codable {
    struct Param: Codable {
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
            // Match persisted parameters by name; the type stored before the
            // first compile is provisional (inferred from component count),
            // so adopt the reflected type as long as the shape matches.
            if let existing = parameters.first(where: { $0.name == member.name }),
               existing.values.count == EffectParameter.componentCount(for: member.type) {
                return EffectParameter(
                    name: existing.name,
                    type: member.type,
                    values: existing.values,
                    minimum: existing.minimum,
                    maximum: existing.maximum
                )
            }
            return EffectParameter.makeDefault(name: member.name, type: member.type)
        }
    }

    /// Pushes all current parameter values into the compiled effect's buffer.
    func applyParameters() {
        guard let compiled else { return }
        for parameter in parameters {
            compiled.writeParam(name: parameter.name, type: parameter.type, values: parameter.values)
        }
    }

    var manifest: EffectManifest {
        var params: [String: EffectManifest.Param] = [:]
        for parameter in parameters {
            params[parameter.name] = EffectManifest.Param(
                value: parameter.values,
                min: parameter.minimum,
                max: parameter.maximum
            )
        }
        return EffectManifest(name: name, enabled: enabled, params: params)
    }
}
