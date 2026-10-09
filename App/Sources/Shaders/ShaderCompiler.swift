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
    /// Geometry stages: the draw and simulation counters.
    static let geometryBlock = "CEGeometry"
    /// Geometry stages: the simulation state, one array slice per slot.
    static let stateSampler = "uState"

    /// One reflection standing for all of a stage's shader files, for the
    /// questions asked about the stage as a whole: which controls it has, which
    /// prelude resources it reads. Never used to bind resources — Metal
    /// indices differ per function. A resource counts as used when any file
    /// uses it; `Params` members are merged by name, the first file's
    /// declaration (and metadata) winning.
    static func merged(_ reflections: [ShaderReflection]) -> ShaderReflection {
        guard reflections.count > 1, let first = reflections.first else {
            return reflections.first ?? ShaderReflection(entryPoint: "main0", textures: [], uniformBlocks: [])
        }

        var textures: [TextureBinding] = []
        for texture in reflections.flatMap(\.textures) {
            guard let index = textures.firstIndex(where: { $0.name == texture.name }) else {
                textures.append(texture)
                continue
            }
            let isGlobal = textures[index].isGlobal == true || texture.isGlobal == true
            if textures[index].mslTexture < 0 && texture.mslTexture >= 0 {
                textures[index] = texture
            }
            textures[index].isGlobal = isGlobal ? true : nil
        }

        var blocks: [UniformBlock] = []
        for block in reflections.flatMap(\.uniformBlocks) {
            guard let index = blocks.firstIndex(where: { $0.name == block.name }) else {
                blocks.append(block)
                continue
            }
            let existing = blocks[index]
            let members = existing.members + block.members.filter { member in
                !existing.members.contains { $0.name == member.name }
            }
            blocks[index] = UniformBlock(
                name: existing.name,
                binding: existing.binding,
                mslBuffer: max(existing.mslBuffer, block.mslBuffer),
                size: max(existing.size, block.size),
                members: members
            )
        }

        return ShaderReflection(entryPoint: first.entryPoint, textures: textures, uniformBlocks: blocks)
    }

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
    /// The shader file holding that call.
    var file: ShaderFile = .fragment
}

/// One GLSL source file of a stage. Fragment stages only have `fragment`;
/// geometry stages always have `vertex` and `fragment`, plus `simulation`
/// while their simulation pass is on.
enum ShaderFile: String, CaseIterable, Identifiable {
    case simulation
    case vertex
    case fragment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simulation: return "Simulation"
        case .vertex: return "Vertex"
        case .fragment: return "Fragment"
        }
    }

    var fileName: String {
        switch self {
        case .simulation: return "simulate.frag"
        case .vertex: return "shader.vert"
        case .fragment: return "shader.frag"
        }
    }
}

/// Which interface the prelude declares around a user source file.
enum ShaderPrelude: Equatable {
    /// A fragment stage: one fullscreen pass with `vUV` in and `outColor` out.
    case fullscreen
    /// A geometry stage's simulation pass, writing one `outStateN` per slot.
    case simulation(stateSlots: Int)
    /// A geometry stage's vertex shader.
    case geometryVertex
    /// A geometry stage's fragment shader, fed by its vertex shader.
    case geometryFragment

    var isGeometry: Bool {
        self != .fullscreen
    }
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
    /// The stage file `line` refers to.
    var file: ShaderFile = .fragment

    static func == (lhs: ShaderDiagnostic, rhs: ShaderDiagnostic) -> Bool {
        lhs.line == rhs.line && lhs.message == rhs.message && lhs.severity == rhs.severity
            && lhs.file == rhs.file
    }

    func inFile(_ file: ShaderFile) -> ShaderDiagnostic {
        var copy = self
        copy.file = file
        return copy
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
    /// bindings 4-15. Bindings 16-21 and 24 carry the vision data
    /// (segmentation mattes, face/hand/body observations); the underlying
    /// detectors only run while a stage of the active effect actually uses one
    /// of those uniforms. Bindings 22-23 expose every stage's output texture
    /// and the per-stage index data behind `ceStageTexture`.
    /// Geometry stages add binding 25 (`CEGeometry`) and 26 (`uState`).
    static let maxStageReferences = 8

    /// Upper bound of the Simulation pass' `outState0` … `outState3`.
    static let maxStateSlots = 4

    /// The prelude a fragment stage is compiled with.
    static let prelude = makePrelude(for: .fullscreen)

    static func makePrelude(for kind: ShaderPrelude) -> String {
        var parts = ["#version 450\n"]
        switch kind {
        case .fullscreen:
            parts.append(fullscreenInterface)
        case .simulation(let stateSlots):
            parts.append((0..<max(1, min(stateSlots, maxStateSlots))).map { slot in
                "layout(location = \(slot)) out vec4 outState\(slot);\n"
            }.joined())
        case .geometryVertex:
            parts.append(vertexInterface)
        case .geometryFragment:
            parts.append(geometryFragmentInterface)
        }
        parts.append(resources)
        parts.append(mathFunctions)
        parts.append(noiseFunctions)
        parts.append(skeletonFunctions)
        if kind.isGeometry {
            parts.append(geometryResources)
        }
        switch kind {
        case .simulation:
            parts.append(simulationFunctions)
        case .geometryVertex:
            parts.append(vertexFunctions)
        case .fullscreen, .geometryFragment:
            break
        }
        return parts.joined(separator: "\n")
    }

    /// Appended after a vertex shader's user source, whose `main` the prelude
    /// renamed: every varying is written whatever the user's code does, which
    /// Metal needs to link the vertex and fragment functions.
    static let vertexEpilogue = """

    #undef main
    void main() {
        gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
        vColor = vec4(1.0);
        vData0 = vec4(0.0);
        vData1 = vec4(0.0);
        ceUserMain();
    }

    """

    private static let fullscreenInterface = """
    layout(location = 0) in vec2 vUV;
    layout(location = 0) out vec4 outColor;

    """

    private static let vertexInterface = """
    // Varyings, interpolated across each primitive for the Fragment shader.
    layout(location = 0) out vec4 vColor;
    layout(location = 1) out vec4 vData0;
    layout(location = 2) out vec4 vData1;

    """

    private static let geometryFragmentInterface = """
    layout(location = 0) in vec4 vColor;
    layout(location = 1) in vec4 vData0;
    layout(location = 2) in vec4 vData1;
    layout(location = 0) out vec4 outColor;

    // The pixel being shaded, in the same space as a fragment stage's vUV.
    #define vUV (gl_FragCoord.xy / uResolution)

    """

    private static let resources = """
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

    layout(std140, binding = 24) uniform CEBodies {
        int  uBodyCount;      // detected people (0 ... CE_MAX_BODIES)
        vec4 uBodyInfo[4];    // x = confidence
        vec4 uBodyJoints[76]; // 19 joints per body: xy = vUV position, z = confidence
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

    #define CE_MAX_BODIES   4
    #define CE_BODY_JOINTS 19

    // Joint indices into uBodyJoints (per body). Left / right are the
    // person's own sides, so mirroring swaps which side of the frame they
    // land on.
    #define CE_BODY_NOSE           0
    #define CE_BODY_LEFT_EYE       1
    #define CE_BODY_RIGHT_EYE      2
    #define CE_BODY_LEFT_EAR       3
    #define CE_BODY_RIGHT_EAR      4
    #define CE_BODY_NECK           5
    #define CE_BODY_LEFT_SHOULDER  6
    #define CE_BODY_RIGHT_SHOULDER 7
    #define CE_BODY_LEFT_ELBOW     8
    #define CE_BODY_RIGHT_ELBOW    9
    #define CE_BODY_LEFT_WRIST     10
    #define CE_BODY_RIGHT_WRIST    11
    #define CE_BODY_ROOT           12
    #define CE_BODY_LEFT_HIP       13
    #define CE_BODY_RIGHT_HIP      14
    #define CE_BODY_LEFT_KNEE      15
    #define CE_BODY_RIGHT_KNEE     16
    #define CE_BODY_LEFT_ANKLE     17
    #define CE_BODY_RIGHT_ANKLE    18

    vec4 ceHistory(vec2 uv, int ago) {
        int idx = uHeadIndex - ago;
        idx = ((idx % uFrameCount) + uFrameCount) % uFrameCount;
        float z = (float(idx) + 0.5) / float(uFrameCount);
        return texture(uFrames, vec3(uv, z));
    }

    vec4 ceHandJoint(int hand, int joint) {
        return uHandJoints[hand * CE_HAND_JOINTS + joint];
    }

    vec4 ceBodyJoint(int body, int joint) {
        return uBodyJoints[body * CE_BODY_JOINTS + joint];
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
    
    // Single-pass disc blur: `taps` samples on a golden-angle spiral, rotated
    // per pixel so undersampling reads as fine grain rather than rings.
    // `radius` is in pixels; 16-32 taps is plenty. falloff 0.0 gives a flat
    // disc (bokeh), 1.0 a soft, roughly Gaussian look. Cost = taps reads.
    vec4 ceDiscBlurArray(sampler2DArray tex, vec2 uv, float index, float radius, int taps, float falloff) {
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
            sum += texture(tex, vec3(uv + vec2(cos(a), sin(a)) * r * scale, index)) * w;
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
    
    float _luminance(vec3 color) {
        return 0.21 * color.r + 0.72 * color.g + 0.07 * color.b;
    }
    
    // Helper function for `opticalFlow()`, to sample a pixel color from the camera frame history
    vec4 _cePx(vec2 uv, int ago, bool luma) {
        vec4 color = ceHistory(uv, ago);
        return luma ? vec4(vec3(_luminance(color.rgb)), color.a) : color;
    }

    // Pixel-based displacement calculation between two images, using the Lucas-Kanade method.
    // `offset` is the distance between images; `lambda` is the optical flow sensitivity.
    // `luma` is true for grayscale images, false for RGB.
    vec2 ceOpticalFlow(vec2 uv, int next, int past, float offset, float lambda, bool luma) {
        vec2 off = vec2(offset, 0);
        vec4 gradX = (_cePx(uv + off.xy, next, luma) - _cePx(uv - off.xy, next, luma)) + (_cePx(uv + off.xy, past, luma) - _cePx(uv - off.xy, past, luma));
        vec4 gradY = (_cePx(uv + off.yx, next, luma) - _cePx(uv - off.yx, next, luma)) + (_cePx(uv + off.yx, past, luma) - _cePx(uv - off.yx, past, luma));
        vec4 gradMag = sqrt((gradX * gradX) + (gradY * gradY) + vec4(lambda));
        vec4 diff = _cePx(uv, next, luma) - _cePx(uv, past, luma);
        return vec2((diff * (gradX / gradMag)).x, (diff * (gradY / gradMag)).x);
    }

    """
    
    private static let mathFunctions = """
    #define PI 3.1415926536
    #define TWO_PI 6.2831853072
    
    float degToRad(float deg) {
        return deg * PI / 180.0;
    }
    
    float radToDeg(float deg) {
        return deg * 180.0 / PI;
    }
    
    float max(vec3 v) {
      return max(max(v.x, v.y), v.z);
    }
    
    float max(vec4 v) {
      return max(max(v.x, v.y), max(v.z, v.w));
    }

    float wrap(float a, float low, float high) {
        if (a > high) return a - (high - low);
        if (a < low) return a + (high - low);
        return a;
    }

    vec2 wrap(vec2 a, vec2 low, vec2 high) {
        return vec2(wrap(a.x, low.x, high.x), wrap(a.y, low.y, high.y));
    }
    
    vec3 wrap(vec3 a, vec3 low, vec3 high) {
        return vec3(wrap(a.x, low.x, high.x), wrap(a.y, low.y, high.y), wrap(a.z, low.z, high.z));
    }
    
    vec4 wrap(vec4 a, vec4 low, vec4 high) {
        return vec4(wrap(a.x, low.x, high.x), wrap(a.y, low.y, high.y), wrap(a.z, low.z, high.z), wrap(a.w, low.w, high.w));
    }
    
    float map(float value, float min1, float max1, float min2, float max2) {
      return min2 + (value - min1) * (max2 - min2) / (max1 - min1);
    }

    vec2 map(vec2 value, vec2 min1, vec2 max1, vec2 min2, vec2 max2) {
      return min2 + (value - min1) * (max2 - min2) / (max1 - min1);
    }
    
    vec3 map(vec3 value, vec3 min1, vec3 max1, vec3 min2, vec3 max2) {
      return min2 + (value - min1) * (max2 - min2) / (max1 - min1);
    }
    
    vec4 map(vec4 value, vec4 min1, vec4 max1, vec4 min2, vec4 max2) {
      return min2 + (value - min1) * (max2 - min2) / (max1 - min1);
    }

    float luminance(vec3 color) {
        return 0.21 * color.r + 0.72 * color.g + 0.07 * color.b;
    }
    
    vec3 rgb2hsv(vec3 c) {
        vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
        vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

        float d = q.x - min(q.w, q.y);
        float e = 1.0e-10;
        return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
    }

    vec3 hsv2rgb(vec3 c) {
        vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }
    """

    private static let noiseFunctions = """
    // PCG hash (Jarzynski & Olano 2020).
    uint _cePcg(uint v) {
        uint state = v * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
        return (word >> 22u) ^ word;
    }

    float _ceUnit(uint h) {
        return float(h >> 8u) * (1.0 / 16777216.0);
    }

    // Stable random values in [0, 1): the same input always gives the same
    // value, and neighbouring inputs are uncorrelated.
    float ceHash(int n) { return _ceUnit(_cePcg(uint(n))); }
    float ceHash(float x) { return _ceUnit(_cePcg(floatBitsToUint(x))); }
    float ceHash(vec2 p) {
        return _ceUnit(_cePcg(floatBitsToUint(p.x) ^ _cePcg(floatBitsToUint(p.y))));
    }
    float ceHash(vec3 p) {
        return _ceUnit(_cePcg(floatBitsToUint(p.x) ^ _cePcg(floatBitsToUint(p.y) ^ _cePcg(floatBitsToUint(p.z)))));
    }

    // Four independent random values in [0, 1) for one integer seed.
    vec4 ceHash4(int n) {
        uint a = _cePcg(uint(n));
        uint b = _cePcg(a);
        uint c = _cePcg(b);
        uint d = _cePcg(c);
        return vec4(_ceUnit(a), _ceUnit(b), _ceUnit(c), _ceUnit(d));
    }

    vec3 _ceMod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
    vec4 _ceMod289(vec4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
    vec4 _cePermute(vec4 x) { return _ceMod289(((x * 34.0) + 1.0) * x); }

    // 3D simplex noise (Ashima Arts / Stefan Gustavson, MIT): smooth, in
    // roughly [-1, 1], with features about 1 unit apart. Use time as z to
    // animate a 2D field.
    float ceSimplex(vec3 v) {
        const vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);
        const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);

        vec3 i = floor(v + dot(v, C.yyy));
        vec3 x0 = v - i + dot(i, C.xxx);

        vec3 g = step(x0.yzx, x0.xyz);
        vec3 l = 1.0 - g;
        vec3 i1 = min(g.xyz, l.zxy);
        vec3 i2 = max(g.xyz, l.zxy);

        vec3 x1 = x0 - i1 + C.xxx;
        vec3 x2 = x0 - i2 + C.yyy;
        vec3 x3 = x0 - D.yyy;

        i = _ceMod289(i);
        vec4 p = _cePermute(_cePermute(_cePermute(
                    i.z + vec4(0.0, i1.z, i2.z, 1.0))
                  + i.y + vec4(0.0, i1.y, i2.y, 1.0))
                  + i.x + vec4(0.0, i1.x, i2.x, 1.0));

        vec3 ns = 0.142857142857 * D.wyz - D.xzx;
        vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
        vec4 x_ = floor(j * ns.z);
        vec4 y_ = floor(j - 7.0 * x_);
        vec4 x = x_ * ns.x + ns.yyyy;
        vec4 y = y_ * ns.x + ns.yyyy;
        vec4 h = 1.0 - abs(x) - abs(y);

        vec4 b0 = vec4(x.xy, y.xy);
        vec4 b1 = vec4(x.zw, y.zw);
        vec4 s0 = floor(b0) * 2.0 + 1.0;
        vec4 s1 = floor(b1) * 2.0 + 1.0;
        vec4 sh = -step(h, vec4(0.0));
        vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
        vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

        vec3 p0 = vec3(a0.xy, h.x);
        vec3 p1 = vec3(a0.zw, h.y);
        vec3 p2 = vec3(a1.xy, h.z);
        vec3 p3 = vec3(a1.zw, h.w);
        vec4 norm = 1.79284291400159 - 0.85373472095314
            * vec4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3));
        p0 *= norm.x;
        p1 *= norm.y;
        p2 *= norm.z;
        p3 *= norm.w;

        vec4 m = max(0.6 - vec4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
        m = m * m;
        return 42.0 * dot(m * m, vec4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
    }

    float ceSimplex(vec2 p) { return ceSimplex(vec3(p, 0.0)); }

    // Fractal (layered) simplex noise in roughly [-1, 1]: `octaves` layers,
    // each twice the frequency and half the amplitude of the one before.
    float ceFbm(vec3 p, int octaves) {
        float sum = 0.0;
        float amplitude = 0.5;
        float total = 0.0;
        for (int i = 0; i < 8; i++) {
            if (i >= octaves) { break; }
            sum += amplitude * ceSimplex(p);
            total += amplitude;
            p = p * 2.0 + vec3(19.1, 7.3, 3.7);
            amplitude *= 0.5;
        }
        return sum / max(total, 0.0001);
    }

    float ceFbm(vec2 p, int octaves) { return ceFbm(vec3(p, 0.0), octaves); }

    // Curl of simplex noise at p, with t moving through the field: a
    // swirling, divergence-free 2D flow, so particles advected by it neither
    // bunch up nor thin out. Magnitude is roughly 0 ... 3.
    vec2 ceCurlNoise(vec2 p, float t) {
        const float e = 0.01;
        float dx = ceSimplex(vec3(p.x + e, p.y, t)) - ceSimplex(vec3(p.x - e, p.y, t));
        float dy = ceSimplex(vec3(p.x, p.y + e, t)) - ceSimplex(vec3(p.x, p.y - e, t));
        return vec2(dy, -dx) / (2.0 * e);
    }

    """

    private static let skeletonFunctions = """
    #define CE_HAND_BONES 20
    #define CE_BODY_BONES 18

    // Bone `bone` (0 ... CE_HAND_BONES - 1) of the hand skeleton as a pair of
    // joint indices, wrist to fingertip: ceHandJoint(hand, ceHandBone(i).x)
    // to ceHandJoint(hand, ceHandBone(i).y).
    ivec2 ceHandBone(int bone) {
        const ivec2 bones[20] = ivec2[](
            ivec2(0, 1), ivec2(1, 2), ivec2(2, 3), ivec2(3, 4),
            ivec2(0, 5), ivec2(5, 6), ivec2(6, 7), ivec2(7, 8),
            ivec2(0, 9), ivec2(9, 10), ivec2(10, 11), ivec2(11, 12),
            ivec2(0, 13), ivec2(13, 14), ivec2(14, 15), ivec2(15, 16),
            ivec2(0, 17), ivec2(17, 18), ivec2(18, 19), ivec2(19, 20)
        );
        return bones[clamp(bone, 0, 19)];
    }

    // Bone `bone` (0 ... CE_BODY_BONES - 1) of the body skeleton as a pair of
    // joint indices into ceBodyJoint: face, arms, spine, legs.
    ivec2 ceBodyBone(int bone) {
        const ivec2 bones[18] = ivec2[](
            ivec2(0, 1), ivec2(0, 2), ivec2(1, 3), ivec2(2, 4), ivec2(5, 0),
            ivec2(5, 6), ivec2(6, 8), ivec2(8, 10),
            ivec2(5, 7), ivec2(7, 9), ivec2(9, 11),
            ivec2(5, 12), ivec2(12, 13), ivec2(13, 15), ivec2(15, 17),
            ivec2(12, 14), ivec2(14, 16), ivec2(16, 18)
        );
        return bones[clamp(bone, 0, 17)];
    }

    """

    private static let geometryResources = """
    // Geometry stage data. The draw is uVerticesPerItem vertices for each of
    // uCount items; the simulation state holds one texel per item and slot.
    layout(std140, binding = 25) uniform CEGeometry {
        int   uCount;           // items drawn (and simulated)
        int   uVerticesPerItem; // vertices drawn per item
        int   uSimFrame;        // frames simulated since the last reset
        int   uSubstep;         // 0 ... uSubsteps - 1 within this frame
        int   uSubsteps;        // simulation steps per frame
        int   uStateSlots;      // vec4 slots per item; 0 without simulation
        ivec2 uStateSize;       // texels of each state slot
        float uSimDelta;        // uTimeDelta / uSubsteps
    };

    // Simulation state, one array slice per slot, 32-bit float. Reads the
    // latest completed step.
    layout(binding = 26) uniform sampler2DArray uState;

    // State slot `slot` of item `index`. Reads vec4(0) for indices outside
    // 0 ... uCount - 1, for missing slots, and without a simulation pass.
    vec4 ceState(int slot, int index) {
        if (slot < 0 || slot >= uStateSlots || index < 0 || index >= uCount) { return vec4(0.0); }
        ivec2 texel = ivec2(index % uStateSize.x, index / uStateSize.x);
        return texelFetch(uState, ivec3(texel, slot), 0);
    }

    """

    private static let simulationFunctions = """
    // The item this invocation updates.
    #define ceItemIndex (int(gl_FragCoord.y) * uStateSize.x + int(gl_FragCoord.x))

    """

    private static let vertexFunctions = """
    #define ceItemIndex gl_InstanceIndex
    #define ceVertexIndex gl_VertexIndex

    // Places this vertex at `uv`, in the same space as vUV: (0, 0) top-left,
    // (1, 1) bottom-right.
    void ceEmit(vec2 uv) {
        gl_Position = vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    }

    // Corner `vertex` (0 ... 5) of a quad drawn as two triangles, in [-1, 1].
    // Six vertices per item and ceEmit(center + ceQuadCorner(ceVertexIndex)
    // * radius / uResolution) give a camera-facing square `radius` px wide.
    vec2 ceQuadCorner(int vertex) {
        const vec2 corners[6] = vec2[](
            vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(-1.0, 1.0),
            vec2(-1.0, 1.0), vec2(1.0, -1.0), vec2(1.0, 1.0)
        );
        return corners[clamp(vertex, 0, 5)];
    }

    // Center of cell `index` of a `cells.x` x `cells.y` grid over the frame,
    // row by row from the top-left, in vUV space.
    vec2 ceGridPoint(int index, ivec2 cells) {
        return (vec2(index % cells.x, index / cells.x) + 0.5) / vec2(cells);
    }

    // Vertex `vertex` of a mesh covering the frame with `cells.x` x `cells.y`
    // quads, six vertices (two triangles) each, in vUV space. Draw it as
    // Triangles with 6 * cells.x * cells.y vertices.
    vec2 ceGridVertex(int vertex, ivec2 cells) {
        int quad = vertex / 6;
        vec2 corner = ceQuadCorner(vertex % 6) * 0.5 + 0.5;
        return (vec2(quad % cells.x, quad / cells.x) + corner) / vec2(cells);
    }

    #define main ceUserMain

    """

    private static func lineCount(of text: String) -> Int {
        text.components(separatedBy: "\n").count - 1
    }

    static let fullscreenPreludeLineCount = lineCount(of: prelude)

    private static var initialized = false
    private static let initLock = NSLock()

    /// Compiles one user source file with the prelude for `kind`. `file`
    /// tags every diagnostic. `references` are the stage-name slots taken by
    /// the stage's other files, so one name maps to one slot across all of
    /// them; the output's `stageReferences` includes them.
    static func compile(
        userSource: String,
        prelude kind: ShaderPrelude = .fullscreen,
        file: ShaderFile = .fragment,
        references: [StageReference] = []
    ) throws -> ShaderCompileOutput {
        do {
            return try compileUntagged(userSource: userSource, kind: kind, file: file, references: references)
        } catch let error as ShaderCompileError {
            throw ShaderCompileError(diagnostics: error.diagnostics.map { $0.inFile(file) })
        }
    }

    private static func compileUntagged(
        userSource: String,
        kind: ShaderPrelude,
        file: ShaderFile,
        references: [StageReference]
    ) throws -> ShaderCompileOutput {
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
        let lines = source.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("#version") {
            source = (["// #version supplied by prelude"] + lines.dropFirst()).joined(separator: "\n")
        }

        let rewrite = rewritingStageNames(in: source, file: file, existing: references)
        source = rewrite.source

        let kindPrelude = kind == .fullscreen ? prelude : makePrelude(for: kind)
        var fullSource = kindPrelude + source
        if kind == .geometryVertex {
            fullSource += vertexEpilogue
        }
        let stage = kind == .geometryVertex ? Int32(ST_STAGE_VERTEX) : Int32(ST_STAGE_FRAGMENT)

        var mslOut: UnsafeMutablePointer<CChar>?
        var reflectionOut: UnsafeMutablePointer<CChar>?
        var logOut: UnsafeMutablePointer<CChar>?

        let status = st_compile(fullSource, stage, &mslOut, &reflectionOut, &logOut)
        defer {
            st_string_free(mslOut)
            st_string_free(reflectionOut)
            st_string_free(logOut)
        }

        var log = logOut.map { String(cString: $0) } ?? ""
        if kind == .geometryVertex {
            // The prelude renames the user's main; report it by its own name.
            log = log.replacingOccurrences(of: "ceUserMain", with: "main")
        }
        var diagnostics = parseDiagnostics(
            log: log,
            preludeLineCount: lineCount(of: kindPrelude),
            userLineCount: lineCount(of: source) + 1
        ) + rewrite.diagnostics

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
            diagnostics: diagnostics.filter { $0.severity == .warning }.map { $0.inFile(file) },
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
        in source: String,
        file: ShaderFile = .fragment,
        existing: [StageReference] = []
    ) -> (source: String, references: [StageReference], diagnostics: [ShaderDiagnostic]) {
        var references = existing
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
                    references.append(StageReference(name: name, slot: slot, line: lineNumber, file: file))
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
    static func parseDiagnostics(
        log: String,
        preludeLineCount: Int = ShaderCompiler.fullscreenPreludeLineCount,
        userLineCount: Int = .max
    ) -> [ShaderDiagnostic] {
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
                    line: userLine >= 1 && userLine <= userLineCount ? userLine : nil,
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
