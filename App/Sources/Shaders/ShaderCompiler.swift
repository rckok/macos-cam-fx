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
        /// Inspector range from a preceding `// @metadata(...)` line, if any.
        var minimum: [Double]? = nil
        var maximum: [Double]? = nil
        var defaultValue: [Double]? = nil
        var isColor: Bool? = nil

        enum CodingKeys: String, CodingKey {
            case name, type, offset
        }
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

    /// Prelude sampler carrying the previous pass' output.
    static let previousOutputSampler = "uPrev"

    /// True when the shader reads `uPrev`, i.e. it builds on the output of the
    /// effects before it. A prelude uniform the user source never references is
    /// dead-code-eliminated by the transpiler and reported with a negative
    /// Metal resource index, so it does not count.
    var samplesPreviousOutput: Bool {
        textures.contains { $0.name == Self.previousOutputSampler && $0.mslTexture >= 0 }
    }
}

struct ShaderCompileOutput {
    let msl: String
    let reflection: ShaderReflection
    /// Warnings that did not fail the compile.
    let diagnostics: [ShaderDiagnostic]
}

struct ShaderDiagnostic: Identifiable, Equatable, Error {
    enum Severity: Equatable {
        case error
        case warning
    }

    let id = UUID()
    /// 1-based line in the *user's* source, if the error maps to one.
    let line: Int?
    let message: String
    var severity: Severity = .error

    static func == (lhs: ShaderDiagnostic, rhs: ShaderDiagnostic) -> Bool {
        lhs.line == rhs.line && lhs.message == rhs.message && lhs.severity == rhs.severity
    }
}

struct ShaderCompileError: Error {
    let diagnostics: [ShaderDiagnostic]
}

/// Compiles user GLSL fragment shaders to MSL, injecting the standard effect
/// prelude and remapping compiler error lines back to user-source lines.
enum ShaderCompiler {

    /// Interface every effect shader sees. Uniform bindings 0-2 are reserved;
    /// user `Params` blocks conventionally use binding 3, user samplers
    /// bindings 4-15. Bindings 16-20 carry the vision data (segmentation
    /// mattes, face/hand observations); the underlying detectors only run
    /// while an enabled effect actually uses one of those uniforms.
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

    // Vision data. Textures and observation coordinates are in vUV space
    // (top-left origin, mirroring already applied).
    layout(binding = 16) uniform sampler2D uPersonMatte; // luma matte: 1 = person, 0 = background
    layout(binding = 17) uniform sampler2D uFaceMask;    // R = left eye, G = right eye, B = mouth, A = union
    layout(binding = 18) uniform sampler2D uHandMask;    // approximate hand silhouette (luma)

    layout(std140, binding = 19) uniform CEFace {
        int  uFaceCount;        // detected faces (0 ... CE_MAX_FACES)
        vec4 uFaceRects[4];     // xy = top-left origin, zw = size, in vUV space
        vec4 uFaceOriented[4];  // xy = centre in vUV, zw = size of the rolled box in frame heights
        vec4 uFaceAngles[4];    // x = roll, y = yaw, z = pitch (radians), w = confidence
    };

    layout(std140, binding = 20) uniform CEHands {
        int  uHandCount;      // detected hands (0 ... CE_MAX_HANDS)
        vec4 uHandInfo[2];    // x = chirality (-1 left, +1 right, 0 unknown), y = confidence
        vec4 uHandJoints[42]; // 21 joints per hand: xy = vUV position, z = confidence
    };

    #define CE_MAX_FACES 4
    #define CE_MAX_HANDS 2
    #define CE_HAND_JOINTS 21

    // Joint indices into uHandJoints (per hand), wrist to fingertips:
    #define CE_WRIST      0
    #define CE_THUMB_CMC  1
    #define CE_THUMB_MP   2
    #define CE_THUMB_IP   3
    #define CE_THUMB_TIP  4
    #define CE_INDEX_MCP  5
    #define CE_INDEX_PIP  6
    #define CE_INDEX_DIP  7
    #define CE_INDEX_TIP  8
    #define CE_MIDDLE_MCP 9
    #define CE_MIDDLE_PIP 10
    #define CE_MIDDLE_DIP 11
    #define CE_MIDDLE_TIP 12
    #define CE_RING_MCP   13
    #define CE_RING_PIP   14
    #define CE_RING_DIP   15
    #define CE_RING_TIP   16
    #define CE_LITTLE_MCP 17
    #define CE_LITTLE_PIP 18
    #define CE_LITTLE_DIP 19
    #define CE_LITTLE_TIP 20

    vec4 ceHistory(vec2 uv, int ago) {
        int idx = uHeadIndex - ago;
        idx = ((idx % uFrameCount) + uFrameCount) % uFrameCount;
        float z = (float(idx) + 0.5) / float(uFrameCount);
        return texture(uFrames, vec3(uv, z));
    }

    vec4 ceHandJoint(int hand, int joint) {
        return uHandJoints[hand * CE_HAND_JOINTS + joint];
    }

    // Maps uv into the local frame of a face: (0, 0) at the centre of its box,
    // +-1 at the edges, x along the face's right and y towards its chin. The
    // frame rotates with the head, so this is the rotated counterpart of
    // uFaceRects. Aspect is corrected with uResolution, keeping the box
    // rectangular on screen.
    vec2 ceFaceLocal(int face, vec2 uv) {
        vec4 box = uFaceOriented[face];
        float aspect = uResolution.x / max(uResolution.y, 1.0);
        vec2 d = vec2((uv.x - box.x) * aspect, uv.y - box.y);
        float c = cos(uFaceAngles[face].x);
        float s = sin(uFaceAngles[face].x);
        vec2 local = vec2(c * d.x + s * d.y, c * d.y - s * d.x);
        return local / max(box.zw * 0.5, vec2(1e-6));
    }

    // 1 inside the rotated box of `face`, 0 outside.
    float ceFaceBox(int face, vec2 uv) {
        vec2 p = abs(ceFaceLocal(face, uv));
        return step(max(p.x, p.y), 1.0);
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

        let log = logOut.map { String(cString: $0) } ?? ""
        var diagnostics = parseDiagnostics(log: log)

        guard status == 0, let mslOut, let reflectionOut else {
            diagnostics.append(contentsOf: ParamMetadataParser.parse(from: userSource).diagnostics)
            throw ShaderCompileError(diagnostics: diagnostics.isEmpty
                ? [ShaderDiagnostic(line: nil, message: log.isEmpty ? "Unknown shader compile error" : log)]
                : diagnostics)
        }

        let msl = String(cString: mslOut)
        let reflectionJSON = Data(String(cString: reflectionOut).utf8)
        let decoded = try JSONDecoder().decode(ShaderReflection.self, from: reflectionJSON)
        let (reflection, metadataDiagnostics) = applyingParamMetadata(decoded, source: userSource)
        diagnostics.append(contentsOf: metadataDiagnostics)
        if diagnostics.contains(where: { $0.severity == .error }) {
            throw ShaderCompileError(diagnostics: diagnostics)
        }
        return ShaderCompileOutput(
            msl: msl,
            reflection: reflection,
            diagnostics: diagnostics.filter { $0.severity == .warning }
        )
    }

    private static func applyingParamMetadata(
        _ reflection: ShaderReflection,
        source: String
    ) -> (ShaderReflection, [ShaderDiagnostic]) {
        let parsed = ParamMetadataParser.parse(from: source)
        var diagnostics = parsed.diagnostics
        guard !parsed.metadata.isEmpty || !diagnostics.isEmpty else {
            return (reflection, diagnostics)
        }

        let blocks = reflection.uniformBlocks.map { block -> ShaderReflection.UniformBlock in
            guard block.name == "Params" else { return block }
            let members = block.members.map { member -> ShaderReflection.BlockMember in
                guard let meta = parsed.metadata[member.name] else { return member }
                let expected = EffectParameter.componentCount(for: member.type)
                var updated = member
                var valid = true

                func align(_ values: [Double]?, key: String) -> [Double]? {
                    guard let values else { return nil }
                    switch ParamMetadataParser.alignedComponents(
                        values,
                        expected: expected,
                        key: key,
                        type: member.type,
                        name: member.name,
                        line: meta.line
                    ) {
                    case .success(let aligned):
                        return aligned
                    case .failure(let diagnostic):
                        diagnostics.append(diagnostic)
                        valid = false
                        return nil
                    }
                }

                let minimum = align(meta.minimum, key: "min")
                let maximum = align(meta.maximum, key: "max")
                let defaultValue = align(meta.defaultValue, key: "default")
                if let minimum, let maximum {
                    for (index, pair) in zip(minimum, maximum).enumerated() where pair.0 > pair.1 {
                        diagnostics.append(ShaderDiagnostic(
                            line: meta.line,
                            message: "@metadata min exceeds max for \(member.type) \(member.name) component \(index)",
                            severity: .error
                        ))
                        valid = false
                    }
                }
                guard valid else { return member }
                updated.minimum = minimum
                updated.maximum = maximum
                updated.defaultValue = defaultValue
                updated.isColor = meta.isColor
                return updated
            }
            return ShaderReflection.UniformBlock(
                name: block.name,
                binding: block.binding,
                mslBuffer: block.mslBuffer,
                size: block.size,
                members: members
            )
        }
        return (
            ShaderReflection(
                entryPoint: reflection.entryPoint,
                textures: reflection.textures,
                uniformBlocks: blocks
            ),
            diagnostics
        )
    }

    /// Parses glslang and Metal compiler logs and maps line numbers past
    /// the injected prelude back to the user's source.
    static func parseDiagnostics(log: String) -> [ShaderDiagnostic] {
        var diagnostics: [ShaderDiagnostic] = []
        let glslangPattern = /(ERROR|WARNING):\s+\d+:(\d+):\s*(.*)/
        let metalPattern = /(?:^|\n)[^:\n]+:(\d+):\d+:\s*(error|warning):\s*([^\n]+)/

        for rawLine in log.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let match = line.firstMatch(of: glslangPattern) {
                let severity: ShaderDiagnostic.Severity = String(match.1) == "WARNING" ? .warning : .error
                let compilerLine = Int(match.2) ?? 0
                let userLine = compilerLine - preludeLineCount
                let message = String(match.3)
                if isSummaryMessage(message) { continue }
                diagnostics.append(ShaderDiagnostic(
                    line: userLine >= 1 ? userLine : nil,
                    message: message,
                    severity: severity
                ))
            } else if line.uppercased().hasPrefix("ERROR:") {
                let message = String(line.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces)
                if isSummaryMessage(message) { continue }
                diagnostics.append(ShaderDiagnostic(line: nil, message: message, severity: .error))
            } else if line.uppercased().hasPrefix("WARNING:") {
                let message = String(line.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces)
                if isSummaryMessage(message) { continue }
                diagnostics.append(ShaderDiagnostic(line: nil, message: message, severity: .warning))
            }
        }

        if diagnostics.isEmpty {
            for match in log.matches(of: metalPattern) {
                let severity: ShaderDiagnostic.Severity = String(match.2).lowercased() == "warning" ? .warning : .error
                diagnostics.append(ShaderDiagnostic(
                    line: nil,
                    message: String(match.3),
                    severity: severity
                ))
            }
        }

        if diagnostics.isEmpty, !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(ShaderDiagnostic(line: nil, message: log))
        }

        var seen = Set<String>()
        return diagnostics.filter { diagnostic in
            let key = "\(diagnostic.severity)-\(diagnostic.line ?? 0)-\(diagnostic.message)"
            return seen.insert(key).inserted
        }
    }

    private static func isSummaryMessage(_ message: String) -> Bool {
        message.contains("compilation errors") || message.contains("No code generated")
    }
}
