import Foundation

/// Reflection data produced by the transpiler for one compiled fragment shader.
struct ShaderReflection: Codable {
    struct TextureBinding: Codable {
        let name: String
        let binding: Int
        let mslTexture: Int
        let mslSampler: Int
        let dim: String
        /// From a preceding `// @metadata(global)` line, if any.
        var isGlobal: Bool? = nil

        enum CodingKeys: String, CodingKey {
            case name, binding, mslTexture, mslSampler, dim
        }
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
        var isGlobal: Bool? = nil

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
    /// Prelude array texture holding every stage's output (slice = stage index).
    static let stageTexturesSampler = "uStageTextures"
    /// Prelude block carrying the per-stage index, count, and resolved name refs.
    static let stagesBlock = "CEStages"

    /// True when the shader reads `uPrev`, i.e. it builds on the output of the
    /// stages before it. A prelude uniform the user source never references is
    /// dead-code-eliminated by the transpiler and reported with a negative
    /// Metal resource index, so it does not count.
    var samplesPreviousOutput: Bool {
        samples(Self.previousOutputSampler)
    }

    /// True when the shader reads other stages' outputs (or its own previous
    /// frame) through `ceStageTexture` / `ceSelfTexture`.
    var samplesStageTextures: Bool {
        samples(Self.stageTexturesSampler)
    }

    private func samples(_ name: String) -> Bool {
        textures.contains { $0.name == name && $0.mslTexture >= 0 }
    }
}

/// A `ceStageTexture("Name", ...)` call in user source, rewritten to read the
/// stage index from `uStageRefs[slot]`. The app resolves the name against the
/// owning effect whenever its layout changes, so no recompile is needed.
struct StageReference: Equatable {
    let name: String
    /// Index into `uStageRefs`.
    let slot: Int
    /// 1-based line in user source of the first call using this name.
    let line: Int
}

struct ShaderCompileOutput {
    let msl: String
    let reflection: ShaderReflection
    /// Warnings that did not fail the compile.
    let diagnostics: [ShaderDiagnostic]
    let stageReferences: [StageReference]
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

    /// Interface every stage shader sees. Uniform bindings 0-2 are reserved;
    /// user `Params` blocks conventionally use binding 3, user samplers
    /// bindings 4-15. Bindings 16-21 carry the vision data (segmentation
    /// mattes, face/hand observations); the underlying detectors only run
    /// while a stage of the active effect actually uses one of those uniforms.
    /// Bindings 22-23 expose every stage's output texture and the per-stage
    /// index data behind `ceStageTexture`.
    static let maxStageReferences = 8

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
        int  uFaceCount;      // detected faces (0 ... CE_MAX_FACES)
        vec4 uFaceRects[4];   // xy = top-left origin, zw = size, in vUV space
    };

    // Separate from CEFace so that using rectangles alone keeps the cheaper
    // detector: these centers need full facial-landmark detection. Indexed
    // like uFaceRects. Each entry: xy = center, z = 1 when located,
    // w = half the region's width (same units as uFaceRects.z).
    layout(std140, binding = 21) uniform CEFacePoints {
        vec4 uFaceLeftEye[4];
        vec4 uFaceRightEye[4];
        vec4 uFaceMouth[4];
    };

    layout(std140, binding = 20) uniform CEHands {
        int  uHandCount;      // detected hands (0 ... CE_MAX_HANDS)
        vec4 uHandInfo[2];    // x = chirality (-1 left, +1 right, 0 unknown), y = confidence
        vec4 uHandJoints[42]; // 21 joints per hand: xy = vUV position, z = confidence
    };

    // Stage outputs. Slice i holds the output of stage i of the active effect:
    // this frame's output for stages before the current one, the previous
    // frame's output for the current stage itself and every stage after it.
    layout(binding = 22) uniform sampler2DArray uStageTextures;

    layout(std140, binding = 23) uniform CEStages {
        int uStageIndex;       // position of this stage in the effect (0-based)
        int uStageCount;       // stages in the effect (= slices in uStageTextures)
        // Indices behind ceStageTexture("Name", ...) calls, four per vector.
        ivec4 uStageRefs[\(maxStageReferences / 4)];
    };

    #define CE_MAX_FACES 4
    #define CE_MAX_HANDS 2
    #define CE_HAND_JOINTS 21
    #define CE_MAX_STAGE_REFS \(maxStageReferences)

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

    // Output of stage `index`. Out-of-range indices (including the -1 the app
    // uses for a name it could not resolve) read as transparent black.
    vec4 ceStageTexture(int index, vec2 uv) {
        if (index < 0 || index >= uStageCount) { return vec4(0.0); }
        return texture(uStageTextures, vec3(uv, float(index)));
    }

    // This stage's own output from the previous frame (feedback buffer).
    vec4 ceSelfTexture(vec2 uv) {
        return ceStageTexture(uStageIndex, uv);
    }

    // Interleaved gradient noise (Jimenez 2014): a cheap, stable per-pixel
    // value in [0, 1) with no visible pattern. Pass vUV * uResolution.
    float ceNoise(vec2 pixel) {
        return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
    }

    // Single-pass disc blur: `taps` samples on a golden-angle spiral, rotated
    // per pixel so undersampling reads as fine grain rather than rings.
    // `radius` is in pixels; 16-32 taps is plenty. falloff 0.0 gives a flat
    // disc (bokeh), 1.0 a soft, roughly Gaussian look. Cost = taps reads.
    vec4 ceDiscBlur(sampler2D tex, vec2 uv, float radius, int taps, float falloff) {
        const float goldenAngle = 2.39996323;
        float rotation = ceNoise(uv * uResolution) * 6.28318531;
        vec2 scale = radius / uResolution;
        vec4 sum = vec4(0.0);
        float total = 0.0;
        for (int i = 0; i < 128; i++) {
            if (i >= taps) { break; }
            float r = sqrt((float(i) + 0.5) / float(taps));
            float a = float(i) * goldenAngle + rotation;
            float w = 1.0 - falloff * r * r;
            sum += texture(tex, uv + vec2(cos(a), sin(a)) * r * scale) * w;
            total += w;
        }
        return sum / max(total, 0.0001);
    }

    // Exact 3x3 Gaussian ([1 2 1] x [1 2 1] / 16) from four bilinear reads at
    // half-texel offsets. `spread` = 1.0 for one texel; larger values widen
    // the kernel (with some undersampling) at the same cost.
    vec4 ceGauss3x3(sampler2D tex, vec2 uv, float spread) {
        vec2 h = 0.5 * spread / uResolution;
        return 0.25 * (
            texture(tex, uv + vec2(-h.x, -h.y)) + texture(tex, uv + vec2(h.x, -h.y)) +
            texture(tex, uv + vec2(-h.x,  h.y)) + texture(tex, uv + vec2(h.x,  h.y))
        );
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

        let rewrite = rewritingStageNames(in: source)
        source = rewrite.source

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
        var diagnostics = parseDiagnostics(log: log) + rewrite.diagnostics

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
            diagnostics: diagnostics.filter { $0.severity == .warning },
            stageReferences: rewrite.references
        )
    }

    private static let stageNameCall = try! NSRegularExpression(
        pattern: #"\bceStageTexture\s*\(\s*"([^"\n]*)"\s*,"#
    )

    /// GLSL has no strings, so `ceStageTexture("Name", uv)` is rewritten to
    /// `ceStageTexture(uStageRefs[k / 4][k % 4], uv)` before compiling. Each
    /// distinct name gets one slot; the app fills the slot with the stage's
    /// current index. The rewrite stays on the same line, so diagnostics keep
    /// their lines.
    static func rewritingStageNames(
        in source: String
    ) -> (source: String, references: [StageReference], diagnostics: [ShaderDiagnostic]) {
        var references: [StageReference] = []
        var diagnostics: [ShaderDiagnostic] = []
        var rewritten: [String] = []

        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let lineNumber = index + 1
            let nsLine = line as NSString
            let matches = stageNameCall.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty else {
                rewritten.append(line)
                continue
            }

            var output = line
            for match in matches.reversed() {
                let name = nsLine.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let slot: Int
                if let existing = references.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    slot = existing.slot
                } else if references.count < maxStageReferences {
                    slot = references.count
                    references.append(StageReference(name: name, slot: slot, line: lineNumber))
                } else {
                    diagnostics.append(ShaderDiagnostic(
                        line: lineNumber,
                        message: "ceStageTexture references more than \(maxStageReferences) distinct stage names",
                        severity: .error
                    ))
                    continue
                }
                if name.isEmpty {
                    diagnostics.append(ShaderDiagnostic(
                        line: lineNumber,
                        message: "ceStageTexture stage name is empty",
                        severity: .error
                    ))
                }
                let replacement = "ceStageTexture(uStageRefs[\(slot / 4)][\(slot % 4)],"
                output = (output as NSString).replacingCharacters(in: match.range, with: replacement)
            }
            rewritten.append(output)
        }

        return (rewritten.joined(separator: "\n"), references, diagnostics)
    }

    private static func applyingParamMetadata(
        _ reflection: ShaderReflection,
        source: String
    ) -> (ShaderReflection, [ShaderDiagnostic]) {
        let parsed = ParamMetadataParser.parse(from: source)
        var diagnostics = parsed.diagnostics
        guard !parsed.metadata.isEmpty || !parsed.samplerMetadata.isEmpty || !diagnostics.isEmpty else {
            return (reflection, diagnostics)
        }

        let blocks = reflection.uniformBlocks.map { block -> ShaderReflection.UniformBlock in
            guard block.name == "Params" else { return block }
            let members = block.members.map { member -> ShaderReflection.BlockMember in
                guard let meta = parsed.metadata[member.name] else { return member }
                let expected = StageParameter.componentCount(for: member.type)
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
                updated.isGlobal = meta.isGlobal
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
        let textures = reflection.textures.map { texture -> ShaderReflection.TextureBinding in
            guard let meta = parsed.samplerMetadata[texture.name] else { return texture }
            var updated = texture
            updated.isGlobal = meta.isGlobal
            return updated
        }

        return (
            ShaderReflection(
                entryPoint: reflection.entryPoint,
                textures: textures,
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
