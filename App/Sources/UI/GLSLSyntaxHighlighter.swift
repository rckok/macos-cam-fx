import AppKit

/// Lexes GLSL 450 fragment-shader source and applies foreground colors to an
/// `NSTextStorage`. Shader bodies are small (hundreds of lines), so every pass
/// re-highlights the whole document; that keeps block comments and undo/redo
/// correct without incremental bookkeeping.
enum GLSLSyntaxHighlighter {

    enum TokenKind {
        case comment
        /// `@metadata(...)` inside a comment; drives the inspector sliders.
        case metadata
        case preprocessor
        case keyword
        case type
        case builtinFunction
        /// Built-in variables and constants: `gl_*`, prelude uniforms, `CE_*`.
        case builtinSymbol
        case number
    }

    struct Token {
        let range: NSRange
        let kind: TokenKind
    }

    // MARK: - Applying colors

    /// Recolors the whole document. Only touches `.foregroundColor`, so it is
    /// safe to run after every character edit without disturbing layout,
    /// selection, or the undo stack.
    static func highlight(_ textStorage: NSTextStorage, baseColor: NSColor = .textColor) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }
        textStorage.beginEditing()
        textStorage.addAttribute(.foregroundColor, value: baseColor, range: fullRange)
        for token in tokens(in: textStorage.string as NSString) {
            textStorage.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
        textStorage.endEditing()
    }

    // MARK: - Palette

    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .comment: commentColor
        case .metadata: metadataColor
        case .preprocessor: preprocessorColor
        case .keyword: keywordColor
        case .type: typeColor
        case .builtinFunction: builtinFunctionColor
        case .builtinSymbol: builtinSymbolColor
        case .number: numberColor
        }
    }

    private static let commentColor = dynamic(light: srgb(0x00, 0x74, 0x00), dark: srgb(0x7F, 0x8C, 0x98))
    private static let metadataColor = dynamic(light: srgb(0xA6, 0x59, 0x00), dark: srgb(0xFF, 0xA1, 0x4F))
    private static let preprocessorColor = dynamic(light: srgb(0x64, 0x38, 0x20), dark: srgb(0xFD, 0x8F, 0x3F))
    private static let keywordColor = dynamic(light: srgb(0x9B, 0x23, 0x93), dark: srgb(0xFC, 0x5F, 0xA3))
    private static let typeColor = dynamic(light: srgb(0x70, 0x3D, 0xAA), dark: srgb(0xD0, 0xA8, 0xFF))
    private static let builtinFunctionColor = dynamic(light: srgb(0x3E, 0x80, 0x87), dark: srgb(0x67, 0xB7, 0xA4))
    private static let builtinSymbolColor = dynamic(light: srgb(0x0F, 0x68, 0xA0), dark: srgb(0x41, 0xA1, 0xC0))
    private static let numberColor = dynamic(light: srgb(0x1C, 0x00, 0xCF), dark: srgb(0xD0, 0xBF, 0x69))

    private static func srgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    // MARK: - Word sets

    static let keywords: Set<String> = [
        "break", "case", "centroid", "const", "continue", "default", "discard",
        "do", "else", "false", "flat", "for", "highp", "if", "in", "inout",
        "invariant", "layout", "lowp", "mediump", "noperspective", "out",
        "precise", "precision", "readonly", "restrict", "return", "shared",
        "smooth", "std140", "std430", "struct", "switch", "true", "uniform",
        "buffer", "coherent", "volatile", "while", "writeonly",
    ]

    static let types: Set<String> = [
        "void", "bool", "int", "uint", "float", "double",
        "vec2", "vec3", "vec4", "bvec2", "bvec3", "bvec4",
        "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4",
        "dvec2", "dvec3", "dvec4",
        "mat2", "mat3", "mat4",
        "mat2x2", "mat2x3", "mat2x4", "mat3x2", "mat3x3", "mat3x4",
        "mat4x2", "mat4x3", "mat4x4",
        "sampler1D", "sampler2D", "sampler3D", "samplerCube",
        "sampler1DArray", "sampler2DArray", "samplerCubeArray",
        "sampler2DShadow", "samplerCubeShadow",
        "isampler2D", "isampler3D", "usampler2D", "usampler3D",
        "atomic_uint",
    ]

    static let builtinFunctions: Set<String> = [
        // Angle & trigonometry
        "radians", "degrees", "sin", "cos", "tan", "asin", "acos", "atan",
        "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
        // Exponential
        "pow", "exp", "log", "exp2", "log2", "sqrt", "inversesqrt",
        // Common
        "abs", "sign", "floor", "trunc", "round", "roundEven", "ceil", "fract",
        "mod", "modf", "min", "max", "clamp", "mix", "step", "smoothstep",
        "isnan", "isinf", "fma", "frexp", "ldexp",
        "floatBitsToInt", "floatBitsToUint", "intBitsToFloat", "uintBitsToFloat",
        // Packing
        "packUnorm2x16", "packSnorm2x16", "packUnorm4x8", "packSnorm4x8",
        "unpackUnorm2x16", "unpackSnorm2x16", "unpackUnorm4x8", "unpackSnorm4x8",
        // Geometric
        "length", "distance", "dot", "cross", "normalize", "faceforward",
        "reflect", "refract",
        // Matrix
        "matrixCompMult", "outerProduct", "transpose", "determinant", "inverse",
        // Vector relational
        "lessThan", "lessThanEqual", "greaterThan", "greaterThanEqual",
        "equal", "notEqual", "any", "all", "not",
        // Texture
        "texture", "textureSize", "textureLod", "textureOffset", "texelFetch",
        "texelFetchOffset", "textureGrad", "textureProj", "textureGather",
        // Derivatives
        "dFdx", "dFdy", "fwidth",
        // Integer
        "bitfieldExtract", "bitfieldInsert", "bitfieldReverse", "bitCount",
        "findLSB", "findMSB",
        // Injected by the prelude
        "ceHistory", "ceHandJoint",
    ]

    /// Variables and constants visible to every effect shader: GLSL built-ins
    /// plus everything `ShaderCompiler.prelude` injects.
    static let builtinSymbols: Set<String> = [
        "gl_FragCoord", "gl_FrontFacing", "gl_PointCoord", "gl_FragDepth",
        // Prelude I/O and textures
        "vUV", "outColor", "uPrev", "uFrames",
        // CEContext members
        "uResolution", "uTime", "uTimeDelta", "uFrameCount", "uHeadIndex", "uFrameNumber",
        // Vision data
        "uPersonMatte", "uFaceMask", "uHandMask",
        "uFaceCount", "uFaceRects", "uHandCount", "uHandInfo", "uHandJoints",
        // Prelude #defines
        "CE_MAX_FACES", "CE_MAX_HANDS", "CE_HAND_JOINTS",
        "CE_WRIST",
        "CE_THUMB_CMC", "CE_THUMB_MP", "CE_THUMB_IP", "CE_THUMB_TIP",
        "CE_INDEX_MCP", "CE_INDEX_PIP", "CE_INDEX_DIP", "CE_INDEX_TIP",
        "CE_MIDDLE_MCP", "CE_MIDDLE_PIP", "CE_MIDDLE_DIP", "CE_MIDDLE_TIP",
        "CE_RING_MCP", "CE_RING_PIP", "CE_RING_DIP", "CE_RING_TIP",
        "CE_LITTLE_MCP", "CE_LITTLE_PIP", "CE_LITTLE_DIP", "CE_LITTLE_TIP",
    ]

    private static func classify(_ word: String) -> TokenKind? {
        if keywords.contains(word) { return .keyword }
        if types.contains(word) { return .type }
        if builtinFunctions.contains(word) { return .builtinFunction }
        if builtinSymbols.contains(word) { return .builtinSymbol }
        return nil
    }

    // MARK: - Tokenizer

    static func tokens(in text: NSString) -> [Token] {
        var tokens: [Token] = []
        let length = text.length
        var i = 0

        while i < length {
            let c = text.character(at: i)

            if c == Self.slash, i + 1 < length {
                let next = text.character(at: i + 1)
                if next == Self.slash {
                    let start = i
                    i += 2
                    while i < length, !isNewline(text.character(at: i)) { i += 1 }
                    appendComment(NSRange(location: start, length: i - start), in: text, to: &tokens)
                    continue
                }
                if next == Self.star {
                    let start = i
                    i += 2
                    while i + 1 < length, !(text.character(at: i) == Self.star && text.character(at: i + 1) == Self.slash) {
                        i += 1
                    }
                    i = i + 1 < length ? i + 2 : length
                    appendComment(NSRange(location: start, length: i - start), in: text, to: &tokens)
                    continue
                }
            }

            if c == Self.hash {
                // Color the directive itself (`#define`, `# if`, ...); the rest
                // of the line is tokenized normally.
                let start = i
                i += 1
                while i < length, isSpaceOrTab(text.character(at: i)) { i += 1 }
                while i < length, isIdentifierChar(text.character(at: i)) { i += 1 }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .preprocessor))
                continue
            }

            if isIdentifierStart(c) {
                let start = i
                while i < length, isIdentifierChar(text.character(at: i)) { i += 1 }
                let word = text.substring(with: NSRange(location: start, length: i - start))
                if let kind = classify(word) {
                    tokens.append(Token(range: NSRange(location: start, length: i - start), kind: kind))
                }
                continue
            }

            if isDigit(c) || (c == Self.dot && i + 1 < length && isDigit(text.character(at: i + 1))) {
                let start = i
                i += 1
                while i < length {
                    let ch = text.character(at: i)
                    if isIdentifierChar(ch) || ch == Self.dot {
                        i += 1
                    } else if ch == Self.plus || ch == Self.minus {
                        // Exponent sign: only part of the literal after e/E.
                        let previous = text.character(at: i - 1)
                        guard previous == Self.lowerE || previous == Self.upperE else { break }
                        i += 1
                    } else {
                        break
                    }
                }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .number))
                continue
            }

            i += 1
        }

        return tokens
    }

    private static func appendComment(_ range: NSRange, in text: NSString, to tokens: inout [Token]) {
        tokens.append(Token(range: range, kind: .comment))
        // `@metadata(...)` runs are re-colored on top of the comment color.
        let limit = NSMaxRange(range)
        var searchRange = range
        while searchRange.length > 0 {
            let found = text.range(of: "@metadata", options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            var end = NSMaxRange(found)
            var j = end
            while j < limit, isSpaceOrTab(text.character(at: j)) { j += 1 }
            if j < limit, text.character(at: j) == Self.openParen {
                var depth = 0
                while j < limit {
                    let ch = text.character(at: j)
                    j += 1
                    if ch == Self.openParen { depth += 1 }
                    if ch == Self.closeParen {
                        depth -= 1
                        if depth == 0 { break }
                    }
                }
                end = j
            }
            tokens.append(Token(range: NSRange(location: found.location, length: end - found.location), kind: .metadata))
            searchRange = NSRange(location: end, length: limit - end)
        }
    }

    /// Whether `location` (a caret position) falls inside a line or block
    /// comment. Used to suppress the completion popup while writing prose.
    static func isInsideComment(_ text: NSString, at location: Int) -> Bool {
        let limit = min(location, text.length)
        var inLineComment = false
        var inBlockComment = false
        var i = 0
        while i < limit {
            let c = text.character(at: i)
            if inLineComment {
                if isNewline(c) { inLineComment = false }
                i += 1
            } else if inBlockComment {
                if c == Self.star, i + 1 < limit, text.character(at: i + 1) == Self.slash {
                    inBlockComment = false
                    i += 2
                } else {
                    i += 1
                }
            } else if c == Self.slash, i + 1 < limit {
                let next = text.character(at: i + 1)
                if next == Self.slash {
                    inLineComment = true
                    i += 2
                } else if next == Self.star {
                    inBlockComment = true
                    i += 2
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return inLineComment || inBlockComment
    }

    // MARK: - Character classes (UTF-16 units)

    static func isIdentifierStart(_ c: unichar) -> Bool {
        (c >= Self.lowerA && c <= Self.lowerZ) || (c >= Self.upperA && c <= Self.upperZ) || c == Self.underscore
    }

    static func isIdentifierChar(_ c: unichar) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }

    static func isDigit(_ c: unichar) -> Bool {
        c >= Self.zero && c <= Self.nine
    }

    private static func isNewline(_ c: unichar) -> Bool {
        c == 0x0A || c == 0x0D || c == 0x85 || c == 0x2028 || c == 0x2029
    }

    private static func isSpaceOrTab(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09
    }

    private static let slash = unichar(UInt8(ascii: "/"))
    private static let star = unichar(UInt8(ascii: "*"))
    private static let hash = unichar(UInt8(ascii: "#"))
    private static let dot = unichar(UInt8(ascii: "."))
    private static let plus = unichar(UInt8(ascii: "+"))
    private static let minus = unichar(UInt8(ascii: "-"))
    private static let lowerE = unichar(UInt8(ascii: "e"))
    private static let upperE = unichar(UInt8(ascii: "E"))
    private static let openParen = unichar(UInt8(ascii: "("))
    private static let closeParen = unichar(UInt8(ascii: ")"))
    private static let underscore = unichar(UInt8(ascii: "_"))
    private static let lowerA = unichar(UInt8(ascii: "a"))
    private static let lowerZ = unichar(UInt8(ascii: "z"))
    private static let upperA = unichar(UInt8(ascii: "A"))
    private static let upperZ = unichar(UInt8(ascii: "Z"))
    private static let zero = unichar(UInt8(ascii: "0"))
    private static let nine = unichar(UInt8(ascii: "9"))
}
