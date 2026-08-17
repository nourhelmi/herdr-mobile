import Foundation

/// Nerd Font / Powerline live in PUA. iOS SF Mono has no glyphs — they tofu as `[?][?]`.
enum UnicodeText {
    static func isPrivateUse(_ value: UInt32) -> Bool {
        (value >= 0xE000 && value <= 0xF8FF)
            || (value >= 0xF0000 && value <= 0xFFFFD)
            || (value >= 0x100000 && value <= 0x10FFFD)
    }

    /// Drop PUA scalars. π, box drawing, emoji, and ASCII stay.
    static func sanitize(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if isPrivateUse(scalar.value) {
                if !output.isEmpty && !output.hasSuffix(" ") { output.append(" ") }
                continue
            }
            output.append(String(scalar))
        }
        return collapseSpaces(output)
    }

    static func displayText(_ raw: String) -> String {
        collapseSeparators(sanitize(raw))
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseSeparators(_ text: String) -> String {
        text.replacingOccurrences(of: " +", with: " · ", options: .regularExpression)
            .replacingOccurrences(of: "(?: · ){2,}", with: " · ", options: .regularExpression)
    }
}
