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

    static let functions: [Symbol] = [
        Symbol(
            id: "ceHistory",
            name: "ceHistory(uv, ago)",
            type: "vec4",
            description: "Sample the raw camera frame from ago frames ago (0 = newest). Handles ring-buffer wrapping automatically."
        ),
    ]

    static let userDefined: [Symbol] = [
        Symbol(
            id: "Params",
            name: "Params",
            type: "uniform block, binding = 3",
            description: "Optional std140 block for effect parameters. Members become sliders, toggles, or color pickers in the inspector."
        ),
        Symbol(
            id: "sampler2D",
            name: "yourSampler",
            type: "uniform sampler2D, binding ≥ 4",
            description: "Optional 2D textures assigned from the shared media library in the inspector."
        ),
    ]
}

/// Collapsible built-in uniform reference for the inspector panel.
struct ShaderGlobalsSection: View {
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Built-in uniforms")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isExpanded {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(ShaderReference.categories) { category in
                        ShaderGlobalsCategory(category: category)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            Divider()
        }
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
