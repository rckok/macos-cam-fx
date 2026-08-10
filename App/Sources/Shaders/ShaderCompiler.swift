import Foundation

/// Reflection data produced by the transpiler for one compiled fragment shader.
struct ShaderReflection: Codable {
    struct TextureBinding: Codable {
        let name: String
        let binding: Int
        let mslTexture: Int
        let mslSampler: Int
        let dim: String
    }

    struct BlockMember: Codable {
        let name: String
        let type: String
        let offset: Int
    }

    struct UniformBlock: Codable {
        let name: String
        let binding: Int
        let mslBuffer: Int
        let size: Int
        let members: [BlockMember]
    }

    let entryPoint: String
    let textures: [TextureBinding]
    let uniformBlocks: [UniformBlock]

    var paramsBlock: UniformBlock? {
        uniformBlocks.first { $0.name == "Params" }
    }
}

struct ShaderCompileOutput {
    let msl: String
    let reflection: ShaderReflection
}

struct ShaderDiagnostic: Identifiable, Equatable {
    let id = UUID()
    /// 1-based line in the *user's* source, if the error maps to one.
    let line: Int?
    let message: String

    static func == (lhs: ShaderDiagnostic, rhs: ShaderDiagnostic) -> Bool {
        lhs.line == rhs.line && lhs.message == rhs.message
    }
}

struct ShaderCompileError: Error {
    let diagnostics: [ShaderDiagnostic]
}

/// Compiles user GLSL fragment shaders to MSL, injecting the standard effect
/// prelude and remapping compiler error lines back to user-source lines.
enum ShaderCompiler {

    /// Interface every effect shader sees. Uniform bindings 0-2 are reserved;
    /// user `Params` blocks conventionally use binding 3.
    static let prelude = """
    #version 450

    layout(location = 0) in vec2 vUV;
    layout(location = 0) out vec4 outColor;

    layout(binding = 0) uniform sampler2D uPrev;
    layout(binding = 1) uniform sampler3D uFrames;

    layout(std140, binding = 2) uniform CEContext {
        vec2  uResolution;
        float uTime;
        float uTimeDelta;
        int   uFrameCount;
        int   uHeadIndex;
        int   uFrameNumber;
        float _cePad0;
    };

    vec4 ceHistory(vec2 uv, int ago) {
        int idx = uHeadIndex - ago;
        idx = ((idx % uFrameCount) + uFrameCount) % uFrameCount;
        float z = (float(idx) + 0.5) / float(uFrameCount);
        return texture(uFrames, vec3(uv, z));
    }

    """

    private static let preludeLineCount = prelude.components(separatedBy: "\n").count - 1

    private static var initialized = false
    private static let initLock = NSLock()

    static func compile(userSource: String) throws -> ShaderCompileOutput {
        initLock.lock()
        if !initialized {
            guard st_initialize() == 0 else {
                initLock.unlock()
                throw ShaderCompileError(diagnostics: [
                    ShaderDiagnostic(line: nil, message: "Failed to initialize shader compiler")
                ])
            }
            initialized = true
        }
        initLock.unlock()

        // Strip a user-provided #version line; the prelude supplies it.
        var source = userSource
        var strippedVersionLine = false
        let lines = source.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("#version") {
            source = (["// #version supplied by prelude"] + lines.dropFirst()).joined(separator: "\n")
            strippedVersionLine = true
            _ = strippedVersionLine
        }

        let fullSource = prelude + source

        var mslOut: UnsafeMutablePointer<CChar>?
        var reflectionOut: UnsafeMutablePointer<CChar>?
        var logOut: UnsafeMutablePointer<CChar>?

        let status = st_compile_fragment(fullSource, &mslOut, &reflectionOut, &logOut)
        defer {
            st_string_free(mslOut)
            st_string_free(reflectionOut)
            st_string_free(logOut)
        }

        guard status == 0, let mslOut, let reflectionOut else {
            let log = logOut.map { String(cString: $0) } ?? "Unknown shader compile error"
            throw ShaderCompileError(diagnostics: parseDiagnostics(log: log))
        }

        let msl = String(cString: mslOut)
        let reflectionJSON = Data(String(cString: reflectionOut).utf8)
        let reflection = try JSONDecoder().decode(ShaderReflection.self, from: reflectionJSON)
        return ShaderCompileOutput(msl: msl, reflection: reflection)
    }

    /// Parses glslang logs ("ERROR: 0:12: message") and maps line numbers past
    /// the injected prelude back to the user's source.
    private static func parseDiagnostics(log: String) -> [ShaderDiagnostic] {
        var diagnostics: [ShaderDiagnostic] = []
        let pattern = /ERROR:\s+\d+:(\d+):\s*(.*)/

        for rawLine in log.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let match = line.firstMatch(of: pattern) {
                let compilerLine = Int(match.1) ?? 0
                let userLine = compilerLine - preludeLineCount
                diagnostics.append(ShaderDiagnostic(
                    line: userLine >= 1 ? userLine : nil,
                    message: String(match.2)
                ))
            } else if line.hasPrefix("ERROR:") {
                let message = String(line.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
                if message.hasPrefix("1 compilation errors") || message.contains("compilation errors.") {
                    continue
                }
                diagnostics.append(ShaderDiagnostic(line: nil, message: message))
            }
        }

        if diagnostics.isEmpty {
            diagnostics.append(ShaderDiagnostic(line: nil, message: log))
        }
        return diagnostics
    }
}
