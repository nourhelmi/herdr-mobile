import SwiftUI

/// Field-log palette: olive-black chassis, phosphor working, flare for blocked.
enum HerdrInk {
    static let void = Color(red: 0.043, green: 0.047, blue: 0.039)
    static let panel = Color(red: 0.078, green: 0.086, blue: 0.071)
    static let inset = Color(red: 0.110, green: 0.118, blue: 0.098)
    static let rule = Color(red: 0.216, green: 0.231, blue: 0.188)
    static let paper = Color(red: 0.910, green: 0.898, blue: 0.835)
    static let mute = Color(red: 0.620, green: 0.631, blue: 0.557)
    static let phosphor = Color(red: 0.784, green: 0.961, blue: 0.259)
    static let flare = Color(red: 1.000, green: 0.302, blue: 0.180)
    static let hush = Color(red: 0.541, green: 0.561, blue: 0.478)
    static let tide = Color(red: 0.369, green: 0.784, blue: 0.753)
    static let ash = Color(red: 0.420, green: 0.420, blue: 0.400)
}

enum HerdrType {
    static let display = Font.system(.title3, design: .serif).weight(.semibold)
    static let section = Font.system(size: 12, weight: .semibold, design: .serif)
    static let body = Font.system(.body, design: .default)
    static let meta = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let key = Font.system(size: 13, weight: .semibold, design: .monospaced)
}

enum AgentState {
    /// blocked first — the Home list is a radar, not an alphabet.
    static func rank(_ raw: String) -> Int {
        switch raw.lowercased() {
        case "blocked": return 0
        case "working": return 1
        case "idle": return 2
        case "done": return 3
        default: return 4
        }
    }

    static func color(_ raw: String) -> Color {
        switch raw.lowercased() {
        case "blocked": return HerdrInk.flare
        case "working": return HerdrInk.phosphor
        case "idle": return HerdrInk.hush
        case "done": return HerdrInk.tide
        default: return HerdrInk.ash
        }
    }

    static func label(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed.lowercased()
    }
}
