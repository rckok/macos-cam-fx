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
            id: "context",
            title: "CEContext (binding = 2)",
            footer: "Members of the injected CEContext uniform block:",
            symbols: contextMembers
        ),
        Category(
            id: "vision",
            title: "Vision data",
            footer: "Face, hand, and segmentation data. The detectors only run while an enabled effect uses one of these uniforms. All coordinates and mask textures are in vUV space (top-left origin, mirroring applied).",
            symbols: vision
        ),
        Category(id: "functions", title: "Functions", symbols: functions),
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
            description: "Write the effect output here. Alpha is preserved through the chain."
        ),
    ]

    static let textures: [Symbol] = [
        Symbol(
            id: "uPrev",
            name: "uPrev",
            type: "uniform sampler2D",
            description: "The previous pass output at the current UV. For the first effect in the chain this is the scaled (and optionally mirrored) camera frame."
        ),
        Symbol(
            id: "uFrames",
            name: "uFrames",
            type: "uniform sampler3D",
            description: "A ring buffer of the last N raw camera frames. The z axis is history: slice 0 is the oldest retained frame, slice N − 1 is the newest. Prefer ceHistory() over manual z indexing."
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
    ]

    static let functions: [Symbol] = [
        Symbol(
            id: "ceHistory",
            name: "ceHistory(uv, ago)",
            type: "vec4",
            description: "Sample the raw camera frame from ago frames ago (0 = newest). Handles ring-buffer wrapping automatically."
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
            description: "Optional std140 block for effect parameters. Members become sliders, toggles, or color pickers in the inspector. Put `// @metadata(min=0 max=1 default=0.5)` on the line above a member to set its slider range. Vectors accept GLSL constructors (`min=vec3(0) max=vec3(1, 2, 1)`). `vec3`/`vec4` use per-component sliders unless you add `color=true`."
        ),
        Symbol(
            id: "sampler2D",
            name: "yourSampler",
            type: "uniform sampler2D, binding ≥ 4",
            description: "Optional 2D textures assigned from the shared media library in the inspector."
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
