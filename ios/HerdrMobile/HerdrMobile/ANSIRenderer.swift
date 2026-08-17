import SwiftUI
import UIKit

/// CSI SGR → AttributedString. Non-SGR escapes are dropped. PUA glyphs are dropped.
enum ANSIRenderer {
    private static let maxSGRParameters = 64
    private static let maxSGRScalars = 256

    static func attributed(_ raw: String, defaultColor: Color = HerdrInk.paper) -> AttributedString {
        var output = AttributedString()
        var style = Style()
        var index = raw.startIndex

        while index < raw.endIndex {
            let scalar = raw[index]
            if scalar == "\u{001B}" {
                let next = raw.index(after: index)
                if next < raw.endIndex, raw[next] == "[",
                   let consumed = readSGR(raw, from: raw.index(after: next)) {
                    applySGR(consumed.params, to: &style)
                    index = consumed.end
                    continue
                }
                index = ANSIStripper.skipEscape(raw, from: next)
                continue
            }
            if scalar == "\u{009B}" {
                if let consumed = readSGR(raw, from: raw.index(after: index)) {
                    applySGR(consumed.params, to: &style)
                    index = consumed.end
                    continue
                }
                index = raw.index(after: index)
                continue
            }
            if scalar == "\u{009D}" {
                index = ANSIStripper.skipOSC(raw, from: raw.index(after: index))
                continue
            }
            if isDroppedControl(scalar) {
                index = raw.index(after: index)
                continue
            }
            if scalar == "\r" {
                index = raw.index(after: index)
                continue
            }

            var chunk = ""
            while index < raw.endIndex {
                let current = raw[index]
                if current == "\u{001B}" || current == "\u{009B}" || current == "\u{009D}" { break }
                if isDroppedControl(current) { break }
                if current == "\r" { break }
                let value = current.unicodeScalars.first?.value ?? 0
                if UnicodeText.isPrivateUse(value) {
                    if !chunk.isEmpty && !chunk.hasSuffix(" ") { chunk.append(" ") }
                } else {
                    chunk.append(current)
                }
                index = raw.index(after: index)
            }
            if !chunk.isEmpty {
                output.append(attributed(chunk, style: style, defaultColor: defaultColor))
            }
        }
        return output
    }

    private struct Style {
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var foreground: Color?
        var background: Color?
    }

    private static func attributed(_ text: String, style: Style, defaultColor: Color) -> AttributedString {
        // NS attributes avoid Swift 6 KeyPath-Sendable warnings on AttributedString setters.
        var color = style.foreground ?? defaultColor
        if style.dim { color = color.opacity(0.65) }
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor(color),
        ]
        if let background = style.background {
            attributes[.backgroundColor] = UIColor(background)
        }
        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        var traits = UIFontDescriptor.SymbolicTraits()
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        let base = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        if let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
            attributes[.font] = UIFont(descriptor: descriptor, size: 12)
        }
        return AttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func applySGR(_ params: [Int], to style: inout Style) {
        if params.isEmpty {
            style = Style()
            return
        }
        var index = 0
        while index < params.count {
            let code = params[index]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22:
                style.bold = false
                style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 39: style.foreground = nil
            case 49: style.background = nil
            case 30...37: style.foreground = ansi16(code - 30, bright: false)
            case 90...97: style.foreground = ansi16(code - 90, bright: true)
            case 40...47: style.background = ansi16(code - 40, bright: false)
            case 100...107: style.background = ansi16(code - 100, bright: true)
            case 38, 48:
                if let color = readExtendedColor(params, from: &index) {
                    if code == 38 { style.foreground = color } else { style.background = color }
                }
            default:
                break
            }
            index += 1
        }
    }

    private static func readExtendedColor(_ params: [Int], from index: inout Int) -> Color? {
        guard index + 1 < params.count else { return nil }
        let mode = params[index + 1]
        if mode == 5, index + 2 < params.count {
            index += 2
            return xterm256(params[index])
        }
        if mode == 2, index + 4 < params.count {
            let red = params[index + 2]
            let green = params[index + 3]
            let blue = params[index + 4]
            index += 4
            return Color(
                red: Double(clampedByte(red)) / 255,
                green: Double(clampedByte(green)) / 255,
                blue: Double(clampedByte(blue)) / 255
            )
        }
        return nil
    }

    private static func readSGR(_ raw: String, from index: String.Index) -> (params: [Int], end: String.Index)? {
        var cursor = index
        var token = ""
        var params: [Int] = []
        var scalarCount = 0
        while cursor < raw.endIndex {
            scalarCount += 1
            guard scalarCount <= maxSGRScalars else { return nil }
            let value = raw[cursor].unicodeScalars.first?.value ?? 0
            if value >= 0x40 && value <= 0x7E {
                if !token.isEmpty {
                    guard params.count < maxSGRParameters else { return nil }
                    params.append(Int(token) ?? 0)
                }
                let end = raw.index(after: cursor)
                return value == 0x6D ? (params, end) : nil
            }
            if raw[cursor] == ";" {
                guard params.count < maxSGRParameters else { return nil }
                params.append(Int(token) ?? 0)
                token = ""
            } else if raw[cursor].isNumber {
                token.append(raw[cursor])
            }
            cursor = raw.index(after: cursor)
        }
        return nil
    }

    private static func ansi16(_ index: Int, bright: Bool) -> Color {
        let palette: [(Double, Double, Double)] = [
            (0.00, 0.00, 0.00),
            (0.80, 0.00, 0.00),
            (0.00, 0.80, 0.00),
            (0.80, 0.80, 0.00),
            (0.00, 0.45, 0.80),
            (0.80, 0.00, 0.80),
            (0.00, 0.80, 0.80),
            (0.75, 0.75, 0.75),
        ]
        let brightPalette: [(Double, Double, Double)] = [
            (0.50, 0.50, 0.50),
            (1.00, 0.30, 0.30),
            (0.30, 1.00, 0.30),
            (1.00, 1.00, 0.30),
            (0.40, 0.70, 1.00),
            (1.00, 0.40, 1.00),
            (0.30, 1.00, 1.00),
            (1.00, 1.00, 1.00),
        ]
        let rgb = (bright ? brightPalette : palette)[min(max(index, 0), 7)]
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    private static func xterm256(_ index: Int) -> Color {
        let bounded = min(max(index, 0), 255)
        if bounded < 16 { return ansi16(bounded % 8, bright: bounded >= 8) }
        if bounded >= 232 {
            let value = Double(8 + (bounded - 232) * 10) / 255
            return Color(red: value, green: value, blue: value)
        }
        let cube = bounded - 16
        let levels: [Double] = [0, 95, 135, 175, 215, 255].map { $0 / 255 }
        return Color(
            red: levels[cube / 36],
            green: levels[(cube % 36) / 6],
            blue: levels[cube % 6]
        )
    }

    private static func clampedByte(_ value: Int) -> Int {
        min(max(value, 0), 255)
    }

    private static func isDroppedControl(_ scalar: Character) -> Bool {
        guard let value = scalar.unicodeScalars.first?.value, value < 0x20 else { return false }
        return value != 0x09 && value != 0x0A && value != 0x0D
    }
}
