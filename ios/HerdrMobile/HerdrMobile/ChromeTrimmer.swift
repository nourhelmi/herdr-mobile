import Foundation

/// Conservative Pi TUI chrome trim. Port of sidecar `src/chrome.ts`.
/// Cuts a bottom-anchored `╭`/`┌` … `╰`/`└…┘` box plus trailing lens footer.
/// Unsure → show more.
enum ChromeTrimmer {
    private static let maxBoxSpan = 16
    private static let maxFooter = 8

    static func trim(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3 else { return text }

        let plains = lines.map(plainLine)
        guard let top = plains.lastIndex(where: isBoxTop) else { return text }
        let afterTop = plains.suffix(from: plains.index(after: top))
        guard let bottomOffset = afterTop.firstIndex(where: isBoxBottom) else { return text }
        let bottom = plains.distance(from: plains.startIndex, to: bottomOffset)

        let span = bottom - top + 1
        let trailing = Array(plains.suffix(from: plains.index(after: bottomOffset)))
        if span > maxBoxSpan { return text }
        if trailing.count > maxFooter { return text }
        if !trailing.allSatisfy(isFooterLine) { return text }

        var kept = Array(lines.prefix(top))
        while kept.last == "" { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    private static func plainLine(_ line: String) -> String {
        ANSIStripper.strip(line).replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    private static func isBoxTop(_ plain: String) -> Bool {
        let trimmed = plain.drop(while: { $0 == " " || $0 == "\t" })
        return trimmed.hasPrefix("╭") || trimmed.hasPrefix("┌")
    }

    private static func isBoxBottom(_ plain: String) -> Bool {
        let trimmed = plain.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("╰") { return true }
        return trimmed.range(of: "^└[─┬┴┼─\\s].*┘$", options: .regularExpression) != nil
    }

    private static func isFooterLine(_ plain: String) -> Bool {
        let trimmed = plain.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if trimmed.range(of: "^pi-lens\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if trimmed.range(of: "^(checker|orchestrator)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return plain.hasPrefix(" ") || plain.hasPrefix("\t")
    }
}
