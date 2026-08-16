import Foundation

/// Hand-rolled CSI/OSC/C1 stripper. Sidecar `format=text` can still leak escapes.
enum ANSIStripper {
    static func displayText(_ raw: String) -> String {
        normalizeNewlines(strip(raw))
    }

    static func strip(_ raw: String) -> String {
        var output = ""
        output.reserveCapacity(raw.count)
        var index = raw.startIndex

        while index < raw.endIndex {
            let scalar = raw[index]
            if scalar == "\u{001B}" {
                index = skipEscape(raw, from: raw.index(after: index))
                continue
            }
            if scalar == "\u{009B}" {
                index = skipCSI(raw, from: raw.index(after: index))
                continue
            }
            if scalar == "\u{009D}" {
                index = skipOSC(raw, from: raw.index(after: index))
                continue
            }
            if isDroppedControl(scalar) {
                index = raw.index(after: index)
                continue
            }
            output.append(scalar)
            index = raw.index(after: index)
        }
        return output
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func isDroppedControl(_ scalar: Character) -> Bool {
        guard let value = scalar.unicodeScalars.first?.value, value < 0x20 else { return false }
        return value != 0x09 && value != 0x0A && value != 0x0D
    }

    /// ESC already consumed. Advances past CSI / OSC / nF / single-byte sequences.
    private static func skipEscape(_ raw: String, from index: String.Index) -> String.Index {
        guard index < raw.endIndex else { return index }
        switch raw[index] {
        case "[":
            return skipCSI(raw, from: raw.index(after: index))
        case "]":
            return skipOSC(raw, from: raw.index(after: index))
        case "P", "^", "_":
            return skipStringTerminated(raw, from: raw.index(after: index))
        case "(" , ")", "*", "+":
            let after = raw.index(after: index)
            return after < raw.endIndex ? raw.index(after: after) : after
        default:
            return raw.index(after: index)
        }
    }

    /// CSI final byte is 0x40...0x7E.
    private static func skipCSI(_ raw: String, from index: String.Index) -> String.Index {
        var cursor = index
        while cursor < raw.endIndex {
            let value = raw[cursor].unicodeScalars.first?.value ?? 0
            cursor = raw.index(after: cursor)
            if value >= 0x40 && value <= 0x7E { break }
        }
        return cursor
    }

    /// OSC ends at BEL or ST (`ESC \`).
    private static func skipOSC(_ raw: String, from index: String.Index) -> String.Index {
        skipStringTerminated(raw, from: index)
    }

    private static func skipStringTerminated(_ raw: String, from index: String.Index) -> String.Index {
        var cursor = index
        while cursor < raw.endIndex {
            let scalar = raw[cursor]
            if scalar == "\u{0007}" {
                return raw.index(after: cursor)
            }
            if scalar == "\u{001B}" {
                let next = raw.index(after: cursor)
                if next < raw.endIndex, raw[next] == "\\" {
                    return raw.index(after: next)
                }
            }
            cursor = raw.index(after: cursor)
        }
        return cursor
    }
}
