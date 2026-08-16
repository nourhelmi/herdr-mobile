import Foundation

@MainActor
@Observable
final class SettingsStore {
    static let defaultBaseURL = "http://127.0.0.1:8787"
    private static let key = "herdr.baseURL"

    var rawBaseURL: String {
        didSet { UserDefaults.standard.set(rawBaseURL, forKey: Self.key) }
    }

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            rawBaseURL = stored
        } else {
            rawBaseURL = Self.defaultBaseURL
        }
    }

    var baseURL: URL? {
        Self.parse(rawBaseURL)
    }

    static func parse(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}
