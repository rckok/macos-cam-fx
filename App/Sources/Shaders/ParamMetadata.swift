import Foundation

/// Inspector hints declared in the shader as a preceding-line decorator:
/// `// @metadata(min=0.0 max=1000.0 default=1.0 color=true)`
struct ParamMetadata: Equatable {
    var minimum: Double?
    var maximum: Double?
    var defaultValue: Double?
    /// When set, `true` shows a color picker for vec3/vec4; omitted or false
    /// keeps per-component sliders.
    var isColor: Bool?
}

enum ParamMetadataParser {
    private static let metadataLine = try! NSRegularExpression(
        pattern: #"^\s*//\s*@metadata\s*\((.*)\)\s*$"#
    )
    private static let keyValue = try! NSRegularExpression(
        pattern: #"([A-Za-z]+)(?:\s*=\s*([A-Za-z0-9.+-]+))?"#
    )
    private static let uniformParams = try! NSRegularExpression(
        pattern: #"\buniform\s+Params\b"#
    )
    private static let memberDecl = try! NSRegularExpression(
        pattern: #"^(?:layout\s*\([^)]*\)\s+)?(float|int|uint|bool|vec[234]|ivec[234]|uvec[234]|bvec[234])\s+(\w+)\s*(?:\[[^\]]*\])?\s*;"#
    )

    /// Maps `Params` member names to metadata from the decorator on the
    /// preceding non-empty line. Blank lines in between are ignored; any
    /// other comment or code clears a pending decorator.
    static func parse(from source: String) -> [String: ParamMetadata] {
        let lines = source.components(separatedBy: .newlines)
        guard let openIndex = paramsBlockOpenIndex(in: lines) else { return [:] }

        var result: [String: ParamMetadata] = [:]
        var pending: ParamMetadata?
        var depth = 1

        let firstRemainder = contentAfterOpeningBrace(lines[openIndex])
        let remainderLines = [firstRemainder] + lines[(openIndex + 1)...]

        for rawLine in remainderLines {
            if depth <= 0 { break }

            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if let metadata = parseMetadataLine(trimmed) {
                pending = metadata
                continue
            }

            if trimmed.hasPrefix("//") {
                pending = nil
                continue
            }

            let code = strippedCode(trimmed)
            if code.isEmpty {
                pending = nil
                continue
            }

            if let name = memberName(in: code) {
                if let pending {
                    result[name] = pending
                }
            }
            pending = nil

            depth += braceDelta(code)
        }

        return result
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

    private static func parseMetadataLine(_ trimmed: String) -> ParamMetadata? {
        guard let body = firstCapture(metadataLine, in: trimmed, group: 1) else { return nil }
        var metadata = ParamMetadata()
        var found = false
        let nsBody = body as NSString
        keyValue.enumerateMatches(in: body, range: NSRange(location: 0, length: nsBody.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let key = nsBody.substring(with: match.range(at: 1)).lowercased()
            let rawValue: String? = {
                guard match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound else {
                    return nil
                }
                return nsBody.substring(with: match.range(at: 2))
            }()
            switch key {
            case "min":
                guard let value = rawValue.flatMap(Double.init) else { return }
                metadata.minimum = value
                found = true
            case "max":
                guard let value = rawValue.flatMap(Double.init) else { return }
                metadata.maximum = value
                found = true
            case "default":
                guard let value = rawValue.flatMap(Double.init) else { return }
                metadata.defaultValue = value
                found = true
            case "color":
                guard let isColor = parseBool(rawValue) else { return }
                metadata.isColor = isColor
                found = true
            default:
                break
            }
        }
        return found ? metadata : nil
    }

    /// Bare `color` means true. Accepts true/false, yes/no, on/off, 1/0.
    private static func parseBool(_ raw: String?) -> Bool? {
        guard let raw else { return true }
        switch raw.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
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
}
