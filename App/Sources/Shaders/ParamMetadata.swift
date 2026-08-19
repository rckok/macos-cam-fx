import Foundation

/// Inspector hints declared in the shader as a preceding-line decorator:
/// `// @metadata(min=0.0 max=1000.0 default=1.0 color=true)`
/// Vector uniforms accept GLSL constructors: `min=vec3(0) max=vec3(1, 2, 1)`.
struct ParamMetadata: Equatable {
    var minimum: [Double]?
    var maximum: [Double]?
    var defaultValue: [Double]?
    /// When set, `true` shows a color picker for vec3/vec4; omitted or false
    /// keeps per-component sliders.
    var isColor: Bool?
    /// 1-based line of the `@metadata` decorator in user source.
    var line: Int?
}

struct ParamMetadataParseResult {
    var metadata: [String: ParamMetadata]
    var diagnostics: [ShaderDiagnostic]
}

enum ParamMetadataParser {
    private static let metadataLine = try! NSRegularExpression(
        pattern: #"^\s*//\s*@metadata\s*\((.*)\)\s*$"#
    )
    private static let metadataPrefix = try! NSRegularExpression(
        pattern: #"^\s*//\s*@metadata\b"#
    )
    private static let uniformParams = try! NSRegularExpression(
        pattern: #"\buniform\s+Params\b"#
    )
    private static let memberDecl = try! NSRegularExpression(
        pattern: #"^(?:layout\s*\([^)]*\)\s+)?(float|int|uint|bool|vec[234]|ivec[234]|uvec[234]|bvec[234])\s+(\w+)\s*(?:\[[^\]]*\])?\s*;"#
    )

    /// Maps `Params` member names to metadata from the decorator on the
    /// preceding non-empty line. Blank lines in between are ignored; any
    /// other comment or code clears a pending decorator. Constructor and
    /// syntax problems are reported as diagnostics on the decorator line.
    static func parse(from source: String) -> ParamMetadataParseResult {
        let lines = source.components(separatedBy: .newlines)
        guard let openIndex = paramsBlockOpenIndex(in: lines) else {
            return ParamMetadataParseResult(metadata: [:], diagnostics: [])
        }

        var result: [String: ParamMetadata] = [:]
        var diagnostics: [ShaderDiagnostic] = []
        var pending: ParamMetadata?
        var depth = 1

        func consume(_ rawLine: String, lineNumber: Int) {
            if depth <= 0 { return }

            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return }

            switch parseMetadataLine(trimmed, line: lineNumber) {
            case .notMetadata:
                if matches(metadataPrefix, in: trimmed) {
                    diagnostics.append(ShaderDiagnostic(
                        line: lineNumber,
                        message: "malformed @metadata decorator",
                        severity: .error
                    ))
                    pending = nil
                    return
                }
            case .failed(let message):
                diagnostics.append(ShaderDiagnostic(line: lineNumber, message: message, severity: .error))
                pending = nil
                return
            case .parsed(let metadata):
                pending = metadata
                return
            }

            if trimmed.hasPrefix("//") {
                pending = nil
                return
            }

            let code = strippedCode(trimmed)
            if code.isEmpty {
                pending = nil
                return
            }

            if let name = memberName(in: code) {
                if let pending {
                    result[name] = pending
                }
            }
            pending = nil
            depth += braceDelta(code)
        }

        consume(contentAfterOpeningBrace(lines[openIndex]), lineNumber: openIndex + 1)
        var index = openIndex + 1
        while index < lines.count, depth > 0 {
            consume(lines[index], lineNumber: index + 1)
            index += 1
        }

        return ParamMetadataParseResult(metadata: result, diagnostics: diagnostics)
    }

    /// Broadcast a scalar or accept an exact component match.
    static func alignedComponents(
        _ values: [Double],
        expected: Int,
        key: String,
        type: String,
        name: String,
        line: Int?
    ) -> Result<[Double], ShaderDiagnostic> {
        if values.count == 1 {
            return .success(Array(repeating: values[0], count: expected))
        }
        if values.count == expected {
            return .success(values)
        }
        return .failure(ShaderDiagnostic(
            line: line,
            message: "@metadata \(key) for \(type) \(name) has \(values.count) component\(values.count == 1 ? "" : "s"), expected \(expected)",
            severity: .error
        ))
    }

    private static func paramsBlockOpenIndex(in lines: [String]) -> Int? {
        var awaitingBrace = false
        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }

            let code = strippedCode(trimmed)
            if awaitingBrace {
                if code.contains("{") { return index }
                if !code.isEmpty { awaitingBrace = false }
                continue
            }

            if matches(uniformParams, in: code) {
                if code.contains("{") { return index }
                awaitingBrace = true
            }
        }
        return nil
    }

    private static func contentAfterOpeningBrace(_ line: String) -> String {
        let codeLine = strippedCode(line)
        guard let brace = codeLine.firstIndex(of: "{") else { return "" }
        return String(codeLine[codeLine.index(after: brace)...])
    }

    private enum LineResult {
        case notMetadata
        case parsed(ParamMetadata)
        case failed(String)
    }

    private static func parseMetadataLine(_ trimmed: String, line: Int) -> LineResult {
        guard let body = firstCapture(metadataLine, in: trimmed, group: 1) else { return .notMetadata }
        do {
            let fields = try parseMetadataBody(body)
            var metadata = ParamMetadata(line: line)
            var found = false
            for field in fields {
                switch field.key {
                case "min":
                    metadata.minimum = try numericComponents(field, key: "min")
                    found = true
                case "max":
                    metadata.maximum = try numericComponents(field, key: "max")
                    found = true
                case "default":
                    metadata.defaultValue = try numericComponents(field, key: "default")
                    found = true
                case "color":
                    metadata.isColor = try boolValue(field)
                    found = true
                default:
                    break
                }
            }
            guard found else {
                return .failed("@metadata has no recognized keys (min, max, default, color)")
            }
            return .parsed(metadata)
        } catch let error as MetadataParseError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private struct Field {
        var key: String
        var kind: FieldKind
    }

    private enum FieldKind {
        case flag
        case bool(Bool)
        case number(Double)
        case vector([Double])
    }

    private struct MetadataParseError: Error {
        var message: String
    }

    private static func numericComponents(_ field: Field, key: String) throws -> [Double] {
        switch field.kind {
        case .number(let value):
            try requireFinite(value, key: key)
            return [value]
        case .vector(let values):
            for value in values { try requireFinite(value, key: key) }
            return values
        case .flag:
            throw MetadataParseError(message: "@metadata \(key) is missing a value")
        case .bool:
            throw MetadataParseError(message: "@metadata \(key) must be a number or GLSL constructor, not a boolean")
        }
    }

    private static func boolValue(_ field: Field) throws -> Bool {
        switch field.kind {
        case .flag:
            return true
        case .bool(let value):
            return value
        case .number(let value) where value == 0 || value == 1:
            return value == 1
        default:
            throw MetadataParseError(message: "@metadata color must be true, false, 1, or 0")
        }
    }

    private static func requireFinite(_ value: Double, key: String) throws {
        guard value.isFinite else {
            throw MetadataParseError(message: "@metadata \(key) must be a finite number")
        }
    }

    private static func parseMetadataBody(_ body: String) throws -> [Field] {
        var reader = Reader(body)
        var fields: [Field] = []
        reader.skipWhitespace()
        while !reader.isAtEnd {
            guard let key = reader.readIdentifier() else {
                throw MetadataParseError(message: "unexpected token in @metadata")
            }
            reader.skipWhitespace()
            if reader.consume("=") {
                reader.skipWhitespace()
                let kind = try readFieldValue(&reader)
                fields.append(Field(key: key.lowercased(), kind: kind))
            } else {
                fields.append(Field(key: key.lowercased(), kind: .flag))
            }
            reader.skipWhitespace()
        }
        return fields
    }

    private static func readFieldValue(_ reader: inout Reader) throws -> FieldKind {
        if let ident = reader.readIdentifier() {
            reader.skipWhitespace()
            if reader.peek() == "(" {
                let components = try readConstructor(&reader, name: ident)
                return .vector(components)
            }
            if let flag = parseBoolToken(ident) {
                return .bool(flag)
            }
            throw MetadataParseError(message: "unsupported @metadata value '\(ident)'")
        }
        if let number = reader.readNumber() {
            return .number(number)
        }
        throw MetadataParseError(message: "expected a number or GLSL constructor in @metadata")
    }

    private static func readConstructor(_ reader: inout Reader, name: String) throws -> [Double] {
        guard reader.consume("(") else {
            throw MetadataParseError(message: "expected '(' after \(name)")
        }
        reader.skipWhitespace()
        var args: [[Double]] = []
        if reader.peek() != ")" {
            while true {
                reader.skipWhitespace()
                args.append(try readConstructorArgument(&reader))
                reader.skipWhitespace()
                if reader.consume(",") {
                    reader.skipWhitespace()
                    if reader.peek() == ")" {
                        throw MetadataParseError(message: "trailing comma in \(name)()")
                    }
                    continue
                }
                break
            }
        }
        guard reader.consume(")") else {
            throw MetadataParseError(message: "unclosed \(name)() in @metadata")
        }
        return try expandConstructor(name, arguments: args)
    }

    private static func readConstructorArgument(_ reader: inout Reader) throws -> [Double] {
        if let ident = reader.readIdentifier() {
            reader.skipWhitespace()
            if reader.peek() == "(" {
                return try readConstructor(&reader, name: ident)
            }
            throw MetadataParseError(message: "unsupported constructor argument '\(ident)'")
        }
        if let number = reader.readNumber() {
            return [number]
        }
        throw MetadataParseError(message: "expected a number or GLSL constructor argument")
    }

    private static func expandConstructor(_ name: String, arguments: [[Double]]) throws -> [Double] {
        guard let arity = constructorArity(name) else {
            throw MetadataParseError(message: "unsupported constructor '\(name)()' in @metadata")
        }
        let flat = arguments.flatMap { $0 }
        if flat.count == 1 {
            return Array(repeating: flat[0], count: arity)
        }
        if flat.count == arity {
            return flat
        }
        throw MetadataParseError(
            message: "\(name)() expects 1 or \(arity) component\(arity == 1 ? "" : "s"), got \(flat.count)"
        )
    }

    private static func constructorArity(_ name: String) -> Int? {
        switch name {
        case "float", "int", "uint", "bool": return 1
        case "vec2", "ivec2", "uvec2", "bvec2": return 2
        case "vec3", "ivec3", "uvec3", "bvec3": return 3
        case "vec4", "ivec4", "uvec4", "bvec4": return 4
        default: return nil
        }
    }

    private static func parseBoolToken(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: return nil
        }
    }

    private static func memberName(in code: String) -> String? {
        firstCapture(memberDecl, in: code, group: 2)
    }

    private static func strippedCode(_ line: String) -> String {
        if let comment = line.range(of: "//") {
            return String(line[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func braceDelta(_ code: String) -> Int {
        code.reduce(0) { count, character in
            switch character {
            case "{": count + 1
            case "}": count - 1
            default: count
            }
        }
    }

    private static func matches(_ regex: NSRegularExpression, in string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    private static func firstCapture(_ regex: NSRegularExpression, in string: String, group: Int) -> String? {
        let nsString = string as NSString
        guard let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: nsString.length)),
              match.numberOfRanges > group,
              match.range(at: group).location != NSNotFound
        else { return nil }
        return nsString.substring(with: match.range(at: group))
    }

    private struct Reader {
        let source: String
        var index: String.Index

        init(_ source: String) {
            self.source = source
            self.index = source.startIndex
        }

        var isAtEnd: Bool { index >= source.endIndex }

        func peek() -> Character? {
            isAtEnd ? nil : source[index]
        }

        mutating func advance() {
            guard !isAtEnd else { return }
            index = source.index(after: index)
        }

        mutating func skipWhitespace() {
            while let c = peek(), c.isWhitespace { advance() }
        }

        mutating func consume(_ character: Character) -> Bool {
            guard peek() == character else { return false }
            advance()
            return true
        }

        mutating func readIdentifier() -> String? {
            guard let first = peek(), first.isLetter || first == "_" else { return nil }
            let start = index
            advance()
            while let c = peek(), c.isLetter || c.isNumber || c == "_" { advance() }
            return String(source[start..<index])
        }

        mutating func readNumber() -> Double? {
            let start = index
            if peek() == "+" || peek() == "-" { advance() }

            var sawDigit = false
            var sawDot = false
            while let c = peek() {
                if c.isNumber {
                    sawDigit = true
                    advance()
                } else if c == ".", !sawDot {
                    sawDot = true
                    advance()
                } else {
                    break
                }
            }

            if let exp = peek(), exp == "e" || exp == "E" {
                let expStart = index
                advance()
                if peek() == "+" || peek() == "-" { advance() }
                var expDigit = false
                while let c = peek(), c.isNumber {
                    expDigit = true
                    advance()
                }
                if !expDigit { index = expStart }
            }

            guard sawDigit else {
                index = start
                return nil
            }
            return Double(source[start..<index])
        }
    }
}
