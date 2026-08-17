import Foundation

/// Builds the candidate list for the editor's completion popup: GLSL keywords,
/// types, built-in functions, prelude symbols, and identifiers already present
/// in the document (user variables, `Params` members, helper functions).
enum GLSLCompletion {

    /// Every language- and prelude-level word the editor always offers.
    private static let vocabulary: Set<String> = {
        var words = GLSLSyntaxHighlighter.keywords
        words.formUnion(GLSLSyntaxHighlighter.types)
        words.formUnion(GLSLSyntaxHighlighter.builtinFunctions)
        words.formUnion(GLSLSyntaxHighlighter.builtinSymbols)
        words.formUnion(ShaderReference.completionIdentifiers)
        return words
    }()

    /// Completions for `prefix`, best matches first. Case-sensitive prefix
    /// matches rank above case-insensitive ones; ties sort alphabetically.
    /// An empty prefix (manual invocation) returns the full candidate list.
    static func completions(forPrefix prefix: String, in source: String) -> [String] {
        var candidates = vocabulary
        candidates.formUnion(identifiers(in: source))
        candidates.remove(prefix)

        let matches: [(word: String, caseSensitive: Bool)] = candidates.compactMap { word in
            if prefix.isEmpty || word.hasPrefix(prefix) {
                return (word, true)
            }
            if word.lowercased().hasPrefix(prefix.lowercased()) {
                return (word, false)
            }
            return nil
        }

        return matches
            .sorted {
                if $0.caseSensitive != $1.caseSensitive { return $0.caseSensitive }
                return $0.word.localizedCompare($1.word) == .orderedAscending
            }
            .map(\.word)
    }

    /// Identifiers of length >= 3 appearing anywhere in the document.
    /// Includes words inside comments on purpose: parameter names are
    /// documented in `@metadata` comments and still worth completing.
    private static func identifiers(in source: String) -> Set<String> {
        var result: Set<String> = []
        let text = source as NSString
        let length = text.length
        var i = 0
        while i < length {
            if GLSLSyntaxHighlighter.isIdentifierStart(text.character(at: i)) {
                let start = i
                while i < length, GLSLSyntaxHighlighter.isIdentifierChar(text.character(at: i)) { i += 1 }
                if i - start >= 3 {
                    result.insert(text.substring(with: NSRange(location: start, length: i - start)))
                }
            } else {
                i += 1
            }
        }
        return result
    }
}
