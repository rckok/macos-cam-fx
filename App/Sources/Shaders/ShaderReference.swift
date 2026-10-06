import SwiftUI

/// Documentation for symbols injected by `ShaderCompiler.prelude`.
enum ShaderReference {
    struct Symbol: Identifiable {
        let id: String
        let name: String
        let type: String
        let description: String
    }

    struct Category: Identifiable {
        let id: String
        let title: String
        let footer: String?
        let symbols: [Symbol]

        init(id: String, title: String, footer: String? = nil, symbols: [Symbol]) {
            self.id = id
            self.title = title
            self.footer = footer
            self.symbols = symbols
        }
    }

    static let categories: [Category] = [
        Category(id: "io", title: "Inputs / outputs", symbols: io),
        Category(id: "textures", title: "Textures", symbols: textures),
        Category(
            id: "stages",
            title: "Stage textures (bindings 22–23)",
            footer: "Every stage of the active effect owns one slice of uStageTextures. Stages before this one have already rendered this frame; this stage and the ones after it still hold their previous frame, which is what makes feedback loops work. Slices start out transparent black.",
            symbols: stages
        ),
        Category(
            id: "context",
            title: "CEContext (binding = 2)",
            footer: "Members of the injected CEContext uniform block:",
            symbols: contextMembers
        ),
        Category(
            id: "vision",
            title: "Vision data",
            footer: "Face, hand, and segmentation data. The detectors only run while a stage of the active effect uses one of these uniforms. All coordinates and mask textures are in vUV space (top-left origin, mirroring applied).",
            symbols: vision
        ),
        Category(id: "functions", title: "Functions", symbols: functions),
        Category(
            id: "noise",
            title: "Noise and randomness",
            footer: "Available in every stage and tab.",
            symbols: noise
        ),
        Category(
            id: "geometry",
            title: "Geometry stages",
            footer: "Only in geometry stages. The Vertex tab runs Vertices per item times for each of Count items and places each vertex with ceEmit(); the Fragment tab colors what it covers. The optional Simulation tab runs first, once per item for every substep, and keeps per-item state in 32-bit float textures. Everything above is available in all three tabs; vUV and outColor are not available in the Vertex tab.",
            symbols: geometry
        ),
        Category(id: "user", title: "You can also declare", symbols: userDefined),
    ]

    static let io: [Symbol] = [
        Symbol(
            id: "vUV",
            name: "vUV",
            type: "in vec2",
            description: "Fullscreen UV coordinates. (0, 0) is the top-left corner; (1, 1) is the bottom-right."
        ),
        Symbol(
            id: "outColor",
            name: "outColor",
            type: "out vec4",
            description: "Write the stage output here. Alpha is preserved through the effect's stages."
        ),
    ]

    static let textures: [Symbol] = [
        Symbol(
            id: "uPrev",
            name: "uPrev",
            type: "uniform sampler2D",
            description: "The previous stage's output at the current UV. For the first stage of an effect this is the scaled (and optionally mirrored) camera frame — the same pixels as ceHistory(vUV, 0). Nothing carries over from other effects."
        ),
        Symbol(
            id: "uFrames",
            name: "uFrames",
            type: "uniform sampler3D",
            description: "A ring buffer of the last N raw camera frames. The z axis is history: slice 0 is the oldest retained frame, slice N − 1 is the newest. Prefer ceHistory() over manual z indexing."
        ),
    ]

    static let stages: [Symbol] = [
        Symbol(
            id: "ceStageTexture",
            name: "ceStageTexture(index, uv)",
            type: "vec4",
            description: "Output of the stage at `index` (the number shown next to it in the stage list). Also accepts the stage's name as a string literal — ceStageTexture(\"Trail Buffer\", vUV) — which the app resolves against the effect, so reordering stages does not break it. Out-of-range indices and unknown names read transparent black."
        ),
        Symbol(
            id: "ceSelfTexture",
            name: "ceSelfTexture(uv)",
            type: "vec4",
            description: "This stage's own output from the previous frame — a feedback buffer. Same as ceStageTexture(uStageIndex, uv)."
        ),
        Symbol(
            id: "uStageTextures",
            name: "uStageTextures",
            type: "uniform sampler2DArray",
            description: "The stage outputs as a texture array, one slice per stage: texture(uStageTextures, vec3(uv, float(index))). Prefer ceStageTexture(), which range-checks the index."
        ),
        Symbol(
            id: "uStageIndex",
            name: "uStageIndex",
            type: "int (CEStages, binding = 23)",
            description: "This stage's position in the effect, 0-based."
        ),
        Symbol(
            id: "uStageCount",
            name: "uStageCount",
            type: "int (CEStages, binding = 23)",
            description: "Number of stages in the effect, i.e. slices in uStageTextures."
        ),
    ]

    static let contextMembers: [Symbol] = [
        Symbol(
            id: "uResolution",
            name: "uResolution",
            type: "vec2",
            description: "Output size in pixels (currently 1280 × 720, matching the virtual camera)."
        ),
        Symbol(
            id: "uTime",
            name: "uTime",
            type: "float",
            description: "Elapsed time in seconds since the capture stream started."
        ),
        Symbol(
            id: "uTimeDelta",
            name: "uTimeDelta",
            type: "float",
            description: "Time in seconds since the previous rendered frame."
        ),
        Symbol(
            id: "uFrameCount",
            name: "uFrameCount",
            type: "int",
            description: "Depth N of uFrames — the number of past frames kept in the history texture. Configurable in Settings → Frame History."
        ),
        Symbol(
            id: "uHeadIndex",
            name: "uHeadIndex",
            type: "int",
            description: "The z-slice index (0 … N − 1) where the newest raw frame was written. Used internally by ceHistory()."
        ),
        Symbol(
            id: "uFrameNumber",
            name: "uFrameNumber",
            type: "int",
            description: "Monotonically increasing frame counter since the stream started."
        ),
    ]

    static let vision: [Symbol] = [
        Symbol(
            id: "uPersonMatte",
            name: "uPersonMatte",
            type: "uniform sampler2D",
            description: "Person-segmentation luma matte for background subtraction: 1 = person, 0 = background. Sample .r."
        ),
        Symbol(
            id: "uFaceMask",
            name: "uFaceMask",
            type: "uniform sampler2D",
            description: "Face-part segmentation rasterized from facial landmarks. R = left eye, G = right eye, B = mouth, A = union of all parts."
        ),
        Symbol(
            id: "uHandMask",
            name: "uHandMask",
            type: "uniform sampler2D",
            description: "Approximate hand silhouette (luma) built from the detected hand skeleton. Sample .r."
        ),
        Symbol(
            id: "uFaceCount",
            name: "uFaceCount",
            type: "int (CEFace, binding = 19)",
            description: "Number of detected faces (0 … CE_MAX_FACES)."
        ),
        Symbol(
            id: "uFaceRects",
            name: "uFaceRects[4]",
            type: "vec4 (CEFace, binding = 19)",
            description: "Face bounding boxes in vUV space: xy = top-left corner, zw = size."
        ),
        Symbol(
            id: "uFaceLeftEye",
            name: "uFaceLeftEye[4]",
            type: "vec4 (CEFacePoints, binding = 21)",
            description: "Center of face i's left eye: xy = position in vUV space, z = 1 when the eye was located (0 otherwise), w = half the eye's width in the same units as uFaceRects.z. Taken from the pupil landmark when Vision reports one, otherwise from the eye contour."
        ),
        Symbol(
            id: "uFaceRightEye",
            name: "uFaceRightEye[4]",
            type: "vec4 (CEFacePoints, binding = 21)",
            description: "Center of face i's right eye, in the same xy / z / w layout as uFaceLeftEye."
        ),
        Symbol(
            id: "uFaceMouth",
            name: "uFaceMouth[4]",
            type: "vec4 (CEFacePoints, binding = 21)",
            description: "Center of face i's mouth (outer-lip contour), in the same xy / z / w layout as uFaceLeftEye."
        ),
        Symbol(
            id: "uHandCount",
            name: "uHandCount",
            type: "int (CEHands, binding = 20)",
            description: "Number of detected hands (0 … CE_MAX_HANDS)."
        ),
        Symbol(
            id: "uHandInfo",
            name: "uHandInfo[2]",
            type: "vec4 (CEHands, binding = 20)",
            description: "Per hand: x = chirality (-1 left, +1 right, 0 unknown), y = detection confidence."
        ),
        Symbol(
            id: "uHandJoints",
            name: "uHandJoints[42]",
            type: "vec4 (CEHands, binding = 20)",
            description: "21 joints per hand: xy = vUV position, z = joint confidence. Prefer ceHandJoint() with the CE_* joint constants (CE_WRIST, CE_THUMB_TIP, CE_INDEX_TIP, …) over manual indexing."
        ),
        Symbol(
            id: "ceHandJoint",
            name: "ceHandJoint(hand, joint)",
            type: "vec4",
            description: "Joint of hand `hand` (0 … uHandCount − 1) at index `joint` — use the CE_* constants: wrist (CE_WRIST), then CMC/MP/IP/TIP for the thumb and MCP/PIP/DIP/TIP for each finger (CE_THUMB_*, CE_INDEX_*, CE_MIDDLE_*, CE_RING_*, CE_LITTLE_*)."
        ),
        Symbol(
            id: "uBodyCount",
            name: "uBodyCount",
            type: "int (CEBodies, binding = 24)",
            description: "Number of detected people (0 … CE_MAX_BODIES), most confident first."
        ),
        Symbol(
            id: "uBodyInfo",
            name: "uBodyInfo[4]",
            type: "vec4 (CEBodies, binding = 24)",
            description: "Per body: x = detection confidence."
        ),
        Symbol(
            id: "uBodyJoints",
            name: "uBodyJoints[76]",
            type: "vec4 (CEBodies, binding = 24)",
            description: "19 joints per body: xy = vUV position, z = joint confidence (0 when not located). Prefer ceBodyJoint() with the CE_BODY_* joint constants (CE_BODY_NOSE, CE_BODY_LEFT_WRIST, …) over manual indexing."
        ),
        Symbol(
            id: "ceBodyJoint",
            name: "ceBodyJoint(body, joint)",
            type: "vec4",
            description: "Joint of body `body` (0 … uBodyCount − 1) at index `joint` — use the CE_BODY_* constants: NOSE, LEFT/RIGHT_EYE, LEFT/RIGHT_EAR, NECK, LEFT/RIGHT_SHOULDER, LEFT/RIGHT_ELBOW, LEFT/RIGHT_WRIST, ROOT (hip center), LEFT/RIGHT_HIP, LEFT/RIGHT_KNEE, LEFT/RIGHT_ANKLE. Left and right are the person's own sides."
        ),
    ]

    static let functions: [Symbol] = [
        Symbol(
            id: "ceHistory",
            name: "ceHistory(uv, ago)",
            type: "vec4",
            description: "Sample the raw camera frame from ago frames ago (0 = newest). Handles ring-buffer wrapping automatically."
        ),
        Symbol(
            id: "ceDiscBlur",
            name: "ceDiscBlur(tex, uv, radius, taps, falloff)",
            type: "vec4",
            description: "Single-pass disc blur of any sampler2D (uPrev, a media texture, …). `radius` in pixels; `taps` sets quality and cost (16–32 is plenty). `falloff` 0.0 gives a flat bokeh disc, 1.0 a soft Gaussian-like look. Samples lie on a per-pixel-rotated golden-angle spiral, so low tap counts show as fine grain rather than rings. For large true-Gaussian blurs prefer two stages (horizontal, then vertical through uPrev)."
        ),
        Symbol(
            id: "ceGauss3x3",
            name: "ceGauss3x3(tex, uv, spread)",
            type: "vec4",
            description: "Exact 3×3 Gaussian ([1 2 1] ⊗ [1 2 1] / 16) from just four bilinear reads at half-texel offsets. `spread` = 1.0 blurs one texel; larger values widen the kernel at the same cost, with some undersampling."
        ),
        Symbol(
            id: "ceNoise",
            name: "ceNoise(pixel)",
            type: "float",
            description: "Cheap per-pixel noise in [0, 1) with no visible pattern (interleaved gradient noise). Pass vUV * uResolution. Every pixel is independent, so it suits dithering and rotating sample patterns, not smooth fields — use ceSimplex() for those."
        ),
        Symbol(
            id: "ceHandBone",
            name: "ceHandBone(bone)",
            type: "ivec2",
            description: "Bone `bone` (0 … CE_HAND_BONES − 1, 20 bones) of the hand skeleton as two joint indices, wrist to fingertip: draw a line from ceHandJoint(hand, b.x) to ceHandJoint(hand, b.y)."
        ),
        Symbol(
            id: "ceBodyBone",
            name: "ceBodyBone(bone)",
            type: "ivec2",
            description: "Bone `bone` (0 … CE_BODY_BONES − 1, 18 bones) of the body skeleton as two joint indices into ceBodyJoint(): face, arms, spine and legs."
        ),
    ]

    static let noise: [Symbol] = [
        Symbol(
            id: "ceHash",
            name: "ceHash(seed)",
            type: "float",
            description: "A random value in [0, 1) for an int, float, vec2 or vec3 seed. The same seed always gives the same value and neighboring seeds are unrelated — e.g. ceHash(ceItemIndex) for a per-particle random number."
        ),
        Symbol(
            id: "ceHash4",
            name: "ceHash4(seed)",
            type: "vec4",
            description: "Four independent random values in [0, 1) for one int seed."
        ),
        Symbol(
            id: "ceSimplex",
            name: "ceSimplex(p)",
            type: "float",
            description: "Smooth simplex noise in roughly [−1, 1] for a vec2 or vec3 point, with features about 1 unit apart. Scale p for bigger or smaller features; pass time as z to animate a 2D field."
        ),
        Symbol(
            id: "ceFbm",
            name: "ceFbm(p, octaves)",
            type: "float",
            description: "Fractal simplex noise in roughly [−1, 1]: `octaves` (up to 8) layers, each at twice the frequency and half the amplitude of the last. More detail than ceSimplex at `octaves` times the cost."
        ),
        Symbol(
            id: "ceCurlNoise",
            name: "ceCurlNoise(p, t)",
            type: "vec2",
            description: "A swirling 2D flow field at p, changing smoothly with t: the curl of simplex noise, which is divergence-free, so particles moved along it neither bunch up nor thin out. Magnitude roughly 0 … 3."
        ),
    ]

    static let geometry: [Symbol] = [
        Symbol(
            id: "ceItemIndex",
            name: "ceItemIndex",
            type: "int (Simulation, Vertex)",
            description: "The item being simulated or drawn, 0 … uCount − 1."
        ),
        Symbol(
            id: "ceVertexIndex",
            name: "ceVertexIndex",
            type: "int (Vertex)",
            description: "The vertex within the item, 0 … uVerticesPerItem − 1."
        ),
        Symbol(
            id: "ceEmit",
            name: "ceEmit(uv)",
            type: "void (Vertex)",
            description: "Places the vertex at `uv`, in vUV space: (0, 0) top-left, (1, 1) bottom-right — the same space as the vision coordinates. Sets gl_Position; a vertex that never calls it lands in the middle of the frame."
        ),
        Symbol(
            id: "gl_PointSize",
            name: "gl_PointSize",
            type: "float (Vertex)",
            description: "Diameter of a point in pixels when drawing Points; 1 when not written. Points are squares: discard outside length(gl_PointCoord − 0.5) < 0.5 in the Fragment tab for round ones."
        ),
        Symbol(
            id: "vColor",
            name: "vColor",
            type: "vec4 (out in Vertex, in in Fragment)",
            description: "Color handed from the Vertex to the Fragment tab, interpolated across each primitive. White when not written."
        ),
        Symbol(
            id: "vData0",
            name: "vData0, vData1",
            type: "vec4 (out in Vertex, in in Fragment)",
            description: "Two more values handed from the Vertex to the Fragment tab, interpolated across each primitive. Zero when not written."
        ),
        Symbol(
            id: "gl_PointCoord",
            name: "gl_PointCoord",
            type: "vec2 (Fragment)",
            description: "Position within the point being drawn, (0, 0) to (1, 1). Only defined when drawing Points."
        ),
        Symbol(
            id: "ceQuadCorner",
            name: "ceQuadCorner(vertex)",
            type: "vec2 (Vertex)",
            description: "Corner `vertex` (0 … 5) of a quad drawn as two triangles, in [−1, 1]. With 6 vertices per item and Triangles: ceEmit(center + ceQuadCorner(ceVertexIndex) * radius / uResolution) draws a square `radius` pixels from center to edge."
        ),
        Symbol(
            id: "ceGridPoint",
            name: "ceGridPoint(index, cells)",
            type: "vec2 (Vertex)",
            description: "Center of cell `index` of an ivec2 `cells` grid over the frame, row by row from the top-left, in vUV space."
        ),
        Symbol(
            id: "ceGridVertex",
            name: "ceGridVertex(vertex, cells)",
            type: "vec2 (Vertex)",
            description: "Vertex `vertex` of a mesh of `cells.x` × `cells.y` quads covering the frame, in vUV space. Draw as Triangles with one item of 6 × cells.x × cells.y vertices, then displace it."
        ),
        Symbol(
            id: "ceState",
            name: "ceState(slot, index)",
            type: "vec4",
            description: "State slot `slot` of item `index` from the latest simulation step. In the Simulation tab that is the previous step; in the Vertex and Fragment tabs, this frame's last. vec4(0) out of range, and without a simulation pass."
        ),
        Symbol(
            id: "outState0",
            name: "outState0 … outState3",
            type: "out vec4 (Simulation)",
            description: "Write the item's next state here, one output per state slot (set in the stage controls). State starts out zero after a reset."
        ),
        Symbol(
            id: "uCount",
            name: "uCount",
            type: "int (CEGeometry, binding = 25)",
            description: "Items drawn and simulated (Count in the stage controls)."
        ),
        Symbol(
            id: "uVerticesPerItem",
            name: "uVerticesPerItem",
            type: "int (CEGeometry, binding = 25)",
            description: "Vertices drawn per item (Vertices per item in the stage controls)."
        ),
        Symbol(
            id: "uSimFrame",
            name: "uSimFrame",
            type: "int (CEGeometry, binding = 25)",
            description: "Frames simulated since the last reset. 0 on the first frame — the moment to seed the state. Resets with Reset Simulation, and when Count or State slots change."
        ),
        Symbol(
            id: "uSubstep",
            name: "uSubstep",
            type: "int (CEGeometry, binding = 25)",
            description: "Which of this frame's uSubsteps simulation steps is running, 0-based."
        ),
        Symbol(
            id: "uSubsteps",
            name: "uSubsteps",
            type: "int (CEGeometry, binding = 25)",
            description: "Simulation steps per frame (Substeps in the stage controls)."
        ),
        Symbol(
            id: "uSimDelta",
            name: "uSimDelta",
            type: "float (CEGeometry, binding = 25)",
            description: "Seconds per simulation step: uTimeDelta / uSubsteps. Multiply velocities by it for motion that does not depend on frame rate or substeps."
        ),
        Symbol(
            id: "uStateSlots",
            name: "uStateSlots",
            type: "int (CEGeometry, binding = 25)",
            description: "vec4 state slots per item; 0 without a simulation pass."
        ),
        Symbol(
            id: "uStateSize",
            name: "uStateSize",
            type: "ivec2 (CEGeometry, binding = 25)",
            description: "Size in texels of each state slot: the smallest near-square texture holding uCount items. Prefer ceState(), which does the indexing."
        ),
        Symbol(
            id: "uState",
            name: "uState",
            type: "uniform sampler2DArray, binding = 26",
            description: "The simulation state as a 32-bit float texture array, one slice per slot. Prefer ceState()."
        ),
    ]

    /// Bare identifier names for editor completion, derived from the symbol
    /// docs above. Skips the "user" category, whose names are placeholders.
    static let completionIdentifiers: [String] = categories
        .filter { $0.id != "user" }
        .flatMap(\.symbols)
        .compactMap { symbol in
            let bare = symbol.name.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return bare.isEmpty ? nil : String(bare)
        }

    static let userDefined: [Symbol] = [
        Symbol(
            id: "Params",
            name: "Params",
            type: "uniform block, binding = 3",
            description: "Optional std140 block for stage parameters. Members become sliders, toggles, or color pickers in the editor panel's stage controls column. Put `// @metadata(min=0 max=1 default=0.5)` on the line above a member to set its slider range. Vectors accept GLSL constructors (`min=vec3(0) max=vec3(1, 2, 1)`). `vec3`/`vec4` use per-component sliders unless you add `color=true`. Add `global` to list the control on the owning effect too, which is the only place Basic Mode can reach it."
        ),
        Symbol(
            id: "sampler2D",
            name: "yourSampler",
            type: "uniform sampler2D, binding ≥ 4",
            description: "Optional 2D textures assigned from the shared media library in the editor panel's stage controls column. Put `// @metadata(global)` on the line above the declaration to list the picker on the owning effect too, which is the only place Basic Mode can reach it. No other metadata key applies to a sampler."
        ),
    ]
}

/// Popover listing the uniforms injected by `ShaderCompiler.prelude`.
struct ShaderGlobalsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Built-in uniforms")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(ShaderReference.categories) { category in
                        ShaderGlobalsCategory(category: category)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 380, height: 480)
    }
}

private struct ShaderGlobalsCategory: View {
    let category: ShaderReference.Category

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            if let footer = category.footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(category.symbols) { symbol in
                    SymbolRow(symbol: symbol)
                }
            }
        }
    }
}

private struct SymbolRow: View {
    let symbol: ShaderReference.Symbol

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(symbol.name)
                .font(.caption.monospaced().weight(.medium))
            Text(symbol.type)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text(symbol.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
