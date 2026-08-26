import Foundation

enum PlaybackQuality: String, CaseIterable, Identifiable, Sendable {
    case standard
    case high
    case original

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .high: "High"
        case .original: "Lossless / Original"
        }
    }

    var detail: String {
        switch self {
        case .standard: "AAC 160 kbps · Recommended"
        case .high: "AAC 256 kbps · Uses more data"
        case .original: "Uploaded source · Highest data usage"
        }
    }
}
