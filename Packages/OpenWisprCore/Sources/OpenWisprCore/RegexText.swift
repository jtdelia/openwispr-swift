import Foundation
import Synchronization

private let regexCache = Mutex<[String: NSRegularExpression]>([:])

func regex(_ pattern: String, caseInsensitive: Bool = false, dotAll: Bool = false) -> NSRegularExpression {
    let key = "\(caseInsensitive ? "i" : "")\(dotAll ? "s" : "")/\(pattern)"
    return regexCache.withLock { cache in
        if let cached = cache[key] { return cached }
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        // Patterns are literals in this module; a bad one is a programming error.
        // swiftlint:disable:next force_try
        let compiled = try! NSRegularExpression(pattern: pattern, options: options)
        cache[key] = compiled
        return compiled
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var fullRange: NSRange { NSRange(startIndex..., in: self) }

    func matches(_ pattern: String, caseInsensitive: Bool = false, dotAll: Bool = false) -> Bool {
        regex(pattern, caseInsensitive: caseInsensitive, dotAll: dotAll).firstMatch(in: self, range: fullRange) != nil
    }

    /// Replaces every match with `replacement` taken literally.
    func replacing(pattern: String, with replacement: String, caseInsensitive: Bool = false) -> String {
        regex(pattern, caseInsensitive: caseInsensitive).stringByReplacingMatches(
            in: self, range: fullRange, withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    /// Replaces every match with what `transform` returns for its captures; index 0 is the whole match.
    func replacing(pattern: String, caseInsensitive: Bool = false, transform: ([String?]) -> String) -> String {
        let expression = regex(pattern, caseInsensitive: caseInsensitive)
        let ns = self as NSString
        var result = ""
        var last = 0
        for match in expression.matches(in: self, range: fullRange) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// The captures of the first match, or nil; index 0 is the whole match.
    func firstMatch(_ pattern: String, caseInsensitive: Bool = false) -> [String?]? {
        guard let match = regex(pattern, caseInsensitive: caseInsensitive).firstMatch(in: self, range: fullRange) else { return nil }
        let ns = self as NSString
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    func split(pattern: String) -> [String] {
        let ns = self as NSString
        var parts: [String] = []
        var last = 0
        for match in regex(pattern).matches(in: self, range: fullRange) {
            parts.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            last = match.range.location + match.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }

    /// Length in UTF-16 code units, which is what the TypeScript original measured.
    var utf16Length: Int { utf16.count }

    /// Like JavaScript's `slice`, in UTF-16 code units; negative bounds count from the end.
    func jsSlice(_ start: Int, _ end: Int? = nil) -> String {
        let length = utf16Length
        let resolve = { (index: Int) in index < 0 ? max(0, length + index) : min(index, length) }
        let from = resolve(start)
        let to = resolve(end ?? length)
        guard to > from else { return "" }
        return (self as NSString).substring(with: NSRange(location: from, length: to - from))
    }

    /// Like JavaScript's `lastIndexOf(search, fromIndex)`, in UTF-16 code units; -1 when absent.
    func jsLastIndex(of search: String, from: Int) -> Int {
        let ns = self as NSString
        let limit = min(from + search.utf16Length, ns.length)
        let range = ns.range(of: search, options: .backwards, range: NSRange(location: 0, length: max(0, limit)))
        return range.location == NSNotFound ? -1 : range.location
    }

    var trimmedStart: String {
        String(drop { $0.isWhitespace })
    }

    var trimmedEnd: String {
        var text = self
        while text.last?.isWhitespace == true { text.removeLast() }
        return text
    }
}

func escapeRegex(_ text: String) -> String {
    NSRegularExpression.escapedPattern(for: text)
}

/// The text JSON-encoded as a string literal, like `JSON.stringify`.
func jsonString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
          let encoded = String(data: data, encoding: .utf8)
    else { return "\"\(text)\"" }
    return encoded
}
