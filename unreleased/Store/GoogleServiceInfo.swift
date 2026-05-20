import Foundation

/// Reads keys from `GoogleService-Info.plist` bundled with the app.
enum GoogleServiceInfo {
    private static let plist: [String: Any]? = {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict
    }()

    static var clientID: String? {
        string(for: "CLIENT_ID")
    }

    static var reversedClientID: String? {
        string(for: "REVERSED_CLIENT_ID")
    }

    static func string(for key: String) -> String? {
        guard let value = plist?[key] as? String, !value.isEmpty else { return nil }
        return value
    }
}
